import Foundation
import Darwin

@main
struct SecurityChecks {
    static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("MacTools-process-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        func executable(_ name: String, body: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        let clean = try executable("clean", body: "printf 'Scanned files: 1\\nInfected files: 0\\n'\nexit 0\n")
        let cleanReport = try ClamAVRunner().run(executable: clean, root: root)
        precondition(cleanReport.exitCode == 0 && cleanReport.findings.isEmpty)
        let found = try executable("found", body: "printf '/fixture/test: Eicar-Test-Signature FOUND\\n'\nexit 1\n")
        let foundReport = try ClamAVRunner().run(executable: found, root: root)
        precondition(foundReport.findings.count == 1 && foundReport.exitCode == 1)
        let failure = try executable("failure", body: "printf 'ERROR: database unavailable\\n' >&2\nexit 2\n")
        let failureReport = try ClamAVRunner().run(executable: failure, root: root)
        precondition(failureReport.exitCode == 2 && failureReport.hasWarnings)
        let verbose = try executable("verbose", body: "dd if=/dev/zero bs=1024 count=1200 2>/dev/null\nprintf 'Scanned files: 1\\n'\n")
        let verboseReport = try ClamAVRunner().run(executable: verbose, root: root)
        precondition(verboseReport.hasWarnings && verboseReport.output.utf8.count < 1_049_000)
        let args = try executable("args", body: "printf '%s\\n' \"$@\"\n")
        let literalRoot = URL(fileURLWithPath: "/tmp/space ; $(touch SHOULD_NOT_EXIST)")
        let argReport = try ClamAVRunner().run(executable: args, root: literalRoot)
        precondition(argReport.output.contains(literalRoot.path), "Root passed as one literal argument")
        let wait = try executable("wait", body: "exec /bin/sleep 30\n")
        let runner = ClamAVRunner()
        let task = Task.detached { try runner.run(executable: wait, root: root) }
        try await Task.sleep(nanoseconds: 200_000_000)
        runner.cancel()
        let cancelled = try await task.value
        precondition(cancelled.cancelled)
        let slowOutput = try executable("progress", body: "printf '/fixture/first: OK\\n'\n/bin/sleep 2\nprintf '/fixture/second: OK\\nScanned files: 2\\n'\n")
        let progress = ProgressProbe()
        let progressStart = Date()
        _ = try ClamAVRunner().runProcess(executable: slowOutput, arguments: [], progress: { progress.record($0) })
        let firstDelay = progress.firstDate!.timeIntervalSince(progressStart)
        print("PROGRESS: first completed-file update after \(firstDelay)s")
        precondition(firstDelay < 1, "Progress must arrive while process is running, not only at exit")
        let inventoryRoot = root.appendingPathComponent("inventory")
        try manager.createDirectory(at: inventoryRoot, withIntermediateDirectories: true)
        let large = Data(repeating: 65, count: 2 * 1024 * 1024)
        try large.write(to: inventoryRoot.appendingPathComponent("original.bin"))
        try large.write(to: inventoryRoot.appendingPathComponent("copy.bin"))
        // The standard harmless antivirus test string, assembled to avoid an
        // antivirus flag on this source file itself.
        let eicar = "X5O!P%@AP[4" + "\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
        try Data(eicar.utf8).write(to: inventoryRoot.appendingPathComponent("test.txt"))
        try Data(eicar.utf8).write(to: inventoryRoot.appendingPathComponent("test-copy.txt"))
        let huge = inventoryRoot.appendingPathComponent("sparse-3GB.bin")
        manager.createFile(atPath: huge.path, contents: nil)
        let hugeHandle = try FileHandle(forWritingTo: huge)
        try hugeHandle.truncate(atOffset: 3 * 1024 * 1024 * 1024)
        try hugeHandle.close()
        let cache = root.appendingPathComponent("hashes.sqlite")
        let inventory = try DiskScanner.scan(root: inventoryRoot, findDuplicates: true, cacheURL: cache)
        let inventoryReport = try ClamAVRunner().runInventory(executable: args, inventory: inventory, proofURL: cache)
        precondition(inventoryReport.output.contains("--file-list="))
        precondition(!inventoryReport.output.contains("--recursive"))
        let batchRoot = root.appendingPathComponent("batches")
        try manager.createDirectory(at: batchRoot, withIntermediateDirectories: true)
        var batchFiles: [DiskFile] = []
        for index in 0..<1024 {
            let file = batchRoot.appendingPathComponent("\(index).txt")
            try Data("Safe local scanner fixture \(index)".utf8).write(to: file)
            batchFiles.append(try DiskFile.snapshot(at: file))
        }
        let batches = DiskScanResult(root: batchRoot, completedAt: Date(), files: batchFiles, folders: [], categories: [], duplicates: [], skipped: 0, warningSamples: [], reachedLimit: false, duplicateSearch: false, volumeTotal: 0, volumeFree: 0, bytes: 0, allocatedBytes: 0, redundantBytes: 0)
        let parallel = try executable("parallel", body: "for arg in \"$@\"; do case \"$arg\" in --file-list=*) list=${arg#--file-list=};; esac; done\n/bin/sleep 2\ncount=0\nwhile IFS= read -r path; do printf '%s: OK\\n' \"$path\"; count=$((count + 1)); done < \"$list\"\nprintf 'Scanned files: %s\\n' \"$count\"\n")
        let parallelStarted = Date()
        let parallelReport = try ClamAVRunner().runInventory(executable: parallel, inventory: batches, proofURL: root.appendingPathComponent("missing.sqlite"), maximumWorkers: 4)
        precondition(parallelReport.scannedFiles == 1024 && parallelReport.exitCode == 0)
        precondition(Date().timeIntervalSince(parallelStarted) < 5, "Workers must overlap, not run sequentially")
        print("PASS: bounded parallel workers, aggregate progress/results, all 1,024 paths checked once in \(Date().timeIntervalSince(parallelStarted))s")
        let batchFailure = try executable("batch-failure", body: "printf 'ERROR: engine unavailable\\n'\nexit 2\n")
        let batchFailureReport = try ClamAVRunner().runInventory(executable: batchFailure, inventory: batches, proofURL: root.appendingPathComponent("missing.sqlite"))
        precondition(batchFailureReport.exitCode == 2 && batchFailureReport.hasWarnings)
        let batchRunner = ClamAVRunner()
        let batchTask = Task.detached { try batchRunner.runInventory(executable: wait, inventory: batches, proofURL: root.appendingPathComponent("missing.sqlite")) }
        try await Task.sleep(nanoseconds: 400_000_000)
        batchRunner.cancel()
        let batchCancelled = try await batchTask.value
        precondition(batchCancelled.cancelled)
        precondition(!ScanWarning(id: UUID(), date: Date(), title: "Disk-Scan unvollständig", detail: "4 nicht lesbare Dateien").isImportant)
        precondition(ScanWarning(id: UUID(), date: Date(), title: "Verdächtige Dateien gefunden", detail: "fixture").isImportant)
        if ProcessInfo.processInfo.environment["MACTOOLS_REAL_ENGINE"] == "1" {
            let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Vendor/ClamAV/bin/clamscan")
            let database = SecurityScanStore.databaseDirectory
            let started = Date()
            let actual = try ClamAVRunner().runInventory(executable: executable, inventory: inventory, proofURL: cache,
                extraArguments: ["--database=\(database.path)"])
            print(actual.output)
            precondition(actual.exitCode == 1 && actual.items.filter { $0.isTest }.count == 2)
            precondition(actual.scannedFiles == 2 && actual.reusedFiles == 2 && actual.excludedFiles == 0)
            precondition(actual.limitedFiles == 1 && actual.hasWarnings, "Oversized sparse files must be reported as unexamined, never clean")
            let realBatchStart = Date()
            let realBatches = try ClamAVRunner().runInventory(executable: executable, inventory: batches, proofURL: root.appendingPathComponent("missing.sqlite"), extraArguments: ["--database=\(database.path)"], maximumWorkers: 4)
            precondition(realBatches.exitCode == 0 && realBatches.scannedFiles == 1024)
            print("PASS: actual parallel ClamAV checked 1,024 unique files, \(Date().timeIntervalSince(realBatchStart))s")
            print("PASS: actual bundled ClamAV/EICAR, inventory shared, large and small identical content checked once, findings propagated to both EICAR copies, \(Date().timeIntervalSince(started))s")
        }
        print("PASS: process exit codes, findings, stderr, pipe draining, capped log, literal arguments, cancellation")
        if ProcessInfo.processInfo.environment["MACTOOLS_REAL_ENGINE"] != "1" { print("NOTE: mock process checks only; bundled engine not requested") }
    }
}

private final class ProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Date?
    var firstDate: Date? { lock.lock(); defer { lock.unlock() }; return first }
    func record(_ count: Int) { lock.lock(); if first == nil && count > 0 { first = Date() }; lock.unlock() }
}
