import Foundation
import SQLite3

@main struct CodexUsageHistoryChecks {
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        let parser = ISO8601DateFormatter()
        let now = parser.date(from:"2026-10-27T12:00:00Z")!
        if CommandLine.arguments.contains("--live") {
            let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory()+"/.codex")
            let started = Date()
            let history = try CodexUsageHistoryIndex.read(home:home,cache:URL(fileURLWithPath:FileManager.default.currentDirectoryPath+"/build/usage-history-live76.sqlite"))
            let week = history.summary(start:CodexUsagePeriod.week.start(now:Date(),calendar:history.calendar))
            let month = history.summary(start:CodexUsagePeriod.month.start(now:Date(),calendar:history.calendar))
            print("LIVE: \(history.readableFiles) readable / \(history.missingFiles) unavailable; \(history.rows.count) daily chat/model rows; 7 days \(week.totals.total); 30 days \(month.totals.total); \(Date().timeIntervalSince(started)) seconds")
            let result: [String:Any] = ["readable":history.readableFiles,"unavailable":history.missingFiles,"days7":week.totals.total,"days30":month.totals.total,"months":history.months().map { ["month":CodexUsageFormat.month($0),"tokens":history.summary(month:$0).totals.total] }]
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"build/usage-history-live76.json"))
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-token-history-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let cache = root.appendingPathComponent("cache.sqlite")
        let a = root.appendingPathComponent("a.jsonl"), b = root.appendingPathComponent("b.jsonl"), c = root.appendingPathComponent("c.jsonl")
        var db: OpaquePointer?
        precondition(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path,&db)==SQLITE_OK)
        let insert = "CREATE TABLE threads(id TEXT,rollout_path TEXT,created_at INTEGER DEFAULT 0,updated_at INTEGER DEFAULT 1793102400); INSERT INTO threads(id,rollout_path) VALUES('a','\(a.path)'),('b','\(b.path)'),('c','\(c.path)'),('missing','\(root.path)/missing.jsonl');"
        precondition(sqlite3_exec(db,insert,nil,nil,nil)==SQLITE_OK)
        precondition(sqlite3_exec(db,"UPDATE threads SET created_at=1790841600; UPDATE threads SET created_at=1788307200 WHERE id='missing';",nil,nil,nil)==SQLITE_OK)
        sqlite3_close(db)
        func json(_ object: [String:Any]) throws -> String { String(decoding:try JSONSerialization.data(withJSONObject:object,options:.sortedKeys),as:UTF8.self)+"\n" }
        func context(_ name: String) throws -> String { try json(["type":"turn_context","payload":["model":name]]) }
        func event(_ stamp: String,_ total: Int64, last: Int64? = nil) throws -> String {
            func counters(_ value: Int64) -> [String:Int64] { ["input_tokens":value*4/5,"output_tokens":value/5,"cached_input_tokens":value*2/5,"total_tokens":value] }
            return try json(["timestamp":stamp,"type":"event_msg","payload":["type":"token_count","info":["total_token_usage":counters(total),"last_token_usage":counters(last ?? total)]]])
        }
        let e1 = try event("2026-09-30T21:59:59Z",100)
        let e2 = try event("2026-09-30T22:00:00Z",300)
        let e3 = try event("2026-10-21T10:00:00Z",350)
        let e4 = try event("2026-10-27T10:00:00Z",500)
        let large = String(repeating:"x",count:2_500_000)+"\n"
        try (context("model-a")+e1+e2+large+e3+e4+e4).write(to:a,atomically:true,encoding:.utf8)
        try (context("model-a")+e1+e2+e3+e4+context("model-b")+event("2026-10-27T11:00:00Z",600,last:100)).write(to:b,atomically:true,encoding:.utf8)
        try (context("model-c")+event("2026-10-27T11:30:00Z",1_000_000,last:10)).write(to:c,atomically:true,encoding:.utf8)
        let first = try CodexUsageHistoryIndex.read(home:root,cache:cache,calendar:calendar,now:now)
        precondition(first.readableFiles==3 && first.missingFiles==1)
        precondition(!first.canCompare(parser.date(from:"2026-09-01T00:00:00Z")!, now), "Missing histories must suppress percentage comparisons")
        precondition(first.summary().totals.total==610,"Copied events and repeated cumulative snapshots must not inflate usage")
        let september = parser.date(from:"2026-09-01T00:00:00Z")!, october = parser.date(from:"2026-10-01T00:00:00Z")!
        precondition(first.coverage(month:september).created == 1 && first.coverage(month:october).created == 3, "Chat metadata must remain available independently of token event coverage")
        precondition(first.summary(month:september).totals.total==100 && first.summary(month:october).totals.total==510,"Month boundaries must use Zurich local time")
        precondition(first.summary(start:CodexUsagePeriod.week.start(now:now,calendar:calendar)).totals.total==310)
        precondition(first.summary(start:CodexUsagePeriod.month.start(now:now,calendar:calendar)).totals.total==610)
        precondition(first.summary().models.first { $0.name=="model-a" }?.tokens==500)
        precondition(first.summary().models.first { $0.name=="model-b" }?.tokens==100)
        precondition(first.cumulativeDays(month:october,now:now).last?.tokens==510 && first.cumulativeDays(month:october,now:now).last?.day==27)
        let warm = try CodexUsageHistoryIndex.read(home:root,cache:cache,calendar:calendar,now:now)
        precondition(warm.summary().totals==first.summary().totals,"Warm reads must not count events twice")
        let appended = try event("2026-10-27T11:45:00Z",1_000_040,last:40)
        let cut = appended.index(appended.startIndex,offsetBy:appended.count/2)
        let handle = try FileHandle(forWritingTo:c); try handle.seekToEnd()
        try handle.write(contentsOf:Data(appended[..<cut].utf8))
        let partial = try CodexUsageHistoryIndex.read(home:root,cache:cache,calendar:calendar,now:now)
        precondition(partial.summary().totals.total==610,"An incomplete streamed JSON line must wait")
        try handle.write(contentsOf:Data(appended[cut...].utf8)); try handle.close()
        let complete = try CodexUsageHistoryIndex.read(home:root,cache:cache,calendar:calendar,now:now)
        precondition(complete.summary().totals.total==650,"Incremental read must recover a partial trailing record exactly once")
        try FileManager.default.removeItem(at:a)
        let unavailable = try CodexUsageHistoryIndex.read(home:root,cache:cache,calendar:calendar,now:now)
        precondition(unavailable.summary().totals.total==650 && unavailable.missingFiles==2,"Already indexed historical counters must survive unavailable source files")
        print("PASS: timezone/month/week boundaries, cumulative deltas, inherited baseline, duplicate/fork history, model attribution, oversized lines, incremental cache, partial streaming lines, unavailable coverage and monthly cumulative comparison")
    }
}
