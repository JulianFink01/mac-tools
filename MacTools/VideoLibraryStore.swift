import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class VideoLibraryStore: ObservableObject {
    static let shared = VideoLibraryStore()

    nonisolated static let appSupportDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0].appendingPathComponent("LiveWallpaper", isDirectory: true)

    nonisolated static let videosDirectory = appSupportDirectory.appendingPathComponent("Videos", isDirectory: true)
    nonisolated static let thumbnailsDirectory = appSupportDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
    nonisolated static let libraryURL = appSupportDirectory.appendingPathComponent("library.json", isDirectory: false)

    @Published private(set) var videos: [WallpaperVideo] = []
    @Published var errorMessage: String?
    /// Export progress per video while an optimized copy is being written.
    @Published private(set) var optimization: [UUID: Double] = [:]

    private var removalSubscription: AnyCancellable?
    private let fileManager: FileManager
    nonisolated private static let supportedExtensions = Set(["mp4", "mov", "m4v"])

    private struct LibraryFile: Codable {
        var videos: [WallpaperVideo]
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        ensureDirectoriesExist()
        loadLibrary()
        removalSubscription = FileActions.shared.removals.sink { [weak self] change in
            guard let self else { return }
            let paths = change.paths.map(DiskScanner.canonicalPath)
            let oldCount = self.videos.count
            self.videos.removeAll { video in
                let path = DiskScanner.canonicalPath(video.fileURL.path)
                return paths.contains { path == $0 || path.hasPrefix($0 + "/") }
            }
            if self.videos.count != oldCount { self.saveLibrary() }
        }
    }

    func video(with id: UUID?) -> WallpaperVideo? {
        guard let id else { return nil }
        return videos.first { $0.id == id }
    }

    func importVideos(from urls: [URL]) async -> [WallpaperVideo] {
        errorMessage = nil
        var importedVideos: [WallpaperVideo] = []

        for sourceURL in urls {
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let imported = try await importVideo(from: sourceURL)
                importedVideos.append(imported)
            } catch {
                errorMessage = "Could not import \(sourceURL.lastPathComponent): \(error.localizedDescription)"
            }
        }

        if !importedVideos.isEmpty {
            videos.insert(contentsOf: importedVideos, at: 0)
            saveLibrary()
        }

        return importedVideos
    }

    func remove(_ video: WallpaperVideo) {
        errorMessage = nil
        var removed: [String] = []
        do {
            if let optimized = video.optimizedURL, fileManager.fileExists(atPath: optimized.path) {
                try fileManager.removeItem(at: optimized)
                removed.append(optimized.path)
            }
            if fileManager.fileExists(atPath: video.fileURL.path) {
                try fileManager.removeItem(at: video.fileURL)
            }
            removed.append(video.fileURL.path)
            videos.removeAll { $0.id == video.id }
            saveLibrary()
            if let thumbnailURL = video.thumbnailURL,
               fileManager.fileExists(atPath: thumbnailURL.path) {
                try fileManager.removeItem(at: thumbnailURL)
                removed.append(thumbnailURL.path)
            }
        } catch {
            errorMessage = "Entfernen fehlgeschlagen für \(video.displayName): \(error.localizedDescription)"
        }
        FileActions.shared.recordRemoval(paths: removed)
    }

    /// Encodes a copy for this Mac's displays and plays it from then on. The
    /// original file stays untouched and returns as soon as the copy is removed.
    func optimize(_ video: WallpaperVideo) async {
        guard optimization[video.id] == nil, videos.contains(where: { $0.id == video.id }) else { return }
        errorMessage = nil
        guard let target = await WallpaperOptimizer.proposedTarget(for: video.fileURL) else {
            errorMessage = "„\(video.displayName)“ passt bereits zu deinen Bildschirmen."
            return
        }
        optimization[video.id] = 0
        let destination = Self.videosDirectory.appendingPathComponent(video.id.uuidString + "-optimized.mp4", isDirectory: false)
        let source = video.fileURL
        let id = video.id
        do {
            try await WallpaperOptimizer.export(source: source, to: destination, target: target) { [weak self] value in
                Task { @MainActor in
                    guard let self, self.optimization[id] != nil else { return }
                    self.optimization[id] = min(1, max(0, value))
                }
            }
            let bytes = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)??.int64Value
            if let index = videos.firstIndex(where: { $0.id == id }) {
                removeOptimizedFile(of: videos[index], keeping: destination)
                videos[index].optimizedFileName = destination.lastPathComponent
                videos[index].optimizedWidth = target.width
                videos[index].optimizedHeight = target.height
                videos[index].optimizedFrameRate = target.frameRate
                videos[index].optimizedBytes = bytes
                saveLibrary()
            } else {
                try? fileManager.removeItem(at: destination)
            }
        } catch is CancellationError {
            try? fileManager.removeItem(at: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            errorMessage = "Die optimierte Kopie konnte nicht erstellt werden: \(error.localizedDescription)"
        }
        optimization[id] = nil
    }

    /// Returns playback to the original file and deletes the copy.
    func removeOptimized(_ video: WallpaperVideo) {
        guard let index = videos.firstIndex(where: { $0.id == video.id }) else { return }
        removeOptimizedFile(of: videos[index], keeping: nil)
        videos[index].optimizedFileName = nil
        videos[index].optimizedWidth = nil
        videos[index].optimizedHeight = nil
        videos[index].optimizedFrameRate = nil
        videos[index].optimizedBytes = nil
        saveLibrary()
    }

    private func removeOptimizedFile(of video: WallpaperVideo, keeping: URL?) {
        guard let url = video.optimizedURL, url != keeping, fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    func randomVideo(excluding excludedID: UUID? = nil) -> WallpaperVideo? {
        let candidates = videos.filter { $0.id != excludedID }
        return (candidates.isEmpty ? videos : candidates).randomElement()
    }

    private func ensureDirectoriesExist() {
        do {
            try fileManager.createDirectory(at: Self.videosDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: Self.thumbnailsDirectory, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Could not create application support directories: \(error.localizedDescription)"
        }
    }

    private func loadLibrary() {
        guard fileManager.fileExists(atPath: Self.libraryURL.path) else {
            videos = []
            return
        }

        do {
            let data = try Data(contentsOf: Self.libraryURL)
            let loadedVideos = try JSONDecoder.liveWallpaper.decode(LibraryFile.self, from: data).videos
            videos = loadedVideos.filter { fileManager.fileExists(atPath: $0.fileURL.path) }.map { video in
                guard let optimized = video.optimizedURL, !fileManager.fileExists(atPath: optimized.path) else { return video }
                var value = video
                value.optimizedFileName = nil; value.optimizedWidth = nil
                value.optimizedHeight = nil; value.optimizedFrameRate = nil; value.optimizedBytes = nil
                return value
            }

            if videos.count != loadedVideos.count {
                saveLibrary()
                errorMessage = "Einige gespeicherte Videos wurden nicht mehr gefunden und aus der Bibliothek entfernt."
            }
        } catch {
            videos = []
            errorMessage = "Could not read library.json: \(error.localizedDescription)"
        }
    }

    private func saveLibrary() {
        do {
            let data = try JSONEncoder.liveWallpaper.encode(LibraryFile(videos: videos))
            try data.write(to: Self.libraryURL, options: [.atomic])
        } catch {
            errorMessage = "Could not save library.json: \(error.localizedDescription)"
        }
    }

    private func importVideo(from sourceURL: URL) async throws -> WallpaperVideo {
        try await Task.detached(priority: .userInitiated) {
            try Self.importVideoSynchronously(from: sourceURL)
        }.value
    }

    nonisolated private static func importVideoSynchronously(from sourceURL: URL) throws -> WallpaperVideo {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension) else {
            throw ImportError.unsupportedFileType
        }

        let id = UUID()
        let destinationFileName = "\(id.uuidString).\(fileExtension)"
        let destinationURL = Self.videosDirectory.appendingPathComponent(destinationFileName, isDirectory: false)
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        guard fileManager.fileExists(atPath: destinationURL.path) else {
            throw ImportError.copyFailed
        }

        let asset = AVURLAsset(url: destinationURL)
        let duration = try loadDuration(for: asset)
        guard duration.seconds.isFinite, duration.seconds > 0 else {
            try? fileManager.removeItem(at: destinationURL)
            throw ImportError.invalidVideo
        }

        let thumbnailFileName = try generateThumbnail(for: asset, duration: duration.seconds, id: id)
        return WallpaperVideo(
            id: id,
            displayName: sourceURL.deletingPathExtension().lastPathComponent,
            fileName: destinationFileName,
            originalFileName: sourceURL.lastPathComponent,
            thumbnailFileName: thumbnailFileName,
            duration: duration.seconds,
            importedAt: Date()
        )
    }

    nonisolated private static func loadDuration(for asset: AVAsset) throws -> CMTime {
        let semaphore = DispatchSemaphore(value: 0)
        var loadedDuration: CMTime = .invalid
        var loadedError: Error?

        asset.loadValuesAsynchronously(forKeys: ["duration"]) {
            var error: NSError?
            let status = asset.statusOfValue(forKey: "duration", error: &error)

            if status == .loaded {
                loadedDuration = asset.duration
            } else {
                loadedError = error ?? ImportError.invalidVideo
            }

            semaphore.signal()
        }

        semaphore.wait()

        if let loadedError {
            throw loadedError
        }

        return loadedDuration
    }

    nonisolated private static func generateThumbnail(for asset: AVAsset, duration: TimeInterval, id: UUID) throws -> String? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)

        let thumbnailSecond = min(0.2, max(0, duration / 2))
        let imageTime = CMTime(seconds: thumbnailSecond, preferredTimescale: 600)
        let cgImage = try generator.copyCGImage(at: imageTime, actualTime: nil)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let fileName = "\(id.uuidString).png"
        let url = Self.thumbnailsDirectory.appendingPathComponent(fileName, isDirectory: false)
        try pngData.write(to: url, options: [.atomic])
        return fileName
    }
}

private enum ImportError: LocalizedError {
    case unsupportedFileType
    case invalidVideo
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "Unterstützt werden .mp4-, .mov- und .m4v-Dateien."
        case .invalidVideo:
            return "Die Datei konnte nicht als abspielbares Video erkannt werden."
        case .copyFailed:
            return "Das Video konnte nicht in die Bibliothek kopiert werden."
        }
    }
}

private extension JSONEncoder {
    static var liveWallpaper: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var liveWallpaper: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
