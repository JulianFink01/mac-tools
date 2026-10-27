import SwiftUI
import Charts

struct CodexGoalStrip: View {
    @ObservedObject var store: CodexStore
    let goal: CodexGoal
    let edit: () -> Void
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Button(action: edit) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "target").foregroundStyle(goal.status == "active" ? Color.mint : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(goal.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            Text(goal.objective).font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help("Ziel bearbeiten")
                VStack(alignment: .trailing, spacing: 4) { Text(goal.durationLabel); Text(goal.tokens.formatted() + (goal.budget.map { " / " + $0.formatted() } ?? "") + " Tokens") }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                Button { change("set", fields: ["status": goal.isRunning ? "paused" : "active"]) } label: {
                    Image(systemName: goal.isRunning ? "pause.circle" : "play.circle").font(.system(size: 16)).frame(width: 26, height: 28)
                }.buttonStyle(.plain).help(goal.isRunning ? "Ziel pausieren" : "Ziel fortsetzen").accessibilityLabel(goal.isRunning ? "Ziel pausieren" : "Ziel fortsetzen").disabled(busy)
                Button { change("clear") } label: { Image(systemName: "trash").font(.system(size: 13)).frame(width: 26, height: 28) }
                    .buttonStyle(.plain).help("Ziel entfernen").accessibilityLabel("Ziel entfernen").disabled(busy)
                if busy { ProgressView().controlSize(.mini) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(.horizontal, 12).padding(.vertical, 10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    private func change(_ operation: String, fields: [String: Any] = [:]) {
        busy = true
        Task { do { _ = try await store.goal(operation, fields: fields); await store.loadGoal(); error = nil } catch { self.error = error.localizedDescription }; busy = false }
    }
}

struct CodexScheduledChat: Identifiable, Equatable {
    let id: String
    let name: String
    let prompt: String
    let status: String
    let schedule: String
    let threadID: String?
    static func load(root: URL) -> [Self] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let text = try? String(contentsOf: folder.appendingPathComponent("automation.toml"), encoding: .utf8) else { return nil }
            func value(_ key: String) -> String? {
                guard let regex = try? NSRegularExpression(pattern: "(?m)^" + key + #"\s*=\s*(\"(?:[^\"\\]|\\.)*\"|'[^']*')\s*$"#), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
                let raw = String(text[range])
                if raw.hasPrefix("'") { return String(raw.dropFirst().dropLast()) }
                return ((try? JSONSerialization.jsonObject(with: Data(("[" + raw + "]").utf8))) as? [String])?.first
            }
            guard let id = value("id"), let name = value("name") else { return nil }
            return Self(id: id, name: name, prompt: value("prompt") ?? "", status: value("status") ?? "UNKNOWN", schedule: value("rrule") ?? "", threadID: value("target_thread_id"))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    var scheduleLabel: String {
        let fields = Dictionary(schedule.split(separator: ";").compactMap { piece -> (String, String)? in let pair = piece.split(separator: "=", maxSplits: 1); return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil }, uniquingKeysWith: { _, new in new })
        let interval = fields["INTERVAL"] ?? "1"
        switch fields["FREQ"] {
        case "MINUTELY": return "Alle " + interval + " Minuten"
        case "HOURLY": return "Alle " + interval + " Stunden"
        case "DAILY": return "Täglich" + (fields["BYHOUR"].map { " · " + $0 + ":" + (fields["BYMINUTE"] ?? "00") } ?? "")
        case "WEEKLY": return "Wöchentlich" + (fields["BYDAY"].map { " · " + $0 } ?? "")
        default: return "Zeitplan in Codex"
        }
    }
    static func open(_ id: String? = nil, edit: Bool = false) {
        var parts = URLComponents(); parts.scheme = "codex"; parts.host = "automations"
        if let id { parts.path = "/" + id; parts.queryItems = [URLQueryItem(name: "automationSource", value: "local"), URLQueryItem(name: "edit", value: edit ? "true" : "false")] }
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }
}

struct CodexScheduledChatsView: View {
    let openChat: (String) -> Void
    let close: () -> Void
    @State private var schedules: [CodexScheduledChat] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack { Button(action: close) { Label("Chats", systemImage: "chevron.left") }.buttonStyle(.plain); Spacer(); Button("In Codex verwalten") { CodexScheduledChat.open() } }
                Label("Geplante Chats", systemImage: "calendar.badge.clock").font(.largeTitle.bold())
                Text("Deine lokal gespeicherten Codex-Automationen. Ausführen, Zeitplan ändern und pausieren öffnest du über die zugehörige Steuerung in Codex.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if schedules.isEmpty { Text("Keine lokalen Automationen gefunden. Cloud-Zeitpläne stehen in Codex zur Verfügung.").foregroundStyle(.secondary).padding(.vertical, 30) }
                ForEach(schedules) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Image(systemName: "calendar").foregroundStyle(.mint); Text(item.name).font(.headline); Spacer(); Text(item.status == "ACTIVE" ? "Aktiv" : item.status == "PAUSED" ? "Pausiert" : item.status).font(.caption).foregroundStyle(item.status == "ACTIVE" ? Color.green : .secondary) }
                        Text(item.scheduleLabel).font(.caption).foregroundStyle(.secondary)
                        Text(item.prompt).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        HStack { Button("In Codex steuern") { CodexScheduledChat.open(item.id) }; Button("Zeitplan bearbeiten") { CodexScheduledChat.open(item.id, edit: true) }; if let id = item.threadID { Button("Chat öffnen") { openChat(id) } } }
                    }.padding(20).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }.task {
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex").appendingPathComponent("automations")
            schedules = await Task.detached(priority: .utility) { CodexScheduledChat.load(root: root) }.value
        }
    }
}

struct CodexGoalEditor: View {
    @ObservedObject var store: CodexStore
    @Environment(\.dismiss) private var dismiss
    @State private var objective = ""
    @State private var budget = ""
    @State private var status = ""
    @State private var tokens: Int64 = 0
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Label("Ziel dieses Chats", systemImage: "target").font(.title2.bold()); Spacer(); Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction) }
            TextEditor(text: $objective).font(.body).frame(minHeight: 100).padding(8).background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityLabel("Zielbeschreibung")
            HStack { Text("Token-Budget (optional)"); TextField("Unbegrenzt", text: $budget).frame(width: 150) }
            if !status.isEmpty { Text("Status: " + status + " · " + tokens.formatted() + " Tokens verwendet").font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if store.selectedID == nil { Text("Wähle zuerst einen bestehenden Chat oder starte eine Unterhaltung.").foregroundStyle(.secondary) }
            HStack {
                Button("Ziel speichern") { mutate("set", fields: ["objective": objective, "status": "active", "origin": "user"].merging(budgetValue) { _, new in new }) }.disabled(objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!budget.isEmpty && Int64(budget).map { $0 > 0 } != true))
                if !status.isEmpty {
                    Button(status == "active" ? "Pausieren" : "Fortsetzen") { mutate("set", fields: ["status": status == "active" ? "paused" : "active", "origin": "user"]) }
                    Button("Ziel entfernen") { mutate("clear") }
                }
                Spacer(); if busy { ProgressView().controlSize(.small) }
            }.disabled(busy || store.selectedID == nil)
        }.padding(24).frame(width: 560).task(id: store.selectedID) { await read() }
    }
    private var budgetValue: [String: Any] { if let value = Int64(budget), value > 0 { return ["tokenBudget": value] }; return [:] }
    @MainActor private func read() async {
        guard store.selectedID != nil else { return }; busy = true; defer { busy = false }
        do { apply(try await store.goal("get")); error = nil } catch { self.error = error.localizedDescription }
    }
    private func apply(_ response: [String: Any]) {
        if let goal = response["goal"] as? [String: Any] { objective = goal["objective"] as? String ?? ""; status = goal["status"] as? String ?? ""; budget = (goal["tokenBudget"] as? NSNumber)?.stringValue ?? ""; tokens = (goal["tokensUsed"] as? NSNumber)?.int64Value ?? 0 }
        else { objective = ""; budget = ""; status = ""; tokens = 0 }
    }
    private func mutate(_ operation: String, fields: [String: Any] = [:]) {
        busy = true
        Task { do { _ = try await store.goal(operation, fields: fields); apply(try await store.goal("get")); error = nil } catch { self.error = error.localizedDescription }; busy = false }
    }
}

