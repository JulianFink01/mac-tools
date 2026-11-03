import AppKit
import AVFoundation

@MainActor
final class WallpaperController {
    private struct WallpaperEntry {
        let screenID: UInt32
        let window: WallpaperWindow
        let playerView: WallpaperPlayerView
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
        var timeObserver: Any?
        var lastObservedTime: TimeInterval
        var lastProgressAt: Date
    }

    private let settings: SettingsStore
    private let library: VideoLibraryStore
    private var entries: [UInt32: WallpaperEntry] = [:]
    private var currentVideoURL: URL?
    private var configureTask: Task<Void, Never>?
    private var healthCheckTimer: Timer?

    init(settings: SettingsStore, library: VideoLibraryStore) {
        self.settings = settings
        self.library = library
    }

    /// Read-only playback telemetry also supports native pause/resume regression checks.
    var playbackSnapshot: [(seconds: TimeInterval, rate: Float)] {
        entries.values.compactMap { entry in
            guard let player = entry.player else { return nil }
            return (entry.lastObservedTime, player.rate)
        }
    }

    var playbackAssets: [AVAsset] {
        entries.values.compactMap { $0.player?.currentItem?.asset }
    }

    func start() {
        applyCurrentVideo()
    }

    func applyCurrentVideo() {
        guard let video = library.video(with: settings.currentVideoID),
              FileManager.default.fileExists(atPath: video.fileURL.path) else {
            closeAllWindows()
            return
        }

        rebuildWindowsIfNeeded()
        configurePlayers(with: video.fileURL)
    }

    func handleScreenConfigurationChanged() {
        guard library.video(with: settings.currentVideoID) != nil else {
            closeAllWindows()
            return
        }

        rebuildWindowsIfNeeded()
        applyCurrentVideo()
    }

    func updateAspectMode() {
        entries.values.forEach { $0.playerView.setAspectMode(settings.aspectMode) }
    }

    func pausePlayback() {
        entries.values.forEach { $0.player?.pause() }
        stopHealthCheck()
    }

    func resumePlayback() {
        guard !settings.isPaused else { return }

        if entries.isEmpty {
            applyCurrentVideo()
        }

        for id in Array(entries.keys) {
            guard var entry = entries[id] else { continue }
            entry.player?.play()
            entry.lastProgressAt = Date()
            entries[id] = entry
        }
        refreshWallpaperWindows()
        startHealthCheck()
    }

    func closeAllWindows() {
        configureTask?.cancel()
        configureTask = nil
        entries.values.forEach { entry in
            if let player = entry.player, let observer = entry.timeObserver { player.removeTimeObserver(observer) }
            entry.player?.pause()
            entry.playerView.setPlayer(nil)
            entry.window.orderOut(nil)
            entry.window.close()
        }
        entries.removeAll()
        currentVideoURL = nil
        stopHealthCheck()
    }

    private func rebuildWindowsIfNeeded() {
        let screens = NSScreen.screens.filter { screen in
            let id = screenID(for: screen)
            return !(CGDisplayVendorNumber(id) == 0x4D54 && CGDisplayModelNumber(id) == 1)
        }
        let currentScreenIDs = Set(screens.map(screenID(for:)))

        for (id, entry) in entries where !currentScreenIDs.contains(id) {
            if let player = entry.player, let observer = entry.timeObserver { player.removeTimeObserver(observer) }
            entry.player?.pause()
            entry.playerView.setPlayer(nil)
            entry.window.close()
            entries[id] = nil
        }

        for screen in screens {
            let id = screenID(for: screen)
            if let existing = entries[id] {
                existing.window.setFrame(screen.frame, display: true)
                existing.playerView.frame = NSRect(origin: .zero, size: screen.frame.size)
                continue
            }

            let window = WallpaperWindow(screen: screen)
            let playerView = WallpaperPlayerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            playerView.setAspectMode(settings.aspectMode)
            window.contentView = playerView
            window.orderFrontRegardless()

            entries[id] = WallpaperEntry(
                screenID: id,
                window: window,
                playerView: playerView,
                player: nil,
                looper: nil,
                timeObserver: nil,
                lastObservedTime: 0,
                lastProgressAt: Date()
            )
        }
    }

