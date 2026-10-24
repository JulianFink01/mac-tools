import AppKit
import Combine

struct ScanSnapshot: Codable, Identifiable {
    var id: UUID = UUID()
    let root: String
    let date: Date
    let bytes: Int64
    let files: Int
    let skipped: Int?
}

@MainActor
final class DiskScanStore: ObservableObject {
    static let shared = DiskScanStore(eagerRestore:false)
    @Published var root = FileManager.default.homeDirectoryForCurrentUser {
        didSet { defaults.set(root.path, forKey: "diskScanRoot") }
    }
    @Published var findDuplicates = UserDefaults.standard.object(forKey: "scanFindDuplicates") as? Bool ?? true {
        didSet { defaults.set(findDuplicates, forKey: "scanFindDuplicates") }
    }
    @Published private(set) var summary: DiskScanSummary?
    @Published private(set) var cachedResultAvailable = false
    @Published private(set) var result: DiskScanResult? { didSet { if let result { summary = DiskScanSummary(result) }; prepareDuplicateIndex() } }
    private let eagerRestore: Bool
    private var inventoryConsumers = Set<UUID>()
    private var inventoryRelease: Task<Void,Never>?
    private var restorableDate: Date?
    private var restoreTask: Task<Void,Never>?
    private var unloadedRemovalTask: Task<Void,Never>?
    func beginInventoryAccess(_ consumer:UUID) async {
        inventoryConsumers.insert(consumer); inventoryRelease?.cancel()
        await unloadedRemovalTask?.value
        if result == nil { restoreCachedResult() }
        await restoreTask?.value
    }
    func endInventoryAccess(_ consumer:UUID) {
        inventoryConsumers.remove(consumer); scheduleInventoryRelease()
    }
    private func scheduleInventoryRelease() {
        guard !eagerRestore,inventoryConsumers.isEmpty else { return }
        inventoryRelease?.cancel()
        inventoryRelease = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:10_000_000_000) } catch { return }
            self?.releaseUnusedInventory()
        }
    }
    func releaseUnusedInventory() {
        guard !eagerRestore,inventoryConsumers.isEmpty,!isScanning,!isSaving,!isApplyingRemovals,!isRestoring,
              let result,restorableDate == result.completedAt else { return }
        duplicateIndexTask?.cancel(); duplicateIndexTask = nil
        self.result = nil; duplicateIndex = nil; FileBrowserStore.shared.releaseCache(root: result.root, date: result.completedAt)
    }
    @Published private(set) var duplicateIndex: DuplicateViewIndex?
    private var duplicateIndexTask: Task<Void, Never>?
    private var duplicateIndexGeneration = UUID()
    @Published private(set) var isScanning = false
    @Published private(set) var isSaving = false
    @Published private(set) var isApplyingRemovals = false
    @Published private(set) var removedPaths: Set<String> = []
    private var pendingRemovals: Set<String> = []
    private var pendingDirectories: Set<String> = []
    private var removalSubscription: AnyCancellable?
    var acceptsFileChanges = true
    private var suppressDuplicateRebuild = false
    @Published private(set) var isRestoring = false
    @Published private(set) var progress = DiskScanProgress(files: 0, bytes: 0, phase: "Bereit")
    @Published private(set) var status = "Wähle einen Ordner oder ein Volume für die Analyse."
    @Published private(set) var history: [ScanSnapshot] = []
    @Published private(set) var accessStatus = ""
    @Published private(set) var isCheckingAccess = false
    @Published private(set) var restoredResult = false
    @Published private(set) var resultIsProvisional = false
    private var task: Task<Void, Never>?
    private var selectionGeneration = UUID()
    private let defaults: UserDefaults
    private let resultURL: URL
    private let historyURL: URL

    init(defaults: UserDefaults = .standard, directory: URL = VideoLibraryStore.appSupportDirectory, eagerRestore:Bool = true,
         defaultRoot: URL? = nil, retainUnavailableRoot: Bool = false) {
        self.eagerRestore = eagerRestore; self.defaults = defaults
        resultURL = directory.appendingPathComponent("last-disk-scan.plist")
        historyURL = directory.appendingPathComponent("disk-history.json")
        findDuplicates = defaults.object(forKey: "scanFindDuplicates") as? Bool ?? true
        if let savedRoot = defaults.string(forKey: "diskScanRoot"),
           retainUnavailableRoot || FileManager.default.fileExists(atPath: savedRoot) {
            root = URL(fileURLWithPath: savedRoot, isDirectory: true)
        } else if let defaultRoot { root = defaultRoot }
        if let data = try? Data(contentsOf: historyURL), let saved = try? JSONDecoder().decode([ScanSnapshot].self, from: data) {
            history = saved
        }
        cachedResultAvailable = FileManager.default.fileExists(atPath:resultURL.path)
        removalSubscription = FileActions.shared.removals.sink { [weak self] change in
            guard let self, self.acceptsFileChanges else { return }
            self.applyRemoved(paths:change.paths,directories:change.directories)
        }
        if eagerRestore { restoreCachedResult() }
        else if cachedResultAvailable {
            status = "Gespeicherter Scan verfügbar · Dateiliste wird bei Bedarf geladen."
            summary = try? DiskScanCache.summary(from:resultURL)
            if let saved = summary, DiskScanner.canonicalPath(saved.root.path) != DiskScanner.canonicalPath(root.path) {
                summary = nil; cachedResultAvailable = false
                status = "Bereit für die Analyse."
            }
        }
    }
    private func restoreCachedResult() {
        guard result == nil,!isRestoring,!isScanning,cachedResultAvailable else { return }
        isRestoring = true; status = "Gespeicherte Dateiliste wird geladen …"
        let url = resultURL,generation = selectionGeneration
        restoreTask = Task {
            let saved = await Task.detached(priority:.utility) { try? DiskScanCache.load(from:url) }.value
            if selectionGeneration == generation { isRestoring = false }
            guard selectionGeneration == generation,!isScanning,result == nil,let saved,
                  saved.root.resolvingSymlinksInPath() == root.resolvingSymlinksInPath() else { return }
            restoredResult = true; restorableDate = saved.completedAt; result = saved
            status = "Gespeicherter Scan · " + saved.completedAt.formatted(date:.abbreviated,time:.shortened) + (saved.reachedLimit || saved.skipped > 0 ? " · mit Einschränkungen" : "")
            scheduleInventoryRelease()
        }
    }

    /// Retain the index across tab/window changes. Antivirus progress must not
    /// restart filtering a million duplicate paths or touch their directories.
    private func prepareDuplicateIndex() {
        if suppressDuplicateRebuild { return }
        duplicateIndexTask?.cancel()
        let token = UUID(); duplicateIndexGeneration = token
        guard let result else { duplicateIndex = nil; return }
        duplicateIndexTask = Task {
            let worker = Task.detached(priority: .userInitiated) { try DuplicateViewIndex.build(result.duplicates) }
            do {
                let value = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard duplicateIndexGeneration == token else { return }
                duplicateIndex = value
            } catch { }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Scan-Ordner wählen"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectRoot(url)
    }

    func selectRoot(_ url: URL) {
        guard !isScanning, !isSaving, !isApplyingRemovals, root != url else { return }
        let oldRoot = root
        let oldDate = result?.completedAt ?? summary?.completedAt
        selectionGeneration = UUID()
        isRestoring = false
        root = url
        result = nil;summary = nil;cachedResultAvailable = false;restorableDate = nil
        if let oldDate { FileBrowserStore.shared.releaseCache(root: oldRoot, date: oldDate) }
        status = "Bereit für die Analyse."
    }

    func start() {
        guard !isScanning, !isRestoring, !isSaving, !isApplyingRemovals else { return }
        selectionGeneration = UUID()
        isScanning = true
        progress = DiskScanProgress(files: 0, bytes: 0, phase: "Dateien erfassen")
        status = "Scan läuft …"
        let scanRoot = root
        let duplicates = findDuplicates
        let generation = selectionGeneration
        let previousResult = result
        let wasRestored = restoredResult
        let hashesURL = resultURL.deletingLastPathComponent().appendingPathComponent("file-hashes.sqlite")
        task = Task {
            let worker = Task.detached(priority: .utility) {
                try DiskScanner.scan(root: scanRoot, findDuplicates: duplicates, cacheURL: hashesURL, inventory: { partial in
                    Task { @MainActor [weak self] in
                        guard let self, self.isScanning, self.selectionGeneration == generation else { return }
                        self.restoredResult = false
                        self.resultIsProvisional = true
                        self.result = partial
                    }
                }) { update in
                    Task { @MainActor [weak self] in
                        guard self?.isScanning == true, self?.selectionGeneration == generation else { return }
                        self?.progress = update
                    }
                }
            }
            do {
                let value = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                  onCancel: { worker.cancel() })
                try Task.checkCancellation()
                restoredResult = false
                resultIsProvisional = false
                removedPaths = []
                result = value
                isSaving = true
                progress = DiskScanProgress(files: value.files.count, bytes: value.bytes, phase: "Ergebnis speichern")
                status = "Inhaltsprüfung abgeschlossen · Ergebnis wird gespeichert …"
                let cacheURL = resultURL
                let saveError = await Task.detached(priority: .utility) { () -> String? in
                    do {
                        try DiskScanCache.save(value, to: cacheURL)
                        return nil
                    } catch { return error.localizedDescription }
                }.value
                status = (value.omissions?.unavailable ?? value.skipped) > 0 ? "Gesamtscan beendet · \(value.files.count.formatted()) Dateien · \((value.omissions?.unavailable ?? value.skipped).formatted()) nicht lesbare Dateien."
                    : "Gesamtscan abgeschlossen · \(value.files.count.formatted()) Dateien · \(value.completedAt.formatted(date: .abbreviated, time: .shortened))"
                if let saveError { status += " · Speichern fehlgeschlagen: " + saveError }
                else { restorableDate = value.completedAt; cachedResultAvailable = true }
                if !value.reachedLimit {
                    history.append(ScanSnapshot(root: value.root.path, date: value.completedAt, bytes: value.bytes, files: value.files.count, skipped: value.omissions?.unavailable ?? value.skipped))
                    history = Array(history.suffix(100))
                    do { try JSONEncoder().encode(history).write(to: historyURL, options: .atomic) }
                    catch { status += " Verlauf konnte nicht gespeichert werden: \(error.localizedDescription)" }
                }
            } catch is CancellationError {
                resultIsProvisional = true
                result = previousResult; restoredResult = wasRestored
                status = "Scan abgebrochen. Der letzte gespeicherte Scan bleibt erhalten."
            } catch {
                resultIsProvisional = true
                result = previousResult; restoredResult = wasRestored
                status = "Scan fehlgeschlagen: \(error.localizedDescription)"
            }
            isSaving = false
            isScanning = false
            resultIsProvisional = false
            task = nil; scheduleInventoryRelease()
        }
    }

    func isRemoved(_ path: String) -> Bool {
        let path = DiskScanner.canonicalPath(path)
        if removedPaths.contains(path) { return true }
        var ancestor = (path as NSString).deletingLastPathComponent
        while ancestor != "/" && !ancestor.isEmpty {
            if removedPaths.contains(ancestor) { return true }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        return false
    }

    /// Publish removal masks and duplicate counters immediately. Serialize the
    /// larger inventory update and journal writes; rapid removals are queued.
    func applyRemoved(paths: [String], directories: Set<String> = []) {
        guard let previous = result else {
            guard cachedResultAvailable,let summary else { return }
            let base = DiskScanner.canonicalPath(summary.root.path)
            let scoped = Set(paths.map(DiskScanner.canonicalPath).filter { DiskScanner.isPathInScanScope($0, root: base) })
            guard !scoped.isEmpty else { return }
            pendingRemovals.formUnion(scoped); pendingDirectories.formUnion(directories.map(DiskScanner.canonicalPath).filter { DiskScanner.isPathInScanScope($0, root: base) })
            removedPaths.formUnion(scoped)
            guard !isApplyingRemovals else { return }; isApplyingRemovals = true
            let destination = resultURL,date = summary.completedAt
            unloadedRemovalTask = Task {
                while !pendingRemovals.isEmpty {
                    let batch = pendingRemovals,folders = pendingDirectories; pendingRemovals = [];pendingDirectories = []
                    let failure = await Task.detached(priority:.utility) { () -> String? in
                        do { try DiskScanCache.saveRemoved(paths:batch,directories:folders,scanDate:date,to:destination); return nil }
                        catch { return error.localizedDescription }
                    }.value
                    if let failure { status = "Bereinigungsstand konnte nicht gespeichert werden: " + failure }
                }
                isApplyingRemovals = false; unloadedRemovalTask = nil
            }
            return
        }
        let rootPath = DiskScanner.canonicalPath(previous.root.path)
        let fresh = Set(paths.map(DiskScanner.canonicalPath).filter { DiskScanner.isPathInScanScope($0, root: rootPath) && !removedPaths.contains($0) })
        guard !fresh.isEmpty else { return }
        removedPaths.formUnion(fresh)
        duplicateIndex = duplicateIndex?.removing(paths: fresh)
        pendingRemovals.formUnion(fresh)
        pendingDirectories.formUnion(directories.map(DiskScanner.canonicalPath))
        guard !isApplyingRemovals else { return }
        isApplyingRemovals = true
        let destination = resultURL
        Task {
            while !pendingRemovals.isEmpty, let current = result {
                let batch = pendingRemovals, folders = pendingDirectories
                pendingRemovals = []; pendingDirectories = []
                let index = duplicateIndex
                let update = await Task.detached(priority: .utility) {
                    // Also handle whole app/data folders removed from Apps.
                    var expanded = batch
                    if !folders.isEmpty {
                        let prefixes = folders.map { $0 + "/" }
                        for file in current.files where prefixes.contains(where: { DiskScanner.canonicalPath(file.path).hasPrefix($0) }) { expanded.insert(file.path) }
                    }
                    let value = current.removing(paths: expanded)
                    do { try DiskScanCache.saveRemoved(paths: expanded, scanDate: value.completedAt, to: destination); return (value, expanded, String?.none, index?.removing(paths: expanded)) }
                    catch { return (value, expanded, Optional(error.localizedDescription), index?.removing(paths: expanded)) }
                }.value
                // A concurrent completed scan owns its own result.
                guard result?.completedAt == current.completedAt else { continue }
                let later = pendingRemovals
                duplicateIndex = later.isEmpty ? update.3 : update.3?.removing(paths: later)
                suppressDuplicateRebuild = duplicateIndex != nil
                result = update.0
                suppressDuplicateRebuild = false
                if let error = update.2 { status = "Bereinigt · Speichern fehlgeschlagen: " + error }
            }
            isApplyingRemovals = false; scheduleInventoryRelease()
        }
    }

    func checkAccess() {
        guard !isCheckingAccess else { return }
        // Probe only sample paths from the scan, without altering permissions or results.
        let probes = result?.warningSamples.compactMap { sample -> String? in
            guard let split = sample.range(of: ": ") else { return nil }
            return String(sample[..<split.lowerBound])
        } ?? []
        guard !probes.isEmpty else { accessStatus = "Keine gespeicherten Problempfade zum Prüfen."; return }
        isCheckingAccess = true
        Task {
            let counts = await Task.detached(priority: .utility) { () -> (Int, Int, Int) in
                var readable = 0, blocked = 0, missing = 0
                for path in probes {
                    do {
                        let url = URL(fileURLWithPath: path)
                        if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                            _ = try FileManager.default.contentsOfDirectory(atPath: path)
                        } else {
                            let handle = try FileHandle(forReadingFrom: url)
                            defer { try? handle.close() }
                            _ = try handle.read(upToCount: 1)
                        }
                        readable += 1
                    }
                    catch {
                        let error = error as NSError
                        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { missing += 1 }
                        else { blocked += 1 }
                    }
                }
                return (readable, blocked, missing)
            }.value
            accessStatus = "Aktuell: \(counts.0) der \(probes.count) Beispielpfade lesbar, \(counts.1) nicht erreichbar, \(counts.2) nicht mehr vorhanden."
                + (counts.1 == 0 ? " Neue Freigaben werden erst durch einen neuen Scan in der Statistik berücksichtigt." : " macOS blockiert diese Zugriffe weiterhin; die Fenstersteuerungsfreigabe ist kein Nachweis für Festplattenvollzugriff.")
            isCheckingAccess = false
        }
    }

    func cancel() { guard !isSaving else { return }; task?.cancel(); status = "Scan wird abgebrochen …" }
}

func diskBytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}