struct CodexQueueStrip: View {
    @ObservedObject var store: CodexStore
    let threadID: String
    @State private var editing: CodexQueuedMessage?
    private var active: Bool { store.selected?.status == "active" || store.currentTurn != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Warteschlange · \((store.queuedMessages[threadID] ?? []).count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(store.queuedMessages[threadID] ?? []) { message in
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).help("Nachricht verschieben").onDrag { NSItemProvider(object: ("mactools-queue:" + threadID + ":" + message.id.uuidString) as NSString) }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(message.text.isEmpty ? "Anhänge" : message.text).font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                if !message.references.isEmpty { CodexQueueAttachments(references: message.references) }
                                if store.queueNeedsReview(message.id) { Text("Übergabe prüfen · bleibt gespeichert").font(.system(size: 10)).foregroundStyle(.orange) }
                            }
                            CodexQueueMoveButtons(index: (store.queuedMessages[threadID] ?? []).firstIndex(where: { $0.id == message.id }) ?? 0, count: (store.queuedMessages[threadID] ?? []).count) { offset in store.moveQueued(message.id, in: threadID, offset: offset) }.disabled(store.sending)
                            Button { Task { _ = await store.deliverQueued(message.id, in: threadID, steer: active) } } label: { Image(systemName: "arrow.turn.up.right").frame(width: 24, height: 25) }.buttonStyle(.plain).help(active ? "Jetzt steuern" : "Jetzt senden").accessibilityLabel(active ? "Jetzt steuern" : "Jetzt senden").disabled(store.sending)
                            Button { store.setQueueEditing(message.id, in: threadID, editing: true); editing = message } label: { Image(systemName: "pencil").frame(width: 24, height: 25) }.buttonStyle(.plain).help("Nachricht bearbeiten").accessibilityLabel("Wartende Nachricht bearbeiten")
                            Button { store.removeQueued(message.id, in: threadID) } label: { Image(systemName: "xmark").frame(width: 24, height: 25) }.buttonStyle(.plain).help("Aus Warteschlange entfernen").accessibilityLabel("Aus Warteschlange entfernen")
                        }.padding(9).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                            .onDrop(of: ["public.utf8-plain-text"], isTargeted: nil) { providers in CodexQueueDrop.receive(providers, prefix: "mactools-queue:" + threadID + ":") { source in if let id = UUID(uuidString: source) { store.moveQueued(id, in: threadID, before: message.id) } } }
                    }
                }
            }.scrollIndicators(.hidden).frame(height: min(180, CGFloat((store.queuedMessages[threadID] ?? []).count) * 76))
        }.sheet(item: $editing) { message in
            CodexQueueEditDialog(text: message.text, attachments: message.references.map(\.name)) { text in store.editQueued(message.id, in: threadID, text: text); return true }
                .onDisappear { store.setQueueEditing(message.id, in: threadID, editing: false) }
        }
    }
}
private struct CodexQueueEditDialog: View {
    let attachments: [String]
    let save: (String) async -> Bool
    @State private var text: String
    @State private var saving = false
    @State private var failed = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    init(text: String, attachments: [String] = [], save: @escaping (String) async -> Bool) {
        self.attachments = attachments; self.save = save; _text = State(initialValue: text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "pencil.line").font(.system(size: 19, weight: .medium)).foregroundStyle(.mint).frame(width: 42, height: 42).background(Color.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Nachricht bearbeiten").font(.system(size: 17, weight: .semibold))
                    Text("Deine wartende Nachricht").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26).background(Color.primary.opacity(0.06), in: Circle()) }.buttonStyle(.plain).help("Schließen").disabled(saving)
            }
            TextEditor(text: $text).font(.system(size: 14)).lineSpacing(4).scrollContentBackground(.hidden).padding(12)
                .frame(minHeight: 170, maxHeight: 270).background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.09), lineWidth: 1)).focused($focused).accessibilityLabel("Wartende Nachricht")
            if !attachments.isEmpty { Label(attachments.joined(separator: ", "), systemImage: "paperclip").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if failed { Label("Änderung nicht bestätigt. Bitte erneut prüfen.", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
            HStack(spacing: 12) {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.bordered).disabled(saving)
                Button("Änderung speichern") { Task { saving = true; failed = false; let success = await save(text); saving = false; if success { dismiss() } else { failed = true } } }
                    .keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent).tint(.mint)
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
            }.controlSize(.large)
        }.padding(24).frame(width: 560).background(Color(nsColor: .windowBackgroundColor))
            .onAppear { focused = true }.interactiveDismissDisabled(saving)
    }
}

