import Foundation
import Darwin

/// Lightweight menu/overview data; it never retains the file or duplicate tables.
struct DiskScanSummary: Codable, Sendable {
    let root: URL
    let completedAt: Date
    let fileCount: Int
    let duplicateCount: Int
    let bytes: Int64
    let redundantBytes: Int64
    var allocatedBytes: Int64 = 0
    var preview: DiskScanResult? = nil
    var largestFolders: [DiskBucket]? = nil
    init(_ result: DiskScanResult) {
        root = result.root; completedAt = result.completedAt; fileCount = result.files.count
        duplicateCount = result.duplicates.count; bytes = result.bytes; redundantBytes = result.redundantBytes
        allocatedBytes = result.allocatedBytes
        largestFolders = DiskScanner.largestFolders(result.folders)
        preview = DiskScanResult(root: result.root, completedAt: result.completedAt, files: Array(result.files.prefix(8)), folders: largestFolders ?? [], categories: result.categories,
            duplicates: [], skipped: result.skipped, warningSamples: result.warningSamples, reachedLimit: result.reachedLimit, duplicateSearch: result.duplicateSearch,
            volumeTotal: result.volumeTotal, volumeFree: result.volumeFree, bytes: result.bytes, allocatedBytes: result.allocatedBytes, redundantBytes: result.redundantBytes, omissions: result.omissions)
    }
    init(root:URL,completedAt:Date,fileCount:Int,duplicateCount:Int,bytes:Int64,redundantBytes:Int64) {
        self.root=root;self.completedAt=completedAt;self.fileCount=fileCount;self.duplicateCount=duplicateCount;self.bytes=bytes;self.redundantBytes=redundantBytes
    }
}

/// Chunked, atomic scan persistence avoids building one enormous property-list object graph.
enum DiskScanCache {
    private static let magic = Data("MTSCAN02".utf8)
    private static let legacyMagic = Data("MTSCAN01".utf8)
    private struct Header: Codable {
        let root: URL; let completedAt: Date
        let fileCount: Int; let folderCount: Int; let categoryCount: Int; let duplicateCount: Int
        let skipped: Int; let warningSamples: [String]; let reachedLimit: Bool; let duplicateSearch: Bool
        let volumeTotal: Int64; let volumeFree: Int64; let bytes: Int64; let allocatedBytes: Int64; let redundantBytes: Int64
        let omissions: ScanOmissions?
        var largestFiles: [DiskFile]? = nil
        var largestFolders: [DiskBucket]? = nil
        var categories: [DiskBucket]? = nil
        init(_ value: DiskScanResult) {
            root = value.root; completedAt = value.completedAt
            fileCount = value.files.count; folderCount = value.folders.count
            categoryCount = value.categories.count; duplicateCount = value.duplicates.count
            skipped = value.skipped; warningSamples = value.warningSamples
            reachedLimit = value.reachedLimit; duplicateSearch = value.duplicateSearch
            volumeTotal = value.volumeTotal; volumeFree = value.volumeFree
            bytes = value.bytes; allocatedBytes = value.allocatedBytes; redundantBytes = value.redundantBytes
            omissions = value.omissions; largestFiles = Array(value.files.prefix(8)); categories = value.categories
            largestFolders = DiskScanner.largestFolders(value.folders)
        }
    }
    private struct GroupHeader: Codable { let id: String; let count: Int }
    private enum CacheError: Error { case corrupt, writeFailed(Int32) }

