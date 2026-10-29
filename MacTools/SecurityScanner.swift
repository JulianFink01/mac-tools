import Foundation
import Combine
import Darwin
import SQLite3
import CryptoKit

struct SecurityFinding: Identifiable, Codable, Sendable {
    var id: String { path + signature }
    let path: String
    let signature: String
    var isTest: Bool { signature.localizedCaseInsensitiveContains("eicar") }
    var isLimit: Bool { signature.contains("Heuristics.Limits.Exceeded") }
    var url: URL { URL(fileURLWithPath: path, isDirectory: false) }
}

struct SecurityReport: Codable, Sendable {
    let exitCode: Int32
    let output: String
    let cancelled: Bool
    var unchangedFiles: Int? = nil
    var reusedFiles: Int? = nil
    var excludedFiles: Int? = nil
    var limitedFiles: Int? = nil
    var emptyFiles: Int? = nil
    var removedPaths: [String]? = nil
    var cloudFiles: Int? = nil
    var missingFiles: Int? = nil
    private struct Parsed: Sendable {
        var findings: [String] = []
        var items: [SecurityFinding] = []
        var scannedFiles = 0
        var warnings = false
        init(_ output:String) {
            var found: [String] = [],entries: [SecurityFinding] = [],scanned = 0,warned = false,readCount = false
            output.enumerateLines { line,_ in
                if line.hasSuffix(" FOUND") {
                    found.append(line)
                    let body = line.dropLast(" FOUND".count)
                    if let separator = body.range(of:": ",options:.backwards) { entries.append(SecurityFinding(path:String(body[..<separator.lowerBound]),signature:String(body[separator.upperBound...]))) }
                }
                if !readCount,line.hasPrefix("Scanned files:") { readCount = true; scanned = Int(line.dropFirst("Scanned files:".count).trimmingCharacters(in:.whitespaces)) ?? 0 }
                let lower = line.trimmingCharacters(in:.whitespaces).lowercased()
                if lower.hasPrefix("warning:") || lower.hasPrefix("error:") || lower.hasPrefix("libclamav warning:") || lower.hasPrefix("libclamav error:") || line.contains("Heuristics.Limits.Exceeded") { warned = true }
            }
            findings=found;items=entries;scannedFiles=scanned;warnings=warned
        }
    }
    private let parsed: Parsed
    private enum CodingKeys: String,CodingKey { case exitCode,output,cancelled,unchangedFiles,reusedFiles,excludedFiles,limitedFiles,emptyFiles,removedPaths,cloudFiles,missingFiles }
    init(exitCode:Int32,output:String,cancelled:Bool,reusedFiles:Int? = nil,excludedFiles:Int? = nil,limitedFiles:Int? = nil,emptyFiles:Int? = nil,removedPaths:[String]? = nil,cloudFiles:Int? = nil,missingFiles:Int? = nil,unchangedFiles:Int? = nil) {
        self.exitCode=exitCode;self.output=output;self.cancelled=cancelled;self.reusedFiles=reusedFiles;self.excludedFiles=excludedFiles;self.limitedFiles=limitedFiles;self.emptyFiles=emptyFiles;self.removedPaths=removedPaths
        parsed = Parsed(output)
        self.cloudFiles = cloudFiles; self.missingFiles = missingFiles; self.unchangedFiles = unchangedFiles
    }
    init(from decoder:Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        self.init(exitCode:try c.decode(Int32.self,forKey:.exitCode),output:try c.decode(String.self,forKey:.output),cancelled:try c.decode(Bool.self,forKey:.cancelled),reusedFiles:try c.decodeIfPresent(Int.self,forKey:.reusedFiles),excludedFiles:try c.decodeIfPresent(Int.self,forKey:.excludedFiles),limitedFiles:try c.decodeIfPresent(Int.self,forKey:.limitedFiles),emptyFiles:try c.decodeIfPresent(Int.self,forKey:.emptyFiles),removedPaths:try c.decodeIfPresent([String].self,forKey:.removedPaths),cloudFiles:try c.decodeIfPresent(Int.self,forKey:.cloudFiles),missingFiles:try c.decodeIfPresent(Int.self,forKey:.missingFiles),unchangedFiles:try c.decodeIfPresent(Int.self,forKey:.unchangedFiles))
    }
    var findings: [String] { parsed.findings }
    var items: [SecurityFinding] {
        guard let removedPaths,!removedPaths.isEmpty else { return parsed.items }
        let removed = Set(removedPaths); return parsed.items.filter { !removed.contains($0.path) }
    }
    var scannedFiles: Int { parsed.scannedFiles }
    var hasWarnings: Bool { (excludedFiles ?? 0) > 0 || (limitedFiles ?? 0) > 0 || parsed.warnings }
    var threatCount: Int { items.filter { !$0.isTest && !$0.isLimit }.count }
    var hasCriticalIssue: Bool { !cancelled && exitCode != 0 && exitCode != 1 }
    var title: String {
        if cancelled { return "Prüfung abgebrochen" }
        if exitCode != 0 && exitCode != 1 { return "Prüfung konnte nicht abgeschlossen werden" }
        if threatCount > 0 { return "Verdächtige Dateien gefunden" }
        if items.contains(where: \.isTest) { return "Testdatei erkannt – Schutzprüfung erfolgreich" }
        if !(removedPaths ?? []).isEmpty && items.isEmpty { return "Gemeldete Dateien entfernt" }
        if exitCode == 1 && !hasWarnings { return "Die Engine meldet einen Fund – Details prüfen" }
        if scannedFiles == 0 && (unchangedFiles ?? 0) == 0 { return "Keine Dateien geprüft" }
        return "Keine Bedrohung im geprüften Bereich erkannt"
    }
    var explanation: String {
        if cancelled { return "Die Prüfung wurde gestoppt. Einige Dateien wurden noch nicht geprüft." }
        if exitCode != 0 && exitCode != 1 { return "Es liegt kein vollständiges Ergebnis vor. Aktualisiere die Schutzdaten und starte die Prüfung erneut." }
        if threatCount > 0 { return "Öffne diese Dateien vorerst nicht. Prüfe ihren Ursprung. Bei Unsicherheit kannst du sie in den Papierkorb verschieben." }
        if items.contains(where: \.isTest) { return "Die harmlose EICAR-Testdatei wurde erkannt. Sie dient zur Prüfung des Virenschutzes und ist kein echter Virus." }
        if !(removedPaths ?? []).isEmpty && items.isEmpty { return "Die ausgewählten Dateien wurden aus dem Scan-Ergebnis entfernt. Die übrigen Dateien benötigen dafür keinen neuen Scan." }
        if scannedFiles == 0 && (unchangedFiles ?? 0) > 0 { return "Seit der letzten Prüfung unverändert. Die gespeicherten Ergebnisse gelten für dieselbe Engine und dieselben Virensignaturen." }
        if scannedFiles == 0 { return "Im gewählten Bereich wurden keine Dateien geprüft. Wähle einen anderen Ordner oder prüfe die Zugriffsrechte." }
        return "In diesem Scan wurde keine bekannte Bedrohung gefunden. Eine Prüfung kann neue oder unbekannte Schadsoftware übersehen."
    }
}

