import AppKit
import Combine
import CryptoKit

struct DiskScanVolume: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var root: URL
    var isPrimary: Bool
    var isInternal: Bool
    var isMounted: Bool
    var total: Int64? = nil
    var free: Int64? = nil
    var icon: String { isInternal ? "internaldrive" : "externaldrive" }

    static func mounted() -> [DiskScanVolume] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            let primary = url.path == "/"
            guard primary || url.path.hasPrefix("/Volumes/") else { return nil }
            let info = try? url.resourceValues(forKeys: keys)
            guard info?.volumeIsLocal != false else { return nil }
            return DiskScanVolume(id: primary ? "internal" : (info?.volumeUUIDString?.lowercased() ?? "mount:" + url.path),
                name: info?.volumeName ?? url.lastPathComponent, root: url, isPrimary: primary,
                isInternal: info?.volumeIsInternal ?? primary, isMounted: true,
                total: info?.volumeTotalCapacity.map(Int64.init), free: info?.volumeAvailableCapacity.map(Int64.init))
        }
    }
}

@MainActor final class DiskVolumeProfile {
    var volume: DiskScanVolume
    let disk: DiskScanStore
    let security: SecurityScanStore
    init(volume: DiskScanVolume, disk: DiskScanStore, security: SecurityScanStore) {
        self.volume = volume; self.disk = disk; self.security = security
        setMounted(volume.isMounted)
    }
    func setMounted(_ mounted: Bool) {
        volume.isMounted = mounted
        let safe = mounted && (volume.isPrimary || DiskVolumeStore.contains(disk.root, in: volume.root))
        disk.acceptsFileChanges = safe; security.acceptsFileChanges = safe
        if !mounted { cancel() }
    }
    func cancel() {
        if disk.isScanning { disk.cancel() }
        if security.isScanning || security.isUpdating { security.cancel() }
    }
}

/// Each volume retains its own small store and disk-backed inventory. Switching
/// the UI neither replaces the PC's scan nor starts a scan on a mounted drive.
@MainActor final class DiskVolumeStore: ObservableObject {
    static let shared = DiskVolumeStore(startPrimary: { AutomaticScans.shared.runNow() }, cancelPrimary: { AutomaticScans.shared.cancelCombined() })
    @Published private(set) var volumes: [DiskScanVolume] = []
    @Published var selectedID: String { didSet { defaults.set(selectedID, forKey: "diskSelectedVolume") } }
    private let defaults: UserDefaults
    private let directory: URL
    private let discover: () -> [DiskScanVolume]
    private let primaryDisk: DiskScanStore
    private let primarySecurity: SecurityScanStore
    private let startPrimary: (() -> Void)?
    private let cancelPrimary: (() -> Void)?
    private var profiles: [String: DiskVolumeProfile] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var catalogURL: URL { directory.appendingPathComponent("disk-volumes.json") }

