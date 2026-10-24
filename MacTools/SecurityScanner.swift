import Foundation
import Combine
import Darwin

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
    var reusedFiles: Int? = nil
    var excludedFiles: Int? = nil
    var limitedFiles: Int? = nil
    var emptyFiles: Int? = nil
    var removedPaths: [String]? = nil
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
    private enum CodingKeys: String,CodingKey { case exitCode,output,cancelled,reusedFiles,excludedFiles,limitedFiles,emptyFiles,removedPaths }
    init(exitCode:Int32,output:String,cancelled:Bool,reusedFiles:Int? = nil,excludedFiles:Int? = nil,limitedFiles:Int? = nil,emptyFiles:Int? = nil,removedPaths:[String]? = nil) {
        self.exitCode=exitCode;self.output=output;self.cancelled=cancelled;self.reusedFiles=reusedFiles;self.excludedFiles=excludedFiles;self.limitedFiles=limitedFiles;self.emptyFiles=emptyFiles;self.removedPaths=removedPaths
        parsed = Parsed(output)
    }
    init(from decoder:Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        self.init(exitCode:try c.decode(Int32.self,forKey:.exitCode),output:try c.decode(String.self,forKey:.output),cancelled:try c.decode(Bool.self,forKey:.cancelled),reusedFiles:try c.decodeIfPresent(Int.self,forKey:.reusedFiles),excludedFiles:try c.decodeIfPresent(Int.self,forKey:.excludedFiles),limitedFiles:try c.decodeIfPresent(Int.self,forKey:.limitedFiles),emptyFiles:try c.decodeIfPresent(Int.self,forKey:.emptyFiles),removedPaths:try c.decodeIfPresent([String].self,forKey:.removedPaths))
    }
    var findings: [String] { parsed.findings }
    var items: [SecurityFinding] {
        guard let removedPaths,!removedPaths.isEmpty else { return parsed.items }
        let removed = Set(removedPaths); return parsed.items.filter { !removed.contains($0.path) }
    }
    var scannedFiles: Int { parsed.scannedFiles }
    var hasWarnings: Bool { (excludedFiles ?? 0) > 0 || (limitedFiles ?? 0) > 0 || parsed.warnings }
    var threatCount: Int { items.filter { !$0.isTest && !$0.isLimit }.count }
    var title: String {
        if cancelled { return "Prüfung abgebrochen" }
        if exitCode != 0 && exitCode != 1 { return "Prüfung konnte nicht abgeschlossen werden" }
        if threatCount > 0 { return "Verdächtige Dateien gefunden" }
        if hasWarnings { return "Prüfung mit Einschränkungen" }
        if items.contains(where: \.isTest) { return "Testdatei erkannt – Schutzprüfung erfolgreich" }
        if !(removedPaths ?? []).isEmpty && items.isEmpty { return "Gemeldete Dateien entfernt" }
        if exitCode == 1 { return "Die Engine meldet einen Fund – Details prüfen" }
        if scannedFiles == 0 { return "Keine Dateien geprüft" }
        return "Keine Bedrohung im geprüften Bereich erkannt"
    }
    var explanation: String {
        if cancelled { return "Die Prüfung wurde gestoppt. Einige Dateien wurden noch nicht geprüft." }
        if exitCode != 0 && exitCode != 1 { return "Es liegt kein vollständiges Ergebnis vor. Aktualisiere die Schutzdaten und starte die Prüfung erneut." }
        if threatCount > 0 { return "Öffne diese Dateien vorerst nicht. Prüfe ihren Ursprung. Bei Unsicherheit kannst du sie in den Papierkorb verschieben." }
        if hasWarnings { return "Ein Teil der Dateien konnte nicht vollständig geprüft werden. Das Ergebnis gilt nur für die tatsächlich geprüften Dateien." }
        if items.contains(where: \.isTest) { return "Die harmlose EICAR-Testdatei wurde erkannt. Sie dient zur Prüfung des Virenschutzes und ist kein echter Virus." }
        if !(removedPaths ?? []).isEmpty && items.isEmpty { return "Die ausgewählten Dateien wurden aus dem Scan-Ergebnis entfernt. Die übrigen Dateien benötigen dafür keinen neuen Scan." }
        if scannedFiles == 0 { return "Im gewählten Bereich wurden keine Dateien geprüft. Wähle einen anderen Ordner oder prüfe die Zugriffsrechte." }
        return "In diesem Scan wurde keine bekannte Bedrohung gefunden. Eine Prüfung kann neue oder unbekannte Schadsoftware übersehen."
    }
}

