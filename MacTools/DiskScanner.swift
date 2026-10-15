import Foundation
import CryptoKit
import Darwin
import SQLite3

struct DiskFile: Identifiable, Codable, Sendable {
    var id: String { path }
    let path: String
    let bytes: Int64
    let allocatedBytes: Int64
    let modified: Date?
    let identity: String
    var url: URL { URL(fileURLWithPath: path, isDirectory: false) }
    static func snapshot(at url: URL) throws -> DiskFile {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ScanError.unreadable(url.path) }
        return DiskFile(path: url.path, bytes: info.st_size, allocatedBytes: Int64(info.st_blocks) * 512,
                        modified: DiskScanner.modificationDate(info), identity: "\(info.st_dev):\(info.st_ino)")
    }
}

struct DiskBucket: Identifiable, Codable, Sendable {
    var id: String { name }
    let name: String
    var bytes: Int64
    var count: Int
}

struct DuplicateGroup: Identifiable, Codable, Sendable {
    let id: String
    let files: [DiskFile]
    var redundantBytes: Int64 { Int64(files.count - 1) * (files.first?.bytes ?? 0) }
}

struct ScanOmissions: Codable, Sendable {
    var unavailable = 0
    var changing = 0
    var cloudOnly = 0
}

struct DiskScanResult: Codable, Sendable {
    let root: URL
    let completedAt: Date
    let files: [DiskFile]
    let folders: [DiskBucket]
    let categories: [DiskBucket]
    let duplicates: [DuplicateGroup]
    let skipped: Int
    let warningSamples: [String]
    let reachedLimit: Bool
    let duplicateSearch: Bool
    let volumeTotal: Int64
    let volumeFree: Int64
    let bytes: Int64
    let allocatedBytes: Int64
    let redundantBytes: Int64
    var omissions: ScanOmissions? = nil
}

struct DiskScanProgress: Sendable {
    let files: Int
    let bytes: Int64
    let phase: String
    var fraction: Double? = nil
}

/// Reads files only. Symlinks are never followed; hard links are counted once per inode.
enum DiskScanner {
    /// macOS exposes these same directories under two lexical roots. State
    /// comparisons must not perform filesystem/symlink probes after deletion.
    static func canonicalPath(_ path: String) -> String {
        if path == "/var" || path.hasPrefix("/var/") || path == "/tmp" || path.hasPrefix("/tmp/") || path == "/etc" || path.hasPrefix("/etc/") { return "/private" + path }
        return path
    }

    static func isTrashPath(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/") || path.hasSuffix("/.Trash") || path.hasSuffix("/.Trashes")
    }

