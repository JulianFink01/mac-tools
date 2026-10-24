import Foundation
import Combine

struct FileBrowserRequest: Hashable {
    let date: Date
    let scope: String
    let query: String
    var fileCount: Int = 0
}

/// Stores lightweight array offsets, so filtering does not copy a complete scan.
struct FileBrowserIndex: Sendable {
    let files: [Int]
    let folders: [DiskBucket]
    let bytes: Int64

    static func build(_ result: DiskScanResult, scope: String, query: String) throws -> FileBrowserIndex {
        let prefix = scope == "/" ? "/" : scope + "/"
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var files: [Int] = [], bytes: Int64 = 0
        for (index, file) in result.files.enumerated() {
            if index % 512 == 0 { try Task.checkCancellation() }
            if file.path.hasPrefix(prefix), term.isEmpty || file.path.localizedCaseInsensitiveContains(term) {
                files.append(index); bytes += file.bytes
            }
        }
        var folders: [DiskBucket] = []
        for (index, folder) in result.folders.enumerated() {
            if index % 512 == 0 { try Task.checkCancellation() }
            guard folder.name.hasPrefix(prefix), !folder.name.dropFirst(prefix.count).contains("/"),
                  term.isEmpty || folder.name.localizedCaseInsensitiveContains(term) else { continue }
            folders.append(folder)
        }
        return FileBrowserIndex(files: files, folders: folders, bytes: bytes)
    }
}

@MainActor
final class FileBrowserStore: ObservableObject {
    static let shared = FileBrowserStore()
    private var cache: [FileBrowserRequest: FileBrowserIndex] = [:]
    private var recentRequests: [FileBrowserRequest] = []
    private func remember(_ value: FileBrowserIndex, for request: FileBrowserRequest) {
        cache[request] = value; recentRequests.removeAll { $0 == request }; recentRequests.append(request)
        while recentRequests.count > 4 { cache.removeValue(forKey: recentRequests.removeFirst()) }
    }
    func prime(_ result: DiskScanResult) async {
        let request = FileBrowserRequest(date: result.completedAt, scope: result.root.path, query: "", fileCount: result.files.count)
        guard cache[request] == nil else { return }
        let value = await Task.detached(priority: .utility) { try? FileBrowserIndex.build(result, scope: result.root.path, query: "") }.value
        if let value { remember(value, for: request) }
    }
    @Published private(set) var index: FileBrowserIndex?
    @Published private(set) var loadedRequest: FileBrowserRequest?
    @Published private(set) var isLoading = false
    @Published private(set) var error = ""
    private var generation = UUID()
    private var loadingRequest: FileBrowserRequest?
    func releaseCache(root: URL? = nil, date: Date? = nil) {
        if let root {
            let base = DiskScanner.canonicalPath(root.path)
            func matches(_ request: FileBrowserRequest) -> Bool {
                if let date, request.date != date { return false }
                let scope = DiskScanner.canonicalPath(request.scope)
                return base == "/" || scope == base || scope.hasPrefix(base + "/")
            }
            cache = cache.filter { !matches($0.key) }; recentRequests.removeAll(where: matches)
            guard (loadedRequest ?? loadingRequest).map(matches) == true else { return }
        } else { cache.removeAll(); recentRequests.removeAll() }
        generation = UUID(); index = nil; loadedRequest = nil; isLoading = false
        loadingRequest = nil
    }

    /// SwiftUI cancels superseded requests; stale filters never replace newer results.
    func load(_ result: DiskScanResult, request: FileBrowserRequest) async {
        if loadedRequest == request, index != nil { return }
        let token = UUID(); generation = token
        if let cached = cache[request] { loadedRequest = request; index = cached; isLoading = false; loadingRequest = nil; error = ""; return }
        isLoading = true; error = ""; index = nil; loadedRequest = nil; loadingRequest = request
        defer { if generation == token { isLoading = false; loadingRequest = nil } }
        do {
            if !request.query.isEmpty { try await Task.sleep(nanoseconds: 180_000_000) }
            try Task.checkCancellation()
            let worker = Task.detached(priority: .userInitiated) {
                try FileBrowserIndex.build(result, scope: request.scope, query: request.query)
            }
            let value = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            guard generation == token else { return }
            remember(value, for: request)
            loadedRequest = request; index = value
        } catch is CancellationError { /* The next scope/search owns the visible result. */ }
        catch { if generation == token { self.error = error.localizedDescription } }
    }
}

