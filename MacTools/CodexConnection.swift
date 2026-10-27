import Foundation
import AppKit

struct CodexFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A server rejection is distinct from a timeout or a broken transport: only an explicit
/// missing-thread rejection can safely trigger a single rehydration before retrying a turn.
struct CodexRPCFailure: LocalizedError {
    let code: Int?
    let message: String
    var errorDescription: String? { message }
    func isMissingThread(_ id: String) -> Bool { message == "thread not found: " + id }
}

/// JSONL transport to the installed Codex CLI. No credentials are read by MacTools.
@MainActor
final class CodexConnection {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onRequest: ((Any, String, [String: Any]) -> Void)?
    var onDisconnect: ((String) -> Void)?
    private let executableOverride: URL?
    private let environmentOverrides: [String: String]
    private let clientName: String
    init(executableURL: URL? = nil, environment: [String: String] = [:], clientName: String = "mactools") {
        executableOverride = executableURL; environmentOverrides = environment; self.clientName = clientName
    }
    private var process: Process?
    private var input: FileHandle?
    private var output: Pipe?
    private var errors: Pipe?
    private var reader: CodexJSONLineReader?
    private var errorTail = Data()
    private var sequence = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var generation = UUID()
    private(set) var sharedServer = false

    static func executable() -> URL? {
        let custom = UserDefaults.standard.string(forKey: "codexExecutable")
        let candidates = [custom,
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex"]
        return candidates.compactMap { $0 }.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    func connect() async throws {
        guard process == nil else { return }
        guard let executable = executableOverride ?? Self.executable() else {
            throw CodexFailure(message: "Codex CLI nicht gefunden. Installiere Codex oder wähle die ausführbare Datei.")
        }
        let proc = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        let home = environmentOverrides["CODEX_HOME"] ?? ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        sharedServer = executableOverride == nil && FileManager.default.fileExists(atPath: home + "/app-server-control/app-server-control.sock")
        proc.executableURL = executable
        proc.arguments = sharedServer ? ["app-server", "proxy"] : ["app-server"]
        proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var environment = ProcessInfo.processInfo.environment
        environment.merge(environmentOverrides) { _, value in value }
        environment["PATH"] = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        proc.environment = environment
        proc.standardInput = stdinPipe; proc.standardOutput = stdoutPipe; proc.standardError = stderrPipe
        let token = UUID(); generation = token
        let reader = CodexJSONLineReader { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.receive(message)
            }
        }
        self.reader = reader
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            reader.receive(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.errorTail.append(data); self.errorTail = Data(self.errorTail.suffix(2048))
            }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                let detail = String(data: self.errorTail, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let message = detail.isEmpty ? "Codex-Verbindung wurde beendet." : "Codex-Verbindung beendet: " + detail
                self.stop(); self.onDisconnect?(message)
            }
        }
        do { try proc.run() } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        process = proc; input = stdinPipe.fileHandleForWriting; output = stdoutPipe; errors = stderrPipe
        do {
            _ = try await request("initialize", ["clientInfo": ["name": clientName, "title": "MacTools", "version": "0.2.3"], "capabilities": ["experimentalApi": true]])
            try write(["method": "initialized", "params": [:]])
        } catch { stop(); throw error }
    }

    func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        sequence += 1; let id = sequence
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try write(["id": id, "method": method, "params": params]) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error); return }
            timeouts[id] = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                guard let self else { return }
                self.timeouts.removeValue(forKey: id)
                self.pending.removeValue(forKey: id)?.resume(throwing: CodexFailure(message: "Codex antwortet nicht auf \(method). Bitte erneut verbinden."))
            }
        }
    }

    func reply(id: Any, result: [String: Any]) throws { try write(["id": id, "result": result]) }
    func reject(id: Any) throws { try write(["id": id, "error": ["code": -32601, "message": "Diese Anfrage wird von MacTools nicht unterstützt."]]) }

    private func write(_ message: [String: Any]) throws {
        guard let input, process?.isRunning == true else { throw CodexFailure(message: "Keine Verbindung zu Codex.") }
        var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
        try input.write(contentsOf: data)
    }

    private func receive(_ message: [String: Any]) {
            if let method = message["method"] as? String {
                let params = message["params"] as? [String: Any] ?? [:]
                if let id = message["id"] { onRequest?(id, method, params) }
                else { onEvent?(method, params) }
            } else if let id = message["id"] as? Int {
                timeouts.removeValue(forKey: id)?.cancel()
                guard let continuation = pending.removeValue(forKey: id) else { return }
                if let error = message["error"] as? [String: Any] {
                    continuation.resume(throwing: CodexRPCFailure(code: error["code"] as? Int, message: error["message"] as? String ?? "Codex-Anfrage fehlgeschlagen."))
                } else { continuation.resume(returning: message["result"] as? [String: Any] ?? [:]) }
            }
    }

    func stop() {
        generation = UUID()
        output?.fileHandleForReading.readabilityHandler = nil; errors?.fileHandleForReading.readabilityHandler = nil
        try? input?.close(); if process?.isRunning == true { process?.terminate() }
        process = nil; input = nil; output = nil; errors = nil; reader = nil; errorTail.removeAll()
        timeouts.values.forEach { $0.cancel() }; timeouts.removeAll()
        let requests = pending; pending.removeAll()
        requests.values.forEach { $0.resume(throwing: CodexFailure(message: "Codex-Verbindung getrennt.")) }
    }
}

/// Incremental framing scans each byte once; large replies decode off AppKit's thread.
final class CodexJSONLineReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacTools.CodexJSON", qos: .userInitiated)
    private var buffer = Data()
    private var searched = 0
    private let deliver: ([String: Any]) -> Void
    init(deliver: @escaping ([String: Any]) -> Void) { self.deliver = deliver }
    func receive(_ data: Data) {
        queue.async { [self] in
            buffer.append(data)
            var consumed = 0
            while searched < buffer.count {
                let newline: Int? = buffer.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress, let found = memchr(base.advanced(by: searched), 10, raw.count - searched) else { return nil }
                    return base.distance(to: found)
                }
                guard let newline else { searched = buffer.count; break }
                let line = buffer.subdata(in: consumed..<newline)
                consumed = newline + 1; searched = consumed
                if let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { deliver(message) }
            }
            if consumed > 0 { buffer = Data(buffer.dropFirst(consumed)); searched -= consumed }
        }
    }
}
