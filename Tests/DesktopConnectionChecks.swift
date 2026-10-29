import Foundation
@main struct DesktopConnectionChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--live") {
            let desktop = CodexDesktopConnection(); var received = false
            desktop.selectedID = CommandLine.arguments.dropFirst().drop(while: { $0 != "--live" }).dropFirst().first ?? "01a1699c-6645-7103-b179-66e2ca45673b"
            desktop.onState = { _, state in received = state["threadRuntimeStatus"] != nil }
            try await desktop.connect()
            let followed = await desktop.follow(desktop.selectedID!); precondition(followed)
            for _ in 0..<100 where !received { try await Task.sleep(nanoseconds: 20_000_000) }
            precondition(received)
            // A deliberately nonexistent ID exercises the local protocol without
            // granting or declining any actual permission request.
            try await desktop.answer("mactools-nonexistent-" + UUID().uuidString, method: "mcpServer/elicitation/request", in: desktop.selectedID!, result: ["action":"decline", "content":NSNull()])
            desktop.stop()
            print("PASS: installed desktop owner discovery, live snapshot and local approval protocol acknowledged with a nonexistent request ID")
            return
        }
        let path = "/tmp/mactools-ipc-" + UUID().uuidString + ".sock"
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [FileManager.default.currentDirectoryPath + "/Tests/Fixtures/codex-desktop.py", path]
        server.environment = ProcessInfo.processInfo.environment.merging(["MACTOOLS_TEST_DROP_FIRST_SNAPSHOT":"1"]) { _, new in new }
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
        precondition(desktop.runtimeStatus("test-thread") == nil)
        let retriedSubscription = await desktop.follow("test-thread")
        precondition(retriedSubscription)
        for _ in 0..<500 where !changed { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(changed)
        print("PASS: a dropped initial stream subscription is retried without losing the selected owner")
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
        try await desktop.answer("mcp-consent",method:"mcpServer/elicitation/request",in:"test-thread",result:["action":"accept","content":[:],"_meta":["persist":"session"]])
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
        let streamPath = path + "-stream"
        let streamServer = Process(); streamServer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        streamServer.arguments = [FileManager.default.currentDirectoryPath + "/Tests/Fixtures/codex-desktop-reconnect.py", streamPath]
        try streamServer.run()
        defer { if streamServer.isRunning { streamServer.terminate() }; try? FileManager.default.removeItem(atPath: streamPath) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: streamPath) { try await Task.sleep(nanoseconds: 20_000_000) }
        let stream = CodexDesktopConnection(socketPath: streamPath); stream.selectedID = "old-selected"
        var observedCycle = -1, disconnects = 0
        stream.onState = { _, state in observedCycle = state["reconnectCycle"] as? Int ?? -1 }
        stream.onDisconnect = { disconnects += 1 }
        for cycle in 0..<3 {
            try await stream.connect()
            let subscribed = await stream.follow("old-selected"); precondition(subscribed)
            for _ in 0..<150 where observedCycle != cycle { try await Task.sleep(nanoseconds: 20_000_000) }
            precondition(observedCycle == cycle, "The selected chat must receive new state after every reconnect")
            if cycle < 2 {
                for _ in 0..<150 where disconnects <= cycle { try await Task.sleep(nanoseconds: 20_000_000) }
                precondition(!stream.connected && !stream.hasOwner("old-selected"))
            }
        }
        stream.stop()
        print("PASS: two real socket drops reconnect and resubscribe the same selected chat with fresh owner and stream state; no input sent")
        print("PASS: fragmented IPC frames, owner runtime snapshot, native queue, start/steer/interrupt contract" + (ProcessInfo.processInfo.environment["MACTOOLS_TEST_LARGE_FRAME"] == nil ? "" : "; valid 70-MiB snapshot accepted without disconnect"))
    }
}
