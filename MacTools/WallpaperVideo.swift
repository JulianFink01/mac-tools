import Foundation

struct WallpaperVideo: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String
    var fileName: String
    var originalFileName: String
    var thumbnailFileName: String?
    var duration: TimeInterval
    var importedAt: Date
    /// A copy encoded for this Mac's displays. The original file always stays.
    var optimizedFileName: String?
    var optimizedWidth: Int?
    var optimizedHeight: Int?
    var optimizedFrameRate: Int?
    var optimizedBytes: Int64?

    var fileURL: URL {
        VideoLibraryStore.videosDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    var optimizedURL: URL? {
        optimizedFileName.map { VideoLibraryStore.videosDirectory.appendingPathComponent($0, isDirectory: false) }
    }

    /// What the wallpaper and the screen saver actually play.
    var playbackURL: URL {
        guard let optimizedURL, FileManager.default.fileExists(atPath: optimizedURL.path) else { return fileURL }
        return optimizedURL
    }

    var optimizedLabel: String? {
        guard let optimizedWidth, let optimizedHeight, let optimizedFrameRate else { return nil }
        let size = "\(optimizedWidth)×\(optimizedHeight) · \(optimizedFrameRate) fps"
        guard let optimizedBytes else { return size }
        return size + " · " + diskBytes(optimizedBytes)
    }

    var thumbnailURL: URL? {
        guard let thumbnailFileName else { return nil }
        return VideoLibraryStore.thumbnailsDirectory.appendingPathComponent(thumbnailFileName, isDirectory: false)
    }
}