/// Runs a local ClamAV process without a shell or any remove/move options.
final class ClamAVRunner: @unchecked Sendable {
    // Preserve finite resource budgets while allowing normal SDK archives and ML files.
    // MaxFileSize is capped at 2 GiB inside ClamAV; larger files remain scan details.
    static let scanArguments = ["--follow-dir-symlinks=0", "--follow-file-symlinks=0", "--alert-exceeds-max=yes",
                                "--max-filesize=2G", "--max-scansize=4G", "--max-scantime=120000",
                                "--max-files=100000", "--max-recursion=64", "--fail-if-cvd-older-than=7"]
    private let lock = NSLock()
    private var processes: [Process] = []
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        for process in processes where process.isRunning { process.terminate() }
    }

    func run(executable: URL, root: URL, extraArguments: [String] = []) throws -> SecurityReport {
        try runProcess(executable: executable, arguments: ["--recursive", "--infected", "--cross-fs=no"]
                           + Self.scanArguments + extraArguments + ["--", root.path])
    }

    func recheckFindings(executable: URL?, paths: [String], extraArguments: [String] = []) throws -> CurrentSecurityFindings {
        var files: [DiskFile] = [], pending: [String] = []
        for path in Set(paths).sorted() {
            var info = stat()
            if lstat(path, &info) != 0 {
                if errno != ENOENT && errno != ENOTDIR { pending.append(path) }
                continue
            }
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_flags & UInt32(SF_DATALESS) == 0,
                  info.st_size <= 2_147_483_648, let file = try? DiskFile.snapshot(at: URL(fileURLWithPath: path)) else {
                pending.append(path); continue
            }
            files.append(file)
        }
        guard !files.isEmpty, let executable else {
            return CurrentSecurityFindings(items: [], pendingPaths: pending + files.map(\.path), checkedAt: Date())
        }
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-recheck-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: list) }
        let safe = files.filter { !$0.path.contains("\n") }
        pending += files.filter { $0.path.contains("\n") }.map(\.path)
        guard !safe.isEmpty else { return CurrentSecurityFindings(items: [], pendingPaths: pending, checkedAt: Date()) }
        try Data((safe.map(\.path).joined(separator: "\n") + "\n").utf8).write(to: list)
        let result = try runProcess(executable: executable, arguments: Self.scanArguments + ["--infected", "--file-list=\(list.path)"] + extraArguments)
        var current: [SecurityFinding] = []
        for file in safe {
            guard let after = try? DiskFile.snapshot(at: file.url), file.identity == after.identity,
                  file.bytes == after.bytes, file.modified == after.modified else {
                var info = stat()
                if lstat(file.path, &info) == 0 || (errno != ENOENT && errno != ENOTDIR) { pending.append(file.path) }
                continue
            }
            let matches = result.items.filter { $0.path == file.path }
            current += matches.filter { !$0.isLimit }
            if matches.contains(where: \.isLimit) || result.cancelled || result.hasCriticalIssue
                || result.output.components(separatedBy: .newlines).contains(where: { $0.contains(file.path) && ($0.hasPrefix("WARNING:") || $0.hasSuffix(" ERROR")) }) {
                pending.append(file.path)
            }
        }
        return CurrentSecurityFindings(items: current, pendingPaths: pending, checkedAt: Date())
    }

    func runProcess(executable: URL, arguments: [String], progress: @Sendable (Int) -> Void = { _ in },
                    activity: @Sendable (String) -> Void = { _ in },
                    verdict: @Sendable (String, String) -> Void = { _, _ in }) throws -> SecurityReport {
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        let certificates = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("etc/certs")
        if FileManager.default.fileExists(atPath: certificates.path) {
            var environment = ProcessInfo.processInfo.environment
            environment["CVD_CERTS_DIR"] = certificates.path
            child.environment = environment
        }
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        processes.append(child)
        do { try child.run() } catch { processes.removeAll { $0 === child }; lock.unlock(); throw error }
        lock.unlock()
        // Drain continuously so a verbose process cannot fill the pipe and deadlock.
        var output = Data()
        var truncated = false
        var pending = Data(), completed = 0
        var lastProgress = Date.distantPast
        var readBuffer = [UInt8](repeating: 0, count: 8192)
        var lastActivity = Date.distantPast
        while true {
            // FileHandle.read(upToCount:) may wait to fill the requested buffer
            // on this macOS runtime. POSIX read returns the currently available
            // pipe bytes, keeping file progress live even when the next file is slow.
            let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &readBuffer, readBuffer.count)
            if count < 0 { if errno == EINTR { continue }; throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if count == 0 { break }
            pending.append(contentsOf: readBuffer.prefix(count))
            while let newline = pending.firstIndex(of: 10) {
                let line = pending.prefix(through: newline)
                let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines)
                let clean = text.hasSuffix(": OK") || text.hasSuffix(": Empty file")
                if text.hasPrefix("Scanning "), Date().timeIntervalSince(lastActivity) > 0.2 {
                    activity(URL(fileURLWithPath: String(text.dropFirst("Scanning ".count))).lastPathComponent)
                    lastActivity = Date()
                }
                if clean, let separator = text.range(of: ": ", options: .backwards) {
                    verdict(String(text[..<separator.lowerBound]), "")
                } else if text.hasSuffix(" FOUND") {
                    let body = text.dropLast(" FOUND".count)
                    if let separator = body.range(of: ": ", options: .backwards) {
                        verdict(String(body[..<separator.lowerBound]), String(body[separator.upperBound...]))
                    }
                }
                if clean || text.hasSuffix(" FOUND") || text.hasSuffix(" ERROR") {
                    completed += 1
                    if Date().timeIntervalSince(lastProgress) > 0.2 { progress(completed); lastProgress = Date() }
                }
                if !clean && !text.hasPrefix("Scanning ") { output.append(line) }
                pending.removeSubrange(...newline)
            }
            if pending.count > 1_048_576 { output.append(pending); pending.removeAll(keepingCapacity: true) }
            if output.count > 1_048_576 {
                output.removeFirst(output.count - 1_048_576)
                truncated = true
            }
        }
        output.append(pending)
        if output.count > 1_048_576 { output.removeFirst(output.count - 1_048_576); truncated = true }
        progress(completed)
        child.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled; processes.removeAll { $0 === child }; lock.unlock()
        let text = String(decoding: output, as: UTF8.self)
        return SecurityReport(exitCode: child.terminationStatus,
                              output: (truncated ? "WARNING: Protokoll auf die letzten 1 MB begrenzt.\n" : "") + text,
                              cancelled: wasCancelled)
    }

    /// Use the disk inventory; load signatures once and avoid a second tree walk.
    /// Currently identical files share one content check, backed by the
    /// disk scan's complete hash proof. No extension-based safety shortcuts.
    func runInventory(executable: URL, inventory: DiskScanResult, proofURL: URL,
                      extraArguments: [String] = [], maximumWorkers: Int = 4, verdictURL: URL? = nil, progress: @escaping @Sendable (String) -> Void = { _ in },
                      fileProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) throws -> SecurityReport {
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-virus-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: list) }
        let verdicts = verdictURL.flatMap { SecurityVerdictCache(url: $0, context: SecurityVerdictCache.context(executable: executable, arguments: extraArguments), reusable: SecurityVerdictCache.signaturesAreFresh(arguments: extraArguments)) }
        let proof = ScanFingerprintProof(url: proofURL)
        var reusedPaths: Set<String> = []
        var reusedGroups: [(original: DiskFile, digest: String, copies: [DiskFile])] = []
        if let proof {
            for (groupIndex, group) in inventory.duplicates.enumerated() {
                if groupIndex % 256 == 0 { progress("Virenprüfung vorbereiten · Identische Inhalte zuordnen · \(groupIndex.formatted()) / \(inventory.duplicates.count.formatted()) Gruppen") }
                guard (group.files.first?.bytes ?? 0) > 0, (group.files.first?.bytes ?? 0) <= 2_147_483_648 else { continue }
                lock.lock(); let stopped = cancelled; lock.unlock(); if stopped { throw CancellationError() }
                guard let original = group.files.first(where: { proof.matches($0, digest: group.id) }) else { continue }
                var originalInfo = stat()
                if lstat(original.path, &originalInfo) == 0, verdicts?.verdict(path: original.path, info: originalInfo) != nil { continue }
                var copies: [DiskFile] = []
                for (index, copy) in group.files.enumerated() where copy.path != original.path {
                    if index % 512 == 0 { lock.lock(); let stopped = cancelled; lock.unlock(); if stopped { throw CancellationError() } }
                    if proof.matches(copy, digest: group.id) {
                        var info = stat()
                        if lstat(copy.path, &info) == 0 { verdicts?.prepare(path: copy.path, info: info) }
                        reusedPaths.insert(copy.path); copies.append(copy)
                    }
                }
                if !copies.isEmpty { reusedGroups.append((original, group.id, copies)) }
            }
        }
        FileManager.default.createFile(atPath: list.path, contents: nil)
        let handle = try FileHandle(forWritingTo: list)
        // Duplicate-hash failures are not antivirus failures. Classify the current
        // file state once instead of inheriting the unrelated inventory counters.
        var buffer = Data(), planned = 0, excluded = 0, cloud = 0, missing = 0, limited = 0, empty = 0, unchanged = 0
        var cachedFindings = ""
        do {
            for (index, file) in inventory.files.reversed().enumerated() {
                if index % 4096 == 0 {
                    lock.lock(); let stopped = cancelled; lock.unlock(); if stopped { throw CancellationError() }
                    progress("Virenprüfung vorbereiten · \(index.formatted()) / \(inventory.files.count.formatted()) Dateien")
                    fileProgress(index, inventory.files.count)
                }
                if reusedPaths.contains(file.path) { continue }
                var info = stat()
                if lstat(file.path, &info) != 0 {
                    if errno == ENOENT || errno == ENOTDIR { missing += 1 } else { excluded += 1 }
                    continue
                }
                guard !file.path.contains("\n"), (info.st_mode & S_IFMT) == S_IFREG else { excluded += 1; continue }
                if info.st_flags & UInt32(SF_DATALESS) != 0 { cloud += 1; continue }
                if info.st_size == 0 { empty += 1; continue }
                // Mirror the explicit ClamAV per-file limit, reporting these files
                // as unexamined rather than accepting its assumed-clean shortcut.
                if info.st_size > 2_147_483_648 { limited += 1; continue }
                if let signature = verdicts?.verdict(path: file.path, info: info) {
                    unchanged += 1
                    if !signature.isEmpty { cachedFindings += "\n\(file.path): \(signature) FOUND" }
                    continue
                }
                verdicts?.prepare(path: file.path, info: info)
                buffer.append(Data((file.path + "\n").utf8)); planned += 1
                if buffer.count >= 64 * 1024 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
            }
            try handle.write(contentsOf: buffer); try handle.close()
        } catch { try? handle.close(); throw error }
        progress("Virenprüfung · Engine starten · \(planned.formatted()) Dateien")
        fileProgress(0, planned)
        if planned == 0 { return SecurityReport(exitCode: cachedFindings.isEmpty ? 0 : 1, output: "Scanned files: 0\n" + cachedFindings, cancelled: false, excludedFiles: excluded, limitedFiles: limited, emptyFiles: empty, cloudFiles: cloud, missingFiles: missing, unchangedFiles: unchanged) }
        // A few long-lived workers load signatures once each. Thousands of
        // short-lived batches would repeatedly pay the engine startup cost.
        let capacity = min(max(1, maximumWorkers), max(1, ProcessInfo.processInfo.activeProcessorCount / 2),
                           max(1, Int(ProcessInfo.processInfo.physicalMemory / (2 * 1024 * 1024 * 1024))))
        let workerCount = min(capacity, max(1, planned / 256))
        let started = Date()
        let aggregate = ParallelScanProgress(workers: workerCount, total: planned, started: started,
                                             progress: progress, fileProgress: fileProgress)
        let lists = (0..<workerCount).map { _ in FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-virus-\(UUID()).txt") }
        defer { for url in lists { try? FileManager.default.removeItem(at: url) } }
        // Stream the prepared list; do not hold millions of paths a second time.
        let input = try FileHandle(forReadingFrom: list)
        var outputs: [FileHandle] = []
        do {
            for url in lists {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                outputs.append(try FileHandle(forWritingTo: url))
            }
            var pending = Data(), buffers = Array(repeating: Data(), count: workerCount), index = 0
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                lock.lock(); let stopped = cancelled; lock.unlock(); if stopped { throw CancellationError() }
                pending.append(chunk)
                var consumed = pending.startIndex
                for newline in pending.indices where pending[newline] == 10 {
                    let slot = index % workerCount
                    buffers[slot].append(pending[consumed...newline]); index += 1; consumed = newline + 1
                    if buffers[slot].count >= 64 * 1024 { try outputs[slot].write(contentsOf: buffers[slot]); buffers[slot].removeAll(keepingCapacity: true) }
                }
                pending.removeSubrange(..<consumed)
            }
            for index in outputs.indices { try outputs[index].write(contentsOf: buffers[index]); try outputs[index].close() }
            try input.close()
        } catch {
            try? input.close(); for handle in outputs { try? handle.close() }; throw error
        }
        aggregate.publish()
        DispatchQueue.concurrentPerform(iterations: workerCount) { index in
            do {
                let result = try self.runProcess(executable: executable, arguments: ["--verbose", "--file-list=\(lists[index].path)"] + Self.scanArguments + extraArguments,
                    progress: { aggregate.update(worker: index, completed: $0) },
                    activity: { aggregate.activity(worker: index, name: $0) }, verdict: { verdicts?.record(path: $0, signature: $1) })
                aggregate.finish(worker: index, report: result)
            } catch { aggregate.fail(error) }
        }
        let report = try aggregate.report()
        var output = report.output + cachedFindings, accepted = 0
        let findings = Dictionary(grouping: report.items, by: \.path)
        if !report.cancelled, report.exitCode == 0 || report.exitCode == 1, let proof {
            for (index, group) in reusedGroups.enumerated() {
                lock.lock(); let stopped = cancelled; lock.unlock(); if stopped { throw CancellationError() }
                if index % 128 == 0 { progress("Virenprüfung abschließen · \(index.formatted()) / \(reusedGroups.count.formatted()) identische Gruppen zuordnen") }
                guard proof.matches(group.original, digest: group.digest) else { excluded += group.copies.count; continue }
                var matching: [DiskFile] = []
                for (copyIndex, copy) in group.copies.enumerated() {
                    if copyIndex % 512 == 0 { lock.lock(); let stopped = cancelled; lock.unlock(); if stopped { throw CancellationError() } }
                    if proof.matches(copy, digest: group.digest) { matching.append(copy) }
                }
                // Validate the original around the whole group; repeated copies
                // do not need millions of redundant metadata/SQLite reads of it.
                guard proof.matches(group.original, digest: group.digest) else { excluded += group.copies.count; continue }
                var originalInfo = stat()
                if lstat(group.original.path, &originalInfo) == 0,
                   let signature = verdicts?.verdict(path: group.original.path, info: originalInfo) {
                    for copy in matching { verdicts?.record(path: copy.path, signature: signature) }
                }
                accepted += matching.count; excluded += group.copies.count - matching.count
                for copy in matching {
                    for finding in findings[group.original.path] ?? [] { output += "\n\(copy.path): \(finding.signature) FOUND" }
                }
            }
        }
        return SecurityReport(exitCode: report.exitCode == 0 && !cachedFindings.isEmpty ? 1 : report.exitCode, output: output, cancelled: report.cancelled, reusedFiles: accepted, excludedFiles: excluded, limitedFiles: limited, emptyFiles: empty, cloudFiles: cloud, missingFiles: missing, unchangedFiles: unchanged)
    }

    static func executable() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ClamAV/bin/clamscan"),
           FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return nil
    }

}

