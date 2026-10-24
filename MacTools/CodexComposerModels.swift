import Foundation

struct CodexModelChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let efforts: [String]
    let defaultEffort: String
    let tiers: [(String, String)]
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    init?(_ json: [String: Any]) {
        guard let id = json["model"] as? String else { return nil }; self.id = id
        name = json["displayName"] as? String ?? id
        efforts = (json["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
        defaultEffort = json["defaultReasoningEffort"] as? String ?? "medium"
        tiers = (json["serviceTiers"] as? [[String: Any]] ?? []).compactMap { value in
            guard let id = value["id"] as? String else { return nil }; return (id, value["name"] as? String ?? id)
        }
    }
}

struct CodexTurnOptions: Codable, Equatable {
    var model: String?
    var effort: String?
    var permission = "inherit"
    var mode = "inherit"
    var serviceTier: String?
    func parameters(cwd: String, fallbackModel: String) -> [String: Any] {
        var values: [String: Any] = [:]
        if let model { values["model"] = model }
        if let effort { values["effort"] = effort }
        if let serviceTier { values["serviceTier"] = serviceTier }
        if mode != "inherit" {
            values["collaborationMode"] = ["mode": mode, "settings": ["model": model ?? fallbackModel, "reasoning_effort": effort as Any? ?? NSNull(), "developer_instructions": NSNull()]]
        }
        if permission != "inherit" {
            values["approvalPolicy"] = permission == "ask" ? "untrusted" : permission == "full" ? "never" : "on-request"
            values["approvalsReviewer"] = permission == "auto" ? "auto_review" : "user"
            values["sandboxPolicy"] = permission == "full" ? ["type": "dangerFullAccess"] : ["type": "workspaceWrite", "writableRoots": [cwd], "networkAccess": false]
        }
        return values
    }
}

struct CodexReference: Codable, Identifiable, Equatable {
    let name: String
    let path: String
    let kind: String
    var detail = ""
    static func attachment(_ url: URL) -> CodexReference {
        CodexReference(name: url.lastPathComponent, path: url.path, kind: ["png", "jpg", "jpeg", "webp", "gif", "heic"].contains(url.pathExtension.lowercased()) ? "image" : "file")
    }
    var id: String { kind + ":" + path }
    var displayName: String { kind == "skill" ? name.components(separatedBy: ":").last!.replacingOccurrences(of: "-", with: " ").capitalized : name }
    var providerLabel: String { kind == "skill" && name.contains(":") ? name.components(separatedBy: ":").dropLast().joined(separator: ":").replacingOccurrences(of: "-", with: " ").capitalized : "" }
    var icon: String { kind == "skill" ? "sparkles" : kind == "plugin" ? "puzzlepiece.extension" : kind == "app" ? "globe" : kind == "image" ? "photo" : "doc" }
    var input: [String: Any] {
        if kind == "image" { return ["type": "localImage", "path": path] }
        if kind == "file" { return ["type": "text", "text": "Referenzdatei oder Ordner: " + path] }
        return ["type": kind == "skill" ? "skill" : "mention", "name": name, "path": path]
    }
}


struct CodexGoal: Equatable {
    let objective: String
    let status: String
    let tokens: Int64
    let budget: Int64?
    let seconds: Int64
    init?(_ json: [String: Any]?) {
        guard let json, let objective = json["objective"] as? String else { return nil }
        self.objective = objective; status = json["status"] as? String ?? "active"
        tokens = (json["tokensUsed"] as? NSNumber)?.int64Value ?? 0
        budget = (json["tokenBudget"] as? NSNumber)?.int64Value
        seconds = (json["timeUsedSeconds"] as? NSNumber)?.int64Value ?? 0
    }
    var isRunning: Bool { status == "active" }
    var durationLabel: String { "\(seconds / 3600) Std. \((seconds % 3600) / 60) Min." }
    var label: String { ["active": "Ziel aktiv", "paused": "Ziel pausiert", "blocked": "Ziel blockiert", "usageLimited": "Zielnutzung begrenzt", "budgetLimited": "Zielbudget erreicht", "complete": "Ziel abgeschlossen"][status] ?? status }
}

struct CodexQueuedMessage: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    var references: [CodexReference]
    let options: CodexTurnOptions
    let cwd: String
    let modelHint: String
}