struct CodexNativeQueueStrip: View {
    @ObservedObject var store: CodexStore
    let threadID: String
    @State private var busy = false
    @State private var editing: CodexNativeQueuedMessage?
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("In Codex wartend · \((store.nativeQueuedMessages[threadID] ?? []).count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(store.nativeQueuedMessages[threadID] ?? []) { message in
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).help("Nachricht verschieben").onDrag { NSItemProvider(object: ("mactools-native-queue:" + threadID + ":" + message.id) as NSString) }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.previewText).font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                if !message.attachments.isEmpty { CodexQueueAttachments(references: message.attachments) }
                            }
                            if message.isServerQueue {
                                let messages = (store.nativeQueuedMessages[threadID] ?? []).filter(\.isServerQueue)
                                CodexQueueMoveButtons(index: messages.firstIndex(where: { $0.id == message.id }) ?? 0, count: messages.count) { offset in Task { busy = true; await store.moveNativeQueued(message.id, in: threadID, offset: offset); busy = false } }
                            }
                            Button { store.openInCodex(threadID) } label: { Image(systemName: "arrow.up.right.square").frame(width: 24, height: 25) }.buttonStyle(.plain).help("Im Originalchat steuern").accessibilityLabel("Im Originalchat steuern")
                            Button { if message.isServerQueue { text = message.text; editing = message } else { store.openInCodex(threadID) } } label: { Image(systemName: "pencil").frame(width: 24, height: 25) }.buttonStyle(.plain).help(message.isServerQueue ? "Wartende Nachricht bearbeiten" : "Sicher im Originalchat bearbeiten")
                            Button { Task { busy = true; await store.removeNativeQueued(message.id, in: threadID); busy = false } } label: { Image(systemName: "xmark").frame(width: 24, height: 25) }.buttonStyle(.plain).help("Aus Codex-Warteschlange entfernen")
                        }.padding(9).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)).disabled(busy)
                            .onDrop(of: ["public.utf8-plain-text"], isTargeted: nil) { providers in CodexQueueDrop.receive(providers, prefix: "mactools-native-queue:" + threadID + ":") { source in Task { busy = true; await store.moveNativeQueued(source, in: threadID, before: message.id); busy = false } } }
                    }
                }
            }.scrollIndicators(.hidden).frame(height: min(180, CGFloat((store.nativeQueuedMessages[threadID] ?? []).count) * 76))
        }.sheet(item: $editing) { message in
            CodexQueueEditDialog(text: message.text) { text in
                busy = true; let success = await store.editNativeQueued(message, in: threadID, text: text); busy = false; return success
            }
        }
    }
}