    static func save(_ value: DiskScanResult, to url: URL, clearRemovals: Bool = true) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent("scan-\(UUID()).tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil) else { throw CacheError.writeFailed(errno) }
        defer { try? manager.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        func write<T: Encodable>(_ object: T) throws {
            try Task.checkCancellation()
            try autoreleasepool {
                let data = try encoder.encode(object)
                var length = UInt32(data.count).littleEndian
                try handle.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
                try handle.write(contentsOf: data)
            }
        }
        func chunks<T: Encodable>(_ array: [T]) throws {
            for offset in stride(from: 0, to: array.count, by: 2048) { try write(Array(array.dropFirst(offset).prefix(2048))) }
        }
        try handle.write(contentsOf: magic)
        try write(Header(value))
        // Flat binary records avoid millions of keyed plist dictionaries on restore.
        for start in stride(from: 0, to: value.files.count, by: 2048) {
            var data = Data()
            func number<T: FixedWidthInteger>(_ value: T) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
            func string(_ value: String) { let bytes = Data(value.utf8); number(UInt32(bytes.count)); data.append(bytes) }
            let batch = value.files.dropFirst(start).prefix(2048)
            number(UInt32(batch.count))
            for file in batch {
                number(file.bytes); number(file.allocatedBytes)
                number((file.modified?.timeIntervalSince1970 ?? .nan).bitPattern)
                string(file.path); string(file.identity)
            }
            try Task.checkCancellation()
            var length = UInt32(data.count).littleEndian
            try handle.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) }); try handle.write(contentsOf: data)
        }
        try chunks(value.folders); try chunks(value.categories)
        // Refer to the canonical file table, preserving shared paths when restoring duplicates.
        var offsets: [String: Int] = [:]
        offsets.reserveCapacity(value.files.count)
        for (index, file) in value.files.enumerated() {
            if index % 2048 == 0 { try Task.checkCancellation() }
            offsets[file.path] = index
        }
        for group in value.duplicates {
            try write(GroupHeader(id: group.id, count: group.files.count))
            for start in stride(from: 0, to: group.files.count, by: 2048) {
                let indices = try group.files.dropFirst(start).prefix(2048).map { file -> Int in
                    guard let index = offsets[file.path] else { throw CacheError.corrupt }; return index
                }
                try write(indices)
            }
        }
        try handle.synchronize()
        try handle.close()
        try Task.checkCancellation()
        guard rename(temporary.path, url.path) == 0 else { throw CacheError.writeFailed(errno) }
        if clearRemovals { try? manager.removeItem(at: removalURL(url)) }
    }

    static func needsMigration(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 8)) != magic
    }
    private struct RemovedPaths: Codable { let scanDate: Date; let paths: Set<String>; var directories: Set<String>? = nil; var summary: DiskScanSummary? = nil }
    static func summary(from url:URL) throws -> DiskScanSummary? {
        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        let signature = try handle.read(upToCount:8)
        guard signature == magic || signature == legacyMagic else { return nil }
        guard let prefix = try handle.read(upToCount:4),prefix.count == 4 else { throw CacheError.corrupt }
        let length = prefix.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << UInt32($1.offset*8) }
        guard length > 0,length <= 1_048_576,let data = try handle.read(upToCount:Int(length)),data.count == Int(length) else { throw CacheError.corrupt }
        let header = try PropertyListDecoder().decode(Header.self,from:data)
        var summary = DiskScanSummary(root:header.root,completedAt:header.completedAt,fileCount:header.fileCount,duplicateCount:header.duplicateCount,bytes:header.bytes,redundantBytes:header.redundantBytes)
        summary.allocatedBytes = header.allocatedBytes
        summary.largestFolders = header.largestFolders
        if let files = header.largestFiles, let categories = header.categories {
            summary.preview = DiskScanResult(root: header.root, completedAt: header.completedAt, files: files, folders: header.largestFolders ?? [], categories: categories, duplicates: [],
                skipped: header.skipped, warningSamples: header.warningSamples, reachedLimit: header.reachedLimit, duplicateSearch: header.duplicateSearch,
                volumeTotal: header.volumeTotal, volumeFree: header.volumeFree, bytes: header.bytes, allocatedBytes: header.allocatedBytes, redundantBytes: header.redundantBytes, omissions: header.omissions)
        }
        if let data = try? Data(contentsOf: removalURL(url)),
           let delta = try? JSONDecoder().decode(RemovedPaths.self, from: data), delta.scanDate == header.completedAt {
            if let updated = delta.summary { return updated }
            if !delta.paths.isEmpty || !(delta.directories ?? []).isEmpty { summary.preview = nil }
        }
        return summary
    }
    private static func removalURL(_ url: URL) -> URL { url.appendingPathExtension("removed.json") }
    /// Persist small cleanup deltas instead of rewriting millions of scan records.
    static func saveRemoved(paths: Set<String>, directories: Set<String> = [], scanDate: Date, to url: URL, summary: DiskScanSummary? = nil) throws {
        let deltaURL = removalURL(url)
        let old = (try? Data(contentsOf: deltaURL)).flatMap { try? JSONDecoder().decode(RemovedPaths.self, from: $0) }
        let combined = paths.union(old?.scanDate == scanDate ? old!.paths : [])
        let combinedDirectories = directories.union(old?.scanDate == scanDate ? old?.directories ?? [] : [])
        try JSONEncoder().encode(RemovedPaths(scanDate: scanDate, paths: combined, directories:combinedDirectories, summary: summary)).write(to: deltaURL, options: .atomic)
    }
    static func load(from url: URL) throws -> DiskScanResult {
        let value = try loadRaw(from: url).withPhysicalAccounting()
        guard let data = try? Data(contentsOf: removalURL(url)),
              let delta = try? JSONDecoder().decode(RemovedPaths.self, from: data), delta.scanDate == value.completedAt else { return value }
        var removed = delta.paths
        let prefixes = (delta.directories ?? []).map { DiskScanner.canonicalPath($0) + "/" }
        if !prefixes.isEmpty { for file in value.files where prefixes.contains(where: { DiskScanner.canonicalPath(file.path).hasPrefix($0) }) { removed.insert(file.path) } }
        return value.removing(paths: removed)
    }
    private static func loadRaw(from url: URL) throws -> DiskScanResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let signature = try handle.read(upToCount: 8)
        guard signature == magic || signature == legacyMagic else {
            // Earlier versions saved an ordinary binary plist at this same stable path.
            return try PropertyListDecoder().decode(DiskScanResult.self, from: Data(contentsOf: url))
        }
        let decoder = PropertyListDecoder()
        let size = Int(try handle.seekToEnd()); try handle.seek(toOffset: 8)
        func block() throws -> Data {
            guard let prefix = try handle.read(upToCount: 4), prefix.count == 4 else { throw CacheError.corrupt }
            let length = prefix.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
            guard length > 0, length <= 16 * 1024 * 1024,
                  let data = try handle.read(upToCount: Int(length)), data.count == Int(length) else { throw CacheError.corrupt }
            return data
        }
        func read<T: Decodable>(_ type: T.Type) throws -> T {
            try autoreleasepool { try decoder.decode(type, from: block()) }
        }
        let header = try read(Header.self)
        guard [header.fileCount, header.folderCount, header.categoryCount, header.duplicateCount].allSatisfy({ $0 >= 0 && $0 <= size / 4 }) else { throw CacheError.corrupt }
        func chunks<T: Decodable>(_ type: T.Type, count: Int) throws -> [T] {
            var values: [T] = []; values.reserveCapacity(count)
            while values.count < count {
                let next = try read([T].self)
                guard !next.isEmpty, next.count <= 2048, next.count <= count - values.count else { throw CacheError.corrupt }
                values.append(contentsOf: next)
            }
            return values
        }
        var files: [DiskFile]
        if signature == legacyMagic { files = try chunks(DiskFile.self, count: header.fileCount) }
        else {
            files = []; files.reserveCapacity(header.fileCount)
            while files.count < header.fileCount {
                try Task.checkCancellation()
                let data = try block()
                try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    var offset = 0
                    func number<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
                        guard raw.count - offset >= MemoryLayout<T>.size else { throw CacheError.corrupt }
                        let value = T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self)); offset += MemoryLayout<T>.size
                        return value
                    }
                    func string() throws -> String {
                        let count = Int(try number(UInt32.self))
                        guard count <= raw.count - offset else { throw CacheError.corrupt }
                        let range = offset..<(offset + count); offset += count
                        guard let value = String(bytes: raw[range], encoding: .utf8) else { throw CacheError.corrupt }; return value
                    }
                    let count = Int(try number(UInt32.self))
                    guard count > 0, count <= 2048, count <= header.fileCount - files.count else { throw CacheError.corrupt }
                    for _ in 0..<count {
                        let bytes = try number(Int64.self), allocated = try number(Int64.self)
                        let modified = Double(bitPattern: try number(UInt64.self))
                        guard bytes >= 0, allocated >= 0, modified.isFinite || modified.isNaN else { throw CacheError.corrupt }
                        files.append(DiskFile(path: try string(), bytes: bytes, allocatedBytes: allocated,
                            modified: modified.isNaN ? nil : Date(timeIntervalSince1970: modified), identity: try string()))
                    }
                    guard offset == raw.count else { throw CacheError.corrupt }
                }
            }
        }
        let folders = try chunks(DiskBucket.self, count: header.folderCount)
        let categories = try chunks(DiskBucket.self, count: header.categoryCount)
        var duplicates: [DuplicateGroup] = []; duplicates.reserveCapacity(header.duplicateCount)
        for _ in 0..<header.duplicateCount {
            let group = try read(GroupHeader.self)
            guard group.count >= 2, group.count <= files.count else { throw CacheError.corrupt }
            let indices = try chunks(Int.self, count: group.count)
            guard indices.allSatisfy({ files.indices.contains($0) }) else { throw CacheError.corrupt }
            duplicates.append(DuplicateGroup(id: group.id, files: indices.map { files[$0] }))
        }
        guard try handle.read(upToCount: 1)?.isEmpty ?? true else { throw CacheError.corrupt }
        return DiskScanResult(root: header.root, completedAt: header.completedAt, files: files, folders: folders,
            categories: categories, duplicates: duplicates, skipped: header.skipped, warningSamples: header.warningSamples,
            reachedLimit: header.reachedLimit, duplicateSearch: header.duplicateSearch, volumeTotal: header.volumeTotal,
            volumeFree: header.volumeFree, bytes: header.bytes, allocatedBytes: header.allocatedBytes, redundantBytes: header.redundantBytes, omissions: header.omissions)
    }
}
