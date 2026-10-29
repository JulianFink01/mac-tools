import Foundation
import Darwin
@main struct RemovalStateChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-state-\(UUID())")
        let files = root.appendingPathComponent("Files"), cache = root.appendingPathComponent("Cache")
        let nested = files.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
        let defaults = UserDefaults(suiteName:"MacTools.state.\(UUID())")!
        defer { try? FileManager.default.removeItem(at:root) }
        let urls = [files.appendingPathComponent("a.jpg"),files.appendingPathComponent("b.jpg"),nested.appendingPathComponent("c.jpg"),nested.appendingPathComponent("d.jpg")]
        for url in urls { try Data("Own harmless state fixture".utf8).write(to:url) }
        let store = DiskScanStore(defaults:defaults,directory:cache); store.root=files; store.start()
        while store.isScanning || store.duplicateIndex == nil { try await Task.sleep(nanoseconds:10_000_000) }
        let originalCache = try Data(contentsOf:cache.appendingPathComponent("last-disk-scan.plist"))
        struct Saved: Codable { let report:SecurityReport; let root:URL; let date:Date }
        let report = SecurityReport(exitCode:1,output:urls.prefix(2).map { $0.path+": Own-Test-Signature FOUND" }.joined(separator:"\n"),cancelled:false)
        let encoder=PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(Saved(report:report,root:files,date:Date())).write(to:cache.appendingPathComponent("last-virus-scan.plist"))
        let security=SecurityScanStore(directory:cache)
        let initial = store.result!
        let browser = FileBrowserStore.shared
        let browserRequest = FileBrowserRequest(date: initial.completedAt, scope: initial.root.path, query: "jpg", fileCount: initial.files.count)
        await browser.load(initial, request: browserRequest)
        FileActions.shared.recordRemoval(paths:[urls[0].path])
        precondition(store.isRemoved(urls[0].path) && store.duplicateIndex?.mediaCopies == 2 && security.report?.items.count == 1)
        FileActions.shared.recordRemoval(paths:[urls[1].path])
        precondition(store.isRemoved(urls[1].path) && store.duplicateIndex?.mediaCopies == 1 && security.report?.items.isEmpty == true)
        while store.isApplyingRemovals { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(store.result?.files.count == 2 && !store.isScanning)
        var updatedRequest = browserRequest; updatedRequest.fileCount = 2
        precondition(browser.loadedRequest == updatedRequest && !browser.isLoading)
        precondition(browser.index?.files.map { store.result!.files[$0].path }.sorted() == urls.suffix(2).map { DiskScanner.canonicalPath($0.path) }.sorted(), "Visible browser offsets must be rebased before publishing removal, without reload")
        let persistedSummary = try DiskScanCache.summary(from: cache.appendingPathComponent("last-disk-scan.plist"))
        precondition(persistedSummary?.fileCount == 2 && persistedSummary?.preview?.files.count == 2, "Summary after restart must reflect removals without loading full inventory")
        let unchangedCache = try Data(contentsOf:cache.appendingPathComponent("last-disk-scan.plist"))
        precondition(unchangedCache == originalCache)
        FileActions.shared.recordRemoval(paths:[nested.path],directories:[nested.path])
        precondition(store.isRemoved(urls[2].path))
        while store.isApplyingRemovals { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(store.result?.files.isEmpty == true && store.duplicateIndex?.all.isEmpty == true)
        let restored=DiskScanStore(defaults:defaults,directory:cache)
        while restored.isRestoring { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(restored.result?.files.isEmpty == true)
        precondition(SecurityScanStore(directory:cache).report?.items.isEmpty == true)
        print("PASS: immediate cross-store removal, queued consecutive removals, folder descendants, persistent journals, unchanged base cache, no rescan")
        let lazy=DiskScanStore(defaults:defaults,directory:cache,eagerRestore:false)
        precondition(lazy.result == nil && !lazy.isRestoring && lazy.summary?.fileCount == 0)
        let consumer=UUID(), secondConsumer=UUID()
        await lazy.beginInventoryAccess(consumer)
        precondition(lazy.result?.files.isEmpty == true)
        await lazy.beginInventoryAccess(secondConsumer)
        lazy.endInventoryAccess(consumer);lazy.releaseUnusedInventory()
        precondition(lazy.result != nil,"Second consumer still needs the inventory")
        lazy.endInventoryAccess(secondConsumer);lazy.releaseUnusedInventory()
        precondition(lazy.result == nil && lazy.duplicateIndex == nil && lazy.summary != nil)
        lazy.applyRemoved(paths:[nested.path],directories:[nested.path])
        while lazy.isApplyingRemovals { try await Task.sleep(nanoseconds:10_000_000) }
        await lazy.beginInventoryAccess(consumer)
        precondition(lazy.result?.files.isEmpty == true)
        lazy.endInventoryAccess(consumer);lazy.releaseUnusedInventory()
        print("PASS: summary-only launch, lazy inventory restore, shared consumers, explicit eviction and unloaded removal journal preserve cached data")
        let groups=(0..<100000).map { i in DuplicateGroup(id:String(i),files:(0..<2).map { j in DiskFile(path:"/tmp/fixture/\(i)-\(j).opus",bytes:1024,allocatedBytes:1024,modified:nil,identity:"\(i)-\(j)") }) }
        let start=Date(); let index=try DuplicateViewIndex.build(groups)
        let loaded=Date(); let after=index.removing(paths:["/tmp/fixture/0-0.opus"])
        precondition(index.all.count == 100000 && after.all.count == 99999 && after.mediaCopies == 99999)
        print("PASS: 100,000 groups indexed \(loaded.timeIntervalSince(start))s, one-group state update \(Date().timeIntervalSince(loaded))s")
    }
}
