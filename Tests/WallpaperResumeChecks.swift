import AppKit
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
                let controller = AppDelegate(settings: settings, library: library)
                self.controller = controller
                controller.bindState()
                settings.setCurrentVideo(video.id)
                try await Task.sleep(nanoseconds: 1_500_000_000)
                guard let playing = controller.wallpaperPlaybackSnapshot.first, playing.rate > 0, playing.seconds > 0.3 else { throw CheckError.notPlaying }
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
                try "PASS: actual AppDelegate bindings and AVPlayer; playing \(playing.seconds), paused \(paused.seconds), resumed \(resumed.seconds), second resume \(twice.seconds)\n".write(toFile: "/Users/julianfink/Documents/Coding/new-world/LiveWallpaper/build/wallpaper-resume-check.log", atomically: true, encoding: .utf8)
                passed = true
            } catch {
                try? "FAIL: \(error)\n".write(toFile: "/Users/julianfink/Documents/Coding/new-world/LiveWallpaper/build/wallpaper-resume-check.log", atomically: true, encoding: .utf8)
            }
            NSApp.terminate(nil)
        }
    }
    enum CheckError: Error { case noVideo, notPlaying, notPaused, notResumed }
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
