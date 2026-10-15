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
        var lastObservedTime: TimeInterval
        var stalledCheckCount: Int
    }

    private let settings: SettingsStore
    private let library: VideoLibraryStore
    private var entries: [UInt32: WallpaperEntry] = [:]
    private var currentVideoURL: URL?
    private var healthCheckTimer: Timer?

    init(settings: SettingsStore, library: VideoLibraryStore) {
        self.settings = settings
        self.library = library
    }

    /// Read-only playback telemetry also supports native pause/resume regression checks.
    var playbackSnapshot: [(seconds: TimeInterval, rate: Float)] {
        entries.values.compactMap { entry in
            guard let player = entry.player else { return nil }
            return (player.currentTime().seconds, player.rate)
        }
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

        entries.values.forEach { $0.player?.play() }
        refreshWallpaperWindows()
        startHealthCheck()
    }

    func closeAllWindows() {
        entries.values.forEach { entry in
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
        let screens = NSScreen.screens
        let currentScreenIDs = Set(screens.map(screenID(for:)))

        for (id, entry) in entries where !currentScreenIDs.contains(id) {
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
                lastObservedTime: 0,
                stalledCheckCount: 0
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

        for id in Array(entries.keys) {
            guard var entry = entries[id] else { continue }
            replacePlayer(in: &entry, with: standardizedURL)
            entries[id] = entry
        }

        refreshWallpaperWindows()
        startHealthCheck()
    }

    private func replacePlayer(in entry: inout WallpaperEntry, with videoURL: URL) {
        entry.player?.pause()
        entry.playerView.setPlayer(nil)
        entry.looper = nil
        entry.player = nil

        let item = AVPlayerItem(url: videoURL)
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
        entry.stalledCheckCount = 0

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

            let currentTime = player.currentTime().seconds
            let observedTime = currentTime.isFinite ? currentTime : 0

            if player.rate > 0,
               abs(observedTime - entry.lastObservedTime) < 0.05 {
                entry.stalledCheckCount += 1
            } else {
                entry.stalledCheckCount = 0
            }

            entry.lastObservedTime = observedTime
            entries[id] = entry

            if entry.stalledCheckCount >= 3 {
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
