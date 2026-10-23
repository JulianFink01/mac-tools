import AppKit

@main
struct NowPlayingChecks {
    @MainActor static func main() throws {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { fatalError("Finder must be running for the native app-resolution check") }
        var sources: [AudioPlaybackSource] = []
        let store = NowPlayingStore(readSources: { sources })
        store.refresh(); precondition(store.playing.isEmpty)
        let source = AudioPlaybackSource(pid: finder.processIdentifier, bundleID: "com.apple.finder")
        sources = [source, source]
        store.refresh()
        precondition(store.playing.count == 1 && store.playing[0].title == nil)
        precondition(store.playing[0].applicationURL.pathExtension == "app")
        store.receive(["Name": "Prüftitel", "Artist": "Prüfinterpret", "Player State": "Playing"], bundleID: "com.apple.finder")
        precondition(store.playing[0].headline == "Prüftitel" && store.playing[0].detail.contains("Prüfinterpret"))
        store.receive(["Player State": "Paused"], bundleID: "com.apple.finder")
        precondition(store.playing.isEmpty, "Paused playback must disappear even if an output stream is still open")
        store.receive(["Player State": "Playing"], bundleID: "com.apple.finder")
        precondition(store.playing[0].title == "Prüftitel", "State-only events preserve metadata")
        sources = []; store.refresh()
        precondition(store.playing.isEmpty, "Remote-only playback or missing local output must not produce a card")
        sources = [AudioPlaybackSource(pid: ProcessInfo.processInfo.processIdentifier, bundleID: "com.apple.finder")]
        store.refresh(); precondition(store.playing.isEmpty, "MacTools' muted wallpaper must never produce a music card")
        var info = PlaybackMetadata(title: "Old", artist: "Old", playing: true)
        info.update(["Name": "", "Artist": "", "Player State": "Stopped"])
        precondition(info.title == nil && info.artist == nil && info.playing == false)
        store.stop()
        print("PASS: app resolution, source deduplication, generic fallback, metadata updates, pause/resume, absent output, self exclusion and stopped metadata")
    }
}
