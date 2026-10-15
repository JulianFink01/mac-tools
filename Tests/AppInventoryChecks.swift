import Foundation

@main struct AppInventoryChecks {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("MacTools-uninstall-\(UUID().uuidString)").resolvingSymlinksInPath()
        let applications = root.appendingPathComponent("Applications")
        let library = root.appendingPathComponent("Library")
        let app = applications.appendingPathComponent("Example.app")
        try manager.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let id = "org.mactools.fixture"
        let info: [String: Any] = ["CFBundleName": "Example", "CFBundleIdentifier": id, "CFBundleShortVersionString": "1.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let cache = library.appendingPathComponent("Caches/" + id)
        try manager.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 8000).write(to: cache.appendingPathComponent("cache.dat"))
        let shared = library.appendingPathComponent("Group Containers/group.org.shared")
        try manager.createDirectory(at: shared, withIntermediateDirectories: true)
        let nameFolder = library.appendingPathComponent("Application Support/Example")
        try manager.createDirectory(at: nameFolder, withIntermediateDirectories: true)
        let sibling = library.appendingPathComponent("Caches/" + id + ".other")
        try manager.createDirectory(at: sibling, withIntermediateDirectories: true)
        let apps = AppInventory.apps(roots: [applications])
        precondition(apps.count == 1 && apps[0].identifier == id)
        let plan = AppInventory.plan(for: apps[0], library: library)
        precondition(plan.items.contains { $0.url.path == cache.path && $0.bytes > 0 })
        precondition(plan.items.contains { $0.url.path == nameFolder.path && $0.title.contains("Zuordnung prüfen") })
        precondition(!plan.items.contains { $0.url.path == shared.path || $0.url.path == sibling.path }, "Shared/prefix-similar folders must not be associated")
        for item in plan.items { try AppInventory.validate(item, app: apps[0], appRoots: [applications], library: library) }
        let cacheItem = plan.items.first { $0.url.path == cache.path }!
        try manager.moveItem(at: cache, to: cache.appendingPathExtension("old"))
        try manager.createSymbolicLink(atPath: cache.path, withDestinationPath: shared.path)
        do { try AppInventory.validate(cacheItem, app: apps[0], appRoots: [applications], library: library); preconditionFailure("Symlink swap must be rejected") } catch {}
        var swapped = info; swapped["CFBundleIdentifier"] = "org.other"
        try PropertyListSerialization.data(fromPropertyList: swapped, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        do { try AppInventory.validate(plan.items.first { $0.isApp }!, app: apps[0], appRoots: [applications], library: library); preconditionFailure("Different app identifier must be rejected") } catch {}
        print("PASS: app inventory, exact-ID data association, name-only candidates flagged, shared/prefix-similar data excluded, sizes, symlink replacement and identifier replacement rejected; no user app removed")
    }
}
