import Foundation
import Darwin

/// Optional follower connection to the installed desktop app's user-owned local socket.
/// The desktop keeps ownership of its chats; MacTools registers under its own name.
@MainActor
final class CodexDesktopConnection {
    var onState: ((String, [String: Any]) -> Void)?
    var onQueue: ((String, [[String: Any]]) -> Void)?
    var onDisconnect: (() -> Void)?
    private var handle: FileHandle?
    private var reader: CodexDesktopFrameReader?
    private var clientID = ""
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var owners: [String: String] = [:]
    private var snapshots: [String: [String: Any]] = [:]
    private var revisions: [String: Int] = [:]
    private var generation = UUID()
    private var connectingTask: Task<Void,Error>?
    private var connectingToken = UUID()
    private let socketPath: String?
    init(socketPath: String? = nil) { self.socketPath = socketPath }
    private var publishTask: Task<Void, Never>?
    private var changedIDs = Set<String>()
    var selectedID: String? {
        didSet {
            if let oldValue, oldValue != selectedID, let old = snapshots[oldValue] {
                snapshots[oldValue] = Self.runtimeSnapshot(old)
            }
        }
    }
    var connected: Bool { handle != nil && !clientID.isEmpty }
    func hasOwner(_ id: String) -> Bool { owners[id] != nil }
    func runtimeStatus(_ id: String) -> [String: Any]? {
        guard owners[id] != nil, let status = snapshots[id]?["threadRuntimeStatus"] as? [String: Any], status["type"] is String else { return nil }
        return status
    }