    static func scan(root: URL, findDuplicates: Bool, cacheURL: URL? = nil,
                     inventory: @Sendable (DiskScanResult) -> Void = { _ in },
                     progress: @Sendable (DiskScanProgress) -> Void = { _ in }) throws -> DiskScanResult {
        let manager = FileManager.default
        let selectedRoot = root.standardizedFileURL
        let rootValues = try selectedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ScanError.invalidRoot
        }
        guard let resolved = realpath(selectedRoot.path, nil) else { throw ScanError.invalidRoot }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        free(resolved)
        var files: [DiskFile] = []
        var identities = Set<String>()
        var folders: [String: DiskBucket] = [:]
        var categories: [String: DiskBucket] = [:]
        var skipped = 0
        var omissions = ScanOmissions()
        var warnings: [String] = []
        var total: Int64 = 0
        var lastProgress = Date.distantPast
        func recordWarning(_ message: String) {
            skipped += 1; omissions.unavailable += 1
            if warnings.count < 10 { warnings.append(message) }
        }
        func recordError(_ path: String, _ error: Error) {
            switch error as? ScanError {
            case .changedFile: skipped += 1; omissions.changing += 1
            case .cloudFile: skipped += 1; omissions.cloudOnly += 1
            default: recordWarning("\(path): \(error.localizedDescription)")
            }
        }
        let keys: [URLResourceKey] = []
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys,
                                                   options: [], errorHandler: { url, error in
            recordWarning("\(url.path): \(error.localizedDescription)")
            return true
        }) else { throw ScanError.invalidRoot }
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            do {
                try autoreleasepool {
                    var info = stat()
                    guard lstat(url.path, &info) == 0 else { throw ScanError.unreadable(url.path) }
                    if (info.st_mode & S_IFMT) == S_IFLNK { return }
                    if (info.st_mode & S_IFMT) == S_IFDIR {
                        folders[url.path] = DiskBucket(name: url.path, bytes: 0, count: 0)
                        return
                    }
                    guard (info.st_mode & S_IFMT) == S_IFREG else { return }
                    let identity = "\(info.st_dev):\(info.st_ino)"
                    guard identities.insert(identity).inserted else { return }
                    let size = info.st_size
                    files.append(DiskFile(path: url.path, bytes: size,
                                          allocatedBytes: Int64(info.st_blocks) * 512,
                                          modified: modificationDate(info), identity: identity))
                    total += size
                    let category = category(for: url.pathExtension)
                    var bucket = categories[category] ?? DiskBucket(name: category, bytes: 0, count: 0)
                    bucket.bytes += size; bucket.count += 1
                    categories[category] = bucket
                    let parent = (url.path as NSString).deletingLastPathComponent
                    if parent != root.path {
                        var folder = folders[parent] ?? DiskBucket(name: parent, bytes: 0, count: 0)
                        folder.bytes += size; folder.count += 1
                        folders[parent] = folder
                    }
                    if Date().timeIntervalSince(lastProgress) > 0.25 {
                        progress(DiskScanProgress(files: files.count, bytes: total, phase: "Dateien erfassen"))
                        lastProgress = Date()
                    }
                }
            } catch is CancellationError { throw CancellationError() }
              catch { recordError(url.path, error) }
        }
        // Accumulate each directory once, rather than walking every file's ancestors.
        for path in folders.keys.sorted(by: { $0.utf8.count > $1.utf8.count }) {
            guard let child = folders[path], child.count > 0 else { continue }
            let parent = (path as NSString).deletingLastPathComponent
            if parent != root.path, var bucket = folders[parent] {
                bucket.bytes += child.bytes; bucket.count += child.count
                folders[parent] = bucket
            }
        }
        try Task.checkCancellation()
        files.sort { $0.bytes > $1.bytes }
        let sortedFolders = folders.values.filter { $0.count > 0 }.sorted { $0.bytes > $1.bytes }
        let sortedCategories = categories.values.sorted { $0.bytes > $1.bytes }
        let allocated = files.reduce(0) { $0 + $1.allocatedBytes }
        let volume = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        func report(_ duplicates: [DuplicateGroup], finished: Bool) -> DiskScanResult {
            DiskScanResult(root: root, completedAt: Date(), files: files,
                           folders: sortedFolders, categories: sortedCategories, duplicates: duplicates,
                           skipped: skipped, warningSamples: warnings, reachedLimit: false,
                           duplicateSearch: finished && findDuplicates,
                           volumeTotal: Int64(volume?.volumeTotalCapacity ?? 0),
                           volumeFree: Int64(volume?.volumeAvailableCapacity ?? 0), bytes: total,
                           allocatedBytes: allocated,
                           redundantBytes: duplicates.reduce(0) { $0 + $1.redundantBytes }, omissions: omissions)
        }
        inventory(report([], finished: false))
        var duplicates: [DuplicateGroup] = []
        if findDuplicates {
            let cache = cacheURL.flatMap { FingerprintCache(url: $0) }
            let candidates = Dictionary(grouping: files.indices.filter { files[$0].bytes > 0 && !isTrashPath(files[$0].path) }, by: { files[$0].bytes })
                .filter { $0.value.count > 1 }.sorted { $0.key > $1.key }
            let candidateCount = candidates.reduce(0) { $0 + $1.value.count }
            var checked = 0
            for (size, group) in candidates {
                try Task.checkCancellation()
                var samples: [String: [Int]] = [:]
                // Small files are hashed once; large files first read at most 192 KiB.
                let sampled = size > 1024 * 1024
                let batchSize = 256
                for start in stride(from: 0, to: group.count, by: batchSize) {
                    try Task.checkCancellation()
                    let batch = Array(group.dropFirst(start).prefix(batchSize))
                    let values: [(Int, Result<String, Error>)]
                    if batch.count >= 32 {
                        values = try batchDigests(batch, files: files, sampled: sampled, cache: cache)
                    } else {
                        values = batch.map { index in
                            (index, Result { try autoreleasepool { try Self.digest(files[index], sampled: sampled, cache: cache) } })
                        }
                    }
                    for (index, value) in values {
                        switch value {
                        case .success(let hash): samples[hash, default: []].append(index)
                        case .failure(let error):
                            if error is CancellationError { throw CancellationError() }
                            recordError(files[index].path, error)
                        }
                    }
                    checked += batch.count
                    if Date().timeIntervalSince(lastProgress) > 0.25 {
                        progress(DiskScanProgress(files: files.count, bytes: total,
                            phase: "Duplikate prüfen · \(checked.formatted()) / \(candidateCount.formatted())", fraction: Double(checked) / Double(max(1, candidateCount))))
                        lastProgress = Date()
                    }
                }
                for (sample, matches) in samples where matches.count > 1 {
                    if !sampled {
                        duplicates.append(DuplicateGroup(id: sample, files: matches.map { files[$0] }.sorted { $0.path < $1.path }))
                        continue
                    }
                    var hashes: [String: [DiskFile]] = [:]
                    for index in matches {
                        let file = files[index]
                        do {
                            let hash = try digest(file, sampled: false, cache: cache) { read in
                                if Date().timeIntervalSince(lastProgress) > 0.5 {
                                    progress(DiskScanProgress(files: files.count, bytes: total,
                                        phase: "SHA-256 · \(file.url.lastPathComponent) · \(diskSize(read)) / \(diskSize(file.bytes))", fraction: Double(read) / Double(max(1, file.bytes))))
                                    lastProgress = Date()
                                }
                            }
                            hashes[hash, default: []].append(file)
                        } catch is CancellationError { throw CancellationError() }
                          catch { recordError(file.path, error) }
                    }
                    for (hash, copies) in hashes where copies.count > 1 {
                        duplicates.append(DuplicateGroup(id: hash, files: copies.sorted { $0.path < $1.path }))
                    }
                }
            }
        }
        try Task.checkCancellation()
        return report(duplicates.sorted { $0.redundantBytes > $1.redundantBytes }, finished: true)
    }

    /// Four bounded workers overlap filesystem latency; a cancelled scan joins them before returning.
    private static func batchDigests(_ indices: [Int], files: [DiskFile], sampled: Bool,
                                     cache: FingerprintCache?) throws -> [(Int, Result<String, Error>)] {
        let batch = FingerprintBatch(), workers = DispatchGroup()
        for worker in 0..<4 {
            workers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { workers.leave() }
                for offset in stride(from: worker, to: indices.count, by: 4) {
                    if batch.isCancelled { return }
                    let index = indices[offset]
                    let value = Result { try autoreleasepool { try digest(files[index], sampled: sampled, cache: cache, cancellation: batch) } }
                    batch.append(index, value)
                }
            }
        }
        while workers.wait(timeout: .now() + .milliseconds(25)) == .timedOut {
            if Task.isCancelled { batch.cancel() }
        }
        try Task.checkCancellation()
        return batch.values
    }

    static func modificationDate(_ info: stat) -> Date {
        Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    private static func diskSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Explicit full-content fingerprint for diagnostics.
    static func fingerprint(_ file: DiskFile) throws -> String {
        try digest(file, sampled: false, cache: nil)
    }

    private static func digest(_ file: DiskFile, sampled: Bool, cache: FingerprintCache?, cancellation: FingerprintBatch? = nil,
                               progress: (Int64) -> Void = { _ in }) throws -> String {
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
        var local = stat()
        guard lstat(file.path, &local) == 0 else { throw ScanError.unreadable(file.path) }
        guard local.st_flags & UInt32(SF_DATALESS) == 0 else { throw ScanError.cloudFile }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ScanError.unreadable(file.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              "\(before.st_dev):\(before.st_ino)" == file.identity,
              before.st_size == file.bytes,
              file.modified.map({ abs(modificationDate(before).timeIntervalSince($0)) < 0.000001 }) ?? false
        else { throw ScanError.changedFile }
        // ctime prevents cache reuse when a same-sized edit restores the old mtime.
        let key = "\(file.identity):\(before.st_size):\(before.st_mtimespec.tv_sec):\(before.st_mtimespec.tv_nsec):\(before.st_ctimespec.tv_sec):\(before.st_ctimespec.tv_nsec)"
        var hasher = SHA256()
        var readBytes: Int64 = 0
        var hash = cache?.get(key, sampled: sampled)
        let cached = hash != nil
        if hash == nil {
            if sampled {
                let count: Int64 = 64 * 1024
                let offsets: [Int64] = [0, max(0, (file.bytes - count) / 2), max(0, file.bytes - count)]
                for offset in offsets {
                    try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
                    try handle.seek(toOffset: UInt64(offset))
                    let expected = Int(min(count, file.bytes - offset))
                    guard let data = try handle.read(upToCount: expected), data.count == expected else { throw ScanError.changedFile }
                    hasher.update(data: data)
                }
            } else {
                while readBytes < file.bytes {
                    try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
                    let count = try autoreleasepool { () -> Int in
                        guard let data = try handle.read(upToCount: Int(min(1024 * 1024, file.bytes - readBytes))), !data.isEmpty else { return 0 }
                        hasher.update(data: data)
                        return data.count
                    }
                    guard count > 0 else { break }
                    readBytes += Int64(count)
                    progress(readBytes)
                }
                guard readBytes == file.bytes else { throw ScanError.changedFile }
            }
            let alphabet = Array("0123456789abcdef".utf8)
            hash = String(bytes: hasher.finalize().flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 15)]] }, encoding: .utf8)!
        }
        var after = stat(), pathInfo = stat()
        guard fstat(descriptor, &after) == 0, lstat(file.path, &pathInfo) == 0,
              pathInfo.st_dev == before.st_dev, pathInfo.st_ino == before.st_ino,
              after.st_size == before.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw ScanError.changedFile }
        if !cached { cache?.put(key, sampled: sampled, digest: hash!) }
        return hash!
    }

    static func category(for ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "mov", "m4v", "mkv", "avi", "webm": return "Videos"
        case "jpg", "jpeg", "png", "heic", "gif", "tiff", "nef", "cr2", "arw", "svg": return "Bilder"
        case "mp3", "wav", "m4a", "flac", "aac", "aiff": return "Audio"
        case "pdf", "doc", "docx", "xls", "xlsx", "pptx", "txt", "md", "csv": return "Dokumente"
        case "zip", "dmg", "tar", "gz", "7z", "rar", "pkg": return "Archive & Installer"
        case "swift", "js", "ts", "tsx", "py", "rs", "c", "h", "json", "html", "css": return "Entwicklung"
        default: return "Sonstige"
        }
    }
}