struct CurrentSecurityFindings: Sendable {
    let items: [SecurityFinding]
    let pendingPaths: [String]
    let checkedAt: Date
    var threatCount: Int { items.filter { !$0.isTest }.count }
}

/// Serializes cross-worker counters and retains failures instead of reporting a
/// successful partial scan when one process fails to start or exits with an error.
private final class ParallelScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: [Int]
    private var reports: [SecurityReport?]
    private var failure: Error?
    private var current = "Engine starten"
    private var lastPublish = Date.distantPast
    private let total: Int
    private let started: Date
    private let progress: @Sendable (String) -> Void
    private let fileProgress: @Sendable (Int, Int) -> Void
    init(workers: Int, total: Int, started: Date, progress: @escaping @Sendable (String) -> Void,
         fileProgress: @escaping @Sendable (Int, Int) -> Void) {
        completed = Array(repeating: 0, count: workers); reports = Array(repeating: nil, count: workers)
        self.total = total; self.started = started; self.progress = progress; self.fileProgress = fileProgress
    }
    func update(worker: Int, completed count: Int) {
        lock.lock(); defer { lock.unlock() }; completed[worker] = count; publishLocked()
    }
    func activity(worker: Int, name: String) {
        lock.lock(); defer { lock.unlock() }; current = name; publishLocked()
    }
    func publish() { lock.lock(); defer { lock.unlock() }; publishLocked(force: true) }
    private func publishLocked(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPublish) >= 0.25 else { return }
        lastPublish = Date()
        let count = completed.reduce(0, +)
        let rate = Int(Double(count) / max(1, Date().timeIntervalSince(started)))
        progress("Virenprüfung · \(count.formatted()) / \(total.formatted()) Dateien · \(reports.count) Worker · \(rate.formatted()) Dateien/s · \(current)")
        fileProgress(count, total)
    }
    func finish(worker: Int, report: SecurityReport) {
        lock.lock(); defer { lock.unlock() }; reports[worker] = report; publishLocked(force: true)
    }
    func fail(_ error: Error) { lock.lock(); defer { lock.unlock() }; if failure == nil { failure = error } }
    func report() throws -> SecurityReport {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        let values = reports.compactMap { $0 }
        guard values.count == reports.count else { throw CocoaError(.fileReadUnknown) }
        let failed = values.first { $0.exitCode != 0 && $0.exitCode != 1 }
        let exitCode = failed?.exitCode ?? (values.contains { $0.exitCode == 1 } ? 1 : 0)
        let count = values.reduce(0) { $0 + $1.scannedFiles }
        let output = "Scanned files: \(count)\nWorkers: \(values.count)\nTime: \(Date().timeIntervalSince(started)) sec\n" + values.enumerated().map {
            "\n--- Worker \($0.offset + 1) ---\n" + $0.element.output
        }.joined()
        return SecurityReport(exitCode: exitCode, output: output, cancelled: values.contains { $0.cancelled })
    }
}

