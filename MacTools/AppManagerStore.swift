import AppKit
import Combine
import Darwin

struct InstalledApp: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let identifier: String
    let version: String
}
struct AppRemovalItem: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let title: String
    let bytes: Int64
    let identity: String
    let isApp: Bool
    let incomplete: Bool
}
struct AppRemovalPlan: Sendable {
    let app: InstalledApp
    let items: [AppRemovalItem]
}

enum AppInventory {
    static var appRoots: [URL] { [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] }
    static func apps(roots: [URL] = appRoots) -> [InstalledApp] {
        var found: [InstalledApp] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                if url.pathExtension == "app" {
                    enumerator.skipDescendants()
                    guard let app = readApp(url) else { continue }
                    found.append(app)
                } else if url.pathComponents.count - root.pathComponents.count >= 2 {
                    enumerator.skipDescendants()
                }
            }
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func readApp(_ url: URL) -> InstalledApp? {
        guard let info = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              info.isDirectory == true, info.isSymbolicLink != true,
              let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              identifier.count > 2, identifier.count < 256,
              identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }) else { return nil }
        return InstalledApp(url: url, name: plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent,
                            identifier: identifier, version: plist["CFBundleShortVersionString"] as? String ?? "—")
    }
    static func plan(for app: InstalledApp, library: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")) -> AppRemovalPlan {
        let id = app.identifier
        let name = app.url.deletingPathExtension().lastPathComponent
        var paths: [(URL, String, Bool)] = [(app.url, "Anwendung", true)]
        let exact = [
            ("Application Support/" + id, "App-Daten"),
            ("Caches/" + id, "Cache"),
            ("Preferences/" + id + ".plist", "Einstellungen"),
            ("Saved Application State/" + id + ".savedState", "Fensterzustand"),
            ("Logs/" + id, "Protokolle"),
            ("WebKit/" + id, "Web-Daten"),
            ("HTTPStorages/" + id, "Web-Speicher"),
            ("HTTPStorages/" + id + ".binarycookies", "Cookies"),
            ("Containers/" + id, "App-Container"),
            ("LaunchAgents/" + id + ".plist", "Autostart")
        ]
        paths += exact.map { (library.appendingPathComponent($0.0), $0.1, false) }
        // Name-only folders are offered separately and left unchecked by the UI.
        if !name.isEmpty && name != "." && name != ".." && !name.contains("/") {
            paths += ["Application Support", "Caches", "Logs"].map { (library.appendingPathComponent($0).appendingPathComponent(name), "Daten mit App-Namen · Zuordnung prüfen", false) }
        }
        var seen = Set<String>()
        let items = paths.compactMap { url, title, isApp -> AppRemovalItem? in
            guard seen.insert(url.path).inserted else { return nil }
            var statInfo = stat()
            guard lstat(url.path, &statInfo) == 0, (statInfo.st_mode & S_IFMT) != S_IFLNK,
                  (statInfo.st_mode & S_IFMT) == S_IFDIR || (statInfo.st_mode & S_IFMT) == S_IFREG else { return nil }
            let size = allocatedSize(url)
            return AppRemovalItem(url: url, title: title, bytes: size.bytes, identity: "\(statInfo.st_dev):\(statInfo.st_ino)", isApp: isApp, incomplete: size.incomplete)
        }
        return AppRemovalPlan(app: app, items: items)
    }
    private static func allocatedSize(_ url: URL) -> (bytes: Int64, incomplete: Bool) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return (0, true) }
        if (info.st_mode & S_IFMT) == S_IFREG { return (Int64(info.st_blocks) * 512, false) }
        var bytes: Int64 = 0; var incomplete = false
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey], errorHandler: { _, _ in incomplete = true; return true }) else { return (0, true) }
        var identities = Set<String>()
        for case let child as URL in enumerator {
            autoreleasepool {
                var item = stat()
                guard lstat(child.path, &item) == 0 else { incomplete = true; return }
                guard (item.st_mode & S_IFMT) == S_IFREG else { return }
                guard identities.insert("\(item.st_dev):\(item.st_ino)").inserted else { return }
                bytes += Int64(item.st_blocks) * 512
            }
        }
        return (bytes, incomplete)
    }
    static func validate(_ item: AppRemovalItem, app: InstalledApp, appRoots: [URL] = appRoots,
                         library: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")) throws {
        let roots = item.isApp ? appRoots : [library]
        let path = item.url.standardizedFileURL.path
        guard roots.contains(where: { path.hasPrefix($0.standardizedFileURL.path + "/") }),
              item.url.resolvingSymlinksInPath().path == path else { throw RemovalError.changed }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK,
              "\(info.st_dev):\(info.st_ino)" == item.identity else { throw RemovalError.changed }
        if item.isApp { guard readApp(item.url)?.identifier == app.identifier else { throw RemovalError.changed } }
    }
    private enum RemovalError: LocalizedError {
        case changed
        var errorDescription: String? { "Pfad fehlt, wurde ersetzt oder liegt außerhalb des freigegebenen Bereichs. Bitte erneut prüfen." }
    }
}