struct CodexLiveSettings {
    let model: String?
    let effort: String?
    init(_ state: [String: Any]) {
        let thread = state["latestThreadSettings"] as? [String: Any] ?? [:]
        let collaboration = state["latestCollaborationMode"] as? [String: Any] ?? thread["collaborationMode"] as? [String: Any] ?? [:]
        let settings = collaboration["settings"] as? [String: Any] ?? [:]
        model = state["latestModel"] as? String ?? thread["model"] as? String ?? settings["model"] as? String
        effort = state["latestReasoningEffort"] as? String ?? thread["effort"] as? String ?? settings["reasoning_effort"] as? String
    }
}

struct CodexNativeQueuedMessage: Identifiable, Equatable {
    let id: String
    let text: String
    let payload: Data
    var isServerQueue: Bool { raw["input"] is [[String: Any]] }
    var raw: [String: Any] { ((try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]) ?? [:] }
    var previewText: String {
        let body = text.range(of: "## My request:").map { String(text[$0.upperBound...]) } ?? text
        let clean = body.replacingOccurrences(of: #"<image\b[^>]*>(?:</image>)?"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.hasPrefix("# Files mentioned by the user:") ? "Angehängte Dateien" : clean.isEmpty ? "Anhänge" : clean
    }
    var attachments: [CodexReference] {
        var value = raw; if !isServerQueue { value["content"] = [["type": "text", "text": text]]; value["restoreMessage"] = ["context": raw["context"] ?? [:]] }
        var refs = CodexMessageImage.collect(value, text: text).map { CodexReference(name: URL(fileURLWithPath: $0.source).lastPathComponent, path: $0.source, kind: "image") }
        if let regex = try? NSRegularExpression(pattern: #"(?m)^## (.+?): (/[^\n]+)$"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 2), in: text) { let ref = CodexReference.attachment(URL(fileURLWithPath: String(text[range]))); if !refs.contains(where: { $0.path == ref.path }) { refs.append(ref) } }
            }
        }
        return refs
    }
    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String, let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) else { return nil }
        let input = value["input"] as? [[String: Any]]
        guard value["text"] is String || input != nil else { return nil }
        self.id = id; text = value["text"] as? String ?? input!.compactMap { $0["text"] as? String }.joined(separator: "\n"); payload = data
    }
    func editedInput(_ text: String) throws -> [[String: Any]] {
        guard var input = raw["input"] as? [[String: Any]] else { throw CodexFailure(message: "Diese Nachricht bitte im Originalchat bearbeiten.") }
        let indices = input.indices.filter { input[$0]["type"] as? String == "text" }
        guard indices.count == 1 else { throw CodexFailure(message: "Nachrichten mit mehreren Textkontexten bitte im Originalchat bearbeiten.") }
        input[indices[0]]["text"] = text; input[indices[0]]["text_elements"] = []
        return input
    }
    func edited(_ text: String) throws -> [String: Any] {
        var value = raw, context = value["context"] as? [String: Any] ?? [:]
        if let prompt = context["prompt"] as? String {
            guard prompt.hasSuffix(self.text), !self.text.isEmpty else { throw CodexFailure(message: "Diesen vorbereiteten Anhang bitte im Originalchat bearbeiten, damit sein Kontext erhalten bleibt.") }
            context["prompt"] = String(prompt.dropLast(self.text.count)) + text
        }
        value["text"] = text; value["context"] = context
        return value
    }
}

