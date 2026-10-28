import Foundation
import AppKit

@main
struct MonitoringPersistenceChecks {
    @MainActor
    static func main() async throws {
        let privateDomain = "MacTools.PrivateVisibility." + UUID().uuidString
        let privateDefaults = UserDefaults(suiteName: privateDomain)!
        privateDefaults.set(["InfraPilot", "AlphaTrader", "Codex-Chats"],forKey:"sidebarFavoriteTools")
        privateDefaults.set(["InfraPilot", "AlphaTrader", "Codex-Chats"],forKey:"sidebarFavoriteOrder")
        privateDefaults.set(["InfraPilot", "AlphaTrader", "Codex-Chats"],forKey:"pinnedMenuTools")
        let publicSettings = SettingsStore(defaults:privateDefaults)
        precondition(!PrivateMCPAccess.enabled && !publicSettings.sidebarFavorites.contains(.infrapilot) && !publicSettings.sidebarFavorites.contains(.alphaTrader))
        precondition(publicSettings.pinnedTools == [.codex])
        publicSettings.setPinned(.infrapilot,enabled:true); publicSettings.setSidebarFavorite(.alphaTrader,enabled:true)
        precondition(publicSettings.pinnedTools == [.codex] && !publicSettings.sidebarTools.contains(.alphaTrader))
        privateDefaults.removePersistentDomain(forName:privateDomain)
        print("PASS: public build hides private integrations even with copied private favorites and rejects enabling them")
        let warning = { (title: String) in ScanWarning(id: UUID(), date: Date(), title: title, detail: "fixture").isImportant }
        precondition(!warning("Nicht lesbare Dateien") && !warning("Disk-Scan fehlgeschlagen") && warning("Verdächtige Dateien gefunden") && warning("Kritisch wenig Speicher"))
        let pinDomain = "MacTools.ToolPins." + UUID().uuidString
        let pinDefaults = UserDefaults(suiteName: pinDomain)!
        let pinSettings = SettingsStore(defaults: pinDefaults)
        pinSettings.setPinned(.codex, enabled: true); pinSettings.setPinned(.containers, enabled: true)
        precondition(SettingsStore(defaults: pinDefaults).pinnedTools == [.codex, .containers])
        pinSettings.setPinned(.codex, enabled: false)
        precondition(SettingsStore(defaults: pinDefaults).pinnedTools == [.containers])
        pinSettings.quickPanelCompactVolume = true; pinSettings.quickPanelEventTabs = false
        precondition(SettingsStore(defaults: pinDefaults).quickPanelCompactVolume && !SettingsStore(defaults: pinDefaults).quickPanelEventTabs)
        pinSettings.quickPanelWidgets = [.cpu, .codex, .volume]
        pinSettings.moveQuickWidget(.volume, to: 0)
        precondition(SettingsStore(defaults: pinDefaults).quickPanelWidgets == [.volume, .cpu, .codex])
        pinSettings.quickPanelWidgets = []
        precondition(SettingsStore(defaults: pinDefaults).quickPanelWidgets.isEmpty)
        pinSettings.setSidebarFavorite(.windows, enabled: true)
        precondition(SettingsStore(defaults: pinDefaults).sidebarTools.contains(.windows))
        let eventPages = QuickPanelCardLayout.eventPages(ids: ["infra", "trader", "docker1", "docker2", "docker3"], containerIDs: ["docker1", "docker2", "docker3"], rows: 4)
        precondition(eventPages == [["infra", "trader", "docker1", "docker2"], ["docker3"]])
        let spareEvents = QuickPanelCardLayout.counts(widgets: [.liveFeed], height: 500, multipleRunningChats: false, eventCount: 8, compactVolume: false, eventTabs: false)
        precondition(spareEvents.events == 4)
        for section in ToolNavigation.Section.pinnable { pinSettings.setSidebarFavorite(section, enabled: false) }
        precondition(SettingsStore(defaults: pinDefaults).sidebarTools.isEmpty)
        precondition(SettingsStore(defaults: pinDefaults).pinnedTools == [.containers], "Sidebar preferences must be independent from macOS menu pins")
        pinSettings.setSidebarFavorite(.codex, enabled: true); pinSettings.setSidebarFavorite(.apps, enabled: true)
        pinSettings.moveSidebar(.apps, before: .codex)
        precondition(SettingsStore(defaults: pinDefaults).sidebarFavorites == [.apps, .codex])
        let favoriteFolder = "/tmp/MacTools-FolderFixture"
        pinSettings.setSidebarFolder(favoriteFolder, enabled: true)
        pinSettings.moveSidebarEntry(.folder(favoriteFolder), before: .tool(.apps))
        precondition(SettingsStore(defaults: pinDefaults).sidebarEntries == [.folder(favoriteFolder), .tool(.apps), .tool(.codex)])
        precondition(!pinSettings.pinnedCodexFolders.contains(favoriteFolder), "App folder favorite must not create a macOS menu item")
        pinSettings.setChatPinned("test-pinned-chat", enabled: true); pinSettings.setChatPinned("test-pinned-chat", enabled: true)
        precondition(SettingsStore(defaults: pinDefaults).pinnedCodexChats == ["test-pinned-chat"])
        pinSettings.setChatPinned("test-pinned-chat", enabled: false)
        precondition(SettingsStore(defaults: pinDefaults).pinnedCodexChats.isEmpty)
        pinSettings.pinCodexFolder(favoriteFolder)
        pinSettings.setSidebarFolder(favoriteFolder, enabled: false)
        precondition(SettingsStore(defaults: pinDefaults).pinnedCodexFolders.contains(favoriteFolder), "Removing an App favorite must preserve the separate macOS pin")
        _ = NSApplication.shared
        let firstWindowDomain = "MacTools.WindowQA." + UUID().uuidString, secondWindowDomain = "MacTools.WindowQA." + UUID().uuidString
        let firstWindowDefaults = UserDefaults(suiteName: firstWindowDomain)!, secondWindowDefaults = UserDefaults(suiteName: secondWindowDomain)!
        firstWindowDefaults.set(true, forKey: "alwaysOnTop"); secondWindowDefaults.set(true, forKey: "alwaysOnTop")
        let mainSelection = CodexStore.shared.selectedID
        let firstWindow = CodexChatWindowController(id: UUID(), chatID: "first-window", defaults: firstWindowDefaults)
        let secondWindow = CodexChatWindowController(id: UUID(), chatID: "second-window", defaults: secondWindowDefaults)
        precondition(firstWindow.store !== secondWindow.store && firstWindow.store !== CodexStore.shared)
        firstWindow.store.drafts["first-window"] = "erster Entwurf"; secondWindow.store.drafts["second-window"] = "zweiter Entwurf"
        firstWindow.store.workingDirectory = "/tmp/first-window"; secondWindow.store.workingDirectory = "/tmp/second-window"
        firstWindow.store.enqueue("nur im ersten Fenster", in: "first-window")
        precondition(secondWindow.store.queuedMessages.isEmpty && firstWindow.store.queuedMessages["first-window"]?.count == 1)
        firstWindow.store.newChat()
        precondition(firstWindow.store.hasPendingWork, "Closing a window must preserve queued work for a previously selected chat")
        precondition(secondWindow.store.selectedID == "second-window" && CodexStore.shared.selectedID == mainSelection)
        precondition(secondWindow.store.drafts["second-window"] == "zweiter Entwurf" && secondWindow.store.workingDirectory == "/tmp/second-window")
        firstWindow.alwaysOnTop = false
        precondition(firstWindow.window?.level == .normal && secondWindow.window?.level == .floating && secondWindow.alwaysOnTop)
        let restoredWindowStore = CodexStore(defaults: secondWindowDefaults, followAllChats: false)
        precondition(restoredWindowStore.drafts["second-window"] == "zweiter Entwurf")
        firstWindow.stop(); secondWindow.stop(); firstWindow.window?.close(); secondWindow.window?.close()
        firstWindowDefaults.removePersistentDomain(forName: firstWindowDomain); secondWindowDefaults.removePersistentDomain(forName: secondWindowDomain)
        print("PASS: independent native chat windows, selections, drafts, queues, folders and per-window floating levels; main selection unchanged")
        let nativeItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        CodexChatMenuAppearance.apply(to: nativeItem.button!, active: true, waiting: true)
        precondition(nativeItem.button?.image?.isTemplate == false, "Waiting chat uses a colored blue symbol")
        CodexChatMenuAppearance.apply(to: nativeItem.button!, active: true, waiting: false)
        precondition(nativeItem.button?.image?.isTemplate == true, "Working chat restores the native menu template")
        var nativeRemoved = 0
        let visibility = StatusItemVisibility(item: nativeItem, name: "MacTools.QA." + UUID().uuidString, userRemoval: { true }) {
            nativeRemoved += 1; pinSettings.setPinned(.containers, enabled: false)
        }
        nativeItem.isVisible = false
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(nativeRemoved == 1 && !SettingsStore(defaults: pinDefaults).pinnedTools.contains(.containers))
        visibility.invalidate(); NSStatusBar.system.removeStatusItem(nativeItem)
        let nonUserItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        var unexpectedRemoval = false
        let nonUserVisibility = StatusItemVisibility(item: nonUserItem, name: "MacTools.QA.Internal." + UUID().uuidString, userRemoval: { false }) { unexpectedRemoval = true }
        nonUserItem.isVisible = false; try await Task.sleep(nanoseconds: 100_000_000)
        precondition(!unexpectedRemoval, "Internal visibility changes must not erase user pins")
        nonUserVisibility.invalidate(); NSStatusBar.system.removeStatusItem(nonUserItem)
        precondition(QuickPanelWidget.rows([.codex, .codexLimit, .cpu], usagePlacement: "chats").first == [.codexLimit, .codex])
        precondition(QuickPanelWidget.rows([.codexLimit, .codex, .cpu], usagePlacement: "chats").first == [.codexLimit, .codex])
        let metrics = QuickPanelWidget.rows([.codexLimit, .cpu, .ram, .gpu, .disk], usagePlacement: "metrics")
        precondition(metrics.map(\.count) == [3, 2], "Five metrics should not produce a clipped fifth column")
        precondition(QuickPanelCardLayout.page(selectedID: "docker", fallback: 1, ids: ["scan", "audio", "docker"], rows: 1) == 2)
        precondition(QuickPanelCardLayout.page(selectedID: "docker", fallback: 2, ids: ["audio", "docker"], rows: 1) == 1)
        precondition(QuickPanelCardLayout.page(selectedID: "docker", fallback: 2, ids: ["audio", "docker"], rows: 2) == 0)
        precondition(QuickPanelCardLayout.page(selectedID: "gone", fallback: 3, ids: ["audio"], rows: 1) == 0)
        print("PASS: selected Docker card survives insertion, removal and adaptive row changes")
        let shared = QuickPanelCardLayout.counts(widgets: [.codexLimit, .codex], height: 144, multipleRunningChats: true, eventCount: 0, compactVolume: false, eventTabs: false, usagePlacement: "chats")
        precondition(shared.codex == 2, "Both chats use the height already allocated to the large limit chart")
        let spacious = QuickPanelCardLayout.counts(widgets: [.codex, .liveFeed], height: 400, multipleRunningChats: true, eventCount: 3, compactVolume: false, eventTabs: false)
        precondition(spacious.codex == 2 && spacious.events == 3)
        let tight = QuickPanelCardLayout.counts(widgets: [.codex, .liveFeed], height: 240, multipleRunningChats: true, eventCount: 3, compactVolume: false, eventTabs: false)
        precondition(tight.codex == 2 && tight.events == 1, "Codex receives the only spare row")
        let oneRunning = QuickPanelCardLayout.counts(widgets: [.codex, .liveFeed], height: 240, multipleRunningChats: false, eventCount: 3, compactVolume: false, eventTabs: false)
        precondition(oneRunning.codex == 1 && oneRunning.events == 2)
        let oneDrive = QuickPanelCardLayout.counts(widgets: [.volume, .codex, .liveFeed], height: 430, multipleRunningChats: true, eventCount: 4, compactVolume: true, eventTabs: false, volumeCount: 1)
        let threeDrives = QuickPanelCardLayout.counts(widgets: [.volume, .codex, .liveFeed], height: 430, multipleRunningChats: true, eventCount: 4, compactVolume: true, eventTabs: false, volumeCount: 3)
        precondition(threeDrives.codex + threeDrives.events < oneDrive.codex + oneDrive.events, "Additional volumes must reserve space before expanding flexible chat and event rows")
        print("PASS: multi-volume storage widget reserves extra height without crowding chat and event cards")
        let goal = CodexGoal(["objective": "Testziel", "status": "usageLimited", "tokensUsed": 200, "timeUsedSeconds": 335657])!
        precondition(goal.label == "Zielnutzung begrenzt" && goal.tokens == 200 && goal.budget == nil && !goal.isRunning && goal.durationLabel == "93 Std. 14 Min.")
        print("PASS: native status-item visibility removal persists; sidebar order survives recreation; visible goal status data")
        pinDefaults.removePersistentDomain(forName: pinDomain)
        print("PASS: only critical warnings; menu tool preferences persist and unpin independently")
        let virtual = DiskFile(path: "/tmp/Docker.raw", bytes: 500_000_000_000, allocatedBytes: 23_800_000_000, modified: nil, identity: "fixture")
        precondition(virtual.displayedBytes == 23_800_000_000 && virtual.isManagedVirtualDisk)
        do { try FileActions.validateForRemoval(virtual); fatalError("VM deletion must be blocked before filesystem access") } catch { precondition(error.localizedDescription.contains("virtuelle Festplatte")) }
        let viewport = VirtualWindowDisplay.surfaceSize(for: CGSize(width: 3440, height: 1440), safeMode: true)
        precondition(viewport.width <= 1536 && viewport.height <= 960 && abs(viewport.width / viewport.height - 3440.0 / 1440.0) < 0.01)
        precondition(VirtualWindowDisplay.surfaceSize(for: CGSize(width: 1000, height: 700), safeMode: false) == CGSize(width: 1000, height: 700))
        print("PASS: widget order/removal persistence; VM physical size and deletion backstop; bounded display geometry")
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