@MainActor
final class AppManagerStore: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var plan: AppRemovalPlan?
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published var selected = Set<String>()
    private var removalSubscription: AnyCancellable?
    init() {
        removalSubscription = FileActions.shared.removals.sink { [weak self] change in
            guard let self else { return }
            let paths = change.paths.map(DiskScanner.canonicalPath)
            func removed(_ path: String) -> Bool {
                let path = DiskScanner.canonicalPath(path)
                return paths.contains { path == $0 || path.hasPrefix($0 + "/") }
            }
            self.apps.removeAll { removed($0.url.path) }
            if let plan = self.plan {
                if removed(plan.app.url.path) { self.plan = nil; self.selected = [] }
                else {
                    let items = plan.items.filter { !removed($0.url.path) }
                    self.plan = AppRemovalPlan(app: plan.app, items: items)
                    self.selected.formIntersection(Set(items.map(\.id)))
                }
            }
        }
    }
    func refresh() {
        guard !busy else { return }
        busy = true
        Task {
            apps = await Task.detached(priority: .utility) { AppInventory.apps() }.value
            busy = false
        }
    }
    func inspect(_ app: InstalledApp) {
        guard !busy else { return }
        busy = true; plan = nil; selected = []; status = "App und zugehörige Daten werden erfasst …"
        Task {
            let value = await Task.detached(priority: .utility) { AppInventory.plan(for: app) }.value
            plan = value
            selected = Set(value.items.filter { !$0.title.contains("Zuordnung prüfen") && $0.isApp }.map(\.id))
            status = "\(value.items.count) Bereiche gefunden. Zusätzliche App-Daten gezielt auswählen."
            busy = false
        }
    }
    func removeSelected() {
        guard !busy, let plan, !selected.isEmpty, plan.app.identifier != Bundle.main.bundleIdentifier,
              plan.app.url != Bundle.main.bundleURL else { return }
        let items = plan.items.filter { selected.contains($0.id) }
        busy = true
        Task {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: plan.app.identifier)
            for app in running { _ = app.terminate() }
            for _ in 0..<30 {
                if running.allSatisfy(\.isTerminated) { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard running.allSatisfy(\.isTerminated) else { status = "Die App läuft noch. Bitte beenden und erneut versuchen."; busy = false; return }
            let result = await Task.detached(priority: .utility) {
                var moved = 0; var removedPaths: [String] = []; var failures: [String] = []
                for item in items {
                    do { try AppInventory.validate(item, app: plan.app); try FileManager.default.trashItem(at: item.url, resultingItemURL: nil); moved += 1; removedPaths.append(item.url.path) }
                    catch { failures.append(item.url.lastPathComponent + ": " + error.localizedDescription) }
                }
                return (removedPaths, "\(moved) von \(items.count) Bereichen in den Papierkorb verschoben." + (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n")))
            }.value
            FileActions.shared.recordRemoval(paths: result.0, directories: Set(result.0))
            status = result.1; self.plan = nil; selected = []; busy = false
            apps = await Task.detached(priority: .utility) { AppInventory.apps() }.value
        }
    }
}
