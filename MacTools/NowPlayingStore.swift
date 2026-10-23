import AppKit
import Combine
import CoreAudio

struct AudioPlaybackSource: Equatable {
    let pid: pid_t
    let bundleID: String
}

/// Reads output activity only. No audio tap, microphone access, or recording.
enum SystemAudioPlayback {
    static func sources() -> [AudioPlaybackSource] {
        guard #available(macOS 14.2, *) else { return [] }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = objects.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { object in
            var active: UInt32 = 0, pid: pid_t = 0
            var propertySize = UInt32(MemoryLayout<UInt32>.size)
            var property = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(object, &property, 0, nil, &propertySize, &active) == noErr, active != 0 else { return nil }
            property.mSelector = kAudioProcessPropertyPID; propertySize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &property, 0, nil, &propertySize, &pid) == noErr, pid != 0 else { return nil }
            var identifier: Unmanaged<CFString>?
            property.mSelector = kAudioProcessPropertyBundleID; propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(object, &property, 0, nil, &propertySize, &identifier) == noErr else { return nil }
            return AudioPlaybackSource(pid: pid, bundleID: identifier?.takeRetainedValue() as String? ?? "")
        }
    }
}

struct PlayingAudio: Identifiable, Equatable {
    let id: String
    let application: String
    let applicationURL: URL
    let title: String?
    let artist: String?
    var isPlaying = true
    var canControl: Bool { ["com.spotify.client", "com.apple.Music", "com.apple.iTunes"].contains(id) }
    var headline: String { title ?? (canControl ? "Musik läuft" : "Audio läuft") }
    var detail: String { [artist, isPlaying ? application : "Pausiert · " + application].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
}

struct PlaybackMetadata: Equatable {
    var title: String?
    var artist: String?
    var playing: Bool?
    mutating func update(_ info: [AnyHashable: Any]) {
        if let name = info["Name"] as? String { title = name.isEmpty ? nil : name }
        if let value = info["Artist"] as? String { artist = value.isEmpty ? nil : value }
        if let state = info["Player State"] as? String {
            switch state.lowercased() { case "playing": playing = true; case "paused", "stopped": playing = false; default: break }
        }
        if info["Player State"] as? String == "Stopped" { title = nil; artist = nil }
    }
}

@MainActor
final class NowPlayingStore: ObservableObject {
    static let shared = NowPlayingStore()
    @Published private(set) var playing: [PlayingAudio] = []
    @Published private(set) var commandRunning = false
    @Published var error: String?
    private var recentLocal: [String: (PlayingAudio, Date)] = [:]
    private var metadata: [String: PlaybackMetadata] = [:]
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private let readSources: (() -> [AudioPlaybackSource])?
    private var cachedSources: [AudioPlaybackSource] = []
    private var sampling = false

    init(readSources: (() -> [AudioPlaybackSource])? = nil) { self.readSources = readSources }

    func start() {
        guard timer == nil else { return }
        let center = DistributedNotificationCenter.default()
        for (name, bundleID) in [("com.spotify.client.PlaybackStateChanged", "com.spotify.client"), ("com.apple.Music.playerInfo", "com.apple.Music"), ("com.apple.iTunes.playerInfo", "com.apple.iTunes")] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] notice in
                let info = notice.userInfo ?? [:]
                Task { @MainActor [weak self] in self?.receive(info, bundleID: bundleID) }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollSources() }
        }
        pollSources()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }; observers.removeAll()
        playing = []; metadata.removeAll()
    }
    func receive(_ info: [AnyHashable: Any], bundleID: String) {
        var value = metadata[bundleID] ?? PlaybackMetadata(); value.update(info); metadata[bundleID] = value
        refresh()
    }
    enum Command { case previous, playPause, next }
    func control(_ command: Command, track: PlayingAudio) async {
        guard track.canControl, !commandRunning else { return }
        commandRunning = true; error = nil; defer { commandRunning = false }
        let action: String
        switch command { case .previous: action = "previous track"; case .playPause: action = "playpause"; case .next: action = "next track" }
        let script = "with timeout of 10 seconds\ntell application id \"" + track.id + "\" to " + action + "\nend timeout"
        let response = await LocalCommand.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", script], timeout: 45)
        if response.status != 0 { error = "Player-Steuerung nicht bestätigt. Erlaube MacTools bei Bedarf unter Datenschutz & Sicherheit → Automation den Zugriff auf " + track.application + ". " + String(response.error.prefix(250)) }
        refresh()
    }
    private func pollSources() {
        guard !sampling else { return }
        sampling = true
        Task {
            let sources = await Task.detached(priority: .utility) { SystemAudioPlayback.sources() }.value
            cachedSources = sources; sampling = false
            refresh()
        }
    }
    func refresh() {
        var result: [String: PlayingAudio] = [:]
        for source in readSources?() ?? cachedSources {
            guard source.pid != ProcessInfo.processInfo.processIdentifier,
                  let running = NSRunningApplication(processIdentifier: source.pid), !running.isTerminated else { continue }
            guard let candidate = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) ?? running.bundleURL else { continue }
            // Audio often comes from a browser/Spotify helper nested inside its parent app.
            let components = candidate.pathComponents
            guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { continue }
            let url = URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(index + 1))))
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier,
                  bundleID != "com.julianfink.LiveWallpaper", bundleID != Bundle.main.bundleIdentifier else { continue }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
            let info = metadata[bundleID]
            let track = PlayingAudio(id: bundleID, application: name, applicationURL: url, title: info?.title, artist: info?.artist, isPlaying: info?.playing != false)
            if track.isPlaying { result[bundleID] = track; recentLocal[bundleID] = (track, Date()) }
            else if track.canControl && recentLocal[bundleID] != nil { result[bundleID] = track }
        }
        for (id, saved) in recentLocal where result[id] == nil && metadata[id]?.playing == false && Date().timeIntervalSince(saved.1) < 300 {
            guard saved.0.canControl, !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else { continue }
            var paused = saved.0; paused.isPlaying = false; result[id] = paused
        }
        let updated = result.values.sorted { lhs, rhs in
            if (lhs.title != nil) != (rhs.title != nil) { return lhs.title != nil }
            return lhs.application.localizedCaseInsensitiveCompare(rhs.application) == .orderedAscending
        }
        if playing != updated { playing = updated }
    }
}