    init(primary: DiskScanStore? = nil, security: SecurityScanStore? = nil,
         defaults: UserDefaults = .standard, directory: URL = VideoLibraryStore.appSupportDirectory,
         discover: @escaping () -> [DiskScanVolume] = DiskScanVolume.mounted, observeMounts: Bool = true,
         startPrimary: (() -> Void)? = nil, cancelPrimary: (() -> Void)? = nil) {
        self.primaryDisk = primary ?? .shared; self.primarySecurity = security ?? .shared
        self.defaults = defaults; self.directory = directory; self.discover = discover
        self.startPrimary = startPrimary; self.cancelPrimary = cancelPrimary
        selectedID = defaults.string(forKey: "diskSelectedVolume") ?? "internal"
        if let data = try? Data(contentsOf: directory.appendingPathComponent("disk-volumes.json")),
           let known = try? JSONDecoder().decode([DiskScanVolume].self, from: data) {
            volumes = known.filter { $0.root.isFileURL && !$0.id.isEmpty }.map { value in var value = value; value.isMounted = false; return value }
        }
        refresh()
        if observeMounts {
            for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
                NSWorkspace.shared.notificationCenter.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
            }
        }
    }
    var selectedVolume: DiskScanVolume? { volumes.first { $0.id == selectedID } ?? volumes.first { $0.isPrimary } ?? volumes.first }
    var selectedProfile: DiskVolumeProfile? { selectedVolume.map { profile(for: $0.id) } }

    func profile(for id: String) -> DiskVolumeProfile {
        if let existing = profiles[id] { return existing }
        let volume = volumes.first { $0.id == id } ?? DiskScanVolume(id: "internal", name: "Dieser Mac", root: URL(fileURLWithPath: "/"), isPrimary: true, isInternal: true, isMounted: true)
        let value: DiskVolumeProfile
        if volume.isPrimary { value = DiskVolumeProfile(volume: volume, disk: primaryDisk, security: primarySecurity) }
        else {
            let key = SHA256.hash(data: Data(volume.id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            let cache = directory.appendingPathComponent("VolumeScans/" + key, isDirectory: true)
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let prefs = UserDefaults(suiteName: "com.julianfink.MacTools.VolumeScan." + key)!
            let disk = DiskScanStore(defaults: prefs, directory: cache, eagerRestore: false, defaultRoot: volume.root, retainUnavailableRoot: true)
            // A renamed mount must never make an old folder path target a different drive.
            if volume.isMounted, !Self.contains(disk.root, in: volume.root) { disk.selectRoot(volume.root) }
            value = DiskVolumeProfile(volume: volume, disk: disk, security: SecurityScanStore(directory: cache))
        }
        profiles[volume.id] = value
        value.disk.$isScanning.dropFirst().filter { !$0 }.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        return value
    }
    func refresh() {
        let mounted = discover()
        var known = Dictionary(volumes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for id in Array(known.keys) { known[id]?.isMounted = false }
        for volume in mounted { known[volume.id] = volume }
        let ordered = known.values.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            if lhs.isMounted != rhs.isMounted { return lhs.isMounted }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        for volume in ordered {
            if let profile = profiles[volume.id] {
                let oldRoot = profile.volume.root
                profile.volume = volume
                if volume.isMounted, oldRoot != volume.root { profile.cancel(); profile.disk.selectRoot(volume.root) }
                if volume.isMounted, !volume.isPrimary, !Self.contains(profile.disk.root, in: volume.root) { profile.disk.selectRoot(volume.root) }
                profile.setMounted(volume.isMounted)
            }
        }
        if volumes != ordered { volumes = ordered }
        if !volumes.contains(where: { $0.id == selectedID }), let first = volumes.first { selectedID = first.id }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(volumes) { try? data.write(to: catalogURL, options: .atomic) }
    }
    func selectVolume(path: String) {
        refresh()
        if let volume = volumes.first(where: { $0.root.path == path }) { selectedID = volume.id }
    }
    func selectFolder(_ url: URL) {
        let target = url.resolvingSymlinksInPath()
        guard let volume = volumes.filter({ $0.isMounted && Self.contains(target, in: $0.root) }).max(by: { $0.root.path.count < $1.root.path.count }) else { return }
        let profile = profile(for: volume.id)
        guard !profile.disk.isScanning, !profile.disk.isSaving, !profile.security.isScanning, !profile.security.isUpdating else { return }
        selectedID = volume.id; profile.disk.selectRoot(target); profile.setMounted(true)
    }
    func chooseFolder(initialDirectory: URL? = nil) {
        let panel = NSOpenPanel(); panel.title = "Scanbereich auf einem Laufwerk wählen"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.directoryURL = initialDirectory ?? selectedProfile?.disk.root
        if panel.runModal() == .OK, let url = panel.url { refresh(); selectFolder(url) }
    }
    func startSelectedDiskScan() {
        guard let volume = selectedVolume, volume.isMounted else { return }
        if volume.isPrimary, let startPrimary { startPrimary(); return }
        let profile = profile(for: volume.id)
        if !Self.contains(profile.disk.root, in: volume.root) { profile.disk.selectRoot(volume.root) }
        guard Self.contains(profile.disk.root, in: volume.root) else { return }
        profile.setMounted(true); profile.disk.start()
    }
    func cancelSelected() {
        if selectedVolume?.isPrimary == true, let cancelPrimary { cancelPrimary() }
        else { selectedProfile?.cancel() }
    }
    func stop() {
        subscriptions.removeAll()
        profiles.values.forEach { $0.disk.acceptsFileChanges = false; $0.security.acceptsFileChanges = false; $0.cancel() }
    }
    static func contains(_ url: URL, in root: URL) -> Bool {
        let path = DiskScanner.canonicalPath(url.standardizedFileURL.path), base = DiskScanner.canonicalPath(root.standardizedFileURL.path)
        return base == "/" || path == base || path.hasPrefix(base + "/")
    }
}
