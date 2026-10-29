import Foundation
import CryptoKit
import Darwin
private struct SavedVolumeSecurity: Codable { let report: SecurityReport; let root: URL; let date: Date }

@main struct VolumeScanChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        precondition(!DiskScanner.isPathInScanScope("/Volumes/Other/file.txt", root: "/"))
        precondition(DiskScanner.isPathInScanScope("/Users/owner/file.txt", root: "/"))
        precondition(DiskScanner.isPathInScanScope("/Volumes/Other/file.txt", root: "/Volumes/Other"))
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacTools-volumes-" + UUID().uuidString)
        let pcFiles = root.appendingPathComponent("Mac/Files"), drive = root.appendingPathComponent("External")
        let driveFiles = drive.appendingPathComponent("Documents"), cache = root.appendingPathComponent("Cache")
        for folder in [pcFiles, driveFiles, cache] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let domain = "MacTools.volume-tests." + UUID().uuidString
        let prefs = UserDefaults(suiteName: domain)!
        let externalID = UUID().uuidString
        let key = SHA256.hash(data: Data(externalID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let externalCache = cache.appendingPathComponent("VolumeScans/" + key)
        let externalDomain = "com.julianfink.MacTools.VolumeScan." + key
        defer { prefs.removePersistentDomain(forName: domain); UserDefaults(suiteName: externalDomain)?.removePersistentDomain(forName: externalDomain); try? fm.removeItem(at: root) }
        for folder in [pcFiles, driveFiles] {
            try Data("same benign fixture".utf8).write(to: folder.appendingPathComponent("a.txt"))
            try Data("same benign fixture".utf8).write(to: folder.appendingPathComponent("b.txt"))
        }
        let pc = DiskScanStore(defaults: prefs, directory: cache, eagerRestore: false)
        pc.root = pcFiles; pc.start()
        try await finish(pc)
        let pcSecurity = SecurityScanStore(directory: cache)
        let internalVolume = DiskScanVolume(id: "internal", name: "Test Mac", root: pcFiles, isPrimary: true, isInternal: true, isMounted: true)
        let externalVolume = DiskScanVolume(id: externalID, name: "Test External", root: drive, isPrimary: false, isInternal: false, isMounted: true)
        var mounted = [internalVolume, externalVolume]
        let volumes = DiskVolumeStore(primary: pc, security: pcSecurity, defaults: prefs, directory: cache, discover: { mounted }, observeMounts: false)
        let initialCache = try Data(contentsOf: cache.appendingPathComponent("last-disk-scan.plist"))
        let initialHistory = try Data(contentsOf: cache.appendingPathComponent("disk-history.json"))
        let initialHashes = try Data(contentsOf: cache.appendingPathComponent("file-hashes.sqlite"))
        let pcDate = pc.summary!.completedAt
        pc.releaseUnusedInventory()
        precondition(pc.result == nil && pc.summary?.fileCount == 2)

        volumes.selectFolder(driveFiles)
        let external = volumes.selectedProfile!
        precondition(external.volume.id == externalID && external.disk !== pc && external.disk.root.path == driveFiles.path)
        precondition(pc.root == pcFiles && !external.disk.isScanning, "Selecting a connected drive must not start a scan or alter the PC root")
        volumes.startSelectedDiskScan(); try await finish(external.disk)
        precondition(external.disk.result?.files.count == 2 && external.disk.history.count == 1)
        precondition(pc.summary?.fileCount == 2 && pc.history.count == 1 && pc.result == nil)
        let afterExternalCache = try Data(contentsOf: cache.appendingPathComponent("last-disk-scan.plist"))
        let afterExternalHistory = try Data(contentsOf: cache.appendingPathComponent("disk-history.json"))
        let afterExternalHashes = try Data(contentsOf: cache.appendingPathComponent("file-hashes.sqlite"))
        precondition(afterExternalCache == initialCache && afterExternalHistory == initialHistory && afterExternalHashes == initialHashes)
        precondition(fm.fileExists(atPath: externalCache.appendingPathComponent("file-hashes.sqlite").path))
        print("PASS: independent volume inventories, histories and hash databases; external scan leaves all PC cache bytes unchanged")

        try fm.removeItem(at: driveFiles.appendingPathComponent("a.txt"))
        FileActions.shared.recordRemoval(paths: [driveFiles.appendingPathComponent("a.txt").path])
        while external.disk.isApplyingRemovals { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(external.disk.result?.files.count == 1 && pc.removedPaths.isEmpty)
        precondition(!fm.fileExists(atPath: cache.appendingPathComponent("last-disk-scan.plist.removed.json").path))
        print("PASS: external cleanup does not journal removals into an unloaded PC inventory")
        let scan = external.disk.result!
        let request = FileBrowserRequest(date: scan.completedAt, scope: scan.root.path, query: "", fileCount: scan.files.count)
        await FileBrowserStore.shared.load(scan, request: request)
        FileBrowserStore.shared.releaseCache(root: URL(fileURLWithPath: "/"), date: pcDate)
        precondition(FileBrowserStore.shared.loadedRequest == request && FileBrowserStore.shared.index != nil)
        print("PASS: releasing a PC-wide inventory leaves the other volume's visible file browser intact")
        let report = SecurityReport(exitCode: 0, output: "Scanned files: 1\nInfected files: 0", cancelled: false)
        let reportEncoder = PropertyListEncoder(); reportEncoder.outputFormat = .binary
        try reportEncoder.encode(SavedVolumeSecurity(report: report, root: driveFiles, date: Date())).write(to: externalCache.appendingPathComponent("last-virus-scan.plist"))

        mounted = [internalVolume]; volumes.refresh()
        precondition(volumes.selectedVolume?.isMounted == false && !external.disk.acceptsFileChanges && !external.security.acceptsFileChanges)
        volumes.startSelectedDiskScan()
        precondition(!external.disk.isScanning && pc.root == pcFiles)
        let detached = root.appendingPathComponent("Detached")
        try fm.moveItem(at: drive, to: detached)
        volumes.stop()

        let restoredPC = DiskScanStore(defaults: prefs, directory: cache, eagerRestore: false)
        let restored = DiskVolumeStore(primary: restoredPC, security: pcSecurity, defaults: prefs, directory: cache, discover: { mounted }, observeMounts: false)
        let offline = restored.selectedProfile!
        precondition(offline.volume.id == externalID && !offline.volume.isMounted && offline.disk.root.path == driveFiles.path)
        precondition(offline.disk.summary?.fileCount == 1 && offline.disk.result == nil && offline.disk.cachedResultAvailable)
        precondition(offline.disk.root != fm.homeDirectoryForCurrentUser, "Disconnected drives must never silently fall back to scanning the home directory")
        precondition(offline.security.scannedRoot?.path == driveFiles.path && pcSecurity.scannedRoot == nil)
        print("PASS: disconnected volume and selected folder survive restart; summary stays lightweight and scanning is blocked")

        try fm.moveItem(at: detached, to: drive)
        mounted = [internalVolume, externalVolume]; restored.refresh()
        let consumer = UUID(); await offline.disk.beginInventoryAccess(consumer)
        precondition(restored.selectedProfile === offline && offline.volume.isMounted && offline.disk.result?.files.count == 1)
        let afterReconnectCache = try Data(contentsOf: cache.appendingPathComponent("last-disk-scan.plist"))
        precondition(afterReconnectCache == initialCache)
        offline.disk.endInventoryAccess(consumer)
        restored.selectedID = "internal"
        precondition(restored.selectedProfile?.disk === restoredPC && restoredPC.summary?.fileCount == 2)
        let anotherFolder = drive.appendingPathComponent("New folder")
        try fm.createDirectory(at: anotherFolder, withIntermediateDirectories: true)
        restored.selectFolder(anotherFolder)
        let afterFolderChange = DiskScanStore(defaults: UserDefaults(suiteName: externalDomain)!, directory: externalCache, eagerRestore: false, defaultRoot: drive, retainUnavailableRoot: true)
        precondition(afterFolderChange.summary == nil && !afterFolderChange.cachedResultAvailable, "A changed scan folder must not show the previous folder's summary after restart")
        restored.stop()
        print("PASS: reconnect restores the same UUID-scoped cache including cleanup deltas; switching back restores the original PC profile")
        print("PASS: changing the selected folder does not restore a different folder's cached summary after restart")
    }
    @MainActor private static func finish(_ store: DiskScanStore) async throws {
        let deadline = Date().addingTimeInterval(20)
        while store.isScanning || store.isSaving {
            precondition(Date() < deadline, "Fixture scan timed out")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(store.summary != nil && !store.status.hasPrefix("Scan fehlgeschlagen"), store.status)
    }
}