/// Runs a local ClamAV process without a shell or any remove/move options.
final class ClamAVRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Process] = []
    private var cancelled = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        for process in processes where process.isRunning { process.terminate() }
    }

    func run(executable: URL, root: URL, extraArguments: [String] = []) throws -> SecurityReport {
        try runProcess(executable: executable, arguments: ["--recursive", "--infected", "--follow-dir-symlinks=0",
                           "--follow-file-symlinks=0", "--cross-fs=no", "--alert-exceeds-max=yes",
                           "--fail-if-cvd-older-than=7"] + extraArguments + ["--", root.path])
    }

    func runProcess(executable: URL, arguments: [String], progress: @Sendable (Int) -> Void = { _ in },
                    activity: @Sendable (String) -> Void = { _ in }) throws -> SecurityReport {
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
                      extraArguments: [String] = [], maximumWorkers: Int = 4, progress: @escaping @Sendable (String) -> Void = { _ in },
                      fileProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) throws -> SecurityReport {
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-virus-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: list) }
        let proof = ScanFingerprintProof(url: proofURL)
        var reusedPaths: Set<String> = []
        var reusedGroups: [(original: DiskFile, digest: String, copies: [DiskFile])] = []
        if let proof {
            for (groupIndex, group) in inventory.duplicates.enumerated() {
                if groupIndex % 256 == 0 { progress("Virenprüfung vorbereiten · Identische Inhalte zuordnen · \(groupIndex.formatted()) / \(inventory.duplicates.count.formatted()) Gruppen") }
                guard (group.files.first?.bytes ?? 0) > 0, (group.files.first?.bytes ?? 0) <= 2_147_483_648 else { continue }
                lock.lock(); let stopped = cancelled; lock.unlock(); if stopped { throw CancellationError() }
                guard let original = group.files.first(where: { proof.matches($0, digest: group.id) }) else { continue }
                var copies: [DiskFile] = []
                for (index, copy) in group.files.enumerated() where copy.path != original.path {
                    if index % 512 == 0 { lock.lock(); let stopped = cancelled; lock.unlock(); if stopped { throw CancellationError() } }
                    if proof.matches(copy, digest: group.id) { reusedPaths.insert(copy.path); copies.append(copy) }
                }
                if !copies.isEmpty { reusedGroups.append((original, group.id, copies)) }
            }
        }
        FileManager.default.createFile(atPath: list.path, contents: nil)
        let handle = try FileHandle(forWritingTo: list)
        var buffer = Data(), planned = 0, excluded = inventory.omissions?.unavailable ?? 0, limited = 0, empty = 0
        do {
            for (index, file) in inventory.files.reversed().enumerated() {
                if index % 4096 == 0 {
                    lock.lock(); let stopped = cancelled; lock.unlock(); if stopped { throw CancellationError() }
                    progress("Virenprüfung vorbereiten · \(index.formatted()) / \(inventory.files.count.formatted()) Dateien")
                    fileProgress(index, inventory.files.count)
                }
                if reusedPaths.contains(file.path) { continue }
                var info = stat()
                guard !file.path.contains("\n"), lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                      info.st_flags & UInt32(SF_DATALESS) == 0 else { excluded += 1; continue }
                if info.st_size == 0 { empty += 1; continue }
                // Mirror the explicit ClamAV per-file limit, reporting these files
                // as unexamined rather than accepting its assumed-clean shortcut.
                if info.st_size > 2_147_483_648 { limited += 1; continue }
                buffer.append(Data((file.path + "\n").utf8)); planned += 1
                if buffer.count >= 64 * 1024 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
            }
            try handle.write(contentsOf: buffer); try handle.close()
        } catch { try? handle.close(); throw error }
        progress("Virenprüfung · Engine starten · \(planned.formatted()) Dateien")
        fileProgress(0, planned)
        if planned == 0 { return SecurityReport(exitCode: 0, output: "Scanned files: 0\n", cancelled: false, excludedFiles: excluded, limitedFiles: limited, emptyFiles: empty) }
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
                let result = try self.runProcess(executable: executable, arguments: ["--verbose", "--follow-dir-symlinks=0", "--follow-file-symlinks=0",
                    "--alert-exceeds-max=yes", "--max-filesize=2G", "--max-scansize=400M", "--max-scantime=30000", "--fail-if-cvd-older-than=7", "--file-list=\(lists[index].path)"] + extraArguments,
                    progress: { aggregate.update(worker: index, completed: $0) },
                    activity: { aggregate.activity(worker: index, name: $0) })
                aggregate.finish(worker: index, report: result)
            } catch { aggregate.fail(error) }
        }
        let report = try aggregate.report()
        var output = report.output, accepted = 0
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
                accepted += matching.count; excluded += group.copies.count - matching.count
                for copy in matching {
                    for finding in findings[group.original.path] ?? [] { output += "\n\(copy.path): \(finding.signature) FOUND" }
                }
            }
        }
        return SecurityReport(exitCode: report.exitCode, output: output, cancelled: report.cancelled, reusedFiles: accepted, excludedFiles: excluded, limitedFiles: limited, emptyFiles: empty)
    }

    static func executable() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ClamAV/bin/clamscan"),
           FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return nil
    }

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
    @Published private(set) var completedAt: Date?
    @Published private(set) var restoredReport = false

    init(directory: URL = VideoLibraryStore.appSupportDirectory) {
        reportURL = directory.appendingPathComponent("last-virus-scan.plist")
        removalSubscription = FileActions.shared.removals.sink { [weak self] change in
            guard let self, self.acceptsFileChanges else { return }
            self.applyRemoved(paths: change.paths)
        }
        refresh()
        if let data = try? Data(contentsOf: reportURL), let saved = try? PropertyListDecoder().decode(SavedScan.self, from: data) {
            report = saved.report; scannedRoot = saved.root; completedAt = saved.date
            restoredReport = true; status = saved.report.title
        }
    }

    /// Keep the original scan output for history, but remove handled paths
    /// from the actionable list immediately and persist without running engines.
    func applyRemoved(paths: [String]) {
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

    func start(root: URL, inventory: DiskScanResult? = nil) {
        refresh()
        guard !isScanning, !isUpdating, let executable else {
            status = "Die ClamAV-Engine fehlt im App-Paket."
            return
        }
        guard hasSignatures else { status = "Die Schutzdaten fehlen. Bitte zuerst aktualisieren."; issue = status; return }
        issue = nil
        technicalLog = ""
        isScanning = true
        progressFraction = nil
        status = "Deine Dateien werden geprüft …"
        let worker = ClamAVRunner()
        runner = worker
        Task {
            do {
                let value = try await Task.detached(priority: .utility) {
                    let arguments = ["--database=\(Self.databaseDirectory.path)", "--cvdcertsdir=\(executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("etc/certs").path)"]
                    if let inventory {
                        return try worker.runInventory(executable: executable, inventory: inventory,
                            proofURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LiveWallpaper/file-hashes.sqlite"),
                            extraArguments: arguments, progress: { update in Task { @MainActor [weak self] in if self?.isScanning == true { self?.status = update } } }, fileProgress: { current, total in
                                Task { @MainActor [weak self] in if self?.isScanning == true { self?.progressFraction = total > 0 ? min(1, Double(current) / Double(total)) : nil } } })
                    }
                    return try worker.run(executable: executable, root: root, extraArguments: arguments)
                }.value
                if !value.cancelled {
                    report = value; scannedRoot = root; completedAt = Date(); restoredReport = false
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

    func cancel() { runner?.cancel(); status = isUpdating ? "Signaturupdate wird abgebrochen …" : "Virenscan wird abgebrochen …" }
}
