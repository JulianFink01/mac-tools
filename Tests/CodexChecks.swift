import Foundation

@main
struct CodexChecks {
    @MainActor
    static func main() async throws {
        var disclosure = CodexActivityExpansionState()
        disclosure.rememberGroup(thread:"one",ids:["a","b"],running:true)
        disclosure.setGroup(false,thread:"one",ids:["a","b"])
        disclosure.rememberGroup(thread:"one",ids:["b","c"],running:true)
        precondition(!disclosure.group(thread:"one",ids:["b","c"],running:true))
        disclosure.setDetail(true,thread:"one",id:"b")
        disclosure.rememberDetail(thread:"one",id:"b",running:false)
        precondition(disclosure.detail(thread:"one",id:"b",running:false))
        disclosure.setDetail(false,thread:"one",id:"c")
        disclosure.rememberDetail(thread:"one",id:"c",running:true)
        precondition(!disclosure.detail(thread:"one",id:"c",running:true))
        precondition(!disclosure.detail(thread:"two",id:"b",running:false))
        print("PASS: opened and closed command choices survive streaming, completion and moving history groups; isolated per chat")
        let longState: [String:Any] = ["turns":[["id":"history-window", "items":(0..<2000).map { ["id":"window-\($0)","type":"agentMessage","text":"Message \($0)"] }]]]
        let tail = CodexTranscript.window(longState,limit:80)
        precondition(tail.messages.count == 80 && tail.hasMore && tail.messages.first?.id == "window-1920" && tail.messages.last?.id == "window-1999")
        let olderWindow = CodexTranscript.window(longState,limit:160)
        precondition(olderWindow.messages.count == 160 && olderWindow.messages.suffix(80).map(\.id) == tail.messages.map(\.id))
        precondition(CodexTranscript.window(["turns":[],"turnsPagination":["hasLoadedOldest":false]],limit:80).hasMore)
        precondition(CodexTranscript.mayHaveOlder(["turnHistory":["history":["isComplete":false]]]))
        precondition(CodexTranscript.mayHaveOlder(["turns":[["itemsPagination":["hasLoadedOldest":false]]]]))
        precondition(!CodexTranscript.mayHaveOlder(["turns":[],"turnsPagination":["hasLoadedOldest":true]]))
        print("PASS: large native history defaults to an 80-item tail; loading older history preserves the exact recent messages")
        let skillLabel = CodexReference(name: "data-analytics:product-business-analysis", path: "/tmp/SKILL.md", kind: "skill")
        precondition(skillLabel.displayName == "Product Business Analysis" && skillLabel.providerLabel == "Data Analytics" && skillLabel.input["name"] as? String == skillLabel.name)
        let fileQueue = CodexNativeQueuedMessage(["id":"file-queue", "input":[["type":"text", "text":"# Files mentioned by the user:\n\n## screenshot.png: /tmp/image.png\n\n## My request:\nBitte Bild prüfen\n<image path=\"/tmp/image.png\"></image>"],["type":"localImage", "path":"/tmp/image.png"]]])!
        precondition(fileQueue.previewText == "Bitte Bild prüfen" && fileQueue.attachments.count == 1)
        let started = Date().addingTimeInterval(-87)
        let commandItems = CodexTranscript.items(["commandExecutionStartedAtMsById":["cmd":started.timeIntervalSince1970 * 1000], "items":[["id":"cmd","type":"commandExecution","status":"inProgress","command":"sleep 120","cwd":"/tmp"]]])
        let runningCommand = CodexMessage.from(commandItems[0])!.activity!
        precondition(runningCommand.isRunning && runningCommand.timingLabel(now: started.addingTimeInterval(87)).contains("1 Min. 27 Sek.") && runningCommand.cwd == "/tmp")
        let completedCommand = CodexMessage.from(["id":"done","type":"commandExecution","status":"completed","command":"echo ok","durationMs":1500,"exitCode":0,"aggregatedOutput":"ok"])!.activity!
        precondition(completedCommand.output == "ok" && completedCommand.durationMs == 1500 && completedCommand.timingLabel(now: Date()).contains("Exit 0"))
        let liveSettings = CodexLiveSettings(["latestReasoningEffort": NSNull(), "latestThreadSettings": ["model": "gpt-6.1-sol", "effort": "high"]])
        precondition(liveSettings.effort == "high" && liveSettings.model == "gpt-6.1-sol", "Null latestReasoningEffort must inherit actual desktop thread settings")
        let steering = CodexMessage.from(["id": "steer-live", "type": "steeringUserMessage", "input": [["type": "text", "text": "Eigene Steuerung"]]])
        precondition(steering?.text == "Eigene Steuerung" && steering?.role == "Du", "Native steering uses input, not content")
        let restored = CodexMessage.from(["id": "steer-restored", "type": "steeringUserMessage", "restoreMessage": ["text": "Wiederhergestellt"]])
        precondition(restored?.text == "Wiederhergestellt")
        let user: [String: Any] = ["id": "live-user", "type": "userMessage", "content": [["type": "text", "text": "Gerade gesendet"]]]
        let old: [String: Any] = ["turnId": "old", "items": [["id": "old-answer", "type": "agentMessage", "text": "Vorherige Antwort"]]]
        let liveTurn: [String: Any] = ["turnId": "current", "status": "inProgress", "items": [user]]
        let timeline = CodexTranscript.turns(["turnHistory": ["history": ["entitiesByKey": ["old": old], "islands": [["entries": [["value": "old"]]]]]], "turns": [liveTurn]])
        precondition(timeline.count == 2 && timeline.flatMap { $0["items"] as? [[String: Any]] ?? [] }.compactMap(CodexMessage.from).last?.text == "Gerade gesendet", "Live outgoing messages must remain visible alongside committed history")
        print("PASS: actual effort inherited when latest field is null; live user turn merged with persisted transcript")
        let now = Date()
        let stale = CodexChat(["id": "stale", "updatedAt": now.timeIntervalSince1970 - 4000])!
        let fresh = CodexChat(["id": "fresh", "updatedAt": now.timeIntervalSince1970 - 60])!
        let running = CodexChat(["id": "running", "updatedAt": now.timeIntervalSince1970 - 90000, "status": ["type": "active"]])!
        precondition(CodexChatOrder.menu([fresh, stale, running], now: now).map(\.id) == ["running", "fresh"])
        precondition(CodexChatOrder.menu([stale], now: now).isEmpty)
        let recency = CodexChat(["id": "metadata-only", "updatedAt": now.timeIntervalSince1970, "recencyAt": now.timeIntervalSince1970 - 90000])!
        precondition(!recency.isRecent, "Metadata updates must not revive an unused chat")
        let native = CodexNativeQueuedMessage(["id": "queued-native", "text": "old", "context": ["prompt": "attachment context\nold", "imageAttachments": [["path": "/tmp/image.png"]]], "unknownFutureField": 42])!
        let edited = try native.edited("new")
        precondition(edited["text"] as? String == "new" && edited["unknownFutureField"] as? Int == 42)
        precondition((edited["context"] as? [String: Any])?["prompt"] as? String == "attachment context\nnew")
        precondition(((edited["context"] as? [String: Any])?["imageAttachments"] as? [[String: Any]])?.count == 1)
        print("PASS: running chats first, one-hour menu cutoff, true activity date, native queue context preserved")
        let validQueue = Data(#"{"queued-follow-ups":{"queue-thread":[{"id":"message","text":"erhalten"}]}}"#.utf8)
        precondition(CodexStore.nativeQueueSnapshot(validQueue, for: "queue-thread")?.count == 1)
        for data in [Data(), Data("{".utf8), Data("{}".utf8), Data(#"{"queued-follow-ups":{"queue-thread":[{"id":"bad"}]}}"#.utf8)] {
            precondition(CodexStore.nativeQueueSnapshot(data, for: "queue-thread") == nil, "Unreadable or incomplete queue snapshots must never clear messages")
        }
        precondition(CodexStore.nativeQueueSnapshot(Data(#"{"queued-follow-ups":{}}"#.utf8), for: "queue-thread")?.isEmpty == true)
        for value: Any in ["turn-id", ["status": "accepted"], ["status": "sent", "turnId": "turn-id"], ["turnId": "turn-id"], ["turn": ["id": "turn-id", "status": "inProgress"]]] { try CodexDesktopConnection.confirmDelivery(value) }
        for value: Any in [NSNull(), [:], ["status": "paused"], ["status": "deferred"], ["status": "unconfirmed"], ["status": "rejected"]] {
            do { try CodexDesktopConnection.confirmDelivery(value); fatalError("Unconfirmed handoff was treated as delivered") } catch { }
        }
        print("PASS: unreadable/malformed queue snapshots preserve messages; only explicit delivery receipts consume outbox entries")
        let imageOnly = CodexMessage.from(["id":"picture-only","type":"userMessage","content":[["type":"localImage","path":"/tmp/picture.png"]]])
        precondition(imageOnly?.images.first?.source == "/tmp/picture.png" && imageOnly?.text.isEmpty == true, "Image-only native messages must remain in the timeline")
        let nativeInput = CodexNativeQueuedMessage(["id":"queued-server","input":[["type":"text","text":"old"],["type":"localImage","path":"/tmp/picture.png"]]])!
        let editedInput = try nativeInput.editedInput("new")
        precondition(nativeInput.isServerQueue && nativeInput.text == "old" && editedInput[1]["path"] as? String == "/tmp/picture.png" && editedInput[0]["text"] as? String == "new")
        print("PASS: native server queue input decoded; individual edit preserves attached image; image-only chat messages retained")
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Tests/Fixtures/codex-app-server.py")
        let catalogDomain = "MacTools.catalog-tests." + UUID().uuidString
        let catalogDefaults = UserDefaults(suiteName:catalogDomain)!
        let catalogConnection = CodexConnection(executableURL:fixture,environment:["MACTOOLS_TEST_SLOW_CATALOG":"1"])
        let catalogStore = CodexStore(connection:catalogConnection,defaults:catalogDefaults)
        catalogStore.workingDirectory = "/tmp"
        await catalogStore.connect()
        let catalogLoad = Task { await catalogStore.loadComposerContext() }
        for _ in 0..<100 where catalogStore.availableReferences.isEmpty { try await Task.sleep(nanoseconds:5_000_000) }
        precondition(!catalogStore.availableReferences.isEmpty && catalogStore.composerContextLoading,"Fast sources must be visible while later app pages are still loading")
        await catalogLoad.value
        precondition(catalogStore.availableReferences.contains { $0.name == "AlphaTraderMCP" })
        catalogStore.stop()
        let cachedConnection = CodexConnection(executableURL:fixture)
        let cachedStore = CodexStore(connection:cachedConnection,defaults:catalogDefaults)
        cachedStore.workingDirectory = "/tmp"
        await cachedStore.connect(); await cachedStore.loadComposerContext()
        precondition(cachedStore.availableReferences.contains { $0.name == "AlphaTraderMCP" })
        let cacheCalls = try await cachedConnection.request("test/catalog-stats")
        precondition(cacheCalls["app/list"] == nil && cacheCalls["skills/list"] == nil && cacheCalls["plugin/list"] == nil,"Reopening must use persisted catalog without repeating catalog requests")
        cachedStore.stop(); catalogDefaults.removePersistentDomain(forName:catalogDomain)
        print("PASS: mention results stream progressively before slow app pages finish; persisted warm catalog makes zero app/skill/plugin requests")
        let connection = CodexConnection(executableURL: fixture)
        let domain = "MacTools.codex-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let store = CodexStore(connection: connection, defaults: defaults)
        defer { store.stop(); defaults.removePersistentDomain(forName: domain) }
        store.drafts["test-old"] = "Erhaltener Entwurf äöü"
        let restoredDraft = CodexStore(connection: CodexConnection(executableURL: fixture), defaults: defaults)
        precondition(restoredDraft.drafts["test-old"] == "Erhaltener Entwurf äöü")
        print("PASS: chat drafts persist across store recreation")
        let projectDomain = "MacTools.project-picker." + UUID().uuidString
        let projectDefaults = UserDefaults(suiteName: projectDomain)!
        let projectConnection = CodexConnection(executableURL: fixture)
        let projectStore = CodexStore(connection: projectConnection, defaults: projectDefaults)
        await projectStore.connect()
        let chosen = projectStore.projects.first!
        projectStore.newChat(in: chosen)
        precondition(projectStore.selectedID == nil && projectStore.newChatProjectID == chosen.id && projectStore.workingDirectory == "/tmp/destination")
        precondition(CodexStore(connection: CodexConnection(executableURL: fixture), defaults: projectDefaults).newChatProjectID == chosen.id)
        let sentInProject = await projectStore.send("Sofort")
        let startState = try await projectConnection.request("test/start-state")
        precondition(sentInProject && startState["cwd"] as? String == "/tmp/destination" && startState["projectId"] as? String == chosen.id)
        projectStore.newChat(); projectStore.selectNewChatProject(nil)
        precondition(projectStore.newChatProjectID == nil && projectStore.workingDirectory == NSHomeDirectory())
        projectStore.newChat(inFolder: "/tmp/destination")
        precondition(projectStore.newChatProjectID == chosen.id && projectStore.workingDirectory == "/tmp/destination")
        projectStore.stop(); projectDefaults.removePersistentDomain(forName: projectDomain)
        print("PASS: existing project selectable for every new chat; project and cwd captured; assignment confirmed after first accepted turn; folder shortcut preselects project")
        let sharedQueue = CodexQueueRepository(defaults: defaults)
        let firstView = CodexStore(connection: CodexConnection(executableURL: fixture), defaults: defaults, queue: sharedQueue)
        let otherDomain = "MacTools.queue-window." + UUID().uuidString
        let otherDefaults = UserDefaults(suiteName: otherDomain)!
        defer { otherDefaults.removePersistentDomain(forName: otherDomain) }
        let secondView = CodexStore(connection: CodexConnection(executableURL: fixture), defaults: otherDefaults, queue: sharedQueue)
        firstView.enqueue("bleibt beim Fensterwechsel", in: "shared-chat")
        let sharedID = firstView.queuedMessages["shared-chat"]!.first!.id
        precondition(secondView.queuedMessages["shared-chat"]?.first?.id == sharedID)
        secondView.editQueued(sharedID, in: "shared-chat", text: "in beiden Fenstern geändert")
        precondition(firstView.queuedMessages["shared-chat"]?.first?.text == "in beiden Fenstern geändert")
        firstView.stop(); secondView.newChat()
        precondition(CodexQueueRepository(defaults: defaults).messages["shared-chat"]?.first?.id == sharedID)
        precondition(sharedQueue.claim("shared-chat") && !sharedQueue.claim("shared-chat"), "Two windows must not deliver the same chat concurrently")
        sharedQueue.release("shared-chat")
        sharedQueue.observe("shared-chat", active: true); sharedQueue.observe("shared-chat", active: false)
        let completion = sharedQueue.epochs["shared-chat"]
        sharedQueue.blocked.insert("shared-chat"); sharedQueue.ready.remove("shared-chat")
        sharedQueue.observe("shared-chat", active: false)
        precondition(sharedQueue.epochs["shared-chat"] == completion && sharedQueue.blocked.contains("shared-chat") && !sharedQueue.ready.contains("shared-chat"), "Duplicate idle snapshots must not drain the next message")
        sharedQueue.observe("shared-chat", active: true)
        precondition(!sharedQueue.ready.contains("shared-chat"), "Editing a queue must never advance it while its conversation is running")
        sharedQueue.observe("shared-chat", active: false)
        sharedQueue.observe("shared-chat", active: true)
        sharedQueue.delivered("shared-chat", since: completion ?? 0)
        precondition(!sharedQueue.ready.contains("shared-chat"), "A delayed receipt from the previous turn must not advance the next running turn")
        secondView.removeQueued(sharedID, in: "shared-chat")
        precondition(firstView.queuedMessages["shared-chat"]?.isEmpty == true)
        firstView.enqueue("Reihenfolge A", in: "ordered-chat"); firstView.enqueue("Reihenfolge B", in: "ordered-chat")
        let ordered = firstView.queuedMessages["ordered-chat"]!
        firstView.moveQueued(ordered[1].id, in: "ordered-chat", offset: -1)
        precondition(secondView.queuedMessages["ordered-chat"]?.map(\.text) == ["Reihenfolge B", "Reihenfolge A"])
        firstView.moveQueued(ordered[0].id, in: "ordered-chat", before: ordered[1].id)
        precondition(CodexQueueRepository(defaults: defaults).messages["ordered-chat"]?.map(\.text) == ["Reihenfolge A", "Reihenfolge B"])
        for item in ordered { firstView.removeQueued(item.id, in: "ordered-chat") }
        print("PASS: one persisted conversation queue across independent windows; shared edit/delete and delivery lock; duplicate idle cannot drain queue")
        await store.connect()
        precondition(store.connected, store.error ?? "not connected")
        precondition(store.usageBuckets.first?.windows.first?.remaining == 70 && store.usageBuckets.first?.windows.last?.label == "7 Tage")
        precondition(CodexUsageBucket.parse(["rateLimits": ["primary": NSNull(), "secondary": NSNull()]]).first?.windows.isEmpty == true, "Unavailable usage must not appear as zero percent")
        print("PASS: real rate-limit contract parsed as remaining percentage; absent usage stays unavailable")
        store.enqueue("nicht bestätigt", in: "test-old")
        let failedQueueID = store.queuedMessages["test-old"]!.first!.id
        let failedQueueSend = await store.deliverQueued(failedQueueID, in: "test-old", steer: false)
        precondition(!failedQueueSend && store.queuedMessages["test-old"]?.first?.id == failedQueueID && store.queueNeedsReview(failedQueueID))
        let restoredFailedQueue = CodexStore(connection: CodexConnection(executableURL: fixture), defaults: defaults)
        precondition(restoredFailedQueue.queuedMessages["test-old"]?.first?.id == failedQueueID && restoredFailedQueue.queueNeedsReview(failedQueueID))
        store.removeQueued(failedQueueID, in: "test-old")
        print("PASS: failed delivery remains visible and persisted with review flag; automatic resubmission suspended across store recreation")
        precondition(store.chats.first?.title == "Prüfchat äöü")
        precondition(!store.chats.contains { $0.statusLabel == "Läuft" })
        await store.refresh(older: true)
        precondition(store.chats.map(\.id) == ["test-old", "test-older", "test-outdated"])
        precondition(store.chats.map(\.updatedAt) == store.chats.map(\.updatedAt).sorted(by: >))
        let bucketDate = Date(timeIntervalSince1970: 1_800_000_000)
        let earlierChat = CodexChat(["id": "a", "updatedAt": bucketDate.timeIntervalSince1970 + 20])!
        let laterChat = CodexChat(["id": "b", "updatedAt": bucketDate.timeIntervalSince1970 + 200])!
        precondition(CodexChatOrder.sorted([laterChat, earlierChat], previous: ["a", "b"]).map(\.id) == ["a", "b"], "Parallel updates in an hour must not reshuffle chats")
        var later = laterChat; later.updatedAt = bucketDate.addingTimeInterval(3601)
        precondition(CodexChatOrder.sorted([earlierChat, later], previous: ["a", "b"]).map(\.id) == ["b", "a"], "A newer hour advances the chat")
        print("PASS: stable order within the same hour; newer activity hour advances correctly")
        let destination = store.projects.first!
        await store.move(["test-older"], to: destination)
        precondition(store.chats.first { $0.id == "test-older" }?.projectID == destination.id)
        precondition(store.folder(for: store.chats.first { $0.id == "test-older" }!) == "/tmp/destination")
        await store.archive(["test-older"])
        precondition(!store.chats.contains { $0.id == "test-older" })
        await store.select("test-old")
        precondition(store.messages.map(\.text) == ["Neuere Antwort"])
        let nativeRequest: [String:Any] = ["id":"native-request-1", "method":"item/commandExecution/requestApproval", "params":["threadId":"test-old","command":"echo native-fixture","reason":"native live request"]]
        store.desktop.onState?("test-old", ["requests":[nativeRequest]])
        let nativePrompt = store.prompts.first!
        precondition(nativePrompt.desktop && nativePrompt.params["command"] as? String == "echo native-fixture")
        store.desktop.onState?("test-old", ["requests":[nativeRequest]])
        precondition(store.prompts.first?.id == nativePrompt.id, "Stream updates must preserve prompt identity and typed answers")
        store.desktop.onState?("test-old", ["requests":[]])
        precondition(store.prompts.isEmpty, "Native completion/removal must clear the live request")
        print("PASS: native request snapshot streams into chat; stable identity across patches; resolved state clears request")
        precondition(store.nativeQueuedMessages["test-old"]?.count == 2 && store.nativeQueuedMessages["test-old"]?.first?.isServerQueue == true)
        let nativeFirst = store.nativeQueuedMessages["test-old"]!.first!
        _ = await store.editNativeQueued(nativeFirst, in: "test-old", text: "Gezielt geändert")
        precondition(store.nativeQueuedMessages["test-old"]?.first?.text == "Gezielt geändert" && store.nativeQueuedMessages["test-old"]?.count == 2)
        await store.moveNativeQueued(nativeFirst.id, in: "test-old", offset: 1)
        precondition(store.nativeQueuedMessages["test-old"]?.map(\.id) == ["server-queue-2", nativeFirst.id])
        await store.moveNativeQueued(nativeFirst.id, in: "test-old", before: "server-queue-2")
        precondition(store.nativeQueuedMessages["test-old"]?.first?.id == nativeFirst.id)
        _ = try await connection.request("test/queue-failure", ["enabled":true]); await store.refreshNativeQueue()
        precondition(store.nativeQueuedMessages["test-old"]?.count == 2, "Failed queue reads must preserve both messages")
        _ = try await connection.request("test/queue-failure", ["enabled":false])
        await store.removeNativeQueued(nativeFirst.id, in: "test-old")
        precondition(store.nativeQueuedMessages["test-old"]?.map(\.id) == ["server-queue-2"], "Deleting one native submission must preserve others")
        _ = try await connection.request("test/queue-empty"); await store.refreshNativeQueue()
        precondition(store.nativeQueuedMessages["test-old"]?.isEmpty == true)
        print("PASS: real server queue contract → list → individual update preserving sibling → transient read failure retains → delete one → confirmed empty clears")
        async let firstAgents: () = store.loadSubagents("test-third-root")
        async let secondAgents: () = store.loadSubagents("test-second-root")
        _ = await (firstAgents, secondAgents)
        precondition(store.subagents["test-second-root"]?.count == 1 && store.subagents["test-third-root"]?.count == 1, "Simultaneous expansions must each load their own descendants")
        precondition(store.subagents["test-old"]?.count == 3 && store.subagents["test-old"]?.contains { $0.id == "test-unrelated" } == false)
        precondition(!store.recentChats.contains { $0.id == "test-outdated" })
        precondition(!store.canSend, "Isolated server must not take over external chats")
        await store.loadHistory(older: true)
        precondition(store.messages.map(\.text) == ["Ältere Antwort", "Neuere Antwort"])
        await store.loadHistory()
        precondition(store.messages.map(\.text) == ["Ältere Antwort", "Neuere Antwort"], "Refreshing must preserve chronological order")
        print("PASS: handshake, Unicode, real pagination, chronological history and external-chat protection")
        async let first = connection.request("test/first")
        async let second = connection.request("test/second")
        let (a, b) = try await (first, second)
        precondition(a["value"] as? Int == 1 && b["value"] as? Int == 2)
        do { _ = try await connection.request("test/error"); fatalError("Error response swallowed") }
        catch { precondition(error.localizedDescription == "fixture rejection") }
        print("PASS: fragmented JSONL, out-of-order responses and RPC errors")
        await store.loadComposerContext()
        precondition(store.models.first?.id == "fixture-model" && store.availableReferences.count == 5 && store.availableReferences.contains { $0.name == "Eigenes MCP" } && store.availableReferences.contains { $0.name == "AlphaTraderMCP" && $0.path == "app://fixture-app-2" })
        let files = await store.searchReferenceFiles("test")
        precondition(files.first?.path == "/tmp/test.txt")
        print("PASS: all-chat history vs 24h popup, model catalog, installed app/plugin/skill mentions and scoped file search")
        store.newChat(); store.workingDirectory = "/tmp"
        let accepted = await store.send("Testnachricht")
        precondition(accepted)
        for _ in 0..<100 where store.prompts.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(store.selectedID == "test-new")
        precondition(store.messages.map(\.text) == ["Testnachricht", "Hallo äöü!"])
        precondition(defaults.stringArray(forKey: "macToolsCodexThreads") == ["test-new"])
        store.enqueue("Steuerung", in: "test-new")
        let steerID = store.queuedMessages["test-new"]!.first!.id
        let steered = await store.deliverQueued(steerID, in: "test-new", steer: true)
        precondition(steered && store.queuedMessages["test-new"]?.isEmpty == true && store.currentTurn != nil)
        let queuedDuringRun = await store.submit("Sofort")
        precondition(queuedDuringRun && store.queuedMessages["test-new"]?.count == 1)
        let editingID = store.queuedMessages["test-new"]!.first!.id
        store.setQueueEditing(editingID, in: "test-new", editing: true)
        let prompt = store.prompts.first!
        store.answer(prompt, result: ["decision": "decline"])
        for _ in 0..<100 where store.currentTurn != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(store.currentTurn == nil && store.prompts.isEmpty)
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(store.queuedMessages["test-new"]?.count == 1, "An open queue editor must suspend automatic dispatch")
        store.setQueueEditing(editingID, in: "test-new", editing: false)
        for _ in 0..<100 where !(store.queuedMessages["test-new"] ?? []).isEmpty || store.sending { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(store.queuedMessages["test-new"]?.isEmpty == true)
        print("PASS: busy chat queues by default; immediate steer; editing suspends dispatch; next turn drains after completion")
        precondition(store.activity == "Antwort abgeschlossen")
        print("PASS: new chat, send, stream, final readback, approval decline and completion")
        let fast = await store.send("Sofort")
        precondition(fast && store.currentTurn == nil && store.activity == "Antwort abgeschlossen", "Rapid completion must not resurrect a finished turn")
        store.options["test-new"] = CodexTurnOptions(model: "fixture-model", effort: "high", permission: "ask", mode: "plan")
        let settingsAccepted = await store.send("Optionscheck", references: [CodexReference(name: "Prüfskill", path: "/tmp/SKILL.md", kind: "skill")]); precondition(settingsAccepted)
        print("PASS: model, reasoning, plan mode, bounded permissions and structured mention sent in turn request")
        store.options["test-new"] = CodexTurnOptions()
        store.enqueue("Sofort", in: "test-new")
        let queued = store.queuedMessages["test-new"]!.first!
        precondition(CodexStore(connection: CodexConnection(executableURL: fixture), defaults: defaults).queuedMessages["test-new"]?.first?.text == "Sofort")
        store.editQueued(queued.id, in: "test-new", text: "Sofort")
        let queuedAccepted = await store.deliverQueued(queued.id, in: "test-new", steer: false)
        precondition(queuedAccepted && store.queuedMessages["test-new"]?.isEmpty == true)
        print("PASS: queued messages persist, edit, deliver through original thread and clear only after receipt")
        _ = try await connection.request("test/activity")
        for _ in 0..<100 where store.messages.last?.activity?.durationMs != 1500 { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(store.messages.last?.activity?.output == "Ausgabe äöü" && store.messages.last?.activity?.exitCode == 0)
        print("PASS: native command start timestamps, live output deltas, final output, duration and exit code")

        store.options["test-new"] = CodexTurnOptions()
        let pending = await store.send("Offene Anfrage")
        precondition(pending)
        for _ in 0..<100 where store.prompts.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!store.prompts.isEmpty)
        do { _ = try await connection.request("test/exit"); fatalError("Lost connection ignored") }
        catch { precondition(!store.connected && store.currentTurn == nil && store.prompts.isEmpty) }
        print("PASS: pending requests fail promptly when the subprocess exits")
        if CommandLine.arguments.contains("--inference") {
            let rpc = CodexConnection()
            var finalStatus: String?
            var reply = ""
            rpc.onRequest = { id, _, _ in try? rpc.reject(id: id) }
            rpc.onEvent = { method, params in
                if method == "item/agentMessage/delta" { reply += params["delta"] as? String ?? "" }
                if method == "turn/completed" { finalStatus = (params["turn"] as? [String: Any])?["status"] as? String }
            }
            try await rpc.connect()
            let result = try await rpc.request("thread/start", ["cwd": "/tmp", "ephemeral": true])
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else { fatalError("ephemeral thread missing") }
            _ = try await rpc.request("turn/start", ["threadId": id, "input": [["type": "text", "text": "Antworte ausschließlich mit MACTOOLS_OK. Verwende keine Tools und ändere keine Dateien."]]])
            for _ in 0..<300 where finalStatus == nil { try await Task.sleep(nanoseconds: 200_000_000) }
            precondition(finalStatus == "completed" && reply.contains("MACTOOLS_OK"), "Inference failed: \(finalStatus ?? "timeout") \(reply)")
            print("PASS: real ephemeral Codex turn → streamed MACTOOLS_OK → completed (no persisted chat)")
            rpc.stop()
        }
        if CommandLine.arguments.contains("--live") {
            let live = CodexStore(defaults: defaults)
            await live.connect()
            precondition(live.connected, live.error ?? "live connection failed")
            precondition(!live.chats.isEmpty)
            await live.select(live.chats[0].id)
            precondition(!live.messages.isEmpty, live.error ?? "live history missing")
            precondition(live.error == nil, live.error ?? "")
            await live.loadComposerContext()
            precondition(!live.models.isEmpty, "Live model catalog missing")
            print("LIVE composer: \(live.models.count) models, \(live.availableReferences.count) available references")
            print("LIVE: \(live.chats.count) loaded root chats; \(live.subagents[live.chats[0].id]?.count ?? 0) descendants of selected root")
            print("PASS: installed Codex CLI → stored chat list → persisted message readback (no prompt sent)")
            live.stop()
        }
    }
}
