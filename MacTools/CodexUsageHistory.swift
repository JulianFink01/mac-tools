import Foundation
import SQLite3
import CryptoKit

enum CodexUsageFormat {
    static func tokens(_ value: Int64) -> String { Double(value).formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
    static func month(_ date: Date) -> String { date.formatted(.dateTime.month(.wide).year()) }
}

enum CodexUsagePeriod: String, CaseIterable, Identifiable {
    case week, month, all
    var id: String { rawValue }
    var label: String { switch self { case .week: return "7 Tage"; case .month: return "30 Tage"; case .all: return "Gesamt" } }
    func start(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .week: return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        case .month: return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))
        case .all: return nil
        }
    }
}

struct CodexTokenTotals: Equatable {
    var input: Int64 = 0
    var cached: Int64 = 0
    var output: Int64 = 0
    var total: Int64 = 0
    static func + (a: Self, b: Self) -> Self { Self(input: a.input + b.input, cached: a.cached + b.cached, output: a.output + b.output, total: a.total + b.total) }
    var nonnegative: Self { Self(input: max(0,input), cached: max(0,cached), output: max(0,output), total: max(0,total)) }
    func delta(since previous: Self) -> Self { Self(input: input-previous.input, cached: cached-previous.cached, output: output-previous.output, total: total-previous.total).nonnegative }
    init(input: Int64 = 0, cached: Int64 = 0, output: Int64 = 0, total: Int64 = 0) { self.input=input; self.cached=cached; self.output=output; self.total=total }
    init(_ json: [String:Any]) {
        input = (json["input_tokens"] as? NSNumber)?.int64Value ?? 0
        cached = (json["cached_input_tokens"] as? NSNumber)?.int64Value ?? 0
        output = (json["output_tokens"] as? NSNumber)?.int64Value ?? 0
        total = (json["total_tokens"] as? NSNumber)?.int64Value ?? input+output
    }
}

struct CodexUsageSummary {
    struct Model: Identifiable { var name: String; var tokens: Int64; var chats: Int; var id: String { name } }
    var totals: CodexTokenTotals
    var chats: Int
    var models: [Model]
}

struct CodexUsageHistory {
    struct Row {
        var day: Date
        var thread: String
        var model: String
        var tokens: CodexTokenTotals
    }
    var rows: [Row] = []
    var readableFiles = 0
    var missingFiles = 0
    var updatedAt = Date()
    var calendar = Calendar.current
    struct ThreadCoverage {
        var id: String
        var created: Date
        var updated: Date
        var readable: Bool
    }
    var threads: [ThreadCoverage] = []
    func coverage(month: Date) -> (created: Int, missing: Int) {
        let interval = calendar.dateInterval(of: .month, for: month)!
        return (threads.filter { $0.created >= interval.start && $0.created < interval.end }.count,
                threads.filter { !$0.readable && $0.created < interval.end && $0.updated >= interval.start }.count)
    }
    func canCompare(_ a: Date, _ b: Date) -> Bool { missingFiles == 0 && coverage(month: a).missing == 0 && coverage(month: b).missing == 0 }
    var coverageText: String {
        if missingFiles > 0 { return "Zeitwerte aus \(readableFiles) lokalen Verläufen · \(missingFiles) Verläufe fehlen oder sind nicht lesbar. Erfasste Werte können unvollständig sein." }
        return "Zeitwerte aus \(readableFiles) lokalen Verläufen. Cache-Eingaben enthalten; keine Abrechnungswerte."
    }
    func summary(start: Date? = nil, end: Date = .distantFuture) -> CodexUsageSummary {
        let selected = rows.filter { (start == nil || $0.day >= start!) && $0.day < end }
        let groups = Dictionary(grouping: selected, by: \.model)
        return CodexUsageSummary(totals: selected.reduce(.init()) { $0 + $1.tokens }, chats: Set(selected.map(\.thread)).count,
            models: groups.map { name, rows in .init(name: name, tokens: rows.reduce(0) { $0 + $1.tokens.total }, chats: Set(rows.map(\.thread)).count) }
                .sorted { $0.tokens == $1.tokens ? $0.name < $1.name : $0.tokens > $1.tokens })
    }
    func summary(month: Date) -> CodexUsageSummary {
        let interval = calendar.dateInterval(of: .month, for: month)!
        return summary(start: interval.start, end: interval.end)
    }
    func months(now: Date = Date()) -> [Date] {
        let last = calendar.dateInterval(of: .month, for: now)!.start
        let first = calendar.dateInterval(of: .month, for: (rows.map(\.day) + threads.map(\.created)).min() ?? now)!.start
        var result: [Date] = [], date = last
        while date >= first && result.count < 120 {
            result.append(date)
            guard let previous = calendar.date(byAdding: .month, value: -1, to: date) else { break }
            date = previous
        }
        // Always offer the previous month, including when this is a new local profile.
        if result.count == 1, let previous = calendar.date(byAdding: .month, value: -1, to: last) { result.append(previous) }
        return result
    }
    struct DayPoint: Identifiable {
        var day: Int
        var tokens: Int64
        var id: Int { day }
    }
    func cumulativeDays(month: Date, now: Date = Date()) -> [DayPoint] {
        let interval = calendar.dateInterval(of: .month, for: month)!
        let groups = Dictionary(grouping: rows.filter { $0.day >= interval.start && $0.day < interval.end }, by: { calendar.component(.day, from: $0.day) })
        let limit = calendar.isDate(month, equalTo: now, toGranularity: .month) ? calendar.component(.day, from: now) : calendar.range(of: .day, in: .month, for: month)!.count
        var total: Int64 = 0
        return (1...limit).map { day in total += (groups[day] ?? []).reduce(0) { $0 + $1.tokens.total }; return DayPoint(day: day, tokens: total) }
    }
}

