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
    private var occlusionObserver: NSObjectProtocol?
    private var releaseTasks: [UInt32: Task<Void, Never>] = [:]
    private var preparedAsset: AVAsset?
    /// Decoding frames nobody can see was the app's largest constant GPU and power
    /// draw. Playback stops while every desktop window is covered, the display
    /// sleeps or the screen is locked, and picks up again on its own.
    private var energySuspended = false

    init(settings: SettingsStore, library: VideoLibraryStore) {
        self.settings = settings
        self.library = library
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? WallpaperWindow else { return }
            Task { @MainActor in self?.handleOcclusionChange(of: window) }
        }
    }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    /// Set by display sleep and screen lock, independent of the user's setting.
    func setEnergySuspended(_ value: Bool) {
        guard energySuspended != value else { return }
        energySuspended = value
        applyPlaybackState()
    }

    var isEnergySuspended: Bool { energySuspended }

    private func handleOcclusionChange(of window: WallpaperWindow) {
        guard entries.values.contains(where: { $0.window === window }) else { return }
        applyPlaybackState()
    }

    /// Applies the current state without waiting for the next occlusion change.
    func refreshOcclusionState() { applyPlaybackState() }

    /// A desktop window reports itself occluded as soon as other windows cover it
    /// completely. Each display decodes the video in its own player, so a covered
    /// desktop would pay the full price for frames nobody sees.
    private func shouldPlay(_ entry: WallpaperEntry) -> Bool {
        guard !settings.isPaused, !energySuspended else { return false }
        guard settings.pausesHiddenWallpaper else { return true }
        return entry.window.occlusionState.contains(.visible)
    }

    private func applyPlaybackState() {
        var running = false
        for (id, entry) in entries {
            if shouldPlay(entry) {
                releaseTasks.removeValue(forKey: id)?.cancel()
                if entry.player == nil { restorePlayer(for: id) }
                guard let player = entries[id]?.player else { continue }
                running = true
                if player.timeControlStatus == .paused {
                    player.play()
                    entries[id]?.lastProgressAt = Date()
                }
            } else if let player = entry.player {
                if player.timeControlStatus != .paused { player.pause() }
                scheduleRelease(for: id)
            }
        }
        if running { startHealthCheck() } else { stopHealthCheck() }
    }

    /// A covered desktop keeps its paused decoder for a short while, because
    /// switching between windows is constant. Staying covered releases the player:
    /// its pool of decoded frames is the largest block of memory this app holds, and
    /// a 4K frame alone takes several megabytes.
    private func scheduleRelease(for id: UInt32) {
        guard entries[id]?.player != nil, releaseTasks[id] == nil else { return }
        releaseTasks[id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            guard let self else { return }
            self.releaseTasks[id] = nil
            guard let entry = self.entries[id], entry.player != nil, !self.shouldPlay(entry) else { return }
            self.releasePlayer(for: id)
        }
    }

    private func releasePlayer(for id: UInt32) {
        guard var entry = entries[id], let player = entry.player else { return }
        if let observer = entry.timeObserver { player.removeTimeObserver(observer) }
        entry.timeObserver = nil
        player.pause()
        entry.playerView.setPlayer(nil)
        entry.looper = nil
        entry.player = nil
        // The playback position survives so the desktop continues where it stopped.
        entries[id] = entry
    }

    private func restorePlayer(for id: UInt32) {
        guard var entry = entries[id], entry.player == nil else { return }
        guard let asset = preparedAsset else {
            if let url = currentVideoURL {
                currentVideoURL = nil
                configurePlayers(with: url)
            }
            return
        }
        let resumeAt = entry.lastObservedTime
        replacePlayer(in: &entry, with: asset)
        entry.lastObservedTime = resumeAt
        entries[id] = entry
        if resumeAt > 0 {
            entry.player?.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600),
                               toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
        }
    }

    /// How many displays currently decode the video. Also used by the native checks.
    var playingDisplayCount: Int {
        entries.values.filter { ($0.player?.rate ?? 0) > 0 }.count
    }

    /// Read-only playback telemetry also supports native pause/resume regression
    /// checks. The position comes from the player itself, so it does not depend on
    /// how often the progress observer runs.
    var playbackSnapshot: [(seconds: TimeInterval, rate: Float)] {
        entries.values.compactMap { entry in
            guard let player = entry.player else { return nil }
            let seconds = player.currentTime().seconds
            return (seconds.isFinite ? seconds : entry.lastObservedTime, player.rate)
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
        guard !settings.isPaused, !energySuspended else { return }

        if entries.isEmpty {
            applyCurrentVideo()
        }

        refreshWallpaperWindows()
        applyPlaybackState()
    }

    func closeAllWindows() {
        configureTask?.cancel()
        configureTask = nil
        releaseTasks.values.forEach { $0.cancel() }
        releaseTasks.removeAll()
        preparedAsset = nil
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
            entries.values.forEach { $0.playerView.setAspectMode(settings.aspectMode) }
            applyPlaybackState()
            return
        }

        currentVideoURL = standardizedURL
        configureTask?.cancel()
        configureTask = Task { [weak self] in
            do {
                let asset = try await Self.videoOnlyAsset(at: standardizedURL)
                guard let self, !Task.isCancelled, self.currentVideoURL == standardizedURL else { return }
                self.preparedAsset = asset
                for id in Array(self.entries.keys) {
                    guard var entry = self.entries[id] else { continue }
                    self.replacePlayer(in: &entry, with: asset)
                    self.entries[id] = entry
                }
                self.refreshWallpaperWindows()
                self.applyPlaybackState()
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
        entry.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self, weak player] time in
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

        if shouldPlay(entry) {
            player.play()
        }
    }

    private func startHealthCheck() {
        guard healthCheckTimer == nil, !settings.isPaused, !energySuspended else { return }

        // Every tick re-orders the desktop windows, so it stays as rare as the
        // recovery it exists for allows.
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
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
              !energySuspended,
              !entries.isEmpty,
              let playbackURL = currentVideoURL else {
            return
        }

        var shouldRebuildPlayback = false

        for id in Array(entries.keys) {
            guard let candidate = entries[id] else { continue }
            // A display whose desktop is covered has deliberately no player.
            guard shouldPlay(candidate) else { continue }
            guard let entry = entries[id], let player = entry.player else {
                shouldRebuildPlayback = true
                continue
            }

            if player.error != nil || player.currentItem?.status == .failed {
                shouldRebuildPlayback = true
                break
            }

            if player.timeControlStatus == .paused {
                if shouldPlay(entry) { player.play() } else { continue }
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