private enum ScanError: LocalizedError {
    case invalidRoot, unreadable(String), changedFile, cloudFile
    var errorDescription: String? {
        switch self {
        case .invalidRoot: return "Der gewählte Pfad ist kein lesbarer Ordner."
        case .unreadable(let path): return "Datei nicht lesbar: \(path)"
        case .cloudFile: return "Nur in der Cloud vorhanden; für die Inhaltsprüfung zuerst lokal laden."
        case .changedFile: return "Datei wurde während des Scans verändert; Duplikatprüfung übersprungen."
        }
    }
}

/// Scan fingerprints keyed by identity, size, nanosecond mtime and ctime.
private final class FingerprintCache {
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var lookup: OpaquePointer?
    private var insert: OpaquePointer?
    private var pending = 0
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init?(url: URL, readOnly: Bool = false) {
        if readOnly {
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  sqlite3_prepare_v2(db, "SELECT digest FROM fingerprints WHERE key=? AND sampled=?", -1, &lookup, nil) == SQLITE_OK else {
                sqlite3_finalize(lookup); if let db { sqlite3_close(db) }; return nil
            }
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { if let db { sqlite3_close(db) }; return nil }
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS fingerprints (key TEXT, sampled INTEGER, digest TEXT, PRIMARY KEY(key,sampled)); BEGIN;", nil, nil, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "SELECT digest FROM fingerprints WHERE key=? AND sampled=?", -1, &lookup, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO fingerprints VALUES (?,?,?)", -1, &insert, nil) == SQLITE_OK else {
            sqlite3_finalize(lookup); sqlite3_finalize(insert); sqlite3_close(db); return nil
        }
    }
    func get(_ key: String, sampled: Bool) -> String? {
        lock.lock(); defer { lock.unlock() }
        defer { sqlite3_reset(lookup); sqlite3_clear_bindings(lookup) }
        sqlite3_bind_text(lookup, 1, key, -1, transient)
        sqlite3_bind_int(lookup, 2, sampled ? 1 : 0)
        guard sqlite3_step(lookup) == SQLITE_ROW, let value = sqlite3_column_text(lookup, 0) else { return nil }
        return String(cString: value)
    }
    func put(_ key: String, sampled: Bool, digest: String) {
        lock.lock(); defer { lock.unlock() }
        guard insert != nil else { return }
        sqlite3_bind_text(insert, 1, key, -1, transient)
        sqlite3_bind_int(insert, 2, sampled ? 1 : 0)
        sqlite3_bind_text(insert, 3, digest, -1, transient)
        sqlite3_step(insert); sqlite3_reset(insert); sqlite3_clear_bindings(insert)
        pending += 1
        if pending >= 2000 { sqlite3_exec(db, "COMMIT; BEGIN;", nil, nil, nil); pending = 0 }
    }
    deinit {
        if insert != nil { sqlite3_exec(db, "COMMIT;", nil, nil, nil) }
        sqlite3_finalize(lookup); sqlite3_finalize(insert); sqlite3_close(db)
    }
}