@MainActor
final class SecurityScanStore: ObservableObject {
    static let shared = SecurityScanStore()
    @Published private(set) var isScanning = false
    @Published private(set) var isUpdating = false
    @Published private(set) var progressFraction: Double?
    @Published private(set) var technicalLog = ""
    @Published private(set) var issue: String?
    @Published private(set) var report: SecurityReport?
    @Published private(set) var status = "Virenscan wurde noch nicht ausgeführt."
    @Published private(set) var executable = ClamAVRunner.executable()
    @Published private(set) var scannedRoot: URL?
    @Published private(set) var signatureStatus = "Signaturen werden geprüft."
    private var runner: ClamAVRunner?
    nonisolated static let databaseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacTools/ClamAV/database", isDirectory: true)

    private struct SavedScan: Codable { let report: SecurityReport; let root: URL; let date: Date }
    private var removalSubscription: AnyCancellable?
    var acceptsFileChanges = true
    private let reportURL: URL
    private let verdictURL: URL
    @Published private(set) var completedAt: Date?
    @Published private(set) var restoredReport = false
    @Published private(set) var currentFindings: CurrentSecurityFindings?
    @Published private(set) var isCheckingFindings = false
    private var findingGeneration = UUID()
    private var findingRunner: ClamAVRunner?

    func criticalMessages(root: URL) -> [String] {
        var messages: [String] = []
        if let currentFindings, currentFindings.threatCount > 0 { messages.append("\(currentFindings.threatCount) aktuell vorhandene verdächtige Dateien. Details im Virenscan.") }
        if executable == nil { messages.append("Die Virenschutz-Engine fehlt.") }
        if let issue { messages.append(issue) }
        if report?.hasCriticalIssue == true { messages.append("Die Virenprüfung ist fehlgeschlagen. Bitte erneut starten.") }
        if let capacity = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           capacity < 2_000_000_000 { messages.append("Kritisch wenig Speicher: \(diskBytes(Int64(capacity))) frei.") }
        return messages
    }

