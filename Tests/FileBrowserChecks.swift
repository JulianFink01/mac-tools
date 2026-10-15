import Foundation

@main
struct FileBrowserChecks {
    static func main() async throws {
        let root = URL(fileURLWithPath: "/fixture")
        let files = (0..<300_100).map { index in
            DiskFile(path: "/fixture/folder/\(index).PDF", bytes: Int64(index), allocatedBytes: Int64(index), modified: nil, identity: "1:\(index)")
        }
        let folders = [DiskBucket(name: "/fixture/folder", bytes: 1, count: files.count), DiskBucket(name: "/fixture/folder/nested", bytes: 1, count: 1), DiskBucket(name: "/fixture-sibling", bytes: 1, count: 1)]
        let result = DiskScanResult(root: root, completedAt: Date(), files: files, folders: folders, categories: [], duplicates: [], skipped: 0, warningSamples: [], reachedLimit: false, duplicateSearch: false, volumeTotal: 0, volumeFree: 0, bytes: 0, allocatedBytes: 0, redundantBytes: 0)
        let all = try FileBrowserIndex.build(result, scope: root.path, query: "")
        precondition(all.files.count == 300_100 && all.folders.count == 1)
        precondition(all.files.first == 0 && all.files.last == 300_099)
        let scoped = try FileBrowserIndex.build(result, scope: "/fixture/folder", query: "300099.pdf")
        precondition(scoped.files == [300_099] && scoped.bytes == 300_099)
        let sibling = try FileBrowserIndex.build(result, scope: "/fixture-sibling", query: "")
        precondition(sibling.files.isEmpty)
        let task = Task.detached { while !Task.isCancelled { await Task.yield() }; return try FileBrowserIndex.build(result, scope: root.path, query: "PDF") }
        task.cancel()
        do { _ = try await task.value; fatalError("Cancellation ignored") } catch is CancellationError {}
        let store = await FileBrowserStore()
        let oldRequest = FileBrowserRequest(date: result.completedAt, scope: root.path, query: "missing")
        let newRequest = FileBrowserRequest(date: result.completedAt, scope: root.path, query: "300099")
        let oldTask = Task { await store.load(result, request: oldRequest) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let newTask = Task { await store.load(result, request: newRequest) }
        oldTask.cancel()
        await oldTask.value; await newTask.value
        let matches = await store.index?.files
        let loaded = await store.loadedRequest
        precondition(matches == [300_099] && loaded == newRequest)
        func fixture(_ path: String) -> DiskFile { DiskFile(path: path, bytes: 10, allocatedBytes: 10, modified: nil, identity: path) }
        let media = DuplicateGroup(id: "images", files: [fixture("/fixture/a.GIF"), fixture("/fixture/b.jpg")])
        let docs = DuplicateGroup(id: "docs", files: [fixture("/fixture/a.XLSX"), fixture("/fixture/b.CSV"), fixture("/fixture/c.PDF")])
        let library = DuplicateGroup(id: "lib", files: [fixture("/fixture/a.dylib"), fixture("/fixture/b.swift")])
        let trash = DuplicateGroup(id: "trash", files: [fixture("/fixture/.Trash/a.jpg"), fixture("/fixture/.Trash/b.jpg")])
        let mixed = DuplicateGroup(id: "mixed", files: [fixture("/fixture/.Trashes/501/a.jpg"), fixture("/fixture/a.jpg")])
        let types = try DuplicateViewIndex.build([media, docs, library, trash, mixed])
        precondition(types.all.count == 3 && !types.all.contains { $0.id == "trash" || $0.id == "mixed" })
        precondition(types.media.count == 2 && types.mediaCopies == 3 && types.totalCopies == 4 && types.mediaBytes == 30)
        precondition(!types.media.contains { $0.id == "lib" })
        let voiceCopies = (0..<9141).map { fixture("/fixture/WhatsApp/\($0).OpUs") }
        let voice = try DuplicateViewIndex.build([DuplicateGroup(id: "voice", files: voiceCopies)])
        precondition(voice.media.count == 1 && voice.mediaCopies == 9140 && voice.mediaBytes == 91400)
        print("PASS: 9,141 small WhatsApp OPUS files remain visible, with all 9,140 redundant copies counted")
        print("PASS: case-insensitive media/document filter includes GIF/PDF/Excel/CSV, excludes programs/libraries, separate media/total counters")
        print("PASS: 300,100 files indexed, direct folders, scoped/case-insensitive search, sibling exclusion, cancellation, latest request wins")
    }
}