    func connect() async throws {
        if connected { return }
        if let connectingTask { try await connectingTask.value; return }
        stop()
        let token = UUID(); connectingToken = token
        let task = Task { try await self.openConnection() }; connectingTask = task
        defer { if connectingToken == token { connectingTask = nil } }
        try await task.value
    }
    private func openConnection() async throws {
        try Task.checkCancellation()
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        let path = socketPath ?? home + "/ipc/ipc.sock"
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw CodexFailure(message: "Codex Desktop ist nicht verbunden.") }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CodexFailure(message: "Codex Desktop-Verbindung konnte nicht geöffnet werden.") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(descriptor); throw CodexFailure(message: "Codex-Socketpfad ist zu lang.") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let status = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard status == 0 else { Darwin.close(descriptor); throw CodexFailure(message: "Codex Desktop ist nicht erreichbar.") }
        var noSignal: Int32 = 1; setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let token = UUID(); generation = token
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); handle = file
        let reader = CodexDesktopFrameReader { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if let message { self.receive(message) } else { self.stop(); self.onDisconnect?() }
            }
        }
        self.reader = reader
        file.readabilityHandler = { file in
            let data = file.availableData
            if data.isEmpty { file.readabilityHandler = nil }
            reader.receive(data)
        }
        do {
            let response = try await request("initialize", ["clientType": "mactools"], version: 0)
            guard let id = response["clientId"] as? String else { throw CodexFailure(message: "Unbekannte Codex-Desktop-Version.") }
            clientID = id
        } catch { stop(); throw error }
    }
    /// Recovery performs discovery only; it never retries a message or approval.
    func recoverOwner(_ id:String) async -> Bool {
        do { try await connect() } catch { return false }
        owners.removeValue(forKey:id)
        if await follow(id,resnapshot:true) { return true }
        stop()
        do { try await connect() } catch { return false }
        return await follow(id,resnapshot:true)
    }
    func follow(_ id: String, resnapshot: Bool = false) async -> Bool {
        guard connected else { return false }
        if let owner = owners[id] {
            do {
                // Discovery can succeed before the first stream snapshot arrives. A dropped
                // subscription must not leave a window permanently "connected" without data.
                if resnapshot || snapshots[id] == nil { try subscribe(id, owner: owner, following: true) }
                return true
            } catch { owners.removeValue(forKey: id); return false }
        }
        do {
            let response = try await request("thread-owner-discovery", ["hostId": "local", "conversationId": id], version: 1)
            guard let owner = response["_handledBy"] as? String else { return false }
            owners[id] = owner
            try subscribe(id, owner: owner, following: true)
            return true
        } catch { owners.removeValue(forKey: id); return false }
    }
    func send(_ text: String, to id: String, active: Bool, inputs: [[String: Any]]? = nil, options: [String: Any] = [:]) async throws {
        guard let owner = owners[id] else { throw CodexFailure(message: "Der Originalchat ist im Codex Desktop nicht geöffnet.") }
        let input = Self.normalizedInput(inputs ?? [["type":"text","text":text]])
        if active, !options.isEmpty { _ = try await request("thread-follower-update-thread-settings", ["conversationId": id, "threadSettings": options], version: 2, target: owner) }
        var turnRequest = options; turnRequest["threadId"] = id; turnRequest["input"] = input
        let messageID = UUID().uuidString
        let cwd = options["cwd"] as? String
        let context: [String:Any] = ["prompt":text,"addedFiles":[],"fileAttachments":[],"imageAttachments":[],"commentAttachments":[],"ideContext":NSNull(),"workspaceRoots":cwd.map { [$0] } ?? []]
        var restore: [String:Any] = ["id":messageID,"text":text,"context":context,"createdAt":Date().timeIntervalSince1970 * 1000]
        if let cwd { restore["cwd"] = cwd }
        let method = active ? "thread-follower-steer-turn" : "thread-follower-start-turn"
        let params: [String: Any] = active
            ? ["conversationId": id, "input": input, "attachments": [], "clientUserMessageId": messageID, "restoreMessage": restore]
            : ["conversationId": id, "turnStart": ["request": turnRequest.merging(["clientUserMessageId": messageID]) { _, new in new }, "context": ["inheritThreadSettings": true, "restoreMessage":restore, "attachments":[]]]]
        let result = try await request(method, params, version: active ? 1 : 2, target: owner, timeout: 30)
        try Self.confirmDelivery(result["result"])
    }
    /// The desktop renderer reads text_elements.length even for plain text.
    static func normalizedInput(_ input: [[String:Any]]) -> [[String:Any]] {
        input.map { item in
            var item = item
            if item["type"] as? String == "text", !(item["text_elements"] is [Any]) { item["text_elements"] = [] }
            return item
        }
    }
    func loadCompleteHistory(_ id: String) async throws {
        guard let owner = owners[id] else { throw CodexFailure(message:"Der Originalchat ist gerade nicht erreichbar.") }
        _ = try await request("thread-follower-load-complete-history",["conversationId":id],version:1,target:owner,timeout:30)
    }
    static func confirmDelivery(_ value: Any?) throws {
        // Current owner implementations return a turn ID or an explicit admission receipt.
        if let turnID = value as? String, !turnID.isEmpty { return }
        if let receipt = value as? [String: Any] {
            if let status = receipt["status"] as? String {
                if ["accepted", "sent"].contains(status) { return }
                throw CodexFailure(message: "Codex hat die Nachricht nicht übernommen (\(status)). Sie bleibt erhalten.")
            }
            if let turnID = receipt["turnId"] as? String, !turnID.isEmpty { return }
            if let turn = receipt["turn"] as? [String: Any], let turnID = turn["id"] as? String, !turnID.isEmpty { return }
        }
        throw CodexFailure(message: "Codex hat die Übergabe nicht bestätigt. Die Nachricht bleibt erhalten; bitte vor erneutem Senden im Originalchat prüfen.")
    }
    func removeQueued(_ message: String, in id: String) async throws {
        guard let owner = owners[id] else { throw CodexFailure(message: "Der Originalchat ist gerade nicht erreichbar.") }
        _ = try await request("thread-follower-remove-queued-message", ["conversationId": id, "messageId": message], version: 2, target: owner)
    }
    func answer(_ requestID: Any, method: String, in id: String, result: [String: Any]) async throws {
        guard let owner = owners[id] else { throw CodexFailure(message: "Der Originalchat ist gerade nicht verbunden. Die Anfrage bleibt erhalten.") }
        let methods = ["item/commandExecution/requestApproval":"thread-follower-command-approval-decision", "item/fileChange/requestApproval":"thread-follower-file-approval-decision", "item/permissions/requestApproval":"thread-follower-permissions-request-approval-response", "item/tool/requestUserInput":"thread-follower-submit-user-input", "mcpServer/elicitation/request":"thread-follower-submit-mcp-server-elicitation-response"]
        guard let target = methods[method] else { throw CodexFailure(message: "Diese Anfrage bitte im Originalchat beantworten.") }
        var params: [String: Any] = ["conversationId": id, "requestId": requestID]
        if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" { params["decision"] = result["decision"] }
        else { params["response"] = result }
        let response = try await request(target, params, version: 1, target: owner)
        guard response["ok"] as? Bool == true else { throw CodexFailure(message: "Codex hat die Antwort nicht bestätigt. Die Anfrage bleibt erhalten.") }
    }
    func interrupt(_ id: String, turnID: String) async throws {
        guard let owner = owners[id] else { return }
        _ = try await request("thread-follower-interrupt-turn", ["conversationId": id, "expectedTurnId": turnID], version: 4, target: owner)
    }
    private func subscribe(_ id: String, owner: String, following: Bool) throws {
        try write(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1, "sourceClientId": clientID, "targetClientIds": [owner], "params": ["conversationId": id, "hostId": "local", "following": following]])
    }
    private func request(_ method: String, _ params: [String: Any], version: Int, target: String? = nil, timeout: UInt64 = 6) async throws -> [String: Any] {
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            var message: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": clientID, "method": method, "version": version, "params": params, "timeoutMs": timeout * 1000]
            if let target { message["targetClientId"] = target }
            do { try write(message) } catch { pending.removeValue(forKey: id)?.resume(throwing: error); return }
            timers[id] = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: timeout * 1_000_000_000) } catch { return }
                self?.timers.removeValue(forKey: id)
                self?.pending.removeValue(forKey: id)?.resume(throwing: CodexFailure(message: "Codex Desktop hat die Anfrage nicht bestätigt. Bitte vor erneutem Senden den Originalchat prüfen."))
            }
        }
    }
    private func write(_ object: [String: Any]) throws {
        guard let handle else { throw CodexFailure(message: "Codex Desktop ist nicht verbunden.") }
        let payload = try JSONSerialization.data(withJSONObject: object)
        var count = UInt32(payload.count).littleEndian
        var data = withUnsafeBytes(of: &count) { Data($0) }; data.append(payload)
        try handle.write(contentsOf: data)
    }
    private func receive(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
            if type == "client-discovery-request", let id = message["requestId"] {
                try? write(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]])
            } else if type == "response", let id = message["requestId"] as? String {
                timers.removeValue(forKey: id)?.cancel()
                guard let continuation = pending.removeValue(forKey: id) else { return }
                if message["resultType"] as? String == "success" {
                    var result = message["result"] as? [String: Any] ?? [:]; result["_handledBy"] = message["handledByClientId"]
                    continuation.resume(returning: result)
                } else { continuation.resume(throwing: CodexFailure(message: message["error"] as? String ?? "Codex Desktop-Anfrage fehlgeschlagen.")) }
            } else if type == "broadcast", message["method"] as? String == "client-status-changed",
                      let params = message["params"] as? [String: Any], params["status"] as? String == "disconnected", let client = params["clientId"] as? String {
                let lost = owners.filter { $0.value == client }.map(\.key)
                for id in lost { owners.removeValue(forKey: id); snapshots.removeValue(forKey: id); revisions.removeValue(forKey: id) }
            } else if type == "broadcast", message["method"] as? String == "thread-queued-followups-changed", message["version"] as? Int == 2,
                      let params = message["params"] as? [String: Any], params["hostId"] as? String == "local", let id = params["conversationId"] as? String,
                      message["sourceClientId"] as? String == owners[id], let messages = params["messages"] as? [[String: Any]] {
                onQueue?(id, messages)
            } else if type == "broadcast", message["method"] as? String == "thread-stream-state-changed", message["version"] as? Int == 11,
                      let params = message["params"] as? [String: Any], params["hostId"] as? String == "local", let id = params["conversationId"] as? String,
                      message["sourceClientId"] as? String == owners[id], let change = params["change"] as? [String: Any] {
                stateChange(id, change)
            }
    }
    private static func runtimeSnapshot(_ state: [String: Any]) -> [String: Any] {
        var result: [String: Any] = ["threadRuntimeStatus": state["threadRuntimeStatus"] ?? [:]]
        if let requests = state["requests"] { result["requests"] = requests }
        if let date = state["recencyAt"] as? NSNumber, date.doubleValue > 0 { result["recencyAt"] = date }
        return result
    }
    private func stateChange(_ id: String, _ change: [String: Any]) {
        let revision = change["revision"] as? Int ?? 0
        if change["type"] as? String == "snapshot", let state = change["conversationState"] as? [String: Any] {
            revisions[id] = revision
            snapshots[id] = id == selectedID ? state : Self.runtimeSnapshot(state)
        } else if change["type"] as? String == "patches" {
            guard change["baseRevision"] as? Int == revisions[id], var state = snapshots[id] else {
                if let owner = owners[id] { try? subscribe(id, owner: owner, following: true) }; return
            }
            for patch in change["patches"] as? [[String: Any]] ?? [] {
                let path = patch["path"] as? [Any] ?? []
                if id != selectedID, !["threadRuntimeStatus", "recencyAt", "requests"].contains(path.first as? String ?? "") { continue }
                state = Self.patch(state, path: path, operation: patch["op"] as? String ?? "replace", value: patch["value"] ?? NSNull()) as? [String: Any] ?? state
            }
            snapshots[id] = state; revisions[id] = revision
        }
        changedIDs.insert(id)
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            guard let self else { return }
            let ids = self.changedIDs; self.changedIDs.removeAll(); self.publishTask = nil
            for id in ids { if let state = self.snapshots[id] { self.onState?(id, state) } }
        }
    }
    static func patch(_ node: Any, path: [Any], operation: String, value: Any) -> Any {
        guard let key = path.first else { return value }
        let rest = Array(path.dropFirst())
        if var dictionary = node as? [String: Any], let key = key as? String {
            if rest.isEmpty { if operation == "remove" { dictionary.removeValue(forKey: key) } else { dictionary[key] = value } }
            else { dictionary[key] = patch(dictionary[key] ?? [:], path: rest, operation: operation, value: value) }
            return dictionary
        }
        if var array = node as? [Any], let index = key as? Int, index >= 0 {
            if rest.isEmpty {
                if operation == "remove", index < array.count { array.remove(at: index) }
                else if operation == "add", index <= array.count { array.insert(value, at: index) }
                else if index < array.count { array[index] = value }
            } else if index < array.count { array[index] = patch(array[index], path: rest, operation: operation, value: value) }
            return array
        }
        return node
    }
    func stop() {
        connectingTask?.cancel(); connectingTask = nil; connectingToken = UUID()
        publishTask?.cancel(); publishTask = nil; changedIDs.removeAll()
        generation = UUID(); handle?.readabilityHandler = nil; try? handle?.close(); handle = nil; clientID = ""
        timers.values.forEach { $0.cancel() }; timers.removeAll()
        let requests = pending; pending.removeAll(); requests.values.forEach { $0.resume(throwing: CodexFailure(message: "Codex Desktop-Verbindung getrennt.")) }
        reader = nil; owners.removeAll(); snapshots.removeAll(); revisions.removeAll()
    }
}

/// Socket framing and potentially large JSON snapshots must never block AppKit.
private final class CodexDesktopFrameReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacTools.CodexFrames", qos: .userInitiated)
    private var buffer = Data()
    private let deliver: ([String: Any]?) -> Void
    init(deliver: @escaping ([String: Any]?) -> Void) { self.deliver = deliver }
    func receive(_ data: Data) {
        queue.async { [self] in
            guard !data.isEmpty else { deliver(nil); return }
            buffer.append(data)
            while buffer.count >= 4 {
                let length = buffer.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
                guard length > 0, length <= 256 * 1024 * 1024 else { buffer.removeAll(); deliver(nil); return }
                guard buffer.count >= length + 4 else { return }
                let payload = Data(buffer.dropFirst(4).prefix(length)); buffer.removeFirst(length + 4)
                if let message = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] { deliver(message) }
            }
        }
    }
}