private struct CodexQueueMoveButtons: View {
    let index: Int
    let count: Int
    let move: (Int) -> Void
    var body: some View {
        if count > 1 {
            VStack(spacing: 0) {
                Button { move(-1) } label: { Image(systemName: "chevron.up").frame(width: 18, height: 16) }.disabled(index == 0).help("Nachricht nach oben verschieben").accessibilityLabel("Nachricht nach oben verschieben")
                Button { move(1) } label: { Image(systemName: "chevron.down").frame(width: 18, height: 16) }.disabled(index + 1 >= count).help("Nachricht nach unten verschieben").accessibilityLabel("Nachricht nach unten verschieben")
            }.font(.system(size: 9, weight: .semibold)).buttonStyle(.plain)
        }
    }
}
private enum CodexQueueDrop {
    static func receive(_ providers: [NSItemProvider], prefix: String, move: @escaping @MainActor (String) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let value = value as? String, value.hasPrefix(prefix) else { return }
            Task { @MainActor in move(String(value.dropFirst(prefix.count))) }
        }; return true
    }
}
struct CodexQueueAttachments: View {
    let references: [CodexReference]
    var body: some View {
        ScrollView(.horizontal) { HStack(spacing: 6) { ForEach(references) { ref in CodexQueueAttachmentChip(reference: ref) } } }.scrollIndicators(.hidden).frame(height: 34)
    }
}
private struct CodexQueueAttachmentChip: View {
    let reference: CodexReference
    @State private var thumbnail: NSImage?
    @State private var preview = false
    var body: some View {
        Button {
            if reference.kind == "image" { preview = true }
            else if reference.path.hasPrefix("/") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: reference.path)]) }
        } label: {
            HStack(spacing: 6) {
                if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFill().frame(width: 32, height: 28).clipped().clipShape(RoundedRectangle(cornerRadius: 4)) }
                else { Image(systemName: reference.icon).frame(width: 20) }
                Text(reference.displayName).font(.system(size: 10)).lineLimit(1).frame(maxWidth: 170)
            }.padding(.horizontal, 6).padding(.vertical, 2).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(reference.path).accessibilityLabel("Anhang " + reference.displayName)
            .task(id: reference.path) { if reference.kind == "image" { let path = reference.path; let data = await Task.detached(priority: .utility) { CodexChatImage.thumbnailData(path, maximum: 96) }.value; thumbnail = data.flatMap(NSImage.init(data:)) } }
            .popover(isPresented: $preview) { CodexChatImage(source: reference.path).padding(14).frame(width: 510, height: 310) }
    }
}

