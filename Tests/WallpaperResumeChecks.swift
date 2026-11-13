import AppKit
import AVFoundation
import Foundation

@MainActor
final class WallpaperResumeHarness: NSObject, NSApplicationDelegate {
    var passed = false
    private var controller: AppDelegate?
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 480, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window?.title = "MacTools · Hintergrundprüfung"
        window?.contentView = NSTextField(labelWithString: "Native Prüfung: Video starten → pausieren → fortsetzen")
        window?.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            let suite = "MacTools-WallpaperCheck-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            do {
                let library = VideoLibraryStore.shared
                guard let video = library.video(with: SettingsStore.shared.currentVideoID) ?? library.videos.first else { throw CheckError.noVideo }
                let settings = SettingsStore(defaults: defaults)
                settings.setAspectMode(SettingsStore.shared.aspectMode)
                // Whether a desktop is covered depends on the windows open right now.
                // The energy path below is checked directly so the result does not.
                settings.setPausesHiddenWallpaper(false)
                let source = AVURLAsset(url: video.fileURL)
                let sourceAudioTracks = try await source.loadTracks(withMediaType: .audio)
                let controller = AppDelegate(settings: settings, library: library)
                self.controller = controller
                controller.bindState()
                settings.setCurrentVideo(video.id)
                try await Task.sleep(nanoseconds: 2_500_000_000)
                guard let playing = controller.wallpaperPlaybackSnapshot.first, playing.rate > 0, playing.seconds > 0.3 else { throw CheckError.notPlaying }
                guard let asset = controller.wallpaperPlaybackAssets.first,
                      try await asset.loadTracks(withMediaType: .audio).isEmpty else { throw CheckError.audioTrackActive }
                settings.setPaused(true)
                try await Task.sleep(nanoseconds: 400_000_000)
                guard let paused = controller.wallpaperPlaybackSnapshot.first, paused.rate == 0 else { throw CheckError.notPaused }
                try await Task.sleep(nanoseconds: 400_000_000)
                guard let still = controller.wallpaperPlaybackSnapshot.first, abs(still.seconds - paused.seconds) < 0.05 else { throw CheckError.notPaused }
                settings.setPaused(false)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard let resumed = controller.wallpaperPlaybackSnapshot.first, resumed.rate > 0, resumed.seconds - paused.seconds > 0.5 else { throw CheckError.notResumed }
                settings.setPaused(true); settings.setPaused(false)
                try await Task.sleep(nanoseconds: 700_000_000)
                guard let twice = controller.wallpaperPlaybackSnapshot.first, twice.rate > 0, twice.seconds > resumed.seconds + 0.3 else { throw CheckError.notResumed }

                // Energy path: display sleep and screen lock stop every display and
                // release it again without the user's pause switch being involved.
                let playingDisplays = controller.wallpaperPlayingDisplayCount
                guard playingDisplays > 0 else { throw CheckError.notPlaying }
                controller.setWallpaperEnergySuspended(true)
                try await Task.sleep(nanoseconds: 400_000_000)
                guard controller.wallpaperPlayingDisplayCount == 0,
                      let suspended = controller.wallpaperPlaybackSnapshot.first, suspended.rate == 0 else { throw CheckError.notSuspended }
                try await Task.sleep(nanoseconds: 500_000_000)
                guard let frozen = controller.wallpaperPlaybackSnapshot.first, abs(frozen.seconds - suspended.seconds) < 0.05 else { throw CheckError.notSuspended }
                guard !settings.isPaused else { throw CheckError.notSuspended }
                controller.setWallpaperEnergySuspended(false)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard controller.wallpaperPlayingDisplayCount == playingDisplays,
                      let released = controller.wallpaperPlaybackSnapshot.first, released.rate > 0,
                      released.seconds > suspended.seconds + 0.3 else { throw CheckError.notResumed }
                try "PASS: actual AppDelegate bindings and video-only AVPlayer; source audio tracks \(sourceAudioTracks.count), playing \(playing.seconds), paused \(paused.seconds), resumed \(resumed.seconds), second resume \(twice.seconds), displays \(playingDisplays), energy suspended \(suspended.seconds), frozen \(frozen.seconds), released \(released.seconds)\n".write(toFile: "/private/tmp/mactools-wallpaper-resume-check.log", atomically: true, encoding: .utf8)
                passed = true
            } catch {
                try? "FAIL: \(error)\n".write(toFile: "/private/tmp/mactools-wallpaper-resume-check.log", atomically: true, encoding: .utf8)
            }
            NSApp.terminate(nil)
        }
    }
    enum CheckError: Error { case noVideo, notPlaying, notPaused, notResumed, notSuspended, audioTrackActive }
}

@main
struct WallpaperResumeChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        let harness = WallpaperResumeHarness()
        app.delegate = harness
        app.run()
        exit(harness.passed ? 0 : 1)
    }
}
