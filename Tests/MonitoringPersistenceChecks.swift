import Foundation

@main
struct MonitoringPersistenceChecks {
    @MainActor
    static func main() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("MacTools-persistence-\(UUID().uuidString)")
        let fixture = directory.appendingPathComponent("files")
        let cache = directory.appendingPathComponent("cache")
        try manager.createDirectory(at: fixture.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let domain = "MacTools.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { try? manager.removeItem(at: directory); defaults.removePersistentDomain(forName: domain) }
        try Data("duplicate".utf8).write(to: fixture.appendingPathComponent("one.txt"))
        try Data("duplicate".utf8).write(to: fixture.appendingPathComponent("nested/two.txt"))
        try Data(repeating: 3, count: 90000).write(to: fixture.appendingPathComponent("nested/movie.mp4"))
        let settings = SettingsStore(defaults: defaults)
        precondition(settings.enabledMonitorWidgets == Set(MonitorMetric.allCases))
        settings.setWidget(.gpu, enabled: false)
        precondition(!SettingsStore(defaults: defaults).enabledMonitorWidgets.contains(.gpu))
        for metric in MonitorMetric.allCases { settings.setWidget(metric, enabled: false) }
        precondition(SettingsStore(defaults: defaults).enabledMonitorWidgets.isEmpty, "All off must persist as empty, not fall back to defaults")
        settings.setWidget(.ram, enabled: true)
        precondition(SettingsStore(defaults: defaults).enabledMonitorWidgets == [.ram])
        print("PASS: widget defaults, individual disable, all off and re-enable survive settings reload")
        let personalHome = directory.appendingPathComponent("personal-home")
        let cloud = personalHome.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        try manager.createDirectory(at: cloud.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        let cloudVideo = cloud.appendingPathComponent("Downloads/video.mp4")
        try Data("personal-video".utf8).write(to: cloudVideo)
        let cloudFile = try DiskFile.snapshot(at: cloudVideo)
        precondition(DuplicateMediaSafety.eligibleMedia(cloudFile, home: personalHome))
        let project = cloud.appendingPathComponent("project")
        try manager.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        let projectVideo = project.appendingPathComponent("asset.mp4")
        try Data("project-video".utf8).write(to: projectVideo)
        let projectFile = try DiskFile.snapshot(at: projectVideo)
        precondition(!DuplicateMediaSafety.eligibleMedia(projectFile, home: personalHome))
        print("PASS: personal iCloud Drive Downloads selectable; iCloud project assets remain protected")
        let store = DiskScanStore(defaults: defaults, directory: cache)
        store.root = fixture
        store.start()
        while store.isScanning { try await Task.sleep(nanoseconds: 20_000_000) }
        guard let original = store.result else { fatalError(store.status) }
        precondition(original.files.count == 3 && original.duplicates.count == 1 && original.bytes == 90018)
        let restored = DiskScanStore(defaults: defaults, directory: cache)
        for _ in 0..<100 where restored.result == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let originalData = try encoder.encode(original); let restoredData = try encoder.encode(restored.result!)
        precondition(originalData == restoredData, "Whole result including paths, identity, folders, types and duplicates must survive")
        precondition(restored.history.count == 1)
        restored.start(); restored.cancel()
        while restored.isScanning { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(restored.result?.completedAt == original.completedAt, "Cancellation must preserve last completed scan")
        let removedPath = original.files.first { $0.url.lastPathComponent == "two.txt" }!.path
        let removedFile = original.files.first { $0.path == removedPath }!
        let removed: [String] = await withCheckedContinuation { continuation in
            FileActions.shared.trash([removedFile]) { continuation.resume(returning: $0) }
        }
        precondition(removed == [removedPath] && !manager.fileExists(atPath: removedPath))
        let baseBeforeCleanup = try Data(contentsOf: cache.appendingPathComponent("last-disk-scan.plist"))
        restored.applyRemoved(paths: removed)
        precondition(!restored.isScanning, "Deleting must not launch another scan")
        while restored.isSaving || restored.isApplyingRemovals { try await Task.sleep(nanoseconds: 20_000_000) }
        let baseAfterCleanup = try Data(contentsOf: cache.appendingPathComponent("last-disk-scan.plist"))
        precondition(baseAfterCleanup == baseBeforeCleanup, "Cleanup must not rewrite the full scan cache")
        precondition(restored.result!.files.count == 2 && restored.result!.duplicates.isEmpty)
        precondition(restored.result!.bytes == original.bytes - 9)
        precondition(restored.result!.completedAt == original.completedAt && restored.history.count == 1)
        let afterRemoval = DiskScanStore(defaults: defaults, directory: cache)
        for _ in 0..<100 where afterRemoval.result == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(afterRemoval.result?.files.count == 2 && afterRemoval.result?.duplicates.isEmpty == true)
        let stale: [String] = await withCheckedContinuation { continuation in
            FileActions.shared.trash([removedFile]) { continuation.resume(returning: $0) }
        }
        precondition(stale == [removedPath] && FileActions.shared.status?.contains("bereits fehlende") == true)
        print("PASS: real Trash operation reports moved path; repeated stale action removes missing UI entry without pretending another deletion")
        print("PASS: known removals update files, folders, bytes and duplicate groups; persist after restart; no disk/virus rescan; original scan date retained")
        let partial = DiskScanResult(root: original.root, completedAt: original.completedAt, files: original.files, folders: original.folders,
            categories: original.categories, duplicates: original.duplicates, skipped: 2, warningSamples: ["unreadable"], reachedLimit: true,
            duplicateSearch: true, volumeTotal: original.volumeTotal, volumeFree: original.volumeFree, bytes: original.bytes,
            allocatedBytes: original.allocatedBytes, redundantBytes: original.redundantBytes)
        try encoder.encode(partial).write(to: cache.appendingPathComponent("last-disk-scan.plist"))
        let partialStore = DiskScanStore(defaults: defaults, directory: cache)
        for _ in 0..<100 where partialStore.result == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(partialStore.result?.skipped == 2 && partialStore.result?.reachedLimit == true)
        precondition(partialStore.status.contains("Einschränkungen"))
        try Data("broken-cache".utf8).write(to: cache.appendingPathComponent("last-disk-scan.plist"))
        let broken = DiskScanStore(defaults: defaults, directory: cache)
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(broken.result == nil && broken.history.count == 1, "Corrupt cache must not destroy history")
        struct SavedVirus: Codable { let report: SecurityReport; let root: URL; let date: Date }
        let date = Date()
        let report = SecurityReport(exitCode: 1, output: fixture.appendingPathComponent("one.txt").path + ": Eicar-Test-Signature FOUND\nScanned files: 3\n", cancelled: false)
        try encoder.encode(SavedVirus(report: report, root: fixture, date: date)).write(to: cache.appendingPathComponent("last-virus-scan.plist"))
        let virus = SecurityScanStore(directory: cache)
        precondition(virus.report?.items.count == 1 && virus.report?.items.first?.isTest == true && virus.report?.scannedFiles == 3)
        precondition(virus.restoredReport && virus.scannedRoot == fixture && virus.completedAt == date)
        print("PASS: actual disk scan → atomic save → new store restore; cancelled scan preserves result; partial coverage restored; corrupt cache tolerated; virus findings/root/date restored as historical")
        let sampler = SystemSampler()
        let first = sampler.read()
        precondition(first.point.cpu == nil && first.point.diskRead == nil, "Rates need two samples")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let reading = sampler.read()
        guard let cpu = reading.point.cpu, let ram = reading.point.memory else { fatalError("CPU/RAM unavailable") }
        precondition((0...100).contains(cpu) && (0...100).contains(ram))
        precondition(!reading.cores.isEmpty && reading.totalMemory > 0)
        precondition(reading.processes.allSatisfy { $0.memory >= 0 && ($0.cpu ?? 0) >= 0 })
        if let pressure = reading.memoryPressure { precondition([1, 2, 4].contains(pressure)) }
        if let disk = reading.point.diskUsed { precondition((0...100).contains(disk)) }
        if let gpu = reading.point.gpu { precondition((0...100).contains(gpu)) }
        let decoded = try PropertyListDecoder().decode([MonitorPoint].self, from: encoder.encode([reading.point]))
        precondition(decoded.count == 1)
        print("LIVE: CPU \(monitorPercent(cpu)), RAM \(monitorPercent(ram)), GPU \(monitorPercent(reading.point.gpu)), read \(monitorRate(reading.point.diskRead)), write \(monitorRate(reading.point.diskWrite)), \(reading.processes.count) visible processes, \(reading.volumes.count) volumes, cores \(reading.cores.count)")
    }
}
