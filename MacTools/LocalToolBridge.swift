import Foundation
import Darwin

/// Private, same-user IPC shared by the native app and stdio MCP.
/// Requests expire and contain a private per-directory token; no executable or path is accepted.
enum LocalToolBridge {
    static let root = URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_dir), isDirectory: true).appendingPathComponent("Library/Application Support/MacTools/Bridge", isDirectory: true)
    static func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        for folder in [root.deletingLastPathComponent(), root, url] {
            if FileManager.default.fileExists(atPath: folder.path) {
                let info = try FileManager.default.attributesOfItem(atPath: folder.path)
                guard info[.type] as? FileAttributeType == .typeDirectory, (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw BridgeError(message: "Ungültiges lokales Bridge-Verzeichnis.") }
            } else { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
        return url
    }
    static func token(_ directory: URL) throws -> String {
        let url = directory.appendingPathComponent("token")
        if FileManager.default.fileExists(atPath: url.path) {
            let info = try FileManager.default.attributesOfItem(atPath: url.path)
            guard info[.type] as? FileAttributeType == .typeRegular, (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(), let token = String(data: try Data(contentsOf: url), encoding: .utf8), token.count >= 32 else { throw BridgeError(message: "Ungültige Bridge-Anmeldung.") }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return token
        }
        let value = UUID().uuidString + UUID().uuidString
        try Data(value.utf8).write(to: url, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return value
    }
    static func write(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func request(_ action: String, parameters: [String: Any] = [:], destination: String, timeout: TimeInterval = 12) async throws -> [String: Any] {
        let directory = try directory(destination), token = try token(directory)
        let id = UUID().uuidString, now = Date().timeIntervalSince1970
        let request = directory.appendingPathComponent(id + ".request"), response = directory.appendingPathComponent(id + ".response")
        try write(["id": id, "token": token, "action": action, "parameters": parameters, "createdAt": now, "expiresAt": now + timeout], to: request)
        defer { try? FileManager.default.removeItem(at: request); try? FileManager.default.removeItem(at: response) }
        while Date().timeIntervalSince1970 < now + timeout {
            if let data = try? Data(contentsOf: response), let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = result["error"] as? String { throw BridgeError(message: error) }
                return result["result"] as? [String: Any] ?? [:]
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BridgeError(message: "Die lokale Komponente antwortet nicht. Bei einer Steueraktion zuerst den Gerätestatus prüfen; die Bestätigung könnte ausgeblieben sein.")
    }
    struct BridgeError: LocalizedError { let message: String; var errorDescription: String? { message } }
}

@MainActor final class LocalToolBridgeServer {
    private var task: Task<Void, Never>?
    private var inFlight = Set<String>()
    private var directory: URL?
    func start(name: String, handler: @escaping @MainActor (String, [String: Any]) async throws -> [String: Any]) throws {
        guard task == nil else { return }
        let directory = try LocalToolBridge.directory(name), token = try LocalToolBridge.token(directory)
        self.directory = directory
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = Date().timeIntervalSince1970
                for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "request" {
                    let id = url.deletingPathExtension().lastPathComponent
                    guard UUID(uuidString: id) != nil, !self.inFlight.contains(id) else { continue }
                    guard let info = try? FileManager.default.attributesOfItem(atPath: url.path), info[.type] as? FileAttributeType == .typeRegular, (info[.size] as? NSNumber)?.intValue ?? 0 < 1_048_576,
                          let data = try? Data(contentsOf: url), let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], request["id"] as? String == id, request["token"] as? String == token,
                          let created = request["createdAt"] as? Double, let expires = request["expiresAt"] as? Double, created <= now + 2, expires > now, expires - created <= 60,
                          let action = request["action"] as? String else { try? FileManager.default.removeItem(at: url); continue }
                    self.inFlight.insert(id)
                    Task { [weak self] in
                        let response: [String: Any]
                        do {
                            guard Date().timeIntervalSince1970 < expires else { throw LocalToolBridge.BridgeError(message: "Anfrage abgelaufen; nicht ausgeführt.") }
                            response = ["result": try await handler(action, request["parameters"] as? [String: Any] ?? [:])] }
                        catch { response = ["error": error.localizedDescription] }
                        try? LocalToolBridge.write(response, to: directory.appendingPathComponent(id + ".response"))
                        try? FileManager.default.removeItem(at: url); self?.inFlight.remove(id)
                    }
                }
                // Abandoned replies contain home data; remove them after a minute.
                for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where url.pathExtension == "response" {
                    if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(date) > 60 { try? FileManager.default.removeItem(at: url) }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}