/// Incremental, content-free local index. Only timestamps, model names and token counters are retained.
/// Large tool-output lines are skipped with bounded memory; source databases and rollouts stay read-only.
enum CodexUsageHistoryIndex {
    private static let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static var cacheURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacTools/codex-token-history-v1.sqlite") }
    private static func failure(_ message: String) -> NSError { NSError(domain: "MacTools.CodexUsageHistory", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private static func open(_ url: URL, writable: Bool) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(url.path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw failure("Tokenverlauf konnte nicht geöffnet werden.")
        }
        sqlite3_busy_timeout(db, 1500); return db
    }
    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure("Tokenindex konnte nicht aktualisiert werden.") }
    }
    private static func statement(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw failure("Codex stellt die benötigten Verlaufsdaten nicht bereit.") }
        return value
    }
    private static func text(_ s: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(s,column).map { String(cString:$0) } ?? "" }
    private static func bind(_ value: String, _ statement: OpaquePointer, _ index: Int32) { sqlite3_bind_text(statement,index,value,-1,transient) }

    static func read(home: URL, cache: URL = cacheURL, calendar: Calendar = .current, now: Date = Date()) throws -> CodexUsageHistory {
        lock.lock(); defer { lock.unlock() }
        let candidates = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
            .compactMap { url -> (URL,Int)? in guard url.pathExtension == "sqlite", url.lastPathComponent.hasPrefix("state_"), let n=Int(url.deletingPathExtension().lastPathComponent.dropFirst(6)) else { return nil }; return (url,n) }.sorted { $0.1 > $1.1 }
        guard let source = candidates.first?.0 else { throw failure("Keine lokale Codex-Verlaufsdatenbank gefunden.") }
        let sourceDB = try open(source, writable: false); defer { sqlite3_close(sourceDB) }
        let threads = try statement(sourceDB,"SELECT id,rollout_path,created_at,updated_at FROM threads ORDER BY id"); defer { sqlite3_finalize(threads) }
        var paths: [String:String] = [:]
        var coverage: [CodexUsageHistory.ThreadCoverage] = []
        var sourceStatus = sqlite3_step(threads)
        while sourceStatus == SQLITE_ROW {
            let id = text(threads,0); paths[text(threads,1)] = id
            coverage.append(.init(id:id,created:Date(timeIntervalSince1970:sqlite3_column_double(threads,2)),updated:Date(timeIntervalSince1970:sqlite3_column_double(threads,3)),readable:false))
            sourceStatus=sqlite3_step(threads)
        }
        guard sourceStatus == SQLITE_DONE else { throw failure("Die lokale Chatliste konnte nicht vollständig gelesen werden.") }
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try open(cache, writable: true); defer { sqlite3_close(db) }
        try execute(db, """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY,thread TEXT,offset INTEGER,model TEXT,input INTEGER,cached INTEGER,output INTEGER,total INTEGER,has_previous INTEGER,modified REAL);
        CREATE TABLE IF NOT EXISTS events(fingerprint TEXT,path TEXT,thread TEXT,model TEXT,timestamp REAL,input INTEGER,cached INTEGER,output INTEGER,total INTEGER,PRIMARY KEY(fingerprint,path));
        CREATE INDEX IF NOT EXISTS events_path ON events(path);
        CREATE INDEX IF NOT EXISTS events_timestamp ON events(timestamp);
        """)
        var readable = 0, missing = 0
        let root = home.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for (path,thread) in paths.sorted(by: { $0.key < $1.key }) {
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(root), url.pathExtension == "jsonl", let info = try? url.resourceValues(forKeys: [.fileSizeKey,.contentModificationDateKey]), let size = info.fileSize else { missing += 1; continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else { missing += 1; continue }
            defer { try? handle.close() }
            do {
                try index(handle: handle, path: path, thread: thread, size: UInt64(size), modified: info.contentModificationDate?.timeIntervalSince1970 ?? 0, db: db)
                readable += 1
                if let index = coverage.firstIndex(where: { $0.id == thread }) { coverage[index].readable = true }
            } catch { missing += 1 }
        }
        // Keep already captured historical counters when a rollout is later unavailable.
        // Separate source rows let a copied history survive deletion/reindexing of another copy.
        let query = try statement(db, "SELECT fingerprint,path,thread,model,timestamp,input,cached,output,total FROM events ORDER BY timestamp,path")
        defer { sqlite3_finalize(query) }
        struct Key: Hashable { var day: Date; var thread: String; var model: String }
        var grouped: [Key:CodexTokenTotals] = [:]
        var seen = Set<String>()
        var status = sqlite3_step(query)
        while status == SQLITE_ROW {
            defer { status=sqlite3_step(query) }
            guard text(query,1).hasPrefix(root) else { continue }
            let date = Date(timeIntervalSince1970: sqlite3_column_double(query,4))
            guard date <= now else { continue }
            guard seen.insert(text(query,0)).inserted else { continue }
            let key = Key(day: calendar.startOfDay(for: date),thread:text(query,2),model:text(query,3))
            let tokens = CodexTokenTotals(input:sqlite3_column_int64(query,5),cached:sqlite3_column_int64(query,6),output:sqlite3_column_int64(query,7),total:sqlite3_column_int64(query,8))
            grouped[key,default:.init()] = grouped[key,default:.init()] + tokens
        }
        guard status == SQLITE_DONE else { throw failure("Der Tokenverlauf konnte nicht vollständig gelesen werden.") }
        return CodexUsageHistory(rows: grouped.map { .init(day:$0.key.day,thread:$0.key.thread,model:$0.key.model,tokens:$0.value) }.sorted { $0.day < $1.day },readableFiles:readable,missingFiles:missing,updatedAt:now,calendar:calendar,threads:coverage)
    }

    private static func index(handle: FileHandle, path: String, thread: String, size: UInt64, modified: Double, db: OpaquePointer) throws {
        let lookup = try statement(db,"SELECT offset,model,input,cached,output,total,has_previous,modified FROM files WHERE path=?"); defer { sqlite3_finalize(lookup) }
        bind(path,lookup,1)
        var offset: UInt64 = 0, model = "Unbekannt", previous = CodexTokenTotals(), hasPrevious = false, reset = false
        if sqlite3_step(lookup) == SQLITE_ROW {
            offset = UInt64(max(0,sqlite3_column_int64(lookup,0))); model = text(lookup,1)
            previous = .init(input:sqlite3_column_int64(lookup,2),cached:sqlite3_column_int64(lookup,3),output:sqlite3_column_int64(lookup,4),total:sqlite3_column_int64(lookup,5))
            hasPrevious = sqlite3_column_int(lookup,6) != 0
            if offset == size && sqlite3_column_double(lookup,7) == modified { return }
            if offset > size || (offset == size && sqlite3_column_double(lookup,7) != modified) {
                offset=0; model="Unbekannt"; previous = .init(); hasPrevious=false
                reset = true
            }
        }
        try handle.seek(toOffset: offset)
        let insert = try statement(db,"INSERT OR IGNORE INTO events VALUES(?,?,?,?,?,?,?,?,?)"); defer { sqlite3_finalize(insert) }
        let dateParser = ISO8601DateFormatter(); dateParser.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        let plainDateParser = ISO8601DateFormatter()
        let newline = Data([10])
        let needles = ["\"token_count\"","\"turn_context\""].map { Data($0.utf8) }
        var line = Data(), oversized = false, readOffset = offset, completeOffset = offset
        try execute(db,"BEGIN")
        do {
            if reset {
                let clear = try statement(db,"DELETE FROM events WHERE path=?"); bind(path,clear,1); sqlite3_step(clear); sqlite3_finalize(clear)
            }
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                var cursor = chunk.startIndex
                while cursor < chunk.endIndex {
                    let end = chunk.range(of: newline, in: cursor..<chunk.endIndex)?.lowerBound
                    let stop = end ?? chunk.endIndex
                    if !oversized {
                        if line.count + stop-cursor <= 65_536 { line.append(chunk[cursor..<stop]) }
                        else { oversized=true; line.removeAll(keepingCapacity:true) }
                    }
                    if let end {
                        if !oversized, needles.contains(where: { line.range(of:$0) != nil }),
                           let value = (try? JSONSerialization.jsonObject(with: line)) as? [String:Any],
                           let payload = value["payload"] as? [String:Any] {
                            if value["type"] as? String == "turn_context" {
                                if let name = payload["model"] as? String, !name.isEmpty { model=name }
                            } else if value["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
                                      let info = payload["info"] as? [String:Any], let totalJSON = info["total_token_usage"] as? [String:Any],
                                      let stamp = value["timestamp"] as? String, let date = dateParser.date(from:stamp) ?? plainDateParser.date(from:stamp) {
                                let cumulative = CodexTokenTotals(totalJSON)
                                let last = (info["last_token_usage"] as? [String:Any]).map(CodexTokenTotals.init)
                                let delta = hasPrevious && cumulative.total >= previous.total ? cumulative.delta(since:previous) : (last ?? .init())
                                previous = cumulative; hasPrevious = true
                                if delta.total > 0 {
                                    // Copied/forked histories can contain identical past events. Count each event once.
                                    let identity = "\(stamp)|\(cumulative.input)|\(cumulative.cached)|\(cumulative.output)|\(cumulative.total)"
                                    let fingerprint = SHA256.hash(data:Data(identity.utf8)).map { String(format:"%02x",$0) }.joined()
                                    sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                                    for (n,v) in [fingerprint,path,thread,model].enumerated() { bind(v,insert,Int32(n+1)) }
                                    sqlite3_bind_double(insert,5,date.timeIntervalSince1970)
                                    for (n,v) in [delta.input,delta.cached,delta.output,delta.total].enumerated() { sqlite3_bind_int64(insert,Int32(n+6),v) }
                                    guard sqlite3_step(insert) == SQLITE_DONE else { throw failure("Tokenereignis konnte nicht gespeichert werden.") }
                                }
                            }
                        }
                        line.removeAll(keepingCapacity:true); oversized=false
                        completeOffset = readOffset + UInt64(end+1); cursor=end+1
                    } else { cursor=stop }
                }
                readOffset += UInt64(chunk.count)
            }
            let save = try statement(db,"INSERT OR REPLACE INTO files VALUES(?,?,?,?,?,?,?,?,?,?)"); defer { sqlite3_finalize(save) }
            bind(path,save,1); bind(thread,save,2); sqlite3_bind_int64(save,3,Int64(completeOffset)); bind(model,save,4)
            for (n,v) in [previous.input,previous.cached,previous.output,previous.total].enumerated() { sqlite3_bind_int64(save,Int32(n+5),v) }
            let finalModified = (try? FileManager.default.attributesOfItem(atPath:path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? modified
            sqlite3_bind_int(save,9,hasPrevious ? 1 : 0); sqlite3_bind_double(save,10,finalModified)
            guard sqlite3_step(save) == SQLITE_DONE else { throw failure("Tokenindex konnte nicht gespeichert werden.") }
            try execute(db,"COMMIT")
        } catch { try? execute(db,"ROLLBACK"); throw error }
    }
}