    func refreshCurrentFindings(legacyPaths: [String] = []) async {
        let paths = (report?.items.filter { !$0.isLimit }.map(\.path) ?? []) + legacyPaths
        if paths.isEmpty { currentFindings = CurrentSecurityFindings(items: [], pendingPaths: [], checkedAt: Date()); return }
        guard !isScanning, !isUpdating, !isCheckingFindings else { return }
        isCheckingFindings = true
        let generation = findingGeneration
        let worker = ClamAVRunner(); findingRunner = worker
        defer { isCheckingFindings = false; findingRunner = nil }
        let executable = self.executable
        do {
            let result = try await Task.detached(priority: .utility) {
                try worker.recheckFindings(executable: executable, paths: paths,
                    extraArguments: ["--database=\(Self.databaseDirectory.path)"])
            }.value
            if findingGeneration == generation { currentFindings = result }
        } catch {
            if findingGeneration == generation {
                currentFindings = CurrentSecurityFindings(items: [], pendingPaths: Array(Set(paths)).sorted(), checkedAt: Date())
                technicalLog = error.localizedDescription
            }
        }
    }

    init(directory: URL = VideoLibraryStore.appSupportDirectory) {
        reportURL = directory.appendingPathComponent("last-virus-scan.plist")
        verdictURL = directory.appendingPathComponent("virus-verdicts.sqlite")
        removalSubscription = FileActions.shared.removals.sink { [weak self] change in
            guard let self, self.acceptsFileChanges else { return }
            self.applyRemoved(paths: change.paths)
        }
        refresh()
        if let data = try? Data(contentsOf: reportURL), let saved = try? PropertyListDecoder().decode(SavedScan.self, from: data) {
            report = saved.report; scannedRoot = saved.root; completedAt = saved.date
            restoredReport = true; status = saved.report.title
            currentFindings = CurrentSecurityFindings(items: [], pendingPaths: saved.report.items.filter { !$0.isLimit }.map(\.path), checkedAt: saved.date)
        }
    }