struct CodexUsageWindow: Identifiable, Equatable {
    let id: String
    let used: Double
    let minutes: Int?
    let resetsAt: Date?
    var remaining: Double { max(0, min(100, 100 - used)) }
    var label: String { guard let minutes else { return id == "primary" ? "Aktuelles Fenster" : "Weiteres Fenster" }; return minutes >= 1440 ? "\(minutes / 1440) Tage" : minutes >= 60 ? "\(minutes / 60) Std." : "\(minutes) Min." }
    init?(_ value: [String: Any], id: String) {
        guard let used = value["usedPercent"] as? NSNumber, used.doubleValue.isFinite else { return nil }
        self.id = id; self.used = max(0, min(100, used.doubleValue))
        minutes = (value["windowDurationMins"] as? NSNumber)?.intValue
        resetsAt = (value["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }
}
struct CodexUsageBucket: Identifiable, Equatable {
    let id: String
    let title: String
    let windows: [CodexUsageWindow]
    static func parse(_ response: [String: Any]) -> [CodexUsageBucket] {
        let mapped = response["rateLimitsByLimitId"] as? [String: [String: Any]]
        let entries = mapped?.isEmpty == false ? mapped! : (response["rateLimits"] as? [String: Any]).map { ["codex": $0] } ?? [:]
        return entries.keys.sorted { a, b in if a == "codex" { return b != "codex" }; if b == "codex" { return false }; return a < b }.map { id in
            let data = entries[id]!
            let windows = ["primary", "secondary"].compactMap { key in (data[key] as? [String: Any]).flatMap { CodexUsageWindow($0, id: key) } }
            return CodexUsageBucket(id: id, title: data["limitName"] as? String ?? id, windows: windows)
        }
    }
}

struct CodexActivityDetails: Equatable {
    let title: String
    let command: String
    let cwd: String?
    var status: String
    var output: String
    var outputTruncated: Bool
    let exitCode: Int?
    let durationMs: Double?
    var startedAt: Date?
    var observedStart = false
    var isRunning: Bool { ["inProgress", "running", "started"].contains(status) }
    var failed: Bool { ["failed", "declined", "cancelled"].contains(status) || exitCode.map { $0 != 0 } == true }
    static func from(_ item: [String: Any]) -> Self? {
        let type = item["type"] as? String
        guard type == "commandExecution" || type == "mcpToolCall" else { return nil }
        let args = item["arguments"] as? [String: Any] ?? [:]
        let command = item["command"] as? String ?? args["cmd"] as? String ?? args["command"] as? String ?? args["code"] as? String ?? (item["arguments"] as? String) ?? pretty(args)
        let result = item["result"] as? [String: Any] ?? [:]
        var output = item["aggregatedOutput"] as? String ?? (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        if output.isEmpty, let error = item["error"] as? [String: Any] { output = error["message"] as? String ?? "" }
        let truncated = output.count > 65_536; output = String(output.suffix(65_536))
        var status = item["status"] as? String ?? "unknown"
        if result["isError"] as? Bool == true || item["error"] is [String: Any] { status = "failed" }
        let rawDuration = (item["durationMs"] as? NSNumber)?.doubleValue
        let duration = rawDuration.flatMap { $0.isFinite && $0 >= 0 && $0 <= 315_576_000_000 ? $0 : nil }
        let rawStart = item["mactoolsStartedAtMs"] ?? item["startedAtMs"]
        let startMs = (rawStart as? NSNumber)?.doubleValue ?? (rawStart as? String).flatMap(Double.init)
        let start = startMs.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        return Self(title: type == "commandExecution" ? "Befehl" : "Tool · " + (item["tool"] as? String ?? "MCP"), command: command, cwd: item["cwd"] as? String ?? args["workdir"] as? String, status: status, output: output, outputTruncated: truncated, exitCode: (item["exitCode"] as? NSNumber)?.intValue, durationMs: duration, startedAt: start)
    }
    private static func pretty(_ value: [String: Any]) -> String { guard !value.isEmpty, let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) else { return "" }; return text }
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "unbekannt" }
        let seconds = max(0, min(315_576_000, seconds)), whole = Int(seconds + 0.0005)
        if whole >= 3600 { return "\(whole / 3600) Std. \(whole % 3600 / 60) Min. \(whole % 60) Sek." }
        if whole >= 60 { return "\(whole / 60) Min. \(whole % 60) Sek." }
        return seconds < 1 ? String(format: "%.1f Sek.", seconds) : "\(whole) Sek."
    }
    func timingLabel(now: Date) -> String {
        if isRunning { return startedAt.map { (observedStart ? "Beobachtet seit " : "Läuft seit ") + Self.duration(now.timeIntervalSince($0)) } ?? "Läuft · Startzeit nicht verfügbar" }
        let state = failed ? "Fehlgeschlagen" : status == "completed" ? "Ausgeführt" : status
        return state + (durationMs.map { " · " + Self.duration($0 / 1000) } ?? "") + (exitCode.map { " · Exit \($0)" } ?? "")
    }
}

/// Keep explicit disclosure choices outside lazy rows, which can be recreated as the history tail moves.
struct CodexActivityExpansionState: Equatable {
    private var groups: [String:Bool] = [:]
    private var details: [String:Bool] = [:]
    private var groupAnchors: [String:String] = [:]
    private func key(_ thread: String, _ item: String) -> String { thread + ":" + item }
    func groupAnchor(thread: String, ids: [String]) -> String {
        ids.compactMap { groupAnchors[key(thread,$0)] }.first ?? ids.first ?? "empty"
    }
    func group(thread: String, ids: [String], running: Bool) -> Bool {
        ids.compactMap { groups[key(thread,$0)] }.first ?? false
    }
    mutating func rememberGroup(thread: String, ids: [String], running: Bool) {
        let value = group(thread:thread,ids:ids,running:running)
        let anchor = groupAnchor(thread:thread,ids:ids)
        for id in ids where groups[key(thread,id)] == nil { groups[key(thread,id)] = value }
        for id in ids where groupAnchors[key(thread,id)] == nil { groupAnchors[key(thread,id)] = anchor }
    }
    mutating func setGroup(_ value: Bool, thread: String, ids: [String]) {
        for id in ids { groups[key(thread,id)] = value }
    }
    func detail(thread: String, id: String, running: Bool) -> Bool { details[key(thread,id)] ?? false }
    mutating func rememberDetail(thread: String, id: String, running: Bool) {
        if details[key(thread,id)] == nil { details[key(thread,id)] = false }
    }
    mutating func setDetail(_ value: Bool, thread: String, id: String) { details[key(thread,id)] = value }
}

/// Small presentation cache; tool permissions remain authoritative at the Codex server.
@MainActor final class CodexComposerCatalogCache {
    struct Snapshot: Codable { let references: [CodexReference]; let checkedAt: Date }
    static let shared = CodexComposerCatalogCache(defaults: .standard)
    private let defaults: UserDefaults
    private var entries: [String:Snapshot]
    init(defaults: UserDefaults) {
        self.defaults = defaults
        entries = defaults.data(forKey:"codexComposerCatalogV1").flatMap { try? JSONDecoder().decode([String:Snapshot].self,from:$0) } ?? [:]
    }
    func snapshot(_ cwd: String) -> Snapshot? { entries[cwd] }
    func save(_ refs: [CodexReference], cwd: String) {
        entries[cwd] = Snapshot(references:refs,checkedAt:Date())
        if entries.count > 16 { for key in entries.sorted(by: { $0.value.checkedAt > $1.value.checkedAt }).dropFirst(16).map(\.key) { entries.removeValue(forKey:key) } }
        defaults.set(try? JSONEncoder().encode(entries),forKey:"codexComposerCatalogV1")
    }
}

struct CodexQuestionReply: Codable, Equatable {
    let questionItemId: String
    let question: String
    let answer: String
    static func parse(_ text:String) -> [Self]? {
        let value = text.trimmingCharacters(in:.whitespacesAndNewlines),start = "<send_user_message_question_reply>",end = "</send_user_message_question_reply>"
        guard value.hasPrefix(start),value.hasSuffix(end) else { return nil }
        let body = Data(value.dropFirst(start.count).dropLast(end.count).utf8)
        let decoder = JSONDecoder()
        if let replies = try? decoder.decode([Self].self,from:body),!replies.isEmpty { return replies }
        return (try? decoder.decode(Self.self,from:body)).map { [$0] }
    }
    static func message(_ replies:[Self]) -> String? {
        guard !replies.isEmpty,let data = try? JSONEncoder().encode(replies),let json = String(data:data,encoding:.utf8) else { return nil }
        return "<send_user_message_question_reply>\n" + json + "\n</send_user_message_question_reply>"
    }
}
struct CodexAsyncQuestion: Identifiable, Equatable {
    let id: String
    let title: String
    let options: [String]
    static func pending(in turns:[[String:Any]]) -> [Self] {
        guard let turn = turns.last(where: { $0["status"] as? String == "inProgress" }),let items = turn["items"] as? [[String:Any]] else { return [] }
        var answered = Set<String>()
        for item in items {
            let type = item["type"] as? String
            guard type == "userMessage" || type == "steeringUserMessage" else { continue }
            if type == "steeringUserMessage",let status = item["status"] as? String,status != "accepted" { continue }
            let input = item["content"] as? [[String:Any]] ?? item["input"] as? [[String:Any]] ?? []
            guard input.count == 1,let text = input.first?["text"] as? String,let replies = CodexQuestionReply.parse(text) else { continue }
            answered.formUnion(replies.map(\.questionItemId))
        }
        return items.flatMap { item -> [Self] in
            guard item["type"] as? String == "agentMessage",let sourceID = item["id"] as? String else { return [] }
            return (item["questions"] as? [[String:Any]] ?? []).enumerated().compactMap { index,question in
                guard let title = question["title"] as? String,!title.isEmpty,
                      let data = try? JSONSerialization.data(withJSONObject:["request_user_input_async",sourceID,index],options:[.fragmentsAllowed,.withoutEscapingSlashes]),let id = String(data:data,encoding:.utf8),!answered.contains(id) else { return nil }
                return Self(id:id,title:title,options:question["options"] as? [String] ?? [])
            }
        }
    }
}
