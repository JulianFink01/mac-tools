import Foundation
import AppKit
import Combine

/// One outbox per conversation, shared by all windows. UI state and drafts stay local.
@MainActor final class CodexQueueRepository: ObservableObject {
    static let shared = CodexQueueRepository(defaults: .standard, migrateWindows: Bundle.main.bundleIdentifier == "com.julianfink.LiveWallpaper")
    @Published var messages: [String: [CodexQueuedMessage]] = [:] {
        didSet { defaults.set(try? JSONEncoder().encode(messages), forKey: "codexQueuedMessages") }
    }
    @Published var needsReview = Set<UUID>() { didSet { defaults.set(needsReview.map(\.uuidString), forKey: "codexQueueNeedsReview") } }
    var editing = Set<UUID>()
    var blocked = Set<String>()
    var ready = Set<String>()
    var epochs: [String: Int] = [:]
    private var runtime: [String: String] = [:]
    private var inFlight = Set<String>()
    private let defaults: UserDefaults
    init(defaults: UserDefaults, migrateWindows: Bool = false) {
        self.defaults = defaults
        needsReview = Set((defaults.stringArray(forKey: "codexQueueNeedsReview") ?? []).compactMap(UUID.init(uuidString:)))
        messages = defaults.data(forKey: "codexQueuedMessages").flatMap { try? JSONDecoder().decode([String: [CodexQueuedMessage]].self, from: $0) } ?? [:]
        if migrateWindows {
            let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Preferences")
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix("com.julianfink.MacTools.ChatWindow.") && file.pathExtension == "plist" {
                let legacy = UserDefaults(suiteName: file.deletingPathExtension().lastPathComponent)!
                guard let data = legacy.data(forKey: "codexQueuedMessages"), let old = try? JSONDecoder().decode([String: [CodexQueuedMessage]].self, from: data) else { continue }
                for (id, items) in old {
                    let known = Set((messages[id] ?? []).map(\.id))
                    messages[id, default: []].append(contentsOf: items.filter { !known.contains($0.id) })
                }
                // Persist centrally before retiring the former per-window copy.
                defaults.set(try? JSONEncoder().encode(messages), forKey: "codexQueuedMessages")
                if defaults.synchronize() { legacy.removeObject(forKey: "codexQueuedMessages"); legacy.synchronize() }
            }
        }
    }
    func delivered(_ id: String, since epoch: Int) {
        if (epochs[id] ?? 0) == epoch { blocked.insert(id) }
        else if runtime[id] == "idle" { ready.insert(id) }
    }
    func claim(_ id: String) -> Bool { inFlight.insert(id).inserted }
    func release(_ id: String) { inFlight.remove(id) }
    func observe(_ id: String, active: Bool) {
        let value = active ? "active" : "idle"
        guard runtime[id] != value else { return }
        runtime[id] = value
        if active { ready.remove(id) }
        else { epochs[id, default: 0] += 1; blocked.remove(id); ready.insert(id) }
    }
}

struct CodexChat: Identifiable, Equatable {
    let id: String
    var title: String
    var preview: String
    var cwd: String
    var updatedAt: Date
    var status: String
    var flags: [String]
    var rolloutPath: String?
    var projectID: String?
    var parentID: String?
    var agentRole: String?
    var agentName: String?
    var isRecent: Bool { status == "active" || updatedAt >= Date().addingTimeInterval(-86400) }
    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }; self.id = id
        rolloutPath = json["path"] as? String
        projectID = json["projectId"] as? String
        parentID = json["parentThreadId"] as? String
            ?? (((json["source"] as? [String: Any])?["subAgent"] as? [String: Any])?["thread_spawn"] as? [String: Any])?["parent_thread_id"] as? String
        agentRole = json["agentRole"] as? String; agentName = json["agentNickname"] as? String
        preview = json["preview"] as? String ?? ""
        title = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(preview.prefix(90))
        if title.isEmpty { title = "Neuer Chat" }
        cwd = json["cwd"] as? String ?? NSHomeDirectory()
        let recent = (json["recencyAt"] as? NSNumber)?.doubleValue ?? 0
        let timestamp = recent > 0 ? recent : (json["updatedAt"] as? NSNumber)?.doubleValue ?? 0
        updatedAt = Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp)
        let state = json["status"] as? [String: Any] ?? [:]
        status = state["type"] as? String ?? "notLoaded"; flags = state["activeFlags"] as? [String] ?? []
    }
    var statusLabel: String {
        if flags.contains("waitingOnApproval") { return "Freigabe nötig" }
        if flags.contains("waitingOnUserInput") { return "Antwort nötig" }
        switch status {
        case "active": return "Läuft"
        case "idle": return "Bereit"
        case "systemError": return "Fehler"
        default: return "Gespeichert"
        }
    }
}

struct CodexActivityPoint: Identifiable {
    let date: Date
    let running: Int
    let waiting: Int
    var id: Date { date }
}

enum CodexChatOrder {
    static func menu(_ chats: [CodexChat], now: Date = Date()) -> [CodexChat] {
        chats.filter { $0.status == "active" } + chats.filter { $0.status != "active" && $0.updatedAt >= now.addingTimeInterval(-3600) }
    }
    static func hour(_ date: Date) -> Int64 { Int64(floor(date.timeIntervalSince1970 / 3600)) }
    static func sorted(_ chats: [CodexChat], previous: [String]) -> [CodexChat] {
        let ranks = Dictionary(previous.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return chats.sorted { a, b in
            let ah = hour(a.updatedAt), bh = hour(b.updatedAt)
            if ah != bh { return ah > bh }
            if let ar = ranks[a.id], let br = ranks[b.id] { return ar < br }
            if ranks[a.id] == nil && ranks[b.id] != nil { return false }
            if ranks[a.id] != nil && ranks[b.id] == nil { return true }
            return a.updatedAt == b.updatedAt ? a.id < b.id : a.updatedAt > b.updatedAt
        }
    }
}

struct CodexMessageImage: Identifiable, Equatable {
    let source: String
    var id: String { source }
    static func collect(_ item: [String: Any], text: String) -> [CodexMessageImage] {
        var sources: [String] = []
        let content = item["content"] as? [[String: Any]] ?? item["input"] as? [[String: Any]] ?? []
        let context = (item["restoreMessage"] as? [String: Any])?["context"] as? [String: Any] ?? [:]
        let attachments = (item["attachments"] as? [[String: Any]] ?? []) + (item["imageAttachments"] as? [[String: Any]] ?? []) + (context["imageAttachments"] as? [[String: Any]] ?? [])
        for part in content + attachments {
            let type = part["type"] as? String ?? ""
            if ["localImage", "image", "input_image"].contains(type) || (part["mimeType"] as? String ?? "").hasPrefix("image/") {
                if let source = part["path"] as? String ?? part["url"] as? String ?? part["image_url"] as? String ?? (part["image_url"] as? [String: Any])?["url"] as? String { sources.append(source) }
            } else if let path = part["path"] as? String, ["png", "jpg", "jpeg", "webp", "gif", "heic"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) { sources.append(path) }
        }
        for pattern in [#"<image\b[^>]*\bpath="([^"]+)""#, #"!\[[^\]]*\]\(([^)]+)\)"#] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let range = Range(match.range(at: 1), in: text) { sources.append(String(text[range])) }
                }
            }
        }
        var seen = Set<String>()
        return sources.filter { source in
            (source.hasPrefix("/") || source.hasPrefix("file://") || source.hasPrefix("data:image/") || source.hasPrefix("https://") || source.hasPrefix("http://")) && seen.insert(source).inserted
        }.map { CodexMessageImage(source: $0) }
    }
}