private final class FingerprintBatch {
    private let lock = NSLock()
    private var cancelled = false
    private var results: [(Int, Result<String, Error>)] = []
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var values: [(Int, Result<String, Error>)] { lock.lock(); defer { lock.unlock() }; return results }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func append(_ index: Int, _ result: Result<String, Error>) {
        lock.lock(); results.append((index, result)); lock.unlock()
    }
}

/// Reuses the completed scan's full SHA-256 proof. Reads metadata and SQLite only;
/// absent proofs never trigger implicit content reads or hashing.
final class ScanFingerprintProof {
    private let cache: FingerprintCache
    init?(url: URL) {
        guard let cache = FingerprintCache(url: url, readOnly: true) else { return nil }
        self.cache = cache
    }
    func matches(_ file: DiskFile, digest: String) -> Bool {
        var before = stat(), after = stat()
        guard lstat(file.path, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_flags & UInt32(SF_DATALESS) == 0,
              "\(before.st_dev):\(before.st_ino)" == file.identity, before.st_size == file.bytes,
              file.modified.map({ abs(DiskScanner.modificationDate(before).timeIntervalSince($0)) < 0.000001 }) ?? false else { return false }
        let key = "\(file.identity):\(before.st_size):\(before.st_mtimespec.tv_sec):\(before.st_mtimespec.tv_nsec):\(before.st_ctimespec.tv_sec):\(before.st_ctimespec.tv_nsec)"
        guard cache.get(key, sampled: false) == digest, lstat(file.path, &after) == 0 else { return false }
        return before.st_dev == after.st_dev && before.st_ino == after.st_ino && before.st_size == after.st_size
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }
}

extension DiskScanResult {
    func removing(paths: Set<String>) -> DiskScanResult {
        let paths = Set(paths.map(DiskScanner.canonicalPath))
        let removed = files.filter { paths.contains(DiskScanner.canonicalPath($0.path)) }
        let rootPath = DiskScanner.canonicalPath(root.path)
        var folderChanges: [String: (Int64, Int)] = [:], categoryChanges: [String: (Int64, Int)] = [:]
        for file in removed {
            var directory = (DiskScanner.canonicalPath(file.path) as NSString).deletingLastPathComponent
            while directory == rootPath || directory.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") {
                let previous = folderChanges[directory] ?? (0, 0)
                folderChanges[directory] = (previous.0 + file.bytes, previous.1 + 1)
                if directory == rootPath { break }; directory = (directory as NSString).deletingLastPathComponent
            }
            let category = DiskScanner.category(for: file.url.pathExtension), previous = categoryChanges[category] ?? (0, 0)
            categoryChanges[category] = (previous.0 + file.bytes, previous.1 + 1)
        }
        let duplicates = duplicates.compactMap { group -> DuplicateGroup? in
            guard group.files.contains(where: { paths.contains(DiskScanner.canonicalPath($0.path)) }) else { return group }
            let remaining = group.files.filter { !paths.contains(DiskScanner.canonicalPath($0.path)) }
            return remaining.count > 1 ? DuplicateGroup(id: group.id, files: remaining) : nil
        }
        let volumes = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return DiskScanResult(root: root, completedAt: completedAt, files: files.filter { !paths.contains(DiskScanner.canonicalPath($0.path)) },
            folders: folders.map { bucket in let change = folderChanges[DiskScanner.canonicalPath(bucket.name)] ?? (0, 0); return DiskBucket(name: bucket.name, bytes: max(0, bucket.bytes - change.0), count: max(0, bucket.count - change.1)) },
            categories: categories.map { bucket in let change = categoryChanges[bucket.name] ?? (0, 0); return DiskBucket(name: bucket.name, bytes: max(0, bucket.bytes - change.0), count: max(0, bucket.count - change.1)) },
            duplicates: duplicates, skipped: skipped, warningSamples: warningSamples, reachedLimit: reachedLimit, duplicateSearch: duplicateSearch,
            volumeTotal: volumeTotal, volumeFree: volumes?.volumeAvailableCapacity.map(Int64.init) ?? volumeFree,
            bytes: max(0, bytes - removed.reduce(0) { $0 + $1.bytes }), allocatedBytes: max(0, allocatedBytes - removed.reduce(0) { $0 + $1.allocatedBytes }),
            redundantBytes: duplicates.reduce(0) { $0 + $1.redundantBytes }, omissions: omissions)
    }
}
