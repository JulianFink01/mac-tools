import Foundation
import Darwin

@main struct IncrementalSecurityChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("MacTools-incremental-\(UUID())")
        let root = directory.appendingPathComponent("Files")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        func script(_ name: String, body: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(("#!/bin/sh\nfor arg in \"$@\"; do case \"$arg\" in --file-list=*) list=${arg#--file-list=};; esac; done\n" + body).utf8).write(to: url)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        let executable = try script("engine", body: "count=0\nwhile IFS= read -r path; do\ncase \"$path\" in */test.txt) printf '%s: Eicar-Test-Signature FOUND\\n' \"$path\";; *) printf '%s: OK\\n' \"$path\";; esac\ncount=$((count+1))\ndone < \"$list\"\nprintf 'Scanned files: %s\\n' \"$count\"\n")
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try Data("content-a".utf8).write(to: a); try Data("content-b".utf8).write(to: b)
        try Data("test fixture".utf8).write(to: root.appendingPathComponent("test.txt"))
        let verdicts = directory.appendingPathComponent("verdicts.sqlite")
        func scan(_ engine: URL, cache: URL, arguments: [String] = []) throws -> SecurityReport {
            try ClamAVRunner().runInventory(executable: engine, inventory: DiskScanner.scan(root: root, findDuplicates: false),
                proofURL: directory.appendingPathComponent("unused.sqlite"), extraArguments: arguments, verdictURL: cache)
        }
        let cold = try scan(executable, cache: verdicts)
        let warm = try scan(executable, cache: verdicts)
        precondition(cold.scannedFiles == 3 && cold.unchangedFiles == 0)
        precondition(warm.scannedFiles == 0 && warm.unchangedFiles == 3 && warm.items.first?.isTest == true && warm.exitCode == 1)
        let mtime = try a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        try Data("content-c".utf8).write(to: a)
        try manager.setAttributes([.modificationDate: mtime], ofItemAtPath: a.path)
        let changed = try scan(executable, cache: verdicts)
        precondition(changed.scannedFiles == 1 && changed.unchangedFiles == 2, "ctime must invalidate even restored size and mtime")
        try Data("new".utf8).write(to: root.appendingPathComponent("new.txt"))
        let added = try scan(executable, cache: verdicts)
        precondition(added.scannedFiles == 1 && added.unchangedFiles == 3)
        try manager.removeItem(at: b)
        let removed = try scan(executable, cache: verdicts)
        precondition(removed.scannedFiles == 0 && removed.unchangedFiles == 3)
        let db = directory.appendingPathComponent("fixture.hdb")
        try Data("signatures-v1".utf8).write(to: db)
        let databaseArguments = ["--database=\(db.path)"]
        let newSignatures = try scan(executable, cache: verdicts, arguments: databaseArguments)
        let sameSignatures = try scan(executable, cache: verdicts, arguments: databaseArguments)
        precondition(newSignatures.scannedFiles == 3 && sameSignatures.scannedFiles == 0)
        try Data("signatures-v2".utf8).write(to: db)
        let changedSignatures = try scan(executable, cache: verdicts, arguments: databaseArguments)
        precondition(changedSignatures.scannedFiles == 3)
        let failed = try script("failed", body: "while IFS= read -r path; do printf '%s: unreadable ERROR\\n' \"$path\"; done < \"$list\"\nexit 2\n")
        let failure = try scan(failed, cache: verdicts), retry = try scan(failed, cache: verdicts)
        precondition(failure.hasCriticalIssue && retry.unchangedFiles == 0, "Failed attempts must never become cached clean results")
        let mutating = try script("mutating", body: "count=0\nwhile IFS= read -r path; do printf x >> \"$path\"; printf '%s: OK\\n' \"$path\"; count=$((count+1)); done < \"$list\"\nprintf 'Scanned files: %s\\n' \"$count\"\n")
        _ = try scan(mutating, cache: verdicts)
        let afterMutation = try scan(mutating, cache: verdicts)
        precondition(afterMutation.scannedFiles == 3 && afterMutation.unchangedFiles == 0, "Mutations during scan must not be cached")
        let stopped = ClamAVRunner(); stopped.cancel()
        do { _ = try stopped.runInventory(executable: executable, inventory: DiskScanner.scan(root: root, findDuplicates: false), proofURL: db, verdictURL: verdicts); preconditionFailure("Cancelled preparation must stop") }
        catch is CancellationError { }
        let security = SecurityScanStore(directory: directory.appendingPathComponent("State"))
        await security.refreshCurrentFindings()
        precondition(!security.isCheckingFindings && security.currentFindings?.items.isEmpty == true)
        let saved = try PropertyListDecoder().decode(SecurityReport.self, from: PropertyListEncoder().encode(warm))
        precondition(saved.unchangedFiles == 3 && saved.items.first?.isTest == true)
        print("PASS: persisted verdicts; unchanged 3→0 engine reads; same-size/restored-mtime mutation; additions/deletions; signature invalidation; retained findings; failures/cancellation/in-scan changes; idle findings settled")

        if ProcessInfo.processInfo.environment["MACTOOLS_REAL_ENGINE"] == "1" {
            let actualRoot = directory.appendingPathComponent("Actual")
            try manager.createDirectory(at: actualRoot, withIntermediateDirectories: true)
            let clean = actualRoot.appendingPathComponent("clean.txt")
            try Data("harmless real scanner fixture".utf8).write(to: clean)
            let eicar = "X5O!P%@AP[4" + "\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
            for name in ["test.txt", "test-copy.txt"] { try Data(eicar.utf8).write(to: actualRoot.appendingPathComponent(name)) }
            let engine = URL(fileURLWithPath: manager.currentDirectoryPath).appendingPathComponent("Vendor/ClamAV/bin/clamscan")
            let arguments = ["--database=\(SecurityScanStore.databaseDirectory.path)"]
            let proof = directory.appendingPathComponent("real-hashes.sqlite"), cache = directory.appendingPathComponent("real-verdicts.sqlite")
            let inventory = try DiskScanner.scan(root: actualRoot, findDuplicates: true, cacheURL: proof)
            let start = Date()
            let first = try ClamAVRunner().runInventory(executable: engine, inventory: inventory, proofURL: proof, extraArguments: arguments, verdictURL: cache)
            let firstTime = Date().timeIntervalSince(start), next = Date()
            let second = try ClamAVRunner().runInventory(executable: engine, inventory: inventory, proofURL: proof, extraArguments: arguments, verdictURL: cache)
            let secondTime = Date().timeIntervalSince(next)
            print("REAL COLD: \(first.exitCode), scanned \(first.scannedFiles), reused \(first.reusedFiles ?? -1), unchanged \(first.unchangedFiles ?? -1), findings \(first.items.count)\n\(first.output)")
            print("REAL WARM: \(second.exitCode), scanned \(second.scannedFiles), unchanged \(second.unchangedFiles ?? -1), findings \(second.items.count)")
            precondition(first.scannedFiles == 2 && first.reusedFiles == 1 && first.items.filter(\.isTest).count == 2)
            precondition(second.scannedFiles == 0 && second.unchangedFiles == 3 && second.items.filter(\.isTest).count == 2)
            try Data("changed clean fixture".utf8).write(to: clean)
            let third = try ClamAVRunner().runInventory(executable: engine, inventory: DiskScanner.scan(root: actualRoot, findDuplicates: false), proofURL: proof, extraArguments: arguments, verdictURL: cache)
            precondition(third.scannedFiles == 1 && third.unchangedFiles == 2 && third.items.filter(\.isTest).count == 2)
            print("PASS: real bundled ClamAV/EICAR; first \(firstTime)s, unchanged \(secondTime)s, one changed file rescanned; duplicate proof preserved")
        }
    }
}