    /// Keep the original scan output for history, but remove handled paths
    /// from the actionable list immediately and persist without running engines.
    func applyRemoved(paths: [String]) {
        if let currentFindings {
            let canonical = Set(paths.map(DiskScanner.canonicalPath))
            func removed(_ path: String) -> Bool {
                let path = DiskScanner.canonicalPath(path)
                return canonical.contains { path == $0 || path.hasPrefix($0 + "/") }
            }
            self.currentFindings = CurrentSecurityFindings(items: currentFindings.items.filter { !removed($0.path) },
                pendingPaths: currentFindings.pendingPaths.filter { !removed($0) }, checkedAt: currentFindings.checkedAt)
        }
        guard !isScanning, var value = report, let root = scannedRoot, let date = completedAt else { return }
        let canonical = paths.map(DiskScanner.canonicalPath)
        let matching = Set(value.items.map(\.path).filter { candidate in let path = DiskScanner.canonicalPath(candidate); return canonical.contains { path == $0 || path.hasPrefix($0 + "/") } })
        guard !matching.isEmpty else { return }
        value.removedPaths = Array(Set(value.removedPaths ?? []).union(matching)).sorted()
        report = value; status = value.title
        let saved = SavedScan(report: value, root: root, date: date)
        do {
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            try encoder.encode(saved).write(to: reportURL, options: .atomic)
        } catch { technicalLog += "\nBereinigtes Ergebnis konnte nicht gespeichert werden: " + error.localizedDescription }
    }

    func refresh() {
        executable = ClamAVRunner.executable()
        signatureStatus = hasSignatures ? "Lokale Virensignaturen verfügbar. Vor automatischen Scans wird täglich aktualisiert."
            : "Erster Start: Virensignaturen werden per Internet geladen."
    }

    private var hasSignatures: Bool {
        ["daily.cvd", "daily.cld"].contains { FileManager.default.fileExists(atPath: Self.databaseDirectory.appendingPathComponent($0).path) }
    }