struct DuplicateFolderSummary: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let copies: Int
    let bytes: Int64
}

final class DuplicateViewIndex: Sendable {
    let all: [DuplicateGroup]
    let allBytes: Int64
    let media: [DuplicateGroup]
    let mediaBytes: Int64
    let mediaCopies: Int
    let totalCopies: Int
    private let pathGroups: [String: String]
    private let allOffsets: [String: Int]
    private let mediaOffsets: [String: Int]
    private init(all: [DuplicateGroup], allBytes: Int64, media: [DuplicateGroup], mediaBytes: Int64, mediaCopies: Int, totalCopies: Int, pathGroups: [String: String]) {
        self.all = all; self.allBytes = allBytes; self.media = media; self.mediaBytes = mediaBytes
        self.mediaCopies = mediaCopies; self.totalCopies = totalCopies; self.pathGroups = pathGroups
        allOffsets = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($0.element.id, $0.offset) })
        mediaOffsets = Dictionary(uniqueKeysWithValues: media.enumerated().map { ($0.element.id, $0.offset) })
    }
    private static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "svg", "nef", "cr2", "arw", "mp4", "mov", "m4v", "mkv", "avi", "webm", "mp3", "wav", "m4a", "flac", "aac", "aiff", "opus", "ogg", "pdf", "xls", "xlsx", "xlsm", "csv", "ods", "doc", "docx", "ppt", "pptx", "odt", "rtf"]
    static func isMedia(_ file: DiskFile) -> Bool {
        let start = file.path.lastIndex(of: "/").map { file.path.index(after: $0) } ?? file.path.startIndex
        let name = file.path[start...]
        guard let dot = name.lastIndex(of: ".") else { return false }
        return extensions.contains(name[name.index(after: dot)...].lowercased())
    }
    func copiesForRemoval(mediaOnly: Bool, inFolder folder: String? = nil) -> [String: DiskFile] {
        var selected: [String: DiskFile] = [:]
        let base = folder.map(DiskScanner.canonicalPath)
        for group in mediaOnly ? media : all {
            let candidates = group.files.filter { file in
                guard !file.isManagedVirtualDisk else { return false }
                guard let base else { return true }
                return DiskScanner.canonicalPath(file.path).hasPrefix(base == "/" ? "/" : base + "/")
            }
            // Prefer retaining a copy outside the chosen folder. If every copy
            // belongs to it, keep the first one inside instead.
            let copies = candidates.count == group.files.count ? candidates.dropFirst() : candidates[...]
            for file in copies { selected[file.path] = file }
        }
        return selected
    }
    func folders(mediaOnly: Bool, directory: String) throws -> [DuplicateFolderSummary] {
        let base = DiskScanner.canonicalPath(directory), prefix = base == "/" ? "/" : base + "/"
        var totals: [String: (Int, Int64)] = [:]
        for (offset, group) in (mediaOnly ? media : all).enumerated() {
            if offset % 256 == 0 { try Task.checkCancellation() }
            var children: [String: (Int, Int64)] = [:]
            for file in group.files where !file.isManagedVirtualDisk {
                let path = DiskScanner.canonicalPath(file.path)
                guard path.hasPrefix(prefix), let slash = path.dropFirst(prefix.count).firstIndex(of: "/") else { continue }
                let child = String(path[..<slash]), previous = children[child] ?? (0, 0)
                children[child] = (previous.0 + 1, previous.1 + file.bytes)
            }
            for (path, value) in children {
                let keep = value.0 == group.files.count
                let previous = totals[path] ?? (0, 0)
                totals[path] = (previous.0 + value.0 - (keep ? 1 : 0), previous.1 + value.1 - (keep ? group.files.first?.bytes ?? 0 : 0))
            }
        }
        return totals.map { DuplicateFolderSummary(path: $0.key, copies: $0.value.0, bytes: $0.value.1) }
            .filter { $0.copies > 0 }.sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
    }
    /// Only affected groups touch their file arrays. Rendering and tab changes
    /// retain this immutable reference instead of comparing the full scan.
    func removing(paths: Set<String>) -> DuplicateViewIndex {
        let paths = Set(paths.map(DiskScanner.canonicalPath))
        let affected = Set(paths.compactMap { pathGroups[$0] })
        guard !affected.isEmpty else { return self }
        var nextAll = all, nextMedia = media
        var allBytes = self.allBytes, mediaBytes = self.mediaBytes
        var total = totalCopies, mediaCount = mediaCopies
        var dropAll = Set<Int>(), dropMedia = Set<Int>()
        for id in affected {
            if let offset = allOffsets[id] {
                let old = all[offset], files = old.files.filter { !paths.contains(DiskScanner.canonicalPath($0.path)) }
                let updated = DuplicateGroup(id:id,files:files)
                allBytes += (files.count > 1 ? updated.redundantBytes : 0) - old.redundantBytes
                total += max(0,files.count-1) - (old.files.count-1)
                if files.count > 1 { nextAll[offset] = updated } else { dropAll.insert(offset) }
            }
            if let offset = mediaOffsets[id] {
                let old = media[offset], files = old.files.filter { !paths.contains(DiskScanner.canonicalPath($0.path)) }
                let updated = DuplicateGroup(id:id,files:files)
                mediaBytes += (files.count > 1 ? updated.redundantBytes : 0) - old.redundantBytes
                mediaCount += max(0,files.count-1) - (old.files.count-1)
                if files.count > 1 { nextMedia[offset] = updated } else { dropMedia.insert(offset) }
            }
        }
        if !dropAll.isEmpty { nextAll = nextAll.enumerated().compactMap { dropAll.contains($0.offset) ? nil : $0.element } }
        if !dropMedia.isEmpty { nextMedia = nextMedia.enumerated().compactMap { dropMedia.contains($0.offset) ? nil : $0.element } }
        return DuplicateViewIndex(all:nextAll,allBytes:allBytes,media:nextMedia,mediaBytes:mediaBytes,mediaCopies:mediaCount,totalCopies:total,pathGroups:pathGroups)
    }
    static func build(_ groups: [DuplicateGroup]) throws -> DuplicateViewIndex {
        var all: [DuplicateGroup] = [], allBytes: Int64 = 0
        var media: [DuplicateGroup] = [], bytes: Int64 = 0, copies = 0, total = 0
        var pathGroups: [String: String] = [:]
        for (index, group) in groups.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            let activeFiles = group.files.contains(where: { DiskScanner.isTrashPath($0.path) }) ? group.files.filter { !DiskScanner.isTrashPath($0.path) } : group.files
            guard activeFiles.count > 1 else { continue }
            let active = DuplicateGroup(id: group.id, files: activeFiles)
            all.append(active); allBytes += active.redundantBytes
            for file in activeFiles { pathGroups[DiskScanner.canonicalPath(file.path)] = group.id }
            total += activeFiles.count - 1
            let files = activeFiles.allSatisfy(isMedia) ? activeFiles : activeFiles.filter(isMedia)
            if files.count > 1 {
                let filtered = DuplicateGroup(id: group.id, files: files)
                media.append(filtered); bytes += filtered.redundantBytes; copies += files.count - 1
            }
        }
        return DuplicateViewIndex(all: all, allBytes: allBytes, media: media, mediaBytes: bytes, mediaCopies: copies, totalCopies: total, pathGroups: pathGroups)
    }
}
