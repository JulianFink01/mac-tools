import Foundation
import Darwin

@main
struct ScannerChecks {
    static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("MacTools-check-\(UUID().uuidString)")
        try manager.createDirectory(at: root.appendingPathComponent("nested/deep"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        func write(_ path: String, _ data: Data) throws {
            try data.write(to: root.appendingPathComponent(path))
        }
        try write("one.txt", Data("duplicate-content".utf8))
        try write("nested/two.txt", Data("duplicate-content".utf8))
        try write("different.txt", Data("different-content".utf8)) // Same size, different bytes.
        try write("empty.txt", Data())
        try write("nested/empty.txt", Data())
        try write("nested/deep/movie.mp4", Data(repeating: 7, count: 2_500_000))
        try write("unicode-ä.txt", Data("abc".utf8))
        try manager.createSymbolicLink(atPath: root.appendingPathComponent("outside-link").path, withDestinationPath: "/")
        try manager.linkItem(at: root.appendingPathComponent("one.txt"), to: root.appendingPathComponent("hardlink.txt"))
        let result = try DiskScanner.scan(root: root, findDuplicates: true)
        precondition(result.files.count == 7, "Symlink ignored and hard link counted once")
        precondition(result.bytes == 2_500_054, "Exact byte total")
        precondition(result.duplicates.count == 1, "Same-sized different contents and empty files are excluded")
        precondition(result.duplicates[0].files.count == 2 && result.redundantBytes == 17)
        precondition(result.folders.first { $0.name.hasSuffix("/nested") }?.bytes == 2_500_017)
        precondition(result.categories.first { $0.name == "Videos" }?.bytes == 2_500_000)
        precondition(result.skipped == 0 && !result.reachedLimit)
        let withoutDuplicates = try DiskScanner.scan(root: root, findDuplicates: false)
        precondition(withoutDuplicates.duplicates.isEmpty)
        do {
            _ = try DiskScanner.scan(root: root.appendingPathComponent("one.txt"), findDuplicates: false)
            preconditionFailure("A file must not be accepted as scan root")
        } catch { print("PASS: invalid root rejected") }
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try DiskScanner.scan(root: root, findDuplicates: true)
        }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancellation must interrupt") }
        catch is CancellationError { print("PASS: cancellation") }
        // Identical sample regions are only a shortlist, never proof of duplication.
        let largeRoot = root.appendingPathComponent("large")
        try manager.createDirectory(at: largeRoot, withIntermediateDirectories: true)
        var large = Data(repeating: 42, count: 32 * 1024 * 1024)
        try large.write(to: largeRoot.appendingPathComponent("a.bin"))
        try large.write(to: largeRoot.appendingPathComponent("b.bin"))
        large[200_000] = 43 // Outside first/middle/end samples.
        try large.write(to: largeRoot.appendingPathComponent("sample-collision.bin"))
        var distinct = Data(repeating: 44, count: large.count)
        try distinct.write(to: largeRoot.appendingPathComponent("other.bin"))
        let cache = root.appendingPathComponent("fingerprints.sqlite")
        let start = Date()
        let cold = try DiskScanner.scan(root: largeRoot, findDuplicates: true, cacheURL: cache)
        let coldTime = Date().timeIntervalSince(start)
        precondition(cold.duplicates.count == 1 && cold.duplicates[0].files.count == 2, "A sample collision must be rejected by complete SHA-256")
        let warmStart = Date()
        let warm = try DiskScanner.scan(root: largeRoot, findDuplicates: true, cacheURL: cache)
        let warmTime = Date().timeIntervalSince(warmStart)
        precondition(warm.duplicates.map(\.id) == cold.duplicates.map(\.id))
        let changedURL = largeRoot.appendingPathComponent("b.bin")
        let oldDate = try changedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        distinct[300_000] = 45
        try distinct.write(to: changedURL, options: [])
        try manager.setAttributes([.modificationDate: oldDate], ofItemAtPath: changedURL.path)
        let changed = try DiskScanner.scan(root: largeRoot, findDuplicates: true, cacheURL: cache)
        precondition(changed.duplicates.isEmpty, "Same size and restored mtime must not reuse an outdated cached digest")
        print("PASS: large-file samples, sample collision rejected, cache reuse/invalidation; cold \(coldTime)s, warm \(warmTime)s")
        let manyRoot = root.appendingPathComponent("many")
        try manager.createDirectory(at: manyRoot, withIntermediateDirectories: true)
        for number in 0..<2048 {
            var data = Data(repeating: 42, count: 4096)
            let identity = UInt32(number / 2)
            data.replaceSubrange(0..<4, with: withUnsafeBytes(of: identity) { Data($0) })
            try data.write(to: manyRoot.appendingPathComponent("\(number).bin"))
        }
        let many = try DiskScanner.scan(root: manyRoot, findDuplicates: true, cacheURL: cache)
        precondition(many.duplicates.count == 1024 && many.duplicates.allSatisfy { $0.files.count == 2 }, "Parallel batches retain exact groups")
        let again = try DiskScanner.scan(root: manyRoot, findDuplicates: true, cacheURL: cache)
        precondition(again.duplicates.map(\.id).sorted() == many.duplicates.map(\.id).sorted())
        let ready = DispatchSemaphore(value: 0)
        let parallelCancellation = Task.detached {
            try DiskScanner.scan(root: manyRoot, findDuplicates: true, cacheURL: cache,
                                 inventory: { _ in ready.signal() })
        }
        precondition(ready.wait(timeout: .now() + 5) == .success)
        try await Task.sleep(nanoseconds: 5_000_000)
        parallelCancellation.cancel()
        do { _ = try await parallelCancellation.value; preconditionFailure("Parallel scan must cancel") }
        catch is CancellationError { }
        let resumed = try DiskScanner.scan(root: manyRoot, findDuplicates: true, cacheURL: cache)
        precondition(resumed.duplicates.count == 1024, "Worker/cache state remains usable after cancellation")
        print("PASS: 2,048 files in bounded parallel batches, exact groups, concurrent cache statements, cancellation")
        print("PASS: byte totals, folder totals, categories, hardlinks, symlinks, SHA-256, empty files, streaming reads")
    }
}