    private func configurePlayers(with videoURL: URL) {
        let standardizedURL = videoURL.standardizedFileURL

        if currentVideoURL == standardizedURL,
           entries.values.allSatisfy({ $0.player != nil }) {
            refreshWallpaperWindows()
            entries.values.forEach { entry in
                entry.playerView.setAspectMode(settings.aspectMode)
                if !settings.isPaused {
                    entry.player?.play()
                }
            }
            startHealthCheck()
            return
        }

        currentVideoURL = standardizedURL
        configureTask?.cancel()
        configureTask = Task { [weak self] in
            do {
                let asset = try await Self.videoOnlyAsset(at: standardizedURL)
                guard let self, !Task.isCancelled, self.currentVideoURL == standardizedURL else { return }
                for id in Array(self.entries.keys) {
                    guard var entry = self.entries[id] else { continue }
                    self.replacePlayer(in: &entry, with: asset)
                    self.entries[id] = entry
                }
                self.refreshWallpaperWindows()
                self.startHealthCheck()
            } catch {
                guard let self, !Task.isCancelled, self.currentVideoURL == standardizedURL else { return }
                self.library.errorMessage = "Live-Hintergrund konnte nicht gestartet werden: \(error.localizedDescription)"
            }
        }
    }

    private static func videoOnlyAsset(at url: URL) async throws -> AVAsset {
        let source = AVURLAsset(url: url)
        guard let track = try await source.loadTracks(withMediaType: .video).first else {
            throw WallpaperError.noVideoTrack
        }
        let range = try await track.load(.timeRange)
        let transform = try await track.load(.preferredTransform)
        guard range.duration.seconds.isFinite, range.duration.seconds > 0 else {
            throw WallpaperError.noVideoTrack
        }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw WallpaperError.noVideoTrack
        }
        try video.insertTimeRange(range, of: track, at: .zero)
        video.preferredTransform = transform
        return composition
    }

    private enum WallpaperError: LocalizedError {
        case noVideoTrack
        var errorDescription: String? { "Das gewählte Video enthält keine abspielbare Videospur." }
    }

    private func replacePlayer(in entry: inout WallpaperEntry, with asset: AVAsset) {
        if let player = entry.player, let observer = entry.timeObserver { player.removeTimeObserver(observer) }
        entry.timeObserver = nil
        entry.player?.pause()
        entry.playerView.setPlayer(nil)
        entry.looper = nil
        entry.player = nil

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 1

        let player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false

        let looper = AVPlayerLooper(player: player, templateItem: item)
        entry.playerView.setPlayer(player)
        entry.playerView.setAspectMode(settings.aspectMode)
        entry.player = player
        entry.looper = looper
        entry.lastObservedTime = 0
        entry.lastProgressAt = Date()
        let screenID = entry.screenID
        entry.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self, weak player] time in
            Task { @MainActor in
                guard let self, let player, var current = self.entries[screenID], current.player === player,
                      time.seconds.isFinite else { return }
                if abs(time.seconds - current.lastObservedTime) >= 0.05 {
                    current.lastProgressAt = Date()
                }
                current.lastObservedTime = time.seconds
                self.entries[screenID] = current
            }
        }

        if !settings.isPaused {
            player.play()
        }
    }

    private func startHealthCheck() {
        guard healthCheckTimer == nil, !settings.isPaused else { return }

        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 4.7, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.healthCheckPlayback()
            }
        }
    }

    private func stopHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    private func healthCheckPlayback() {
        guard !settings.isPaused,
              !entries.isEmpty,
              let playbackURL = currentVideoURL else {
            return
        }

        var shouldRebuildPlayback = false

        for id in Array(entries.keys) {
            guard var entry = entries[id],
                  let player = entry.player else {
                shouldRebuildPlayback = true
                continue
            }

            if player.error != nil || player.currentItem?.status == .failed {
                shouldRebuildPlayback = true
                break
            }

            if player.timeControlStatus == .paused {
                player.play()
            }

            if player.rate > 0, Date().timeIntervalSince(entry.lastProgressAt) >= 15 {
                shouldRebuildPlayback = true
                break
            }
        }

        if shouldRebuildPlayback {
            currentVideoURL = nil
            configurePlayers(with: playbackURL)
        } else {
            refreshWallpaperWindows()
        }
    }

    private func refreshWallpaperWindows() {
        entries.values.forEach { $0.window.orderFrontRegardless() }
    }

    private func screenID(for screen: NSScreen) -> UInt32 {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? UInt32(abs(screen.hash))
    }
}
