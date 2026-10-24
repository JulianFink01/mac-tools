import Foundation
import Darwin
final class TerminalCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var code: Int32?
    func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
    func finish(_ value: Int32) { lock.lock(); code = value; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
    var exited: Bool { lock.lock(); defer { lock.unlock() }; return code != nil }
}
final class TerminalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: (@Sendable () -> Void)?
    private var open = false
    private var calls = 0
    private var bytes = 0
    func accept(_ data: Data, _ acknowledge: @escaping @Sendable () -> Void) {
        lock.lock(); calls += 1; bytes += data.count
        if !open { held = acknowledge; lock.unlock() } else { lock.unlock(); acknowledge() }
    }
    func release() { lock.lock(); open = true; let callback = held; held = nil; lock.unlock(); callback?() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var size: Int { lock.lock(); defer { lock.unlock() }; return bytes }
}
@main struct TerminalChecks {
    static func wait(_ check: () -> Bool) async throws { for _ in 0..<500 { if check() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; preconditionFailure("PTY timeout") }
    static func main() async throws {
        let settings = SSHConnectionSettings(destination: "example-alias", identityFile: "~/.ssh/test key")
        precondition(settings.valid && settings.arguments.last == "example-alias")
        precondition(settings.arguments.contains(NSString(string: "~/.ssh/test key").expandingTildeInPath))
        precondition(!SSHConnectionSettings(destination: "-oProxyCommand=bad", identityFile: "").valid)
        precondition(!SSHConnectionSettings(destination: "host\ncommand", identityFile: "").valid)
        let capture = TerminalCapture()
        let script = "stty -echo; trap 'printf INTERRUPTED; exit 0' INT; printf READY; IFS= read -r line; printf 'RESULT:%s\\n' \"$line\"; stty size; while :; do sleep 1; done"
        let process = try TerminalProcess(executable: "/bin/sh", arguments: ["-c",script], output: { capture.append($0); $1() }, exit: { capture.finish($0) })
        try await wait { capture.text.contains("READY") }
        process.resize(columns: 112, rows: 37)
        process.send(Data("Grüße vom Terminal\n".utf8))
        try await wait { capture.text.contains("RESULT:Grüße vom Terminal") && capture.text.contains("37 112") }
        process.send(Data([3]))
        try await wait { capture.exited }
        precondition(capture.text.contains("INTERRUPTED")); process.stop()
        print("PASS: controlling PTY, interactive UTF-8 input/output, real window resize and Ctrl-C")
        let a = TerminalCapture(), b = TerminalCapture()
        let first = try TerminalProcess(executable: "/bin/sh", arguments: ["-c","printf FIRST; read x; printf DONE1"], output: { a.append($0); $1() }, exit: { a.finish($0) })
        let second = try TerminalProcess(executable: "/bin/sh", arguments: ["-c","printf SECOND; read x; printf DONE2"], output: { b.append($0); $1() }, exit: { b.finish($0) })
        try await wait { a.text.contains("FIRST") && b.text.contains("SECOND") }
        first.stop(); try await wait { a.exited }
        precondition(!b.exited); second.send(Data("continue\n".utf8)); try await wait { b.exited }; second.stop()
        precondition(b.text.contains("DONE2") && !a.text.contains("DONE2"))
        print("PASS: independent sessions; closing one leaves the other usable; children reaped")
        let gate = TerminalGate(), floodExit = TerminalCapture()
        let flood = try TerminalProcess(executable: "/bin/sh", arguments: ["-c","dd if=/dev/zero bs=4096 count=256 2>/dev/null"], output: { gate.accept($0, $1) }, exit: { floodExit.finish($0) })
        try await wait { gate.count > 0 }; try await Task.sleep(nanoseconds: 100_000_000)
        precondition(gate.count == 1 && gate.size <= 32768, "Renderer backpressure must bound queued output")
        gate.release(); try await wait { gate.size == 1_048_576 && floodExit.exited }; flood.stop()
        print("PASS: slow renderer queues at most one 32 KB chunk; 1 MB output resumes without loss")
    }
}