    func updateSignaturesIfNeeded() async -> Bool {
        do {
            if let baseline = Bundle.main.resourceURL?.appendingPathComponent("ClamAV/database") {
                let database = Self.databaseDirectory
                try await Task.detached(priority: .utility) {
                    try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
                    let items = try FileManager.default.contentsOfDirectory(at: baseline, includingPropertiesForKeys: nil)
                    for item in items where ["cvd", "cld", "sign"].contains(item.pathExtension) {
                        let target = database.appendingPathComponent(item.lastPathComponent)
                        if !FileManager.default.fileExists(atPath: target.path) {
                            try FileManager.default.copyItem(at: item, to: target)
                        }
                    }
                }.value
            }
        } catch { technicalLog = error.localizedDescription; status = "Schutzdaten konnten nicht vorbereitet werden. Bitte erneut versuchen."; issue = status; return false }
        let updated = UserDefaults.standard.object(forKey: "clamavLastUpdate") as? Date ?? .distantPast
        if hasSignatures && Date().timeIntervalSince(updated) < 24 * 3600 { return true }
        if await updateSignatures() { return true }
        // The scanner rejects databases older than seven days itself.
        // Keep the update error visible in the warning history while allowing valid offline scans.
        return hasSignatures
    }

    @discardableResult
    func updateSignatures() async -> Bool {
        guard !isScanning, !isUpdating, let executable else { return false }
        isUpdating = true
        issue = nil
        findingGeneration = UUID(); findingRunner?.cancel()
        technicalLog = ""
        status = "Virensignaturen werden aktualisiert …"
        let worker = ClamAVRunner()
        runner = worker
        defer { isUpdating = false; runner = nil; refresh() }
        do {
            try FileManager.default.createDirectory(at: Self.databaseDirectory, withIntermediateDirectories: true)
            let config = Self.databaseDirectory.deletingLastPathComponent().appendingPathComponent("freshclam.conf")
            let contents = "DatabaseOwner \(NSUserName())\nDatabaseMirror database.clamav.net\nConnectTimeout 15\nReceiveTimeout 60\n"
            try contents.write(to: config, atomically: true, encoding: .utf8)
            let freshclam = executable.deletingLastPathComponent().appendingPathComponent("freshclam")
            let result = try await Task.detached(priority: .utility) {
                try worker.runProcess(executable: freshclam, arguments: ["--config-file=\(config.path)", "--datadir=\(Self.databaseDirectory.path)", "--cvdcertsdir=\(executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("etc/certs").path)", "--stdout"])
            }.value
            if result.cancelled { status = "Signaturupdate abgebrochen."; return false }
            guard result.exitCode == 0, hasSignatures else {
                technicalLog = result.output
                status = "Die Schutzdaten konnten nicht aktualisiert werden. Prüfe die Internetverbindung und versuche es erneut."
                issue = status
                return false
            }
            UserDefaults.standard.set(Date(), forKey: "clamavLastUpdate")
            status = "Virensignaturen sind aktuell."
            return true
        } catch {
            technicalLog = error.localizedDescription
            status = "Die Schutzdaten konnten nicht aktualisiert werden. Bitte erneut versuchen."
            issue = status
            return false
        }
    }

    func start(root: URL, inventory: DiskScanResult? = nil, inventoryIsCurrent: Bool = false) {
        refresh()
        guard !isScanning, !isUpdating, let executable else {
            status = "Die ClamAV-Engine fehlt im App-Paket."
            return
        }
        guard hasSignatures else { status = "Die Schutzdaten fehlen. Bitte zuerst aktualisieren."; issue = status; return }
        issue = nil
        findingGeneration = UUID(); findingRunner?.cancel()
        technicalLog = ""
        isScanning = true
        progressFraction = nil
        status = "Deine Dateien werden geprüft …"
        let worker = ClamAVRunner()
        let verdictURL = self.verdictURL
        runner = worker
        Task {
            do {
                let value = try await Task.detached(priority: .utility) {
                    let arguments = ["--database=\(Self.databaseDirectory.path)", "--cvdcertsdir=\(executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("etc/certs").path)"]
                    let currentInventory: DiskScanResult
                    if inventoryIsCurrent, let inventory { currentInventory = inventory }
                    else {
                        currentInventory = try DiskScanner.scan(root: root, findDuplicates: false, shouldCancel: { worker.isCancelled }, progress: { update in
                            Task { @MainActor [weak self] in if self?.isScanning == true { self?.status = "Änderungen erfassen · \(update.files.formatted()) Dateien" } }
                        })
                    }
                    return try worker.runInventory(executable: executable, inventory: currentInventory,
                        proofURL: verdictURL.deletingLastPathComponent().appendingPathComponent("file-hashes.sqlite"),
                        extraArguments: arguments, verdictURL: verdictURL, progress: { update in Task { @MainActor [weak self] in if self?.isScanning == true { self?.status = update } } }, fileProgress: { current, total in
                            Task { @MainActor [weak self] in if self?.isScanning == true { self?.progressFraction = total > 0 ? min(1, Double(current) / Double(total)) : nil } } })
                }.value
                if !value.cancelled {
                    report = value; scannedRoot = root; completedAt = Date(); restoredReport = false
                    currentFindings = CurrentSecurityFindings(items: value.items.filter { !$0.isLimit }, pendingPaths: [], checkedAt: completedAt!)
                    let saved = SavedScan(report: value, root: root, date: completedAt!)
                    let url = reportURL
                    let saveError = await Task.detached(priority: .utility) { () -> String? in
                        do {
                            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try encoder.encode(saved).write(to: url, options: .atomic)
                            return nil
                        } catch { return error.localizedDescription }
                    }.value
                    if let saveError { technicalLog += "\nErgebnis konnte nicht gespeichert werden: " + saveError }
                }
                status = value.title
            } catch is CancellationError { status = "Virenscan abgebrochen."
            } catch {
                technicalLog = error.localizedDescription
                status = "Die Prüfung konnte nicht gestartet werden. Bitte erneut versuchen."
                issue = status
            }
            isScanning = false
            progressFraction = nil
            runner = nil
        }
    }

