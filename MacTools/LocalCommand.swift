import Foundation
import Darwin

struct LocalCommandResult {
    let status: Int32
    let output: String
    let error: String
}

enum LocalCommand {
    /// File-backed output keeps a verbose or disconnected CLI from blocking either pipe.
    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 12) async -> LocalCommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-command-" + UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let stdout = directory.appendingPathComponent("out"), stderr = directory.appendingPathComponent("err")
                    FileManager.default.createFile(atPath: stdout.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    FileManager.default.createFile(atPath: stderr.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    let out = try FileHandle(forWritingTo: stdout), err = try FileHandle(forWritingTo: stderr)
                    defer { try? out.close(); try? err.close() }
                    let process = Process(); process.executableURL = executable; process.arguments = arguments
                    var environment = ProcessInfo.processInfo.environment
                    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
                    process.environment = environment; process.standardOutput = out; process.standardError = err
                    try process.run()
                    let deadline = DispatchWorkItem {
                        if process.isRunning {
                            process.terminate()
                            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                        }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                    process.waitUntilExit(); deadline.cancel()
                    let output = String(data: (try? Data(contentsOf: stdout)) ?? Data(), encoding: .utf8) ?? ""
                    let error = String(data: (try? Data(contentsOf: stderr)) ?? Data(), encoding: .utf8) ?? ""
                    continuation.resume(returning: LocalCommandResult(status: process.terminationStatus, output: output, error: error))
                } catch { continuation.resume(returning: LocalCommandResult(status: -1, output: "", error: error.localizedDescription)) }
            }
        }
    }
}