struct CodexMessage: Identifiable, Equatable {
    let id: String
    let role: String
    var text: String
    var kind = "message"
    var images: [CodexMessageImage] = []
    var activity: CodexActivityDetails?
    static func from(_ item: [String: Any]) -> CodexMessage? {
        guard let id = item["id"] as? String, let type = item["type"] as? String else { return nil }
        if type == "agentMessage" {
            let text = item["text"] as? String ?? ""
            return CodexMessage(id: id, role: "Codex", text: text, images: CodexMessageImage.collect(item, text: text))
        }
        if type == "userMessage" || type == "steeringUserMessage" {
            let content = item["content"] as? [[String: Any]] ?? item["input"] as? [[String: Any]] ?? []
            var text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if text.isEmpty { text = (item["restoreMessage"] as? [String: Any])?["text"] as? String ?? item["text"] as? String ?? "" }
            let images = CodexMessageImage.collect(item, text: text)
            if let marker = text.range(of: "## My request:") { text = String(text[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
            return text.isEmpty && images.isEmpty ? nil : CodexMessage(id: id, role: "Du", text: text, images: images)
        }
        if type == "reasoning" { return nil }
        let descriptions = ["commandExecution": "Befehl", "fileChange": "Dateiänderung", "mcpToolCall": "Tool", "webSearch": "Websuche", "subAgentActivity": "Subagent", "collabAgentToolCall": "Subagent"]
        if let title = descriptions[type] {
            let detail = item["command"] as? String ?? item["tool"] as? String ?? item["query"] as? String ?? item["agentNickname"] as? String ?? ""
            return CodexMessage(id: id, role: "Codex", text: title + (detail.isEmpty ? "" : " · " + String(detail.prefix(500))), kind: "activity", activity: CodexActivityDetails.from(item))
        }
        return nil
    }
}

enum CodexTranscript {
    static func items(_ turn: [String: Any]) -> [[String: Any]] {
        let starts = turn["commandExecutionStartedAtMsById"] as? [String: Any] ?? [:]
        return (turn["items"] as? [[String: Any]] ?? []).map { item in
            var item = item
            if let id = item["id"] as? String, let time = starts[id] { item["mactoolsStartedAtMs"] = time }
            return item
        }
    }
    /// Only format the requested tail; historical tool arguments/output can be very large.
    static func window(_ state: [String: Any], limit: Int) -> (messages: [CodexMessage], hasMore: Bool, questions:[CodexAsyncQuestion]) {
        let ordered = turns(state)
        let total = ordered.reduce(0) { $0 + ($1["items"] as? [[String: Any]] ?? []).count }
        var remaining = max(1, limit), selected: [[String: Any]] = []
        for turn in ordered.reversed() where remaining > 0 {
            let raw = Array((turn["items"] as? [[String: Any]] ?? []).suffix(remaining))
            var slice = turn; slice["items"] = raw
            selected.insert(contentsOf: items(slice), at: 0); remaining -= raw.count
        }
        return (selected.compactMap(CodexMessage.from), total > limit || mayHaveOlder(state),CodexAsyncQuestion.pending(in:ordered))
    }
    static func mayHaveOlder(_ state: [String:Any]) -> Bool {
        if let history = (state["turnHistory"] as? [String:Any])?["history"] as? [String:Any], history["isComplete"] as? Bool == false || (history["islands"] as? [Any] ?? []).count > 1 { return true }
        if (state["turnsPagination"] as? [String:Any])?["hasLoadedOldest"] as? Bool == false { return true }
        return turns(state).contains { ($0["itemsPagination"] as? [String:Any])?["hasLoadedOldest"] as? Bool == false }
    }
    /// The current live turn is separate from canonical persisted history.
    /// Merge by turn ID so a new user message remains visible before commit.
    static func turns(_ state: [String: Any]) -> [[String: Any]] {
        let live = state["turns"] as? [[String: Any]] ?? []
        guard let history = (state["turnHistory"] as? [String: Any])?["history"] as? [String: Any], let entities = history["entitiesByKey"] as? [String: Any] else { return live }
        var result = (history["islands"] as? [[String: Any]] ?? []).flatMap { $0["entries"] as? [[String: Any]] ?? [] }.compactMap { entry -> [String: Any]? in
            guard let key = entry["value"] as? String else { return nil }; return entities[key] as? [String: Any]
        }
        for turn in live {
            if let id = turn["turnId"] as? String ?? turn["id"] as? String, let index = result.firstIndex(where: { ($0["turnId"] as? String ?? $0["id"] as? String) == id }) { result[index] = turn }
            else { result.append(turn) }
        }
        return result
    }
}

struct CodexPrompt: Identifiable {
    var id = UUID()
    let requestID: Any
    let method: String
    let threadID: String
    let params: [String: Any]
    var desktop = false
    var supported: Bool { ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/tool/requestUserInput", "item/permissions/requestApproval", "mcpServer/elicitation/request"].contains(method) }
    /// Only approval forms whose affirmative response is unambiguous. Browser
    /// auth and verification have their own native flows and remain there.
    var elicitationAcceptance: [String:Any]? {
        guard method == "mcpServer/elicitation/request",params["mode"] as? String == "form",
              let schema = params["requestedSchema"] as? [String:Any],schema["type"] as? String == "object",
              let properties = schema["properties"] as? [String:[String:Any]] else { return nil }
        let kind = (params["_meta"] as? [String:Any])?["codex_approval_kind"] as? String
        guard kind != "browser_auth",kind != "browser_email_otp" else { return nil }
        var content: [String:Any] = [:]
        for (key,field) in properties {
            guard ["approved","confirmed","accepted","allow"].contains(key),field["type"] as? String == "boolean",
                  field["const"] == nil || field["const"] as? Bool == true else { return nil }
            if let choices = field["enum"] as? [Bool],!choices.contains(true) { return nil }
            content[key] = true
        }
        guard Set(schema["required"] as? [String] ?? []).isSubset(of:Set(properties.keys)) else { return nil }
        return ["action":"accept","content":content]
    }
}

@MainActor
final class CodexStore: ObservableObject {
    static let shared = CodexStore(queue: .shared)
    struct Project: Identifiable, Equatable { let id: String; let name: String; let paths: [String] }
    @Published private(set) var projects: [Project] = []
    @Published var showingArchived = false
    private var projectsLoadedAt = Date.distantPast
    private var stableChatOrder: [String] = []
    private var stableFolderOrder: [String] = []
    private var nonArchivedChats: [CodexChat] = []
    @Published private(set) var chats: [CodexChat] = [] {
        didSet {
            recordActivity()
            if !showingArchived {
                nonArchivedChats = chats
                let ids = chats.map(\.id)
                if !ids.isEmpty, stableChatOrder != ids { stableChatOrder = ids; defaults.set(ids, forKey: "codexStableChatOrder") }
                let folders = orderedFolders(chats)
                if !folders.isEmpty, stableFolderOrder != folders { stableFolderOrder = folders; defaults.set(folders, forKey: "codexStableFolderOrder") }
            }
        }
    }
    var liveChats: [CodexChat] { showingArchived ? nonArchivedChats : chats }
    @Published private(set) var activityHistory: [CodexActivityPoint] = []
    var waitingChatIDs: Set<String> {
        var ids = Set(liveChats.filter { $0.flags.contains(where: { ["waitingOnApproval","waitingOnUserInput","waitingOnElicitation"].contains($0) }) }.map(\.id))
        ids.formUnion(prompts.map(\.threadID))
        if !asyncQuestions.isEmpty,let selectedID { ids.insert(selectedID) }
        return ids
    }
    var waitingCount: Int { waitingChatIDs.count }
    private func recordActivity() {
        let now = Date(), running = runningCount
        let waiting = waitingCount
        if let last = activityHistory.last, now.timeIntervalSince(last.date) < 10, last.running == running, last.waiting == waiting { return }
        activityHistory.removeAll { now.timeIntervalSince($0.date) > 3600 }
        activityHistory.append(CodexActivityPoint(date: now, running: running, waiting: waiting))
        if activityHistory.count > 720 { activityHistory.removeFirst(activityHistory.count - 720) }
    }
    @Published private(set) var subagents: [String: [CodexChat]] = [:]
    @Published private(set) var loadingAgentRoots = Set<String>()
    @Published private(set) var agentErrors: [String: String] = [:]
    var loadingAgents: Bool { !loadingAgentRoots.isEmpty }
    @Published private(set) var desktopConnected = false
    @Published var selectedID: String? { didSet { if oldValue != selectedID { selectedGoal = nil } } }
    @Published private(set) var selectedGoal: CodexGoal?
    @Published private(set) var messages: [CodexMessage] = []
    @Published private(set) var asyncQuestions: [CodexAsyncQuestion] = [] { didSet { recordActivity() } }
    @Published private(set) var answeringAsyncQuestions = Set<String>()
    private var confirmedAsyncAnswers = Set<String>()
    func answerAsync(_ question:CodexAsyncQuestion, answer:String) async -> Bool {
        let answer = answer.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !answer.isEmpty,!answeringAsyncQuestions.contains(question.id),asyncQuestions.contains(question),let threadID = selectedID,
              let message = CodexQuestionReply.message([CodexQuestionReply(questionItemId:question.id,question:question.title,answer:answer)]) else { return false }
        answeringAsyncQuestions.insert(question.id);defer { answeringAsyncQuestions.remove(question.id) }
        guard await send(message),selectedID == threadID else { return false }
        confirmedAsyncAnswers.insert(question.id);asyncQuestions.removeAll { $0.id == question.id };return true
    }
    @Published private(set) var hasOlderNativeHistory = false
    private var nativeHistoryLimit = 80
    private var latestNativeTranscript: [String: Any]?
    private var nativeProjectionTask: Task<Void,Never>?
    private var nativeProjectionPending: (id: String, epoch: UUID, limit: Int, state: [String:Any])?
    private var nativeProjectionEpoch = UUID()
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var loadingHistory = false
    @Published private(set) var sending = false
    @Published var error: String?
    @Published private(set) var activity = ""
    @Published private(set) var prompts: [CodexPrompt] = [] { didSet { recordActivity() } }
    @Published private(set) var answeringPrompts = Set<UUID>()
    private var nativePromptPayloads: [String: Data] = [:]
    @Published private(set) var olderCursor: String?
    @Published private(set) var listCursor: String?
    var drafts: [String: String] = [:] { didSet { defaults.set(drafts, forKey: "codexChatDrafts") } }
    @Published private(set) var usageBuckets: [CodexUsageBucket] = []
    @Published private(set) var usageError: String?
    @Published private(set) var usageUpdatedAt: Date?
    private var readingUsage = false
    @Published private(set) var models: [CodexModelChoice] = []
    @Published private(set) var availableReferences: [CodexReference] = []
    @Published private(set) var composerContextLoading = false
    @Published private(set) var composerContextError: String?
    @Published var presentationRevision = 0
    @Published private(set) var currentModel: String?
    @Published private(set) var currentEffort: String?
    @Published var options: [String: CodexTurnOptions] = [:] { didSet { defaults.set(try? JSONEncoder().encode(options), forKey: "codexTurnOptions") } }
    var references: [String: [CodexReference]] = [:] { didSet { defaults.set(try? JSONEncoder().encode(references), forKey: "codexDraftReferences") } }
    var queuedMessages: [String: [CodexQueuedMessage]] { queue.messages }
    private let queue: CodexQueueRepository
    private var queueSubscription: AnyCancellable?
    @Published private(set) var nativeQueuedMessages: [String: [CodexNativeQueuedMessage]] = [:]
    private var serverQueues: [String: [CodexNativeQueuedMessage]] = [:]
    private var legacyQueues: [String: [CodexNativeQueuedMessage]] = [:]
    private var readingNativeQueues = Set<String>()
    private var nativeQueueTask: Task<Void, Never>?
    private var broadcastQueueIDs = Set<String>()
    func setQueueEditing(_ message: UUID, in id: String, editing: Bool) {
        if editing { queue.editing.insert(message) } else { queue.editing.remove(message); scheduleQueue(id) }
    }
    private var queueTasks: [String: Task<Void, Never>] = [:]
    private var desktopActivityDates: [String: Date] = [:]
    private var observedActiveAt: [String: Date] = [:]
    private var pendingOptionIDs = Set<String>()
    func setTurnOptions(_ value: CodexTurnOptions, for id: String) { pendingOptionIDs.insert(id); options[id] = value }
    private var composerContextKey = ""
    private var loadingComposer = false
    @Published var workingDirectory = NSHomeDirectory()
    @Published var newChatProjectID: String? { didSet { defaults.set(newChatProjectID, forKey: "codexNewChatProjectID") } }
    private var pendingProjects: [String: String] = [:] { didSet { defaults.set(pendingProjects, forKey: "codexPendingProjectAssignments") } }
    var newChatProject: Project? { projects.first { $0.id == newChatProjectID } }
    let connection: CodexConnection
    let desktop = CodexDesktopConnection()
    private let enableDesktop: Bool
    private let followAllChats: Bool
    private var checkingOwners = Set<String>()
    private let defaults: UserDefaults
    private let composerCatalog: CodexComposerCatalogCache
    private var poll: Task<Void, Never>?
    private var refreshing = false
    private var agentsLoadedAt: [String: Date] = [:]
    private var historyToken = UUID()
    private var activeTurns: [String: String] = [:]
    private var completedTurns = Set<String>()
    private var approvalItems: [String: [String: Any]] = [:]
    private var managedThreads = Set<String>() {
        didSet { defaults.set(Array(managedThreads), forKey: "macToolsCodexThreads") }
    }
    private var resumedThreads = Set<String>()
    var selected: CodexChat? { chats.first { $0.id == selectedID } ?? subagents.values.flatMap { $0 }.first { $0.id == selectedID } }
    var selectedRootID: String? {
        guard let id = selectedID else { return nil }
        return subagents.first(where: { $0.value.contains { $0.id == id } })?.key ?? id
    }
    var selectedIsDesktopOwned: Bool { selectedID.map(desktop.hasOwner) ?? false }
    var recentChats: [CodexChat] { let recent = liveChats.filter(\.isRecent); return recent.filter { $0.status == "active" } + recent.filter { $0.status != "active" } }
    var menuChats: [CodexChat] { CodexChatOrder.menu(liveChats) }
    var runningCount: Int { liveChats.filter { $0.status == "active" }.count }
    var externalChat: Bool { selectedID.map { !managedThreads.contains($0) } ?? false }
    var canSubmit: Bool { selectedID != nil || canSend }
    var canSend: Bool { connected && !sending && (!externalChat || enableDesktop) }
    var sharedServer: Bool { connection.sharedServer }
    var currentTurn: String? { selectedID.flatMap { activeTurns[$0] } }
    var hasPendingWork: Bool { sending || !activeTurns.isEmpty || queuedMessages.values.contains { !$0.isEmpty } || chats.contains { managedThreads.contains($0.id) && $0.status == "active" } }

    init(connection supplied: CodexConnection? = nil, defaults: UserDefaults = .standard, followAllChats: Bool = true, queue suppliedQueue: CodexQueueRepository? = nil) {
        let connection = supplied ?? CodexConnection()
        self.connection = connection; self.defaults = defaults; self.followAllChats = followAllChats;
        self.composerCatalog = supplied == nil ? .shared : CodexComposerCatalogCache(defaults:defaults)
        queue = suppliedQueue ?? CodexQueueRepository(defaults: defaults)
        stableChatOrder = defaults.stringArray(forKey: "codexStableChatOrder") ?? []
        stableFolderOrder = defaults.stringArray(forKey: "codexStableFolderOrder") ?? []; self.enableDesktop = supplied == nil
        drafts = defaults.dictionary(forKey: "codexChatDrafts") as? [String: String] ?? [:]
        if let data = defaults.data(forKey: "codexTurnOptions") { options = (try? JSONDecoder().decode([String: CodexTurnOptions].self, from: data)) ?? [:] }
        if let data = defaults.data(forKey: "codexDraftReferences") { references = (try? JSONDecoder().decode([String: [CodexReference]].self, from: data)) ?? [:] }
        managedThreads = Set(defaults.stringArray(forKey: "macToolsCodexThreads") ?? [])
        newChatProjectID = defaults.string(forKey: "codexNewChatProjectID")
        pendingProjects = defaults.dictionary(forKey: "codexPendingProjectAssignments") as? [String: String] ?? [:]
        queueSubscription = queue.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        desktop.onQueue = { [weak self] id, values in
            guard let self else { return }
            let messages = values.compactMap(CodexNativeQueuedMessage.init)
            guard messages.count == values.count else { return }
            self.broadcastQueueIDs.insert(id)
            self.legacyQueues[id] = messages; self.publishNativeQueue(id)
        }
        desktop.onState = { [weak self] id, state in self?.applyDesktopState(id, state) }
        desktop.onDisconnect = { [weak self] in self?.desktopConnected = false; self?.broadcastQueueIDs.removeAll(); self?.objectWillChange.send() }
        connection.onEvent = { [weak self] method, params in self?.event(method, params) }
        connection.onRequest = { [weak self] id, method, params in self?.serverRequest(id, method, params) }
        connection.onDisconnect = { [weak self] message in
            guard let self else { return }
            self.connected = false; self.error = message; self.activity = "Verbindung getrennt"
            self.activeTurns.removeAll(); self.resumedThreads.removeAll(); self.prompts.removeAll { !$0.desktop }; self.approvalItems.removeAll()
        }
    }
    func start() {
        guard poll == nil else { return }
        if enableDesktop { nativeQueueTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }; await self.refreshNativeQueue()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        } }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.connected { await self.connect() }
                else {
                    await self.refresh()
                    self.recordActivity()
                    await self.loadUsage()
                    if self.selectedID != nil, !self.selectedIsDesktopOwned, self.currentTurn == nil, !self.loadingHistory { await self.loadHistory() }
                    if self.selectedID != nil { await self.loadGoal() }
                    if let root = self.selectedRootID { await self.loadSubagents(root) }
                }
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            }
        }
    }
    func stop() { nativeProjectionTask?.cancel(); nativeProjectionPending = nil; nativeProjectionEpoch = UUID(); nativeQueueTask?.cancel(); nativeQueueTask = nil; queueTasks.values.forEach { $0.cancel() }; queueTasks.removeAll(); poll?.cancel(); poll = nil; desktop.stop(); desktopConnected = false; connection.stop(); connected = false }
    func connect() async {
        guard !connecting else { return }; connecting = true; defer { connecting = false }
        do {
            try await connection.connect(); connected = true; error = nil
            if enableDesktop { try? await desktop.connect(); desktopConnected = desktop.connected }
            await refresh()
            await loadUsage()
        } catch { self.error = error.localizedDescription; connected = false }
    }
    private var usageAttemptAt = Date.distantPast
    static func isUsageAuthenticationError(_ error: Error) -> Bool {
        let value = error.localizedDescription.lowercased()
        return ["token_expired","401 unauthorized","authentication token is expired","unauthenticated"].contains(where:value.contains)
    }
    func loadUsage(force: Bool = false) async {
        guard connected, !readingUsage, force || Date().timeIntervalSince(usageAttemptAt) >= 60 else { return }
        usageAttemptAt = Date(); readingUsage = true; defer { readingUsage = false }
        do {
            let response: [String:Any]
            do { response = try await connection.request("account/rateLimits/read") }
            catch {
                guard Self.isUsageAuthenticationError(error) else { throw error }
                // The app-server owns authentication and refreshes its own managed credential.
                _ = try await connection.request("account/read",["refreshToken":true])
                response = try await connection.request("account/rateLimits/read")
            }
            usageBuckets = CodexUsageBucket.parse(response); usageUpdatedAt = Date(); usageError = nil
        } catch {
            usageError = Self.isUsageAuthenticationError(error)
                ? "Die Codex-Anmeldung ist abgelaufen und konnte nicht automatisch erneuert werden. Bitte die Anmeldung im Codex-Desktop prüfen. Angezeigte frühere Werte sind nicht aktuell."
                : "Codex-Limits konnten nicht aktualisiert werden. Bitte erneut versuchen. Frühere Werte sind nicht aktuell."
        }
    }
    func reconnect() async {
        composerContextKey = ""; desktop.stop(); desktopConnected = false; connection.stop(); connected = false; resumedThreads.removeAll(); activeTurns.removeAll()
        await connect()
    }
    func refresh(older: Bool = false) async {
        guard connected, !refreshing else { return }; refreshing = true; defer { refreshing = false }
        do {
            if Date().timeIntervalSince(projectsLoadedAt) > 60 {
                if let response = try? await connection.request("project/list", ["limit": 100, "sortKey": "recencyAt", "sortDirection": "desc"]) {
                    let found = (response["data"] as? [[String: Any]] ?? []).compactMap { value -> Project? in
                        guard let id = value["id"] as? String, let name = value["name"] as? String else { return nil }
                        return Project(id: id, name: name, paths: (value["roots"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String })
                    }
                    if projects != found { projects = found }; projectsLoadedAt = Date()
                }
            }
            var params: [String: Any] = ["limit": 100, "sortKey": "updated_at", "sortDirection": "desc", "sourceKinds": ["cli", "vscode", "appServer"], "useStateDbOnly": true]
            params["archived"] = showingArchived
            var found: [CodexChat] = [], next: String? = older ? listCursor : nil
            let targetCount = older ? 0 : max(100, chats.count)
            repeat {
                if let next { params["cursor"] = next } else { params.removeValue(forKey: "cursor") }
                let result = try await connection.request("thread/list", params)
                found += (result["data"] as? [[String: Any]] ?? []).compactMap(CodexChat.init).filter { $0.parentID == nil }
                next = result["nextCursor"] as? String
            } while !older && found.count < targetCount && next != nil
            let runtime = Dictionary(chats.map { ($0.id, ($0.status, $0.flags)) }, uniquingKeysWith: { _, last in last })
            let incoming = found.map { chat -> CodexChat in
                var chat = chat
                if let status = desktop.runtimeStatus(chat.id) { chat.status = status["type"] as? String ?? chat.status; chat.flags = status["activeFlags"] as? [String] ?? [] }
                else if desktop.hasOwner(chat.id), let old = runtime[chat.id] { chat.status = old.0; chat.flags = old.1 }
                if let date = desktopActivityDates[chat.id] { chat.updatedAt = date }
                if let date = observedActiveAt[chat.id], date > chat.updatedAt { chat.updatedAt = date }
                return chat
            }
            let ids = Set(found.map(\.id))
            let merged = older ? chats.filter { !ids.contains($0.id) } + incoming : incoming
            let ordered = CodexChatOrder.sorted(merged, previous: stableChatOrder)
            if chats != ordered { chats = ordered }
            listCursor = next

            for id in Array(pendingProjects.keys) { await assignPendingProject(id) }
            if enableDesktop, !desktop.connected { try? await desktop.connect(); desktopConnected = desktop.connected }
            for chat in recentChats where !showingArchived && (followAllChats || chat.id == selectedID) && !checkingOwners.contains(chat.id) {
                checkingOwners.insert(chat.id)
                Task { [weak self] in
                    guard let self else { return }
                    _ = await self.desktop.follow(chat.id)
                    self.checkingOwners.remove(chat.id); self.objectWillChange.send()
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func goal(_ operation: String, fields: [String: Any] = [:]) async throws -> [String: Any] {
        guard let id = selectedID, ["get", "set", "clear"].contains(operation) else { throw CodexFailure(message: "Wähle zuerst einen Chat.") }
        var params = fields; params["threadId"] = id
        if operation != "get" { params["origin"] = "user" }
        let response = try await connection.request("thread/goal/" + operation, params)
        if selectedID == id, operation == "get" || response["goal"] != nil || operation == "clear" {
            let value = CodexGoal(response["goal"] as? [String: Any]); if selectedGoal != value { selectedGoal = value }
        }
        return response
    }
    func loadGoal() async {
        guard let id = selectedID else { if selectedGoal != nil { selectedGoal = nil }; return }
        if desktop.hasOwner(id) { return }
        _ = try? await goal("get")
    }
    func project(for chat: CodexChat) -> Project? {
        if let id = chat.projectID { return projects.first { $0.id == id } }
        return projects.first { $0.paths.contains(chat.cwd) }
    }
    func folder(for chat: CodexChat) -> String { project(for: chat)?.paths.first ?? chat.cwd }
    func orderedFolders(_ values: [CodexChat]) -> [String] {
        var latest: [String: Int64] = [:]
        for chat in values { let path = folder(for: chat); latest[path] = max(latest[path] ?? Int64.min, CodexChatOrder.hour(chat.updatedAt)) }
        let ranks = Dictionary(stableFolderOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let firstAppearance = Dictionary(values.enumerated().map { (folder(for: $0.element), $0.offset) }, uniquingKeysWith: { first, _ in first })
        return latest.keys.sorted { a, b in
            if latest[a] != latest[b] { return (latest[a] ?? 0) > (latest[b] ?? 0) }
            if let ar = ranks[a], let br = ranks[b] { return ar < br }
            if ranks[a] == nil && ranks[b] != nil { return true }
            if ranks[a] != nil && ranks[b] == nil { return false }
            return (firstAppearance[a] ?? 0) < (firstAppearance[b] ?? 0)
        }
    }
    func folderName(_ path: String) -> String { projects.first { $0.paths.contains(path) }?.name ?? URL(fileURLWithPath: path).lastPathComponent }
    func showArchive(_ enabled: Bool) async {
        if enabled { nonArchivedChats = chats; showingArchived = true; chats = [] }
        else { let live = nonArchivedChats; showingArchived = false; chats = live }
        listCursor = nil; await refresh()
    }
    func archive(_ ids: [String], archived: Bool = true) async {
        do {
            for id in ids {
                if chats.first(where: { $0.id == id })?.status == "active" { throw CodexFailure(message: "Laufenden Chat zuerst beenden; er wurde nicht archiviert.") }
                _ = try await connection.request(archived ? "thread/archive" : "thread/unarchive", ["threadId": id])
                chats.removeAll { $0.id == id }
                if selectedID == id { newChat() }
            }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func move(_ ids: [String], to project: Project) async {
        do {
            for id in ids {
                _ = try await connection.request("thread/metadata/update", ["threadId": id, "projectId": project.id])
                let response = try await connection.request("thread/read", ["threadId": id, "includeTurns": false])
                guard (response["thread"] as? [String: Any])?["projectId"] as? String == project.id else { throw CodexFailure(message: "Die neue Projektzuordnung wurde von Codex nicht bestätigt.") }
                if let index = chats.firstIndex(where: { $0.id == id }) { chats[index].projectID = project.id }
            }
        } catch { self.error = error.localizedDescription }
    }
    func loadSubagents(_ root: String) async {
        guard !loadingAgentRoots.contains(root), Date().timeIntervalSince(agentsLoadedAt[root] ?? .distantPast) > 30 else { return }
        loadingAgentRoots.insert(root); agentErrors[root] = nil
        defer { loadingAgentRoots.remove(root) }
        do {
            var agents: [CodexChat] = []
            // Codex's stored spawn graph resolves all descendant depths, including
            // archived agents. Query each root independently so simultaneous
            // expansions cannot suppress one another.
            for archived in [false, true] {
                var cursor: String?
                repeat {
                    var params: [String: Any] = ["limit": 100, "ancestorThreadId": root, "archived": archived, "useStateDbOnly": true]
                    if let cursor { params["cursor"] = cursor }
                    let response = try await connection.request("thread/list", params)
                    agents += (response["data"] as? [[String: Any]] ?? []).compactMap(CodexChat.init)
                    cursor = response["nextCursor"] as? String
                } while cursor != nil
            }
            let descendants = Array(Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }).values)
            subagents[root] = CodexChatOrder.sorted(descendants, previous: (subagents[root] ?? []).map(\.id))
            agentsLoadedAt[root] = Date()
            // Archived/idle descendants need no complete live transcript subscription.
            if enableDesktop {
                for agent in descendants where agent.status == "active" { Task { [weak self] in _ = await self?.desktop.follow(agent.id) } }
            }
        } catch { agentErrors[root] = "Subagenten konnten nicht geladen werden: " + error.localizedDescription }
    }
    func primeConversation(_ id: String, from source: CodexStore) {
        guard selectedID == id else { return }
        if chats.isEmpty, let chat = source.liveChats.first(where: { $0.id == id }) { chats = [chat] }
        if projects.isEmpty { projects = source.projects }
        if messages.isEmpty, source.selectedID == id {
            messages = source.messages; currentModel = source.currentModel; currentEffort = source.currentEffort
            if !messages.isEmpty { loadingHistory = false }
        }
        if serverQueues[id] == nil { serverQueues[id] = source.serverQueues[id] }
        if legacyQueues[id] == nil { legacyQueues[id] = source.legacyQueues[id] }
        publishNativeQueue(id)
    }
    @discardableResult func prepareSelection(_ id: String) -> Bool {
        guard !sending else { return false }
        historyToken = UUID(); selectedID = id; currentModel = nil; currentEffort = nil; desktop.selectedID = id
        nativeProjectionEpoch = UUID(); nativeHistoryLimit = 80; latestNativeTranscript = nil; hasOlderNativeHistory = false;asyncQuestions = [];confirmedAsyncAnswers = []
        messages = []; olderCursor = nil; activity = ""; error = nil; loadingHistory = true
        return true
    }
    func finishSelection(_ id: String) async {
        guard selectedID == id else { return }
        if enableDesktop { _ = await desktop.follow(id, resnapshot: true); objectWillChange.send() }
        guard selectedID == id else { return }
        if desktop.hasOwner(id) { loadingHistory = false } else { await loadHistory() }
        guard selectedID == id else { return }
        if let root = selectedRootID { await loadSubagents(root) }
        await refreshNativeQueue()
    }
    func select(_ id: String) async {
        guard prepareSelection(id) else { return }
        await finishSelection(id)
    }
    func newChat(in project: Project? = nil) {
        guard !sending else { return }
        let target = project ?? selected.flatMap { self.project(for: $0) } ?? newChatProject
        workingDirectory = target?.paths.first ?? selected?.cwd ?? workingDirectory
        newChatProjectID = target?.id
        historyToken = UUID(); selectedID = nil; desktop.selectedID = nil; messages = [];asyncQuestions = [];confirmedAsyncAnswers = []; olderCursor = nil; loadingHistory = false; activity = ""; error = nil
    }
    func newChat(inFolder folder: String) {
        newChat(in: projects.first { $0.paths.contains(folder) })
        workingDirectory = folder
    }
    func selectNewChatProject(_ project: Project?) {
        guard selectedID == nil, !sending else { return }
        newChatProjectID = project?.id
        workingDirectory = project?.paths.first ?? NSHomeDirectory()
        composerContextKey = ""
    }
    private func assignPendingProject(_ id: String) async {
        guard let project = pendingProjects[id] else { return }
        do {
            _ = try await connection.request("thread/metadata/update", ["threadId": id, "projectId": project])
            let response = try await connection.request("thread/read", ["threadId": id, "includeTurns": false])
            guard (response["thread"] as? [String: Any])?["projectId"] as? String == project else { throw CodexFailure(message: "Projektzuordnung noch nicht bestätigt") }
            if let index = chats.firstIndex(where: { $0.id == id }) { chats[index].projectID = project }
            pendingProjects.removeValue(forKey: id)
        } catch { self.error = "Die Nachricht wurde übergeben. Die Projektzuordnung wird erneut versucht: " + error.localizedDescription }
    }
    func loadHistory(older: Bool = false) async {
        guard let id = selectedID, connected else { return }
        let token = UUID(); historyToken = token; loadingHistory = true
        defer { if historyToken == token { loadingHistory = false } }
        do {
            if enableDesktop, !desktop.hasOwner(id), let path = selected?.rolloutPath {
                let stored = await CodexTranscript.storedMessages(path: path)
                guard selectedID == id, historyToken == token else { return }
                messages = stored; olderCursor = nil; return
            }
            var params: [String: Any] = ["threadId": id, "limit": 12, "itemsView": "full", "sortDirection": "desc"]
            if older, let olderCursor { params["cursor"] = olderCursor }
            let response = try await connection.request("thread/turns/list", params)
            let turns = response["data"] as? [[String: Any]] ?? []
            let items = turns.reversed().flatMap(CodexTranscript.items).compactMap(CodexMessage.from)
            guard selectedID == id, historyToken == token else { return }
            let existing = Set(items.map(\.id))
            if older { messages = items + messages.filter { !existing.contains($0.id) } }
            else {
                let incoming = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
                let known = Set(messages.map(\.id))
                messages = messages.map { incoming[$0.id] ?? $0 } + items.filter { !known.contains($0.id) }
            }
            olderCursor = response["nextCursor"] as? String
            if !older { asyncQuestions = CodexAsyncQuestion.pending(in:Array(turns.reversed())).filter { !confirmedAsyncAnswers.contains($0.id) } }
            if connection.sharedServer, let turn = turns.first, turn["status"] as? String == "inProgress", let turnID = turn["id"] as? String { activeTurns[id] = turnID }
        } catch { if selectedID == id && historyToken == token { self.error = error.localizedDescription } }
    }
    private func publishNativeQueue(_ id: String) {
        let server = serverQueues[id] ?? []
        let known = Set(server.flatMap { [$0.id, $0.raw["clientUserMessageId"] as? String ?? $0.id] })
        let messages = server + (legacyQueues[id] ?? []).filter { !known.contains($0.id) }
        if nativeQueuedMessages[id] != messages { nativeQueuedMessages[id] = messages }
    }
    func refreshNativeQueue() async {
        guard let id = selectedID, connected, readingNativeQueues.insert(id).inserted else { return }
        defer { readingNativeQueues.remove(id) }
        // Current Codex stores queued submissions in its app-server, not in global-state JSON.
        do {
            var values: [[String: Any]] = [], cursor: String?
            repeat {
                var params: [String: Any] = ["threadId": id, "limit": 100]
                if let cursor { params["cursor"] = cursor }
                let result = try await connection.request("thread/queue/list", params)
                guard let page = result["data"] as? [[String: Any]], page.allSatisfy({ CodexNativeQueuedMessage($0) != nil }) else { throw CodexFailure(message: "Codex lieferte eine unvollständige Warteschlange.") }
                values += page; cursor = result["nextCursor"] as? String
            } while cursor != nil
            serverQueues[id] = values.compactMap(CodexNativeQueuedMessage.init)
        } catch { /* Keep the last confirmed server snapshot on transient errors. */ }
        if !broadcastQueueIDs.contains(id) {
            let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
            let values = await Task.detached(priority: .utility) { () -> [[String: Any]]? in
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: home + "/.codex-global-state.json")) else { return nil }
                return Self.nativeQueueSnapshot(data, for: id)
            }.value
            if let values, !broadcastQueueIDs.contains(id) { legacyQueues[id] = values.compactMap(CodexNativeQueuedMessage.init) }
        }
        publishNativeQueue(id)
    }
    func removeNativeQueued(_ message: String, in id: String) async {
        do {
            if nativeQueuedMessages[id]?.first(where: { $0.id == message })?.isServerQueue == true {
                let response = try await connection.request("thread/queue/delete", ["threadId": id, "queuedSubmissionId": message])
                guard response["deleted"] as? Bool == true else { await refreshNativeQueue(); return }
                serverQueues[id]?.removeAll { $0.id == message }
            } else {
                _ = await desktop.follow(id); try await desktop.removeQueued(message, in: id)
                broadcastQueueIDs.insert(id); legacyQueues[id]?.removeAll { $0.id == message }
            }
            publishNativeQueue(id)
        } catch { self.error = error.localizedDescription }
    }
    func editNativeQueued(_ message: CodexNativeQueuedMessage, in id: String, text: String) async -> Bool {
        guard message.isServerQueue else { openInCodex(id); return false }
        do {
            let input = try message.editedInput(text)
            let response = try await connection.request("thread/queue/update", ["threadId": id, "queuedSubmissionId": message.id, "input": input])
            guard let raw = response["queuedSubmission"] as? [String: Any], let confirmed = CodexNativeQueuedMessage(raw), confirmed.id == message.id else { throw CodexFailure(message: "Codex hat die Änderung nicht bestätigt. Bitte Warteschlange erneut prüfen.") }
            if let index = serverQueues[id]?.firstIndex(where: { $0.id == message.id }) { serverQueues[id]?[index] = confirmed }
            publishNativeQueue(id); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    /// An unavailable or malformed snapshot is not an empty queue.
    nonisolated static func nativeQueueSnapshot(_ data: Data, for id: String) -> [[String: Any]]? {
        guard let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let queues = state["queued-follow-ups"] as? [String: Any] else { return nil }
        guard let value = queues[id] else { return [] }
        guard let values = value as? [[String: Any]], values.allSatisfy({ CodexNativeQueuedMessage($0) != nil }) else { return nil }
        return values
    }
    func submit(_ text: String, references: [CodexReference] = []) async -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !references.isEmpty else { return false }
        if let id = selectedID, currentTurn != nil || selected?.status == "active" || !canSend {
            enqueue(text, references: references, in: id); return true
        }
        return await send(text, references: references)
    }
    func enqueue(_ text: String, references: [CodexReference] = [], in id: String) {
        let message = CodexQueuedMessage(id: UUID(), text: text, references: references, options: options[id] ?? CodexTurnOptions(), cwd: selected?.id == id ? selected!.cwd : workingDirectory, modelHint: currentModel ?? models.first?.id ?? "")
        queue.messages[id, default: []].append(message)
    }
    func editQueued(_ message: UUID, in id: String, text: String) {
        guard let index = queuedMessages[id]?.firstIndex(where: { $0.id == message }) else { return }
        queue.messages[id]?[index].text = text
    }
    func moveQueued(_ message: UUID, in id: String, before target: UUID) {
        guard !sending, message != target, var items = queuedMessages[id], let source = items.firstIndex(where: { $0.id == message }), items.contains(where: { $0.id == target }) else { return }
        let item = items.remove(at: source); items.insert(item, at: items.firstIndex(where: { $0.id == target })!); queue.messages[id] = items
    }
    func moveQueued(_ message: UUID, in id: String, offset: Int) {
        guard !sending, var items = queuedMessages[id], let index = items.firstIndex(where: { $0.id == message }), items.indices.contains(index + offset) else { return }
        items.swapAt(index, index + offset); queue.messages[id] = items
    }
    func forkCurrent() async {
        guard let id = selectedID, !sending else { return }
        do {
            let response = try await connection.request("thread/fork", ["threadId": id, "cwd": selected?.cwd ?? workingDirectory])
            guard let thread = response["thread"] as? [String: Any], let chat = CodexChat(thread) else { throw CodexFailure(message: "Codex hat den neuen Chat nicht bestätigt.") }
            managedThreads.insert(chat.id); if !chats.contains(where: { $0.id == chat.id }) { chats.insert(chat, at: 0) }
            await select(chat.id)
        } catch { self.error = error.localizedDescription }
    }
    func moveNativeQueued(_ message: String, in id: String, before target: String? = nil, offset: Int = 0) async {
        guard var items = serverQueues[id], let index = items.firstIndex(where: { $0.id == message }) else { return }
        if let target {
            guard target != message, items.contains(where: { $0.id == target }) else { return }
            let item = items.remove(at: index); items.insert(item, at: items.firstIndex(where: { $0.id == target })!)
        } else { guard items.indices.contains(index + offset) else { return }; items.swapAt(index, index + offset) }
        do {
            _ = try await connection.request("thread/queue/reorder", ["threadId": id, "queuedSubmissionIds": items.map(\.id)])
            await refreshNativeQueue()
        } catch { self.error = "Reihenfolge wurde nicht bestätigt. " + error.localizedDescription }
    }
    func queueNeedsReview(_ message: UUID) -> Bool { queue.needsReview.contains(message) }
    func removeQueued(_ message: UUID, in id: String) { queue.messages[id]?.removeAll { $0.id == message }; queue.needsReview.remove(message) }
    func deliverQueued(_ message: UUID, in id: String, steer: Bool) async -> Bool {
        guard !sending, connected, !queue.editing.contains(message), let item = queuedMessages[id]?.first(where: { $0.id == message }) else { return false }
        guard queue.claim(id) else { return false }
        sending = true; error = nil; queue.ready.remove(id)
        let epoch = queue.epochs[id] ?? 0
        defer { sending = false; queue.release(id) }
        let input: [[String: Any]] = (item.text.isEmpty ? [] : [["type": "text", "text": item.text]]) + item.references.map(\.input)
        let params = item.options.parameters(cwd: item.cwd, fallbackModel: item.modelHint)
        do {
            if enableDesktop, !managedThreads.contains(id) { _ = await desktop.recoverOwner(id) }
            if desktop.hasOwner(id) {
                try await desktop.send(item.text, to: id, active: steer, inputs: input, options: params)
            } else {
                guard managedThreads.contains(id) else { throw CodexFailure(message: "Der ursprüngliche Codex-Chat ist gerade nicht erreichbar. Die Nachricht bleibt in der Warteschlange.") }
                if !resumedThreads.contains(id) { _ = try await connection.request("thread/resume", ["threadId": id]); resumedThreads.insert(id) }
                if steer, let turn = activeTurns[id] {
                    let result = try await connection.request("turn/steer", ["threadId": id, "expectedTurnId": turn, "input": input])
                    guard let acceptedTurn = result["turnId"] as? String, !acceptedTurn.isEmpty else { throw CodexFailure(message: "Codex hat die Steuerung nicht bestätigt. Die Nachricht bleibt erhalten.") }
                } else {
                    var request = params; request["threadId"] = id; request["input"] = input
                    let result = try await connection.request("turn/start", request)
                    guard let confirmed = result["turn"] as? [String: Any], let confirmedID = confirmed["id"] as? String, !confirmedID.isEmpty else { throw CodexFailure(message: "Codex hat den Start nicht bestätigt. Die Nachricht bleibt erhalten.") }
                    if let turn = result["turn"] as? [String: Any], let turnID = turn["id"] as? String, turn["status"] as? String == "inProgress", !completedTurns.contains(turnID) { activeTurns[id] = turnID }
                }
            }
            if options[id] == item.options { pendingOptionIDs.remove(id) }
            removeQueued(message, in: id)
            queue.delivered(id, since: epoch)
            return true
        } catch {
            queue.needsReview.insert(message)
            self.error = error.localizedDescription + " Bitte vor erneutem Senden den Originalchat prüfen."
            return false
        }
    }
    private func queueCompleted(_ id: String) {
        queue.observe(id, active: false)
        scheduleQueue(id)
    }
    private func scheduleQueue(_ id: String) {
        guard connected, desktop.hasOwner(id) || managedThreads.contains(id), queueTasks[id] == nil, let first = queuedMessages[id]?.first, !queue.editing.contains(first.id), !queue.needsReview.contains(first.id), queue.ready.contains(id) else { return }
        queueTasks[id] = Task { [weak self] in
            guard let self else { return }
            while self.sending { do { try await Task.sleep(nanoseconds: 30_000_000) } catch { return } }
            if !Task.isCancelled, let first = self.queuedMessages[id]?.first, !self.queue.editing.contains(first.id), !self.queue.needsReview.contains(first.id), self.queue.ready.contains(id), !self.queue.blocked.contains(id) { if !(await self.deliverQueued(first.id, in: id, steer: false)) { self.queue.ready.remove(id) } }
            self.queueTasks[id] = nil
            if self.queue.ready.contains(id), !self.queue.blocked.contains(id), let next = self.queuedMessages[id]?.first, !self.queue.needsReview.contains(next.id) { self.scheduleQueue(id) }
        }
    }
    func send(_ text: String, references: [CodexReference] = []) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !references.isEmpty), canSend else { return false }
        sending = true; error = nil; defer { sending = false }
        let sendingThreadID = selectedID
        let key = selectedID ?? "new"
        let option = options[key] ?? CodexTurnOptions()
        let turnParameters = option.parameters(cwd: selected?.cwd ?? workingDirectory, fallbackModel: currentModel ?? models.first?.id ?? "")
        let input: [[String: Any]] = (text.isEmpty ? [] : [["type": "text", "text": text]]) + references.map(\.input)
        do {
            if let id = selectedID, externalChat, enableDesktop {
                if !(await desktop.recoverOwner(id)) {
                    openInCodex(id)
                    try await Task.sleep(nanoseconds: 500_000_000)
                    _ = await desktop.recoverOwner(id)
                }
            }
            guard selectedID == sendingThreadID else { throw CodexFailure(message:"Der Chat wurde während der Übergabe gewechselt. Der Entwurf bleibt erhalten.") }
            if let id = selectedID, desktop.hasOwner(id) {
                try await desktop.send(text, to: id, active: currentTurn != nil || selected?.status == "active", inputs: input, options: turnParameters)
                if options[id] == option { pendingOptionIDs.remove(id) }; activity = "An Codex übergeben"; return true
            }
            let id: String
            if let selectedID { id = selectedID }
            else {
                let result = try await connection.request("thread/start", ["cwd": workingDirectory])
                guard let json = result["thread"] as? [String: Any], let chat = CodexChat(json) else { throw CodexFailure(message: "Codex hat keine Chat-ID geliefert.") }
                id = chat.id; managedThreads.insert(id); resumedThreads.insert(id); selectedID = id
                if let project = newChatProjectID { pendingProjects[id] = project }
                chats.removeAll { $0.id == id }; chats.insert(chat, at: 0)
                options[id] = option; drafts[id] = text; self.references[id] = references
            }
            if !resumedThreads.contains(id) {
                // Never take over an externally owned thread on an isolated app-server.
                guard managedThreads.contains(id) else { throw CodexFailure(message: "Der ursprüngliche Codex-Chat ist gerade nicht erreichbar. Der Entwurf bleibt erhalten.") }
                _ = try await connection.request("thread/resume", ["threadId": id]); resumedThreads.insert(id)
            }
            if let turnID = activeTurns[id] {
                _ = try await connection.request("turn/steer", ["threadId": id, "expectedTurnId": turnID, "input": input])
            } else {
                var params = turnParameters; params["threadId"] = id; params["input"] = input
                let result = try await connection.request("turn/start", params)
                if let turn = result["turn"] as? [String: Any], let turnID = turn["id"] as? String, !completedTurns.contains(turnID), turn["status"] as? String == "inProgress" { activeTurns[id] = turnID }
            }
            await assignPendingProject(id)
            if activeTurns[id] != nil { activity = "Codex arbeitet …" }; await refresh(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func interrupt() async {
        guard let id = selectedID, let turnID = activeTurns[id] else { return }
        do {
            if desktop.hasOwner(id) { try await desktop.interrupt(id, turnID: turnID) }
            else { _ = try await connection.request("turn/interrupt", ["threadId": id, "turnId": turnID]) }
        }
        catch { self.error = error.localizedDescription }
    }
    func canAnswer(_ prompt: CodexPrompt) -> Bool {
        let supported = ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/tool/requestUserInput", "item/permissions/requestApproval", "mcpServer/elicitation/request"]
        return !answeringPrompts.contains(prompt.id) && supported.contains(prompt.method) && (prompt.desktop ? desktop.connected && desktop.hasOwner(prompt.threadID) : connected)
    }
    func answer(_ prompt: CodexPrompt, result: [String: Any]) {
        guard canAnswer(prompt) else { return }
        if prompt.desktop {
            answeringPrompts.insert(prompt.id)
            Task {
                defer { answeringPrompts.remove(prompt.id) }
                do {
                    try await desktop.answer(prompt.requestID, method: prompt.method, in: prompt.threadID, result: result)
                    prompts.removeAll { $0.id == prompt.id }
                } catch { self.error = error.localizedDescription }
            }
        } else {
            do { try connection.reply(id: prompt.requestID, result: result); prompts.removeAll { $0.id == prompt.id } }
            catch { self.error = error.localizedDescription }
        }
    }
    private func syncNativePrompts(_ id: String, state: [String: Any]) {
        guard let requests = state["requests"] as? [[String: Any]] else { return }
        if requests.isEmpty {
            if prompts.contains(where: { $0.desktop && $0.threadID == id }) { prompts.removeAll { $0.desktop && $0.threadID == id } }
            nativePromptPayloads.removeValue(forKey: id); return
        }
        let items = CodexTranscript.turns(state).flatMap { $0["items"] as? [[String: Any]] ?? [] }
        let enriched = requests.compactMap { request -> [String: Any]? in
            guard request["completed"] as? Bool != true, let requestID = request["id"], let method = request["method"] as? String else { return nil }
            var params = request["params"] as? [String: Any] ?? [:]
            if let itemID = params["itemId"] as? String, let item = items.first(where: { $0["id"] as? String == itemID }) { for (key,value) in item where params[key] == nil { params[key] = value } }
            return ["id":requestID, "method":method, "params":params]
        }
        let payload = try? JSONSerialization.data(withJSONObject: enriched, options: .sortedKeys)
        guard payload != nativePromptPayloads[id] else { return }; nativePromptPayloads[id] = payload
        let old = prompts.filter { $0.desktop && $0.threadID == id }
        let incoming = enriched.map { request -> CodexPrompt in
            let requestID = request["id"]!, method = request["method"] as! String
            let existing = old.first { String(describing:$0.requestID) == String(describing:requestID) && $0.method == method }
            return CodexPrompt(id: existing?.id ?? UUID(), requestID:requestID, method:method, threadID:id, params:request["params"] as! [String:Any], desktop:true)
        }
        prompts = prompts.filter { !$0.desktop || $0.threadID != id } + incoming
    }
    func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Projekt wählen"; panel.directoryURL = URL(fileURLWithPath: workingDirectory)
        if panel.runModal() == .OK, let url = panel.url { newChatProjectID = projects.first { $0.paths.contains(url.path) }?.id; workingDirectory = url.path }
    }
    func chooseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.prompt = "Codex CLI wählen"
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: "codexExecutable")
            Task { await reconnect() }
        }
    }
    func openInCodex(_ id: String) {
        guard let url = URL(string: "codex://threads/" + id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!) else { return }
        NSWorkspace.shared.open(url)
    }
    private func applyDesktopState(_ id: String, _ state: [String: Any]) {
        if id == selectedID, error?.hasPrefix("Der ursprüngliche Codex-Chat ist gerade nicht erreichbar.") == true { error = nil }
        syncNativePrompts(id, state: state)
        if let runtime = state["threadRuntimeStatus"] as? [String: Any], let status = runtime["type"] as? String, ["active", "idle"].contains(status) {
            queue.observe(id, active: status == "active"); if status == "idle" { scheduleQueue(id) }
        }

        if showingArchived, let index = nonArchivedChats.firstIndex(where: { $0.id == id }), let status = state["threadRuntimeStatus"] as? [String: Any] {
            var chat = nonArchivedChats[index]; chat.status = status["type"] as? String ?? "notLoaded"; chat.flags = status["activeFlags"] as? [String] ?? []
            if chat != nonArchivedChats[index] { objectWillChange.send(); nonArchivedChats[index] = chat }
        }
        if let index = chats.firstIndex(where: { $0.id == id }), let status = state["threadRuntimeStatus"] as? [String: Any] {
            var updatedChat = chats[index]
            updatedChat.status = status["type"] as? String ?? "notLoaded"; updatedChat.flags = status["activeFlags"] as? [String] ?? []
            if let updated = state["recencyAt"] as? NSNumber, updated.doubleValue > 0 { let date = Date(timeIntervalSince1970: updated.doubleValue > 10_000_000_000 ? updated.doubleValue / 1000 : updated.doubleValue); updatedChat.updatedAt = date; desktopActivityDates[id] = date }
            if updatedChat.status == "active", Date().timeIntervalSince(observedActiveAt[id] ?? .distantPast) >= 60 {
                observedActiveAt[id] = Date()
            }
            if let date = observedActiveAt[id], date > updatedChat.updatedAt { updatedChat.updatedAt = date }
            if updatedChat != chats[index] {
                var updated = chats; updated[index] = updatedChat
                chats = CodexChatOrder.sorted(updated, previous: stableChatOrder)
            }
        }
        for root in Array(subagents.keys) {
            if let index = subagents[root]?.firstIndex(where: { $0.id == id }), let status = state["threadRuntimeStatus"] as? [String: Any] {
                subagents[root]?[index].status = status["type"] as? String ?? "notLoaded"
                subagents[root]?[index].flags = status["activeFlags"] as? [String] ?? []
            }
        }
        guard id == selectedID else { return }
        if state.keys.contains("threadGoal") { let value = CodexGoal(state["threadGoal"] as? [String: Any]); if selectedGoal != value { selectedGoal = value } }
        let liveSettings = CodexLiveSettings(state)
        if let model = liveSettings.model, currentModel != model { currentModel = model }
        if let effort = liveSettings.effort, currentEffort != effort { currentEffort = effort }
        if !pendingOptionIDs.contains(id) {
            var value = options[id] ?? CodexTurnOptions()
            if let model = liveSettings.model { value.model = model }
            if let effort = liveSettings.effort { value.effort = effort }
            if options[id] != value { options[id] = value }
        }
        let turns = CodexTranscript.turns(state)
        if !turns.isEmpty { latestNativeTranscript = state; projectNativeTranscript(state) }
        if let turn = turns.last, turn["status"] as? String == "inProgress", let turnID = turn["turnId"] as? String ?? turn["id"] as? String {
            activeTurns[id] = turnID; if activity != "Codex arbeitet …" { activity = "Codex arbeitet …" }
        } else if !turns.isEmpty { activeTurns.removeValue(forKey: id); if !activity.isEmpty { activity = "" } }
    }
    private func projectNativeTranscript(_ state: [String: Any]) {
        guard let id = selectedID else { return }
        nativeProjectionPending = (id, nativeProjectionEpoch, nativeHistoryLimit, state)
        guard nativeProjectionTask == nil else { return }
        nativeProjectionTask = Task { [weak self] in
            guard let self else { return }
            while let next = self.nativeProjectionPending, !Task.isCancelled {
                self.nativeProjectionPending = nil
                let projected = await Task.detached(priority: .userInitiated) { CodexTranscript.window(next.state, limit: next.limit) }.value
                guard !Task.isCancelled, self.selectedID == next.id, self.nativeProjectionEpoch == next.epoch, self.nativeHistoryLimit == next.limit else { continue }
                let old = Dictionary(self.messages.compactMap { message in message.activity.map { (message.id, $0) } }, uniquingKeysWith: { _, last in last })
                let incoming = projected.messages.map { self.preservingActivity($0, old: old[$0.id]) }
                if self.messages != incoming { self.messages = incoming }
                let questions = projected.questions.filter { !self.confirmedAsyncAnswers.contains($0.id) }
                if self.asyncQuestions != questions { self.asyncQuestions = questions }
                if self.hasOlderNativeHistory != projected.hasMore { self.hasOlderNativeHistory = projected.hasMore }
                if self.loadingHistory { self.loadingHistory = false }
            }
            self.nativeProjectionTask = nil
        }
    }
    func loadOlderNativeHistory() async {
        guard let id = selectedID, let state = latestNativeTranscript, hasOlderNativeHistory else { return }
        let epoch = nativeProjectionEpoch
        let count = CodexTranscript.turns(state).reduce(0) { $0 + ($1["items"] as? [[String:Any]] ?? []).count }
        if nativeHistoryLimit >= count, CodexTranscript.mayHaveOlder(state) {
            do {
                try await desktop.loadCompleteHistory(id)
                for _ in 0..<200 where selectedID == id && nativeProjectionEpoch == epoch && latestNativeTranscript.map(CodexTranscript.mayHaveOlder) == true {
                    try await Task.sleep(nanoseconds:10_000_000)
                }
            } catch { self.error = "Älterer Verlauf konnte nicht geladen werden: " + error.localizedDescription; return }
        }
        guard selectedID == id, nativeProjectionEpoch == epoch, let current = latestNativeTranscript else { return }
        nativeHistoryLimit += 80; projectNativeTranscript(current)
        await nativeProjectionTask?.value
    }
    private func event(_ method: String, _ p: [String: Any]) {
        let id = p["threadId"] as? String
        switch method {
        case "thread/queue/changed":
            if id == selectedID { Task { await refreshNativeQueue() } }
        case "account/rateLimits/updated":
            let parsed = CodexUsageBucket.parse(p)
            if !parsed.isEmpty { usageBuckets = parsed; usageUpdatedAt = Date(); usageError = nil }
        case "thread/goal/updated":
            if id == selectedID { let value = CodexGoal(p["goal"] as? [String: Any]); if selectedGoal != value { selectedGoal = value } }
        case "thread/started":
            if let json = p["thread"] as? [String: Any], var chat = CodexChat(json) {
                if let status = desktop.runtimeStatus(chat.id) { chat.status = status["type"] as? String ?? chat.status; chat.flags = status["activeFlags"] as? [String] ?? [] }
                else if desktop.hasOwner(chat.id), let old = liveChats.first(where: { $0.id == chat.id }) { chat.status = old.status; chat.flags = old.flags }
                if let date = desktopActivityDates[chat.id] { chat.updatedAt = date }
                if let date = observedActiveAt[chat.id], date > chat.updatedAt { chat.updatedAt = date }
                let ordered = CodexChatOrder.sorted(liveChats.filter { $0.id != chat.id } + [chat], previous: stableChatOrder)
                if showingArchived { objectWillChange.send(); nonArchivedChats = ordered } else { chats = ordered }
            }
        case "thread/status/changed":
            if let id, desktop.hasOwner(id) { return }
            if let index = chats.firstIndex(where: { $0.id == id }), let status = p["status"] as? [String: Any] {
                chats[index].status = status["type"] as? String ?? "notLoaded"; chats[index].flags = status["activeFlags"] as? [String] ?? []
            }
        case "thread/archived", "thread/deleted":
            chats.removeAll { $0.id == id }
            if selectedID == id { newChat() }
        case "thread/name/updated":
            if let index = chats.firstIndex(where: { $0.id == id }), let name = p["threadName"] as? String ?? p["name"] as? String { chats[index].title = name }
        case "turn/started":
            if let id, let turn = p["turn"] as? [String: Any], let turnID = turn["id"] as? String { activeTurns[id] = turnID; queue.observe(id, active: true) }
        case "turn/completed":
            if let turn = p["turn"] as? [String: Any], let turnID = turn["id"] as? String { completedTurns.insert(turnID) }
            if let id { activeTurns.removeValue(forKey: id); prompts.removeAll { !$0.desktop && $0.threadID == id }; queueCompleted(id) }
            if id == selectedID {
                let turn = p["turn"] as? [String: Any] ?? [:]
                let status = turn["status"] as? String ?? "unknown"
                activity = status == "completed" ? "Antwort abgeschlossen" : status == "interrupted" ? "Unterbrochen" : "Antwort fehlgeschlagen"
                if let err = turn["error"] as? [String: Any] { error = err["message"] as? String }
            }
            Task { await refresh() }
        case "item/started", "item/completed":
            if let id, let item = p["item"] as? [String: Any], let itemID = item["id"] as? String {
                let key = id + ":" + itemID
                if method == "item/started", ["commandExecution", "fileChange"].contains(item["type"] as? String ?? "") { approvalItems[key] = item }
                if method == "item/completed" { approvalItems.removeValue(forKey: key) }
            }
            guard id == selectedID, let item = p["item"] as? [String: Any] else { return }
            if var message = CodexMessage.from(item) {
                message = preservingActivity(message)
                if method == "item/started", message.activity?.isRunning == true, message.activity?.startedAt == nil { message.activity?.startedAt = Date() }
                if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
                else { messages.append(message) }
            } else if method == "item/started" {
                switch item["type"] as? String {
                case "commandExecution": activity = "Befehl wird ausgeführt …"
                case "fileChange": activity = "Dateien werden bearbeitet …"
                case "mcpToolCall": activity = "Tool wird ausgeführt …"
                default: break
                }
            }
        case "item/agentMessage/delta":
            guard id == selectedID, let itemID = p["itemId"] as? String, let delta = p["delta"] as? String else { return }
            if let index = messages.firstIndex(where: { $0.id == itemID }) { messages[index].text += delta }
            else { messages.append(CodexMessage(id: itemID, role: "Codex", text: delta)) }
        case "item/commandExecution/outputDelta":
            guard id == selectedID, let itemID = p["itemId"] as? String, let delta = p["delta"] as? String, let index = messages.firstIndex(where: { $0.id == itemID }), var details = messages[index].activity else { return }
            let combined = details.output + delta; details.outputTruncated = details.outputTruncated || combined.count > 65_536; details.output = String(combined.suffix(65_536)); messages[index].activity = details
        case "serverRequest/resolved":
            if let requestID = p["requestId"] { prompts.removeAll { String(describing: $0.requestID) == String(describing: requestID) } }
        case "error":
            if id == selectedID, let e = p["error"] as? [String: Any] { error = e["message"] as? String }
        default: break
        }
    }
    private func preservingActivity(_ message: CodexMessage) -> CodexMessage {
        preservingActivity(message, old: messages.first(where: { $0.id == message.id })?.activity)
    }
    private func preservingActivity(_ message: CodexMessage, old: CodexActivityDetails?) -> CodexMessage {
        guard var details = message.activity, let old else { return message }
        if details.startedAt == nil { details.startedAt = old.startedAt; details.observedStart = old.observedStart }
        if details.output.isEmpty && !old.output.isEmpty { details.output = old.output; details.outputTruncated = old.outputTruncated }
        var result = message; result.activity = details; return result
    }
    private func serverRequest(_ id: Any, _ method: String, _ params: [String: Any]) {
        let supported = ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/tool/requestUserInput", "item/permissions/requestApproval", "mcpServer/elicitation/request"]
        guard supported.contains(method) else {
            try? connection.reject(id: id); error = "Codex benötigt eine in MacTools nicht unterstützte Anfrage: \(method)"; return
        }
        var details = params
        if let threadID = params["threadId"] as? String, let itemID = params["itemId"] as? String, let item = approvalItems[threadID + ":" + itemID] {
            for (key, value) in item where details[key] == nil { details[key] = value }
        }
        prompts.append(CodexPrompt(requestID: id, method: method, threadID: params["threadId"] as? String ?? "", params: details))
    }
    private func composerApps(progress: @MainActor ([CodexReference]) -> Void) async throws -> [CodexReference] {
        var result: [CodexReference] = [], cursor: String?, seen = Set<String>()
        repeat {
            var params: [String: Any] = ["limit": 500, "forceRefetch": false]
            if let cursor { params["cursor"] = cursor }
            let response = try await connection.request("app/list", params)
            guard let apps = response["data"] as? [[String: Any]] else { throw CodexFailure(message: "Ungültiger App-Katalog") }
            result += apps.compactMap { app in
                guard app["isAccessible"] as? Bool == true, app["isEnabled"] as? Bool != false, let id = app["id"] as? String, let name = app["name"] as? String else { return nil }
                return CodexReference(name: name, path: "app://" + id, kind: "app", detail: app["description"] as? String ?? "")
            }
            progress(result)
            cursor = response["nextCursor"] as? String
            if let cursor, !seen.insert(cursor).inserted { throw CodexFailure(message: "Der App-Katalog wiederholt eine Seite") }
        } while cursor != nil
        return result
    }
    func loadComposerContext(force: Bool = false) async {
        let cwd = selected?.cwd ?? workingDirectory
        let cached = composerCatalog.snapshot(cwd)
        if composerContextKey != cwd {
            availableReferences = cached?.references ?? []
            composerContextError = nil
        }
        guard connected, !loadingComposer else { return }
        if !force, let cached, Date().timeIntervalSince(cached.checkedAt) < 300 {
            composerContextKey = cwd
            if models.isEmpty { await loadComposerModels() }
            return
        }
        loadingComposer = true; composerContextLoading = true; composerContextKey = cwd
        defer {
            loadingComposer = false; composerContextLoading = false
            if cwd != (selected?.cwd ?? workingDirectory) { Task { await self.loadComposerContext() } }
        }
        var found: [CodexReference] = [], failures: [String] = [], appPages: [CodexReference] = []
        @MainActor func publish(_ extra: [CodexReference] = []) {
            guard cwd == (selected?.cwd ?? workingDirectory) else { return }
            let refs = found + extra + (cached?.references ?? [])
            let merged = Array(Dictionary(refs.map { ($0.id,$0) },uniquingKeysWith:{ first,_ in first }).values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if availableReferences != merged { availableReferences = merged }
        }
        // Render each completed source immediately, while all sources are requested in parallel.
        async let skillsResponse = try? connection.request("skills/list", ["cwds":[cwd],"forceReload":false])
        async let pluginsResponse = try? connection.request("plugin/list", ["cwds":[cwd],"forceRefetch":false])
        async let remotePluginsResponse = try? connection.request("plugin/list", ["cwds":[cwd],"forceRefetch":false,"marketplaceKinds":["created-by-me-remote","shared-with-me","workspace-directory"]])
        async let appsResponse = try? composerApps { page in appPages = page; publish(page) }
        if let response = await skillsResponse {
            for entry in response["data"] as? [[String:Any]] ?? [] {
                for skill in entry["skills"] as? [[String:Any]] ?? [] where skill["enabled"] as? Bool != false {
                    if let name = skill["name"] as? String, let path = skill["path"] as? String { found.append(CodexReference(name:name,path:path,kind:"skill",detail:skill["description"] as? String ?? "")) }
                }
            }
            publish()
        } else { failures.append("Skills") }
        for response in await [pluginsResponse,remotePluginsResponse] {
            if let response {
                if !(response["marketplaceLoadErrors"] as? [Any] ?? []).isEmpty { failures.append("Plugin-Kataloge") }
                for market in response["marketplaces"] as? [[String:Any]] ?? [] {
                    for plugin in market["plugins"] as? [[String:Any]] ?? [] where plugin["installed"] as? Bool == true && plugin["enabled"] as? Bool != false {
                        let interface = plugin["interface"] as? [String:Any] ?? [:]
                        if let id = plugin["id"] as? String, let name = interface["displayName"] as? String ?? plugin["name"] as? String { found.append(CodexReference(name:name,path:"plugin://"+id,kind:"plugin",detail:interface["shortDescription"] as? String ?? "")) }
                    }
                }
                publish()
            } else { failures.append("Plugins") }
        }
        if let apps = await appsResponse { found += apps } else { found += appPages; failures.append("Apps") }
        if !failures.isEmpty { found += cached?.references ?? [] }
        let result = Array(Dictionary(found.map { ($0.id,$0) },uniquingKeysWith:{ first,_ in first }).values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if failures.isEmpty { composerCatalog.save(result,cwd:cwd) }
        if cwd == (selected?.cwd ?? workingDirectory) {
            if availableReferences != result { availableReferences = result }
            composerContextError = failures.isEmpty ? nil : failures.joined(separator:", ") + " konnten nicht vollständig geladen werden."
        }
        if models.isEmpty { await loadComposerModels() }
    }
    private func loadComposerModels() async {
        if let response = try? await connection.request("model/list",["limit":100]) {
            let data = response["data"] as? [[String:Any]] ?? []
            models = data.sorted { ($0["isDefault"] as? Bool ?? false) && !($1["isDefault"] as? Bool ?? false) }.filter { $0["hidden"] as? Bool != true }.compactMap(CodexModelChoice.init)
        }
    }
    func searchReferenceFiles(_ query: String) async -> [CodexReference] {
        guard connected, query.count >= 2, (selected?.cwd ?? workingDirectory) != NSHomeDirectory() else { return [] }
        guard let response = try? await connection.request("fuzzyFileSearch", ["query": query, "roots": [selected?.cwd ?? workingDirectory], "cancellationToken": "mactools-composer"]) else { return [] }
        return Array((response["files"] as? [[String: Any]] ?? []).prefix(15)).compactMap { file in
            guard let name = file["file_name"] as? String, let path = file["path"] as? String, let root = file["root"] as? String else { return nil }
            return CodexReference(name: name, path: path.hasPrefix("/") ? path : URL(fileURLWithPath: root).appendingPathComponent(path).path, kind: "file")
        }
    }

}

extension CodexTranscript {
    static func storedMessages(path: String) async -> [CodexMessage] {
        await Task.detached(priority: .utility) {
            let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let root = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard url.path.hasPrefix(root), url.pathExtension == "jsonl", let handle = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0, offset = size > 8_388_608 ? size - 8_388_608 : 0
            try? handle.seek(toOffset: offset)
            var data = (try? handle.readToEnd()) ?? Data()
            if offset > 0, let newline = data.firstIndex(of: 10) { data = Data(data.suffix(from: data.index(after: newline))) }
            return data.split(separator: 10).enumerated().compactMap { index, line -> CodexMessage? in
                guard let value = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], value["type"] as? String == "response_item", let payload = value["payload"] as? [String: Any], payload["type"] as? String == "message", let role = payload["role"] as? String, ["user", "assistant"].contains(role) else { return nil }
                let text = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                guard !text.isEmpty else { return nil }
                if role == "user" { return CodexMessage.from(["id": "stored-\(offset)-\(index)", "type": "userMessage", "content": [["text": text]]]) }
                return CodexMessage(id: "stored-\(offset)-\(index)", role: "Codex", text: text)
            }
        }.value
    }
}