    func cancel() { runner?.cancel(); findingRunner?.cancel(); findingGeneration = UUID(); status = isUpdating ? "Signaturupdate wird abgebrochen …" : "Virenscan wird abgebrochen …" }
}

/// Persist only completed verdicts for the exact file generation and scanner policy.
/// SQLite keeps the multi-million-file inventory off a second in-memory path map.
final class SecurityVerdictCache: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var lookup: OpaquePointer?, stage: OpaquePointer?, staged: OpaquePointer?, insert: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var pending = 0
    private let context: String
    private let reusable: Bool

    static func stamp(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(info.st_flags)"
    }
    static func context(executable: URL, arguments: [String]) -> String {
        var parts = ["verdict-v1"] + ClamAVRunner.scanArguments + arguments
        var urls = [executable]
        for argument in arguments where argument.hasPrefix("--database=") {
            let url = URL(fileURLWithPath: String(argument.dropFirst("--database=".count)))
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
                urls += ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                    .filter { ["cvd", "cld", "cud", "hdb", "ndb", "ldb", "ign", "ign2", "cbc", "yar", "yara"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
            } else { urls.append(url) }
        }
        for url in urls {
            var info = stat()
            parts.append(url.path + ":" + (lstat(url.path, &info) == 0 ? stamp(info) : "missing"))
        }
        return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func signaturesAreFresh(arguments: [String]) -> Bool {
        var newest: Double?
        for argument in arguments where argument.hasPrefix("--database=") {
            let url = URL(fileURLWithPath: String(argument.dropFirst("--database=".count)))
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [url]
            for file in files where ["cvd", "cld"].contains(file.pathExtension) {
                guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
                let data = try? handle.read(upToCount: 512); try? handle.close()
                guard let data, let header = String(data: data, encoding: .utf8),
                      let epoch = header.split(separator: ":").dropFirst(8).first.flatMap({ Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { return false }
                newest = max(newest ?? epoch, epoch)
            }
        }
        // ClamAV applies database age to the latest update; main.cvd is intentionally older.
        return newest.map { Date().timeIntervalSince1970 - $0 <= 7 * 86400 } ?? true
    }
    init?(url: URL, context: String, reusable: Bool = true) {
        self.context = context; self.reusable = reusable
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; return nil }
        sqlite3_busy_timeout(db, 3000)
        let setup = "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS verdicts(path TEXT PRIMARY KEY, stamp TEXT NOT NULL, context TEXT NOT NULL, signature TEXT NOT NULL); CREATE TEMP TABLE attempts(path TEXT PRIMARY KEY, stamp TEXT NOT NULL); BEGIN;"
        guard sqlite3_exec(db, setup, nil, nil, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "SELECT signature FROM verdicts WHERE path=? AND stamp=? AND context=?", -1, &lookup, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO attempts VALUES (?,?)", -1, &stage, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "SELECT stamp FROM attempts WHERE path=?", -1, &staged, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO verdicts VALUES (?,?,?,?)", -1, &insert, nil) == SQLITE_OK else {
            for statement in [lookup, stage, staged, insert] { sqlite3_finalize(statement) }; sqlite3_close(db); return nil
        }
    }
    private func bind(_ values: [String], to statement: OpaquePointer?) {
        sqlite3_reset(statement); sqlite3_clear_bindings(statement)
        for (index, value) in values.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
    }
    func verdict(path: String, info: stat) -> String? {
        guard reusable else { return nil }
        lock.lock(); defer { lock.unlock() }
        bind([path, Self.stamp(info), context], to: lookup)
        defer { sqlite3_reset(lookup) }
        guard sqlite3_step(lookup) == SQLITE_ROW, let value = sqlite3_column_text(lookup, 0) else { return nil }
        return String(cString: value)
    }
    func prepare(path: String, info: stat) {
        lock.lock(); defer { lock.unlock() }
        bind([path, Self.stamp(info)], to: stage); sqlite3_step(stage); sqlite3_reset(stage)
    }
    func record(path: String, signature: String) {
        guard !signature.contains("Heuristics.Limits.Exceeded") else { return }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_flags & UInt32(SF_DATALESS) == 0 else { return }
        let stamp = Self.stamp(info)
        lock.lock(); defer { lock.unlock() }
        bind([path], to: staged)
        let matches = sqlite3_step(staged) == SQLITE_ROW && sqlite3_column_text(staged, 0).map { String(cString: $0) == stamp } == true
        sqlite3_reset(staged)
        guard matches else { return } // Mutation while the engine was reading is never cached.
        bind([path, stamp, context, signature], to: insert); sqlite3_step(insert); sqlite3_reset(insert)
        pending += 1
        if pending >= 2000 { sqlite3_exec(db, "COMMIT; BEGIN;", nil, nil, nil); pending = 0 }
    }
    deinit {
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        for statement in [lookup, stage, staged, insert] { sqlite3_finalize(statement) }; sqlite3_close(db)
    }
}
