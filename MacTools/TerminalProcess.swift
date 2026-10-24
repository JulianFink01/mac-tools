import Foundation
import Darwin

/// Owns a real controlling terminal. Output waits for the renderer's write ACK,
/// keeping both native and JavaScript queues bounded even for very noisy commands.
final class TerminalProcess: @unchecked Sendable {
    private let io = DispatchQueue(label: "MacTools.Terminal.read", qos: .userInitiated)
    private let input = DispatchQueue(label: "MacTools.Terminal.input", qos: .userInitiated)
    private let lock = NSLock()
    private var stopped = false
    private var reaped = false
    private var reader: DispatchSourceRead?
    private var watcher: DispatchSourceProcess?
    private var suspended = false
    private var finishedReading = false
    private let master: Int32
    private let writer: Int32
    let pid: Int32
    private let output: @Sendable (Data, @escaping @Sendable () -> Void) -> Void
    private let exit: @Sendable (Int32) -> Void

    init(executable: String, arguments: [String], environment: [String:String] = ProcessInfo.processInfo.environment,
         columns: UInt16 = 100, rows: UInt16 = 30,
         output: @escaping @Sendable (Data, @escaping @Sendable () -> Void) -> Void,
         exit: @escaping @Sendable (Int32) -> Void) throws {
        self.output = output; self.exit = exit
        var env = environment; env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var fd: Int32 = -1
        let child = argv.withUnsafeBufferPointer { a in envp.withUnsafeBufferPointer { e in
            MTStartTerminal(&fd, executable, a.baseAddress, e.baseAddress, columns, rows)
        } }
        guard child > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let inputFD = dup(fd)
        guard inputFD >= 0 else { kill(child, SIGKILL); Darwin.close(fd); waitpid(child, nil, 0); throw POSIXError(.EMFILE) }
        pid = child; master = fd; writer = inputFD
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(writer, F_SETFD, FD_CLOEXEC)
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        reader = readSource
        readSource.setEventHandler { [weak self] in self?.readOne() }
        readSource.setCancelHandler { Darwin.close(fd) }
        let processSource = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: io)
        watcher = processSource
        processSource.setEventHandler { [self] in
            var status: Int32 = 0; while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            self.lock.lock(); self.reaped = true; self.lock.unlock()
            self.watcher?.cancel(); self.watcher = nil
            self.exit((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
        }
        readSource.resume(); processSource.resume()
    }
    private func readOne() {
        var buffer = [UInt8](repeating: 0, count: 32768)
        let count = Darwin.read(master, &buffer, buffer.count)
        if count > 0 {
            reader?.suspend(); suspended = true
            output(Data(buffer.prefix(count))) { [weak self] in
                guard let self else { return }
                self.io.async { if self.suspended { self.suspended = false; self.reader?.resume() } }
            }
        } else if count == 0 || errno != EINTR { finishReading() }
    }
    private func finishReading() {
        guard !finishedReading else { return }; finishedReading = true
        if suspended { suspended = false; reader?.resume() }
        reader?.cancel(); reader = nil
    }
    func send(_ data: Data) {
        input.async { [self] in
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    lock.lock(); let closed = stopped || reaped; lock.unlock(); if closed { break }
                    let count = Darwin.write(writer, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count } else if errno != EINTR { break }
                }
            }
        }
    }
    func resize(columns: UInt16, rows: UInt16) {
        io.async { [self] in if !finishedReading { MTResizeTerminal(master, columns, rows) } }
    }
    func stop() {
        lock.lock(); if stopped { lock.unlock(); return }; stopped = true; let alive = !reaped; lock.unlock()
        if alive { kill(-pid, SIGHUP) }
        io.async { [self] in finishReading() }
        input.async { [self] in Darwin.close(writer) }
        io.asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock(); let alive = !reaped; lock.unlock(); if alive { kill(-pid, SIGKILL) }
        }
    }
}

struct SSHConnectionSettings: Equatable {
    var destination: String
    var identityFile: String
    var valid: Bool {
        !destination.isEmpty && !destination.hasPrefix("-") && !destination.contains(where: { $0.isWhitespace || $0.isNewline || $0.isASCII && $0.asciiValue! < 32 })
    }
    var arguments: [String] {
        var args = ["-tt", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3"]
        if !identityFile.isEmpty { args += ["-i", NSString(string: identityFile).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        return args + [destination]
    }
}
