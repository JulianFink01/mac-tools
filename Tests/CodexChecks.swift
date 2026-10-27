import Foundation
import SQLite3

@main
struct CodexChecks {
    @MainActor
    static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.contains("--local-stats") {
            let stats = try CodexLocalStats.read()
            print("LOCAL-STATS: \(stats.totalTokens) tokens, \(stats.chats) chats, \(stats.chatsWithTokens) chats with tokens, \(stats.models.count) models")
            return
        }
        let statsHome = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-stats-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: statsHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: statsHome) }
        let statsURL = statsHome.appendingPathComponent("state_10.sqlite")
        var statsDB: OpaquePointer?
        precondition(sqlite3_open(statsURL.path, &statsDB) == SQLITE_OK)
        precondition(sqlite3_exec(statsDB, "CREATE TABLE threads(tokens_used INTEGER,model TEXT); INSERT INTO threads VALUES(12345678900,'model-a'),(100,'model-a'),(50,'model-b'),(0,NULL),(-5,'');", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(statsDB)
        // Numeric version ordering must prefer state_10 over state_9.
        try Data().write(to: statsHome.appendingPathComponent("state_9.sqlite"))
        let statsBefore = try Data(contentsOf: statsURL)
        let localStats = try CodexLocalStats.read(home: statsHome)
        precondition(localStats.totalTokens == 12345679050 && localStats.chats == 5 && localStats.chatsWithTokens == 3)
        precondition(localStats.models.first(where: { $0.name == "model-a" })?.chats == 2 && localStats.models.first(where: { $0.name == "Unbekannt" })?.chats == 2)
        let statsAfter = try Data(contentsOf: statsURL)
        precondition(statsAfter == statsBefore, "Local usage must never modify the Codex database")
        print("PASS: persisted 64-bit token totals, model distribution, unknown models, numeric DB versions and read-only database access")
        var disclosure = CodexActivityExpansionState()
        precondition(!disclosure.group(thread:"one",ids:["a","b"],running:true))
        precondition(!disclosure.detail(thread:"one",id:"a",running:true))
        disclosure.rememberDetail(thread:"one",id:"a",running:true)
        precondition(!disclosure.detail(thread:"one",id:"a",running:false))
        disclosure.rememberGroup(thread:"one",ids:["a","b"],running:true)
        disclosure.setGroup(true,thread:"one",ids:["a","b"])
        disclosure.rememberGroup(thread:"one",ids:["b","new"],running:false)
        precondition(disclosure.group(thread:"one",ids:["b","new"],running:false))
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
        precondition(disclosure.groupAnchor(thread:"one",ids:["prefix","a","b","c"]) == "a")
        disclosure.rememberGroup(thread:"one",ids:["prefix","a","b","c","tail"],running:true)
        precondition(disclosure.groupAnchor(thread:"one",ids:["b","c","tail"]) == "a", "Prepending, streaming and trimming history must preserve the visible activity group's anchor")
        precondition(disclosure.groupAnchor(thread:"two",ids:["prefix","b"]) == "prefix")
        print("PASS: activities and commands default closed even while running; opened and closed command choices survive streaming, completion and moving history groups; isolated per chat")
        func elicitation(_ params:[String:Any]) -> CodexPrompt { CodexPrompt(id:UUID(),requestID:959,method:"mcpServer/elicitation/request",threadID:"test-old",params:params) }
        let emptyForm: [String:Any] = ["mode":"form","requestedSchema":["type":"object","properties":[:]]]
        precondition(elicitation(emptyForm).elicitationAcceptance?["action"] as? String == "accept")
        precondition((elicitation(emptyForm).elicitationAcceptance?["content"] as? [String:Any])?.isEmpty == true)
        precondition(elicitation(["mode":"form","requestedSchema":["type":"object","properties":["approved":["type":"boolean"]],"required":["approved"]]]).elicitationAcceptance?["content"] as? [String:Bool] == ["approved":true])
        precondition(elicitation(["mode":"url"]).elicitationAcceptance == nil)
        precondition(elicitation(["mode":"openai/userVerification"]).elicitationAcceptance == nil)
        precondition(elicitation(["mode":"form","requestedSchema":["type":"object","properties":["password":["type":"string"]]]]).elicitationAcceptance == nil)
        print("PASS: unambiguous MCP approval forms accept the exact schema; verification, URL and unsupported input remain native")
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
        let questionTurns: [[String:Any]] = [["id":"async-turn","status":"inProgress","items":[["id":"call/id","type":"agentMessage","text":"","questions":[["title":"Frage?","options":["A","B"]]]]]]]
        let pendingQuestion = CodexAsyncQuestion.pending(in:questionTurns).first!
        precondition(pendingQuestion.id == "[\"request_user_input_async\",\"call/id\",0]")
        let reply = CodexQuestionReply.message([CodexQuestionReply(questionItemId:pendingQuestion.id,question:"Frage?",answer:"B")])!
        precondition(CodexQuestionReply.parse(reply)?.first?.answer == "B")
        var answeredTurns=questionTurns;var questionItems=answeredTurns[0]["items"] as! [[String:Any]]
        questionItems.append(["id":"answer","type":"userMessage","content":[["type":"text","text":reply]]]);answeredTurns[0]["items"]=questionItems
        precondition(CodexAsyncQuestion.pending(in:answeredTurns).isEmpty)
        var idleQuestionTurns = questionTurns; idleQuestionTurns[0]["status"] = "completed"
        precondition(CodexAsyncQuestion.pending(in:idleQuestionTurns) == [pendingQuestion])
        let laterAnswer: [String:Any] = ["id":"later-turn","status":"completed","items":[["id":"later-answer","type":"userMessage","content":[["type":"text","text":"Zusätzlicher Kontext"],["type":"text","text":reply]]]]]
        precondition(CodexAsyncQuestion.pending(in:idleQuestionTurns + [laterAnswer]).isEmpty)
        let rejectedAnswer: [String:Any] = ["id":"rejected-turn","status":"completed","items":[["id":"rejected-answer","type":"steeringUserMessage","status":"rejected","input":[["type":"text","text":reply]]]]]
        precondition(CodexAsyncQuestion.pending(in:idleQuestionTurns + [rejectedAnswer]) == [pendingQuestion])
        let ordinaryReply: [String:Any] = ["id":"normal-reply","status":"completed","items":[["id":"user-normal","type":"userMessage","content":[["type":"text","text":"volume ist da jetzt"]]]]]
        precondition(CodexAsyncQuestion.pending(in:idleQuestionTurns + [ordinaryReply]).isEmpty)
        let restoredReply: [String:Any] = ["status":"completed","items":[["id":"restored-user","type":"steeringUserMessage","status":"accepted","restoreMessage":["text":"volume ist da jetzt"]]]]
        precondition(CodexAsyncQuestion.pending(in:idleQuestionTurns + [restoredReply]).isEmpty)
        let plainReply: [String:Any] = ["status":"completed","items":[["id":"plain-user","type":"userMessage","text":"volume ist da jetzt"]]]
        precondition(CodexAsyncQuestion.pending(in:idleQuestionTurns + [plainReply]).isEmpty)
        let followupQuestion: [String:Any] = ["id":"next-question","status":"completed","items":[["id":"call-2","type":"agentMessage","questions":[["title":"Neue Frage?"]]]]]
        precondition(CodexAsyncQuestion.pending(in:idleQuestionTurns + [ordinaryReply, followupQuestion]).count == 1)
        precondition(CodexQuestionReply.parse("<send_user_message_question_reply>invalid</send_user_message_question_reply>") == nil)
        print("PASS: async question identity matches native JSON contract; structured reply rendered and accepted answers resolve questions")
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
        let savedWindows = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-window-restore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: savedWindows, withIntermediateDirectories: true)
        let savedWindowID = UUID()
        let savedState: [String:Any] = ["selectedChatID":"test-restored", "macToolsCodexThreads":["test-restored"], "codexChatDrafts":["test-restored":"Entwurf mit Bild"]]
        try PropertyListSerialization.data(fromPropertyList: savedState, format: .binary, options: 0).write(to: savedWindows.appendingPathComponent("com.julianfink.MacTools.ChatWindow." + savedWindowID.uuidString + ".plist"))
        precondition(CodexSavedWindow.find(chatID: "test-restored", excluding: [], directory: savedWindows) == savedWindowID)
        precondition(CodexSavedWindow.find(chatID: "test-restored", excluding: [savedWindowID], directory: savedWindows) == nil)
        precondition(CodexSavedWindow.find(chatID: "other-chat", excluding: [], directory: savedWindows) == nil)
        try FileManager.default.removeItem(at: savedWindows)
        print("PASS: reopening a closed window after app restart reuses its persisted session; active windows and other chats remain isolated")
        let lifecycleDomain = "MacTools.thread-lifecycle." + UUID().uuidString
        let lifecycleDefaults = UserDefaults(suiteName: lifecycleDomain)!
        let lifecycleRPC = CodexConnection(executableURL: fixture, environment: ["MACTOOLS_TEST_THREAD_LIFECYCLE":"1"])
        let lifecycle = CodexStore(connection: lifecycleRPC, defaults: lifecycleDefaults)
        await lifecycle.connect(); lifecycle.newChat(inFolder: "/tmp")
        let initialLifecycleSend = await lifecycle.send("Sofort")
        precondition(initialLifecycleSend)
        for _ in 0..<100 where lifecycle.currentTurn != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let attachment = CodexReference(name: "draft.png", path: "/tmp/draft.png", kind: "image")
        lifecycle.drafts["test-new"] = "Entwurf mit Bild"
        lifecycle.references["test-new"] = [attachment]
        lifecycle.stop()
        precondition(lifecycle.currentTurn == nil && lifecycle.drafts["test-new"] == "Entwurf mit Bild" && lifecycle.references["test-new"] == [attachment])
        await lifecycle.connect(); await lifecycle.select("test-new")
        let reopenedSend = await lifecycle.send("Sofort", references: [attachment])
        precondition(reopenedSend, lifecycle.error ?? "Reopened turn failed")
        let reopenedState = try await lifecycleRPC.request("test/runtime-state")
        precondition(reopenedSend && reopenedState["resumes"] as? Int == 1 && reopenedState["attempts"] as? Int == 1 && reopenedState["turns"] as? Int == 1, "Reopening the same window must resume its thread in the new process before starting a turn")
        precondition((reopenedState["input"] as? [[String:Any]])?.last?["path"] as? String == "/tmp/draft.png")
        for _ in 0..<100 where lifecycle.currentTurn != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        _ = try await lifecycleRPC.request("test/unload-thread", ["threadId":"test-new"])
        let recoveredSend = await lifecycle.send("Sofort", references: [attachment])
        precondition(recoveredSend, lifecycle.error ?? "Runtime recovery failed")
        let recoveredState = try await lifecycleRPC.request("test/runtime-state")
        precondition(recoveredSend && recoveredState["resumes"] as? Int == 2 && recoveredState["attempts"] as? Int == 3 && recoveredState["turns"] as? Int == 2, "Only an explicitly rejected start may be retried after rehydration; it must execute exactly once")
        precondition((recoveredState["input"] as? [[String:Any]])?.last?["path"] as? String == "/tmp/draft.png")
        for _ in 0..<100 where lifecycle.currentTurn != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        _ = try await lifecycleRPC.request("test/start-error", ["message":"upstream timeout; delivery unknown"])
        let ambiguousSend = await lifecycle.send("Sofort", references: [attachment])
        let ambiguousState = try await lifecycleRPC.request("test/runtime-state")
        precondition(!ambiguousSend && ambiguousState["resumes"] as? Int == 2 && ambiguousState["attempts"] as? Int == 4 && ambiguousState["turns"] as? Int == 2, "An ambiguous failure must not resume or resend")
        precondition(lifecycle.drafts["test-new"] == "Entwurf mit Bild" && lifecycle.references["test-new"] == [attachment])
        _ = try await lifecycleRPC.request("test/start-error")
        _ = try await lifecycleRPC.request("test/unload-thread", ["threadId":"test-new"])
        lifecycle.enqueue("Sofort", references: [attachment], in: "test-new")
        let recoveredQueueID = lifecycle.queuedMessages["test-new"]!.first!.id
        let recoveredQueueSend = await lifecycle.deliverQueued(recoveredQueueID, in: "test-new", steer: false)
        let queueState = try await lifecycleRPC.request("test/runtime-state")
        precondition(recoveredQueueSend && lifecycle.queuedMessages["test-new"]?.isEmpty == true && queueState["resumes"] as? Int == 3 && queueState["attempts"] as? Int == 6 && queueState["turns"] as? Int == 3)
        lifecycle.stop(); lifecycleDefaults.removePersistentDomain(forName: lifecycleDomain)
        precondition(CodexStore.followTargets(recent: [], selectedID: "old-selected", followAll: false, archived: false) == ["old-selected"])
        precondition(CodexStore.followTargets(recent: [], selectedID: "archived-selected", followAll: true, archived: true) == ["archived-selected"])
        print("PASS: close/reopen rehydrates thread; lost runtime recovers once; text/image retained; ambiguous send never retried; queued delivery executes once; old/archived selected chats stay subscribed")
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
        precondition(startState["metadataAttempts"] as? Int == 0, "Project is persisted atomically at thread/start, before rollout hydration")
        projectStore.newChat(); projectStore.selectNewChatProject(nil)
        precondition(projectStore.newChatProjectID == nil && projectStore.workingDirectory == NSHomeDirectory())
        projectStore.newChat(inFolder: "/tmp/destination")
        precondition(projectStore.newChatProjectID == chosen.id && projectStore.workingDirectory == "/tmp/destination")
        projectStore.stop(); projectDefaults.removePersistentDomain(forName: projectDomain)
        print("PASS: existing project selectable for every new chat; project and cwd captured; assignment confirmed after first accepted turn; folder shortcut preselects project")
        let retryDomain = "MacTools.project-retry." + UUID().uuidString
        let retryDefaults = UserDefaults(suiteName: retryDomain)!
        retryDefaults.set(["test-old":"project-fixture"],forKey:"codexPendingProjectAssignments")
        let retryConnection = CodexConnection(executableURL:fixture,environment:["MACTOOLS_TEST_PROJECT_STARTUP_FAILURE":"1"])
        let retryStore = CodexStore(connection:retryConnection,defaults:retryDefaults)
        await retryStore.connect()
        precondition(retryStore.error == nil, "An empty startup rollout is deferred without leaking raw metadata errors")
        await retryStore.select("test-old")
        retryStore.error = "Die Nachricht wurde übergeben. Die Projektzuordnung wird erneut versucht: alter Fehler"
        await retryStore.refresh(); await retryStore.refresh()
        precondition(retryStore.error == nil && retryDefaults.dictionary(forKey:"codexPendingProjectAssignments")?.isEmpty == true)
        precondition(retryStore.selected?.projectID == "project-fixture")
        let retryStats = try await retryConnection.request("test/start-state")
        precondition(retryStats["turns"] as? Int == 0 && retryStats["metadataAttempts"] as? Int == 3, "Metadata retries must never resend a user turn")
        retryStore.stop();retryDefaults.removePersistentDomain(forName:retryDomain)
        print("PASS: transient empty rollout retries metadata only; confirmed project clears its stale warning")
        let runtimeQueue = CodexQueueRepository(defaults:defaults)
        let ownerConnection = CodexConnection(executableURL:fixture)
        let ownerView = CodexStore(connection:ownerConnection,defaults:defaults,queue:runtimeQueue)
        let menuView = CodexStore(connection:CodexConnection(executableURL:fixture),defaults:defaults,queue:runtimeQueue)
        await ownerView.connect(); await menuView.connect();ownerView.newChat(inFolder:"/tmp")
        let startedLocally = await ownerView.send("Lokal gestartet")
        precondition(startedLocally)
        await menuView.refresh()
        precondition(menuView.liveChats.contains { $0.id == "test-new" && $0.status == "active" } && menuView.runningCount == 1, "A different app-server omits the newly started chat and its runtime; the menu still sees the owner's summary")
        precondition(menuView.listedChats.contains { $0.id == "test-new" && $0.status == "active" })
        precondition(runtimeQueue.hasLocalWork, "Quitting the host must be guarded while this connection executes a turn")
        await menuView.archive(["test-new"])
        precondition(menuView.error?.contains("Laufenden Chat zuerst beenden") == true && menuView.runningCount == 1, "An independently opened list must not archive another window's active turn")
        _ = try await ownerConnection.request("test/complete-turn")
        try await Task.sleep(nanoseconds:50_000_000)
        precondition(menuView.runningCount == 0 && menuView.liveChats.first { $0.id == "test-new" }?.status == "idle", "Completion must clear the shared active runtime")
        precondition(!runtimeQueue.hasLocalWork, "Completed local turns must not keep the quit guard active")
        ownerView.stop();menuView.stop()
        precondition(runtimeQueue.ownedChats.isEmpty)
        print("PASS: new chat and completion visible across independent window/menu connections without shared transcripts")
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
        _ = try await store.connection.request("test/usage-failure",["mode":"once"])
        await store.loadUsage(force:true)
        precondition(store.usageError == nil && store.usageBuckets.first?.windows.first?.remaining == 70)
        let refreshStats = try await store.connection.request("test/usage-refresh-stats")
        precondition(refreshStats["refreshes"] as? Int == 1)
        _ = try await store.connection.request("test/usage-failure",["mode":"always"])
        await store.loadUsage(force:true)
        precondition(store.usageError?.contains("Anmeldung") == true && store.usageError?.contains("401") == false)
        let afterAuthFailure = try await store.connection.request("test/usage-refresh-stats")
        await store.loadUsage()
        let afterThrottle = try await store.connection.request("test/usage-refresh-stats")
        precondition(afterAuthFailure["refreshes"] as? Int == afterThrottle["refreshes"] as? Int)
        _ = try await store.connection.request("test/usage-failure",["mode":"server"])
        await store.loadUsage(force:true)
        let afterServerFailure = try await store.connection.request("test/usage-refresh-stats")
        precondition(afterServerFailure["refreshes"] as? Int == afterAuthFailure["refreshes"] as? Int)
        _ = try await store.connection.request("test/usage-failure")
        await store.loadUsage(force:true)
        precondition(store.usageError == nil)
        print("PASS: expired usage credential refreshed through account/read once; failed and generic requests throttled, stale values labelled, no reset/credits or credential extraction")
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
        store.desktop.onState?("test-old", ["turns":[["id":"fallback","items":[["id":"stored-0-1","type":"userMessage","content":[["type":"text","text":"<environment_context>bootstrap</environment_context>"]]]]]]])
        for _ in 0..<100 where !store.messages.contains(where: { $0.id == "stored-0-1" }) { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(store.messages.contains { $0.id == "stored-0-1" })
        await store.loadHistory()
        precondition(store.messages.map(\.text) == ["Neuere Antwort"], "Canonical recovery must replace raw rollout fallback rows instead of duplicating internal scaffolding")
        let nativeRequest: [String:Any] = ["id":"native-request-1", "method":"item/commandExecution/requestApproval", "params":["threadId":"test-old","command":"echo native-fixture","reason":"native live request"]]
        store.desktop.onState?("test-old", ["requests":[nativeRequest]])
        let nativePrompt = store.prompts.first!
        precondition(nativePrompt.desktop && nativePrompt.params["command"] as? String == "echo native-fixture")
        store.desktop.onState?("test-old", ["requests":[nativeRequest]])
        precondition(store.prompts.first?.id == nativePrompt.id, "Stream updates must preserve prompt identity and typed answers")
        precondition(store.waitingCount == 1)
        var completedRequest = nativeRequest;completedRequest["completed"] = true
        store.desktop.onState?("test-old",["requests":[completedRequest]])
        precondition(store.prompts.isEmpty && store.waitingCount == 0,"Completed requests retained in native history are not pending input")
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
        precondition(store.olderCursor == nil, "Refreshing the recent tail must not reopen completed pagination")
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
        let questionDomain="MacTools.AsyncQuestionChecks." + UUID().uuidString, questionPrefs=UserDefaults(suiteName:questionDomain)!
        defer { questionPrefs.removePersistentDomain(forName:questionDomain) }
        questionPrefs.set(["test-old"],forKey:"macToolsCodexThreads")
        let questionConnection=CodexConnection(executableURL:fixture)
        let questionStore=CodexStore(connection:questionConnection,defaults:questionPrefs,followAllChats:false)
        await questionStore.connect()
        _ = try await questionConnection.request("test/async-question")
        await questionStore.select("test-old")
        precondition(questionStore.asyncQuestions.count == 1 && questionStore.waitingCount == 1 && questionStore.activityHistory.last?.waiting == 1)
        questionStore.drafts["test-old"]="Unveränderter Entwurf"
        let sentQuestion = await questionStore.answerAsync(questionStore.asyncQuestions[0],answer:"Details")
        precondition(sentQuestion && questionStore.asyncQuestions.isEmpty && questionStore.drafts["test-old"] == "Unveränderter Entwurf")
        let answerState = try await questionConnection.request("test/async-answer-state")
        precondition(answerState["answered"] as? Bool == true)
        precondition(questionStore.waitingCount == 0)
        _ = try await questionConnection.request("test/async-question", ["idle": true])
        await questionStore.select("test-old")
        precondition(questionStore.currentTurn == nil && questionStore.asyncQuestions.count == 1 && questionStore.waitingCount == 1)
        let idleSent = await questionStore.answerAsync(questionStore.asyncQuestions[0], answer: "Details")
        let idleState = try await questionConnection.request("test/async-answer-state")
        precondition(idleSent && idleState["method"] as? String == "turn/start" && questionStore.asyncQuestions.isEmpty && questionStore.waitingCount == 0)
        precondition(questionStore.drafts["test-old"] == "Unveränderter Entwurf")
        print("PASS: completed-turn question remains answerable while idle, starts a new turn, preserves draft, resolves across later turns and clears waiting status")
        _ = try await questionConnection.request("test/elicitation")
        for _ in 0..<100 where questionStore.prompts.isEmpty { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(questionStore.prompts.count == 1 && questionStore.waitingCount == 1 && questionStore.activityHistory.last?.waiting == 1)
        let consent = questionStore.prompts[0]
        questionStore.answer(consent,result:consent.elicitationAcceptance!)
        for _ in 0..<100 where !questionStore.prompts.isEmpty { try await Task.sleep(nanoseconds:10_000_000) }
        let consentState = try await questionConnection.request("test/elicitation-state")
        precondition(consentState["accepted"] as? Bool == true && questionStore.waitingCount == 0 && questionStore.activityHistory.last?.waiting == 0)
        print("PASS: MCP consent explicitly accepted; pending inputs appear once in menu counts and clear after response")
        questionStore.stop()
        print("PASS: async question answered via immediate steering while running, exact reply identity, acknowledged removal and unchanged composer draft")
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
