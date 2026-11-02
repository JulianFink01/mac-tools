import Foundation
import Darwin

@main struct FindingRefreshChecks {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let manager = FileManager.default, directory = manager.temporaryDirectory.appendingPathComponent("MacTools-findings-\(UUID())")
        try manager.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? manager.removeItem(at:directory) }
        let archive = directory.appendingPathComponent("old-sdk.zip"), suspect = directory.appendingPathComponent("suspect.txt")
        try Data(repeating:65,count:8192).write(to:archive);try Data("harmless fixture".utf8).write(to:suspect)
        let missing = directory.appendingPathComponent("gone.txt").path
        struct Saved:Codable { let report:SecurityReport;let root:URL;let date:Date }
        let report = SecurityReport(exitCode:1,output:"\(archive.path): Heuristics.Limits.Exceeded.MaxScanTime FOUND\n\(missing): Fixture.Threat FOUND\nScanned files: 3\n",cancelled:false)
        let encoder=PropertyListEncoder();encoder.outputFormat = .binary
        try encoder.encode(Saved(report:report,root:directory,date:Date())).write(to:directory.appendingPathComponent("last-virus-scan.plist"))
        let store = SecurityScanStore(directory:directory)
        let start=Date()
        await store.refreshCurrentFindings(legacyPaths:[archive.path,missing])
        precondition(Date().timeIntervalSince(start)<1 && !store.isCheckingFindings)
        precondition(store.currentFindings?.items.isEmpty==true && store.currentFindings?.pendingPaths.isEmpty==true,"Historical limit archives must not become threat rechecks")
        await store.refreshCurrentFindings(legacyPaths:[suspect.path])
        precondition(!store.isCheckingFindings && store.currentFindings?.pendingPaths==[suspect.path],"Existing unverified history remains pending, never clean")
        precondition(!manager.fileExists(atPath:directory.appendingPathComponent("virus-verdicts.sqlite").path),"Automatic inspection must not create/write a verdict DB or start an engine")
        print("PASS: reproduced saved threat + historical archive-limit paths; automatic refresh settles immediately and preserves unknown paths")

        func executable(_ name:String,_ body:String)throws->URL {
            let url=directory.appendingPathComponent(name)
            try Data(("#!/bin/sh\n"+body).utf8).write(to:url)
            try manager.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path);return url
        }
        let hanging=try executable("hang","trap '' TERM\nwhile :; do :; done\n")
        let timeoutStart=Date()
        do { _=try ClamAVRunner().runProcess(executable:hanging,arguments:[],timeLimit:0.25);preconditionFailure("Silent/TERM-ignoring engine must time out") }
        catch { precondition(error.localizedDescription.contains("Zeitlimit")) }
        precondition(Date().timeIntervalSince(timeoutStart)<2)
        let closed=try executable("closed-output","exec >/dev/null 2>&1\ntrap '' TERM\nwhile :; do :; done\n")
        let closedStart=Date()
        do { _=try ClamAVRunner().runProcess(executable:closed,arguments:[],timeLimit:0.25);preconditionFailure("Closing stdout must not bypass timeout") }
        catch { precondition(error.localizedDescription.contains("Zeitlimit")) }
        precondition(Date().timeIntervalSince(closedStart)<2)
        let runner=ClamAVRunner()
        let running=Task.detached { try runner.runProcess(executable:hanging,arguments:[]) }
        try await Task.sleep(nanoseconds:100_000_000)
        let cancelledStart=Date();runner.cancel()
        let cancelled=try await running.value
        precondition(cancelled.cancelled && Date().timeIntervalSince(cancelledStart)<2)
        print("PASS: wall-clock timeout, closed-output timeout and cancellation terminate silent/TERM-ignoring engines")

        let timeoutStore = SecurityScanStore(directory:directory, executableURL:hanging, findingTimeLimit:0.25)
        await timeoutStore.refreshCurrentFindings(legacyPaths:[suspect.path],verifyContents:true)
        precondition(!timeoutStore.isCheckingFindings && timeoutStore.findingCheckIssue?.contains("Zeitlimit")==true)
        precondition(timeoutStore.currentFindings?.pendingPaths.contains(suspect.path)==true,"Timeout must preserve unresolved paths")
        let cancelStore = SecurityScanStore(directory:directory, executableURL:hanging, findingTimeLimit:5)
        let check = Task { await cancelStore.refreshCurrentFindings(legacyPaths:[suspect.path],verifyContents:true) }
        while !cancelStore.isCheckingFindings { await Task.yield() }
        cancelStore.cancelFindingCheck()
        precondition(!cancelStore.isCheckingFindings && cancelStore.findingCheckIssue != nil)
        await cancelStore.refreshCurrentFindings(legacyPaths:[suspect.path])
        await check.value
        precondition(!cancelStore.isCheckingFindings && cancelStore.findingCheckIssue == nil && cancelStore.currentFindings?.pendingPaths==[suspect.path],"An old cancelled task must not overwrite the next check")
        print("PASS: store-level timeout, immediate cancel, unresolved paths retained and obsolete result isolation")

        let engine=try executable("cache-engine","printf 'unused\\n'\n")
        let db=directory.appendingPathComponent("verdicts.sqlite"),context=SecurityVerdictCache.context(executable:engine,arguments:[])
        do {
            let cache=SecurityVerdictCache(url:db,context:context)!
            var info=stat();precondition(lstat(suspect.path,&info)==0)
            cache.prepare(path:suspect.path,info:info);cache.record(path:suspect.path,signature:"Fixture.Threat")
        }
        let inspected=try ClamAVRunner().inspectFindings(executable:engine,paths:[suspect.path],verdictURL:db)
        precondition(inspected.items.first?.signature=="Fixture.Threat" && inspected.pendingPaths.isEmpty)
        try Data("changed fixture!".utf8).write(to:suspect)
        let changed=try ClamAVRunner().inspectFindings(executable:engine,paths:[suspect.path],verdictURL:db)
        precondition(changed.items.isEmpty && changed.pendingPaths==[suspect.path])
        store.cancelFindingCheck();precondition(!store.isCheckingFindings)
        print("PASS: metadata-only checks retain matching verified findings and invalidate changed files without engine/content reads")
    }
}