struct CodexUsageWidget: View {
    @ObservedObject var store: CodexStore = .shared
    var compact = false
    var featured = false
    var height: CGFloat = 64
    let open: () -> Void
    private var windows: [CodexUsageWindow] { if store.usageError != nil { return [] }; return (store.usageBuckets.first(where: { $0.id == "codex" }) ?? store.usageBuckets.first)?.windows ?? [] }
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) { Image(systemName: "gauge.with.dots.needle.33percent"); Text(compact || featured ? "Codex" : "Codex-Limit").fontWeight(.semibold); if !compact && !featured { Spacer(); Image(systemName: "chevron.right") } }.font(.system(size: compact || featured ? 10 : 11)).foregroundStyle(.blue)
                if windows.isEmpty { Text(store.usageError == nil ? "Lädt …" : "Nicht verfügbar").font(.caption).foregroundStyle(.secondary) }
                else if featured, let window = windows.min(by: { $0.remaining < $1.remaining }) {
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.1), lineWidth: 6)
                        Circle().trim(from: 0, to: window.remaining / 100).stroke(AngularGradient(colors: window.remaining <= 10 ? [.orange, .yellow, .orange] : [.blue, .cyan, .blue], center: .center), style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                        VStack(spacing: 0) { Text("\(Int(window.remaining.rounded())) %").font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit(); Text("verfügbar").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }.frame(width: 80, height: 80).frame(maxWidth: .infinity).padding(.vertical, 3)
                    Text(window.label).font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                } else if compact {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(Int((windows.map(\.remaining).min() ?? 0).rounded())) %").font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                        Spacer(minLength: 0)
                        if windows.count == 1 { Text(windows[0].label).font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                    ProgressView(value: windows.map(\.remaining).min() ?? 0, total: 100).tint(.blue)
                    if windows.count > 1 { Text(windows.map { $0.label + " " + String(Int($0.remaining.rounded())) + "%" }.joined(separator: " · ")).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1) }
                } else {
                    HStack(spacing: 20) {
                        ForEach(windows) { window in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack { Text(window.label).foregroundStyle(.secondary); Spacer(); Text("Noch \(Int(window.remaining.rounded())) %").fontWeight(.semibold) }.font(.system(size: 10)).monospacedDigit()
                                ProgressView(value: window.remaining, total: 100).tint(window.remaining <= 10 ? .orange : .blue)
                                if let reset = window.resetsAt { Text("Reset " + reset.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1) }
                            }.frame(maxWidth: .infinity)
                        }
                    }
                }
                if store.usageError != nil && !windows.isEmpty { Image(systemName: "clock.badge.exclamationmark").font(.caption2).foregroundStyle(.orange).help("Letzter bekannter Stand; Aktualisierung fehlgeschlagen") }
            }.padding(featured ? 10 : compact ? 9 : 8).frame(maxWidth: .infinity, alignment: .leading).frame(height: height).background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).frame(minWidth: 0, maxWidth: .infinity).onAppear { store.start() }.accessibilityLabel("Codex-Nutzung und Limits öffnen")
    }
}
struct CodexUsageView: View {
    @ObservedObject var store: CodexStore = .shared
    var inPopover = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !inPopover { VStack(alignment: .leading, spacing: 8) { Label("Codex-Nutzung", systemImage: "chart.bar.xaxis").font(.largeTitle.bold()); Text("Kontingent, Tokenverlauf und Monatsvergleich").foregroundStyle(.secondary) } }
                HStack { if inPopover { Label("Codex-Limit", systemImage: "gauge.with.dots.needle.33percent").font(.headline) }; Spacer(); Button { Task { await store.loadUsage(force: true) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Nutzung aktualisieren") }
                if let error = store.usageError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                if store.usageBuckets.allSatisfy({ $0.windows.isEmpty }) { Text("Codex stellt für dieses Konto gerade keine Nutzungsfenster bereit.").foregroundStyle(.secondary) }
                ForEach(store.usageBuckets) { bucket in
                    VStack(alignment: .leading, spacing: 16) {
                        Text(bucket.title == "codex" ? "Codex" : bucket.title).font(.headline)
                        ForEach(bucket.windows) { window in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(window.label); Spacer(); Text((store.usageError == nil ? "Noch " : "Letzter Stand: ") + "\(Int(window.remaining.rounded())) %").fontWeight(.semibold).monospacedDigit().foregroundStyle(store.usageError == nil ? Color.primary : .secondary) }
                                ProgressView(value: window.remaining, total: 100).tint(window.remaining <= 10 ? .orange : .mint)
                                if let reset = window.resetsAt { Text("Zurückgesetzt am " + reset.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }.padding(18).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                }
                if let updated = store.usageUpdatedAt { Text("Stand " + updated.formatted(date: .omitted, time: .shortened) + " · Aktualisierung jede Minute").font(.caption).foregroundStyle(.secondary) }
                Text("Die Limits gelten für dein gesamtes Codex-Konto. Angezeigt wird der verbleibende Anteil, nicht der verbrauchte.").font(.caption).foregroundStyle(.secondary)
                if !inPopover { Divider(); CodexUsageHistoryDetail(store: store) }
            }.padding(inPopover ? 20 : 32).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }.onAppear { store.start() }.task { await store.loadUsage() }
    }
}

struct CodexUsageHistoryDetail: View {
    @ObservedObject var store: CodexStore
    @State private var primary = Calendar.current.dateInterval(of: .month, for: Date())!.start
    @State private var comparison = Calendar.current.date(byAdding: .month, value: -1, to: Calendar.current.dateInterval(of: .month, for: Date())!.start)!
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Lokal erfasste Tokenereignisse").font(.title2.weight(.semibold))
                    Text("Verbrauch zum Zeitpunkt des Tokenereignisses, inklusive Cache-Eingaben.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await store.loadLocalUsageHistory(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(store.readingUsageHistory).accessibilityLabel("Tokenverlauf aktualisieren")
            }
            if let history = store.localUsageHistory {
                Text(history.coverageText).font(.caption).foregroundStyle(history.missingFiles > 0 ? Color.orange : .secondary).fixedSize(horizontal: false, vertical: true)
                if history.rows.isEmpty {
                    Text("Es sind noch keine zeitlich zuordenbaren Tokenereignisse in den lokalen Verläufen vorhanden.").foregroundStyle(.secondary)
                } else {
                    let months = history.months()
                    Text(history.missingFiles > 0 ? "Erfasste Tokens pro Monat · unvollständig" : "Erfasste Tokens pro Monat").font(.headline)
                    Chart(Array(months.prefix(12).reversed()), id: \.self) { month in
                        BarMark(x: .value("Monat", month.formatted(.dateTime.month(.abbreviated).year(.twoDigits))), y: .value("Erfasste Tokens", history.summary(month: month).totals.total)).foregroundStyle(.mint)
                    }.chartXAxis { AxisMarks { AxisValueLabel() } }
                        .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let tokens = value.as(Int64.self) { Text(CodexUsageFormat.tokens(tokens)) } } } }
                        .frame(height: 190).accessibilityLabel("Monatlich erfasste Tokens der letzten zwölf Monate")
                    Divider()
                    Text("Monate vergleichen").font(.headline)
                    HStack(spacing: 24) {
                        Picker("Monat", selection: $primary) { ForEach(months, id: \.self) { month in Text(CodexUsageFormat.month(month)).tag(month) } }
                            .accessibilityLabel("Erster Vergleichsmonat")
                        Picker("Vergleich", selection: $comparison) { ForEach(months, id: \.self) { month in Text(CodexUsageFormat.month(month)).tag(month) } }
                            .accessibilityLabel("Zweiter Vergleichsmonat")
                    }
                    let first = history.summary(month: primary), second = history.summary(month: comparison)
                    HStack(alignment: .top, spacing: 16) {
                        monthCard(primary, summary: first, history: history, color: .mint)
                        monthCard(comparison, summary: second, history: history, color: .blue)
                    }
                    if history.canCompare(primary, comparison) {
                    let difference = first.totals.total-second.totals.total
                    HStack {
                        Text("Differenz").foregroundStyle(.secondary)
                        Spacer()
                        Text((difference >= 0 ? "+" : "−") + CodexUsageFormat.tokens(abs(difference)) + " Tokens").monospacedDigit()
                        if second.totals.total > 0 {
                            Text((Double(difference)/Double(second.totals.total)).formatted(.percent.precision(.fractionLength(1)))).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }.font(.callout)
                    } else {
                        Label("Kein belastbarer Verbrauchsvergleich: Es fehlen historische Tokenereignisse. Die Zahlen zeigen nur den lokal verfügbaren Ausschnitt, keine vollständige Monatsnutzung.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if history.calendar.isDate(primary, equalTo: Date(), toGranularity: .month) || history.calendar.isDate(comparison, equalTo: Date(), toGranularity: .month) {
                        Text("Der laufende Monat enthält nur die bisher erfassten Tage. Auch abgeschlossene Monate können Datenlücken enthalten.").font(.caption).foregroundStyle(.secondary)
                    }
                    Chart {
                        ForEach(history.cumulativeDays(month: primary)) { point in
                            LineMark(x: .value("Tag", point.day), y: .value("Tokens kumuliert", point.tokens)).foregroundStyle(by: .value("Monat", "A · " + CodexUsageFormat.month(primary)))
                        }
                        ForEach(history.cumulativeDays(month: comparison)) { point in
                            LineMark(x: .value("Tag", point.day), y: .value("Tokens kumuliert", point.tokens)).foregroundStyle(by: .value("Monat", "B · " + CodexUsageFormat.month(comparison)))
                        }
                    }.chartForegroundStyleScale(range: [Color.mint, .blue]).chartXScale(domain: 1...31)
                        .chartXAxis { AxisMarks(values: [1,5,10,15,20,25,31]) }
                        .chartXAxisLabel("Tag im Monat").chartYAxisLabel("Tokens kumuliert")
                        .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let tokens = value.as(Int64.self) { Text(CodexUsageFormat.tokens(tokens)) } } } }
                        .frame(height: 240).accessibilityLabel("Kumulierte Tokens der beiden ausgewählten Monate nach Tag")
                    Text("Modelle im Vergleich").font(.headline)
                    let names = Set(first.models.map(\.name) + second.models.map(\.name)).sorted()
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                        GridRow { Text("Modell").fontWeight(.semibold); Text("Monat A").fontWeight(.semibold); Text("Monat B").fontWeight(.semibold) }
                        ForEach(names, id: \.self) { name in
                            GridRow {
                                Text(name).textSelection(.enabled)
                                Text(CodexUsageFormat.tokens(first.models.first { $0.name == name }?.tokens ?? 0)).monospacedDigit()
                                Text(CodexUsageFormat.tokens(second.models.first { $0.name == name }?.tokens ?? 0)).monospacedDigit()
                            }
                        }
                    }.font(.callout)
                    Text("Modellzuordnung aus dem zum Ereignis gespeicherten Kontext; fehlende Angaben erscheinen als „Unbekannt“. Kopierte identische Tokenereignisse werden nur einmal gezählt.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if store.readingUsageHistory {
                HStack(spacing: 12) { ProgressView().controlSize(.small); Text("Tokenereignisse werden einmalig lokal erfasst. Weitere Aktualisierungen lesen nur neue Daten.").foregroundStyle(.secondary) }
            }
            if let error = store.localUsageHistoryError { Text((store.localUsageHistory == nil ? "" : "Letzter Stand · ") + error).font(.caption).foregroundStyle(.orange) }
            if store.readingUsageHistory && store.localUsageHistory != nil { ProgressView("Tokenverlauf wird aktualisiert …").controlSize(.small) }
        }.task {
            while !Task.isCancelled {
                await store.loadLocalUsageHistory()
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            }
        }
    }
    private func monthCard(_ date: Date, summary: CodexUsageSummary, history: CodexUsageHistory, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(CodexUsageFormat.month(date)).font(.headline)
            Text(CodexUsageFormat.tokens(summary.totals.total) + " erfasste Tokens").font(.title2.weight(.semibold)).monospacedDigit()
                .help(summary.totals.total.formatted() + " erfasste Tokens")
            Text("\(history.coverage(month: date).created) angelegte Chats laut Datenbank").font(.caption)
            Text("Tokenereignisse aus \(summary.chats) Chats verfügbar").font(.caption).foregroundStyle(.secondary)
            if history.missingFiles > 0 { Text("Unvollständiger Tokenverlauf").font(.caption.weight(.semibold)).foregroundStyle(.orange) }
            HStack { Text("Input"); Spacer(); Text(CodexUsageFormat.tokens(summary.totals.input)).monospacedDigit() }.font(.caption)
            HStack { Text("davon Cache"); Spacer(); Text(CodexUsageFormat.tokens(summary.totals.cached)).monospacedDigit() }.font(.caption).foregroundStyle(.secondary)
            HStack { Text("Output"); Spacer(); Text(CodexUsageFormat.tokens(summary.totals.output)).monospacedDigit() }.font(.caption)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}
