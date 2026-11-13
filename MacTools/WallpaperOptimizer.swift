import AVFoundation
import AppKit

/// Size and frame rate a wallpaper video actually needs on this Mac.
struct WallpaperOptimizationTarget: Equatable, Sendable {
    let width: Int
    let height: Int
    let frameRate: Int
    /// Share of the per-second pixel work the copy removes, between 0 and 1.
    let saving: Double
    var sizeLabel: String { "\(width)×\(height) · \(frameRate) fps" }
}

struct WallpaperSourceInfo: Equatable, Sendable {
    let size: CGSize
    let frameRate: Float
    var label: String { "\(Int(size.width.rounded()))×\(Int(size.height.rounded())) · \(Int(frameRate.rounded())) fps" }
}

/// A wallpaper video is decoded again on every display, every frame, for as long
/// as a desktop is visible. Playing more pixels or more frames per second than any
/// display can show is work that nothing can make cheaper afterwards, so the copy
/// is encoded once to what the displays actually need.
enum WallpaperOptimizer {
    enum Failure: LocalizedError {
        case noVideoTrack
        case exportUnavailable
        case exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "Das Video enthält keine lesbare Videospur."
            case .exportUnavailable: "Für dieses Video steht kein Encoder zur Verfügung."
            case .exportFailed(let reason): reason
            }
        }
    }

    static let frameRateLimit = 30

    /// Pixel sizes of the attached displays, not their point sizes: a Retina
    /// display shows the wallpaper at its full backing resolution.
    @MainActor static func displayPixelSizes() -> [CGSize] {
        NSScreen.screens.map { screen in
            CGSize(width: screen.frame.width * screen.backingScaleFactor,
                   height: screen.frame.height * screen.backingScaleFactor)
        }
    }

    /// Scaled so the video still covers the largest display completely, which is
    /// what the filling display mode needs; the fitting mode needs no more. Never
    /// scales a video up, and reports nothing when there is little to gain.
    static func target(sourceSize: CGSize, sourceFrameRate: Float, displays: [CGSize],
                       frameRateLimit: Int = frameRateLimit) -> WallpaperOptimizationTarget? {
        let source = CGSize(width: abs(sourceSize.width), height: abs(sourceSize.height))
        guard source.width >= 2, source.height >= 2, sourceFrameRate > 0 else { return nil }
        let usable = displays.filter { $0.width >= 1 && $0.height >= 1 }
        let largest = usable.max { ($0.width * $0.height) < ($1.width * $1.height) }
        let scale = largest.map { min(1, max($0.width / source.width, $0.height / source.height)) } ?? 1
        let width = max(2, Int((source.width * scale / 2).rounded()) * 2)
        let height = max(2, Int((source.height * scale / 2).rounded()) * 2)
        let rate = max(1, sourceFrameRate > Float(frameRateLimit) + 1 ? frameRateLimit : Int(sourceFrameRate.rounded()))
        let before = Double(source.width * source.height) * Double(sourceFrameRate)
        let after = Double(width * height) * Double(rate)
        let saving = before > 0 ? max(0, 1 - after / before) : 0
        guard saving > 0.1 else { return nil }
        return WallpaperOptimizationTarget(width: width, height: height, frameRate: rate, saving: saving)
    }

    static func sourceInfo(of url: URL) async -> WallpaperSourceInfo? {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform),
              let rate = try? await track.load(.nominalFrameRate) else { return nil }
        let displayed = natural.applying(transform)
        let size = CGSize(width: abs(displayed.width), height: abs(displayed.height))
        guard size.width >= 2, size.height >= 2 else { return nil }
        return WallpaperSourceInfo(size: size, frameRate: rate > 0 ? rate : 30)
    }

    @MainActor static func proposedTarget(for url: URL) async -> WallpaperOptimizationTarget? {
        let displays = displayPixelSizes()
        guard let info = await sourceInfo(of: url) else { return nil }
        return target(sourceSize: info.size, sourceFrameRate: info.frameRate, displays: displays)
    }

    /// Writes a video-only copy at the given size and frame rate. The source file
    /// stays untouched; removing the copy returns playback to it.
    static func export(source: URL, to destination: URL, target: WallpaperOptimizationTarget,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideoTrack }
        let range = try await track.load(.timeRange)
        let transform = try await track.load(.preferredTransform)
        let natural = try await track.load(.naturalSize)
        guard range.duration.seconds.isFinite, range.duration.seconds > 0 else { throw Failure.noVideoTrack }

        // The wallpaper never plays sound, so an audio track would be re-encoded
        // for nothing and would reach the player as a track to be silenced.
        let composition = AVMutableComposition()
        guard let copy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.noVideoTrack
        }
        try copy.insertTimeRange(range, of: track, at: .zero)

        let displayed = natural.applying(transform)
        let width = abs(displayed.width), height = abs(displayed.height)
        guard width >= 1, height >= 1 else { throw Failure.noVideoTrack }
        let renderSize = CGSize(width: CGFloat(target.width), height: CGFloat(target.height))
        let scale = min(renderSize.width / width, renderSize.height / height)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: range.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: copy)
        // Rotation first, then the scale that maps the shown image onto the frame.
        layer.setTransform(transform.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        instruction.layerInstructions = [layer]
        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(target.frameRate))

        let available = AVAssetExportSession.exportPresets(compatibleWith: composition)
        let preset = available.contains(AVAssetExportPresetHEVCHighestQuality)
            ? AVAssetExportPresetHEVCHighestQuality
            : (available.contains(AVAssetExportPresetHighestQuality) ? AVAssetExportPresetHighestQuality : available.first)
        guard let preset, let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw Failure.exportUnavailable
        }
        try? FileManager.default.removeItem(at: destination)
        session.outputURL = destination
        session.outputFileType = session.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = false

        let reporter = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { reporter.cancel() }
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        switch session.status {
        case .completed:
            progress(1)
        case .cancelled:
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        default:
            try? FileManager.default.removeItem(at: destination)
            throw Failure.exportFailed(session.error?.localizedDescription ?? "Der Export wurde nicht abgeschlossen.")
        }
    }
}
