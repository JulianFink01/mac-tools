import Foundation

@main
struct DiskScanCacheChecks {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-cache-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("last-disk-scan.plist")
        let files = (0..<8192).map { DiskFile(path: "/fixture/\($0).bin", bytes: 128, allocatedBytes: 512,
                                          modified: Date(timeIntervalSince1970: 100), identity: "1:\($0)") }
        let groups = [DuplicateGroup(id: "large", files: Array(files.prefix(5000))),
                      DuplicateGroup(id: "across-chunks", files: [files[5000], files[8191]])]
        let value = DiskScanResult(root: folder, completedAt: Date(), files: files,
            folders: [DiskBucket(name: "/fixture", bytes: 8192 * 128, count: 8192)], categories: [], duplicates: groups,
            skipped: 3, warningSamples: ["example warning"], reachedLimit: false, duplicateSearch: true,
            volumeTotal: 10000, volumeFree: 5000, bytes: 8192 * 128, allocatedBytes: 8192 * 512,
            redundantBytes: 5000 * 128)
        try DiskScanCache.save(value, to: path)
        let restored = try DiskScanCache.load(from: path)
        precondition(restored.files.count == 8192 && restored.duplicates[0].files.count == 5000)
        precondition(restored.duplicates[1].files.map(\.path) == groups[1].files.map(\.path))
        precondition(restored.completedAt == value.completedAt && restored.skipped == 3 && restored.warningSamples == value.warningSamples)
        let previous = try Data(contentsOf: path)
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            try DiskScanCache.save(value, to: path)
        }
        do { try await cancelled.value; preconditionFailure("Cancelled save must stop") }
        catch is CancellationError { }
        let afterCancellation = try Data(contentsOf: path)
        precondition(afterCancellation == previous, "Cancelled write must preserve previous result")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        precondition(names == [path.lastPathComponent])
        try Data(previous.dropLast(10)).write(to: path)
        do { _ = try DiskScanCache.load(from: path); preconditionFailure("Truncated cache must be rejected") }
        catch { }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(value).write(to: path)
        let legacy = try DiskScanCache.load(from: path)
        precondition(legacy.files.count == 8192, "Legacy plist must remain readable")
        print("PASS: chunked save/restore across file and group boundaries, shared file references, atomic cancellation, no temporary files, corruption rejected, legacy format supported")
    }
}
