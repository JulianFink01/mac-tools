import Foundation
@main struct DesktopConnectionChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--live") {
            let desktop = CodexDesktopConnection(); var received = false
            desktop.selectedID = "01a1699c-6645-7103-b179-66e2ca45673b"
            desktop.onState = { _, state in received = state["threadRuntimeStatus"] != nil }
            try await desktop.connect()
            let followed = await desktop.follow(desktop.selectedID!); precondition(followed)
            for _ in 0..<100 where !received { try await Task.sleep(nanoseconds: 20_000_000) }
            precondition(received); desktop.stop()
            print("PASS: installed desktop owner discovery and live snapshot (read only)")
            return
        }
        let path = "/tmp/mactools-ipc-" + UUID().uuidString + ".sock"
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [FileManager.default.currentDirectoryPath + "/Tests/Fixtures/codex-desktop.py", path]
        try server.run()
        defer { if server.isRunning { server.terminate() }; try? FileManager.default.removeItem(atPath: path) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: path) { try await Task.sleep(nanoseconds: 20_000_000) }
        let desktop = CodexDesktopConnection(socketPath: path); desktop.selectedID = "test-thread"
        var nativeQueue: [[String: Any]] = []
        desktop.onQueue = { _, messages in nativeQueue = messages }
        var changed = false
        desktop.onState = { _, state in
            let turns = state["turns"] as? [[String: Any]] ?? []
            let items = turns.first?["items"] as? [[String: Any]] ?? []
            if items.first?["text"] as? String == "after" { changed = true }
        }
        try await desktop.connect()
        let followed = await desktop.follow("test-thread"); precondition(followed)
        for _ in 0..<500 where !changed { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(changed)
        precondition(desktop.runtimeStatus("test-thread")?["type"] as? String == "active")
        for _ in 0..<100 where nativeQueue.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(nativeQueue.first?["text"] as? String == "native queued")
        try await desktop.removeQueued("native-message", in: "test-thread")
        try await desktop.send("start", to: "test-thread", active: false)
        try await desktop.send("steer", to: "test-thread", active: true)
        try await desktop.send("Text mit Bild", to:"test-thread", active:true, inputs:[["type":"text","text":"Text mit Bild"],["type":"localImage","path":"/tmp/fixture.png"]])
        let reference: [[String:Any]] = [["type":"text","text":"reference","text_elements":[["type":"mention","value":"preserved"]]]]
        precondition((CodexDesktopConnection.normalizedInput(reference).first?["text_elements"] as? [[String:String]])?.first?["value"] == "preserved")
        try await desktop.loadCompleteHistory("test-thread")
        print("PASS: text and local image input, preserved reference elements, complete restore context and owner history request")
        try await desktop.answer("approval-fixture", method: "item/commandExecution/requestApproval", in: "test-thread", result: ["decision":"accept"])
        try await desktop.interrupt("test-thread", turnID: "turn-test")
        desktop.stop()
        let recoveryPath = path + "-recovery"
        let recoveryServer = Process();recoveryServer.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        recoveryServer.arguments = [FileManager.default.currentDirectoryPath + "/Tests/Fixtures/codex-desktop-recovery.py",recoveryPath]
        try recoveryServer.run()
        defer { if recoveryServer.isRunning { recoveryServer.terminate() };try? FileManager.default.removeItem(atPath:recoveryPath) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath:recoveryPath) { try await Task.sleep(nanoseconds:20_000_000) }
        let recovery = CodexDesktopConnection(socketPath:recoveryPath);recovery.selectedID = "recover-thread"
        async let firstConnect: Void = recovery.connect()
        async let secondConnect: Void = recovery.connect()
        _ = try await (firstConnect,secondConnect)
        let recovered = await recovery.recoverOwner("recover-thread")
        precondition(recovered && recovery.hasOwner("recover-thread"))
        recovery.stop()
        print("PASS: concurrent connection attempts share handshake; stale owner discovery reconnects and recovers without any message or mutation")
        print("PASS: fragmented IPC frames, owner runtime snapshot, native queue, start/steer/interrupt contract" + (ProcessInfo.processInfo.environment["MACTOOLS_TEST_LARGE_FRAME"] == nil ? "" : "; valid 70-MiB snapshot accepted without disconnect"))
    }
}
