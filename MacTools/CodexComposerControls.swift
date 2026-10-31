import SwiftUI

struct CodexChatComposer: View {
    @ObservedObject var store: CodexStore
    @State private var editorHeight: CGFloat = 44
    @State private var files: [CodexReference] = []
    @State private var showAllReferences = false
    @State private var showFullAccess = false
    private var key: String { store.selectedID ?? "new" }
    private var text: String {
        get { store.drafts[key] ?? "" }
        nonmutating set { if store.drafts[key] != newValue { store.drafts[key] = newValue } }
    }
    private var references: [CodexReference] {
        get { store.references[key] ?? [] }
        nonmutating set { if store.references[key] != newValue { store.references[key] = newValue } }
    }
    @State private var popup: String?
    @State private var showGoal = false
    private var options: CodexTurnOptions { store.options[key] ?? CodexTurnOptions() }
    private var model: CodexModelChoice? { store.models.first { $0.id == (options.model ?? store.currentModel) } ?? store.models.first }
    private var effectiveEffort: String? { options.effort ?? store.currentEffort ?? (store.selectedID == nil ? model?.defaultEffort : nil) }
    private var effortTitle: String { effectiveEffort.map(effortLabel) ?? "Im Chat" }
    private var mentionQuery: String? {
        if showAllReferences { return "" }
        guard let range = text.range(of: #"(?:^|\s)@([^\s]*)$"#, options: .regularExpression) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().description
    }
    private var slashQuery: String? {
        guard text.hasPrefix("/"), !text.contains("\n"), !text.contains(" ") else { return nil }
        return String(text.dropFirst()).lowercased()
    }
    private let commands = [("archive", "Aktuellen Chat archivieren", "archivebox"), ("pin", "Chat direkt in der Menüleiste an-/abheften", "menubar.rectangle"), ("fork", "Ab diesem Verlauf einen neuen Chat starten", "arrow.triangle.branch"), ("share", "Teilen im Originalchat öffnen", "square.and.arrow.up"), ("review", "Code-Überprüfung im Originalchat öffnen", "text.bubble"), ("compact", "Kontext-Komprimierung im Originalchat öffnen", "arrow.down.right.and.arrow.up.left"), ("mcp", "MCP-Verbindungen im Originalchat anzeigen", "point.3.connected.trianglepath.dotted"), ("plan", "Planmodus einschalten", "lightbulb"), ("default", "Standardmodus einschalten", "bubble.left"), ("model", "Modell auswählen", "cpu"), ("effort", "Denkaufwand einstellen", "bolt"), ("permissions", "Berechtigungen einstellen", "checkmark.shield"), ("mention", "Dateien, Apps und Plugins hinzufügen", "at"), ("new", "Neuen Chat im aktuellen Projekt beginnen", "square.and.pencil"), ("goal", "Ziel dieses Chats", "target")]
    private func commandTitle(_ id: String) -> String { ["archive":"Archivieren", "pin":"In Menüleiste anheften", "fork":"Chat forken", "share":"Chat teilen", "review":"Code-Überprüfung", "compact":"Kompakt", "mcp":"MCP", "plan":"Planmodus", "default":"Standardmodus", "model":"Modell", "effort":"Denkaufwand", "permissions":"Berechtigungen", "mention":"Referenz hinzufügen", "new":"Neuer Chat", "goal":"Ziel"][id] ?? id }
    private func matchingCommands(_ query: String) -> [(String, String, String)] { commands.filter { query.isEmpty || $0.0.localizedCaseInsensitiveContains(query) || commandTitle($0.0).localizedCaseInsensitiveContains(query) } }
    private var skillCandidates: [CodexReference] { guard let query = slashQuery else { return [] }; return Array(store.availableReferences.filter { $0.kind == "skill" && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.displayName.localizedCaseInsensitiveContains(query)) }.prefix(40)) }
    private var candidates: [CodexReference] {
        guard let query = mentionQuery else { return [] }
        return Array((store.availableReferences + files).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || ($0.kind != "file" && $0.detail.localizedCaseInsensitiveContains(query)) }.sorted { a, b in
            let aPrefix = a.name.lowercased().hasPrefix(query.lowercased()), bPrefix = b.name.lowercased().hasPrefix(query.lowercased())
            if aPrefix != bPrefix { return aPrefix }
            if (a.kind == "file") != (b.kind == "file") { return a.kind != "file" }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }.prefix(30))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let query = slashQuery {
                ScrollView { LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(matchingCommands(query), id: \.0) { command in
                        Button { runCommand(command.0) } label: {
                            HStack(spacing: 12) { Image(systemName: command.2).frame(width: 18).foregroundStyle(.mint); Text(commandTitle(command.0)).font(.system(size: 12, weight: .medium)); Text(command.1).font(.caption).foregroundStyle(.secondary).lineLimit(1); Spacer() }.padding(9).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if !skillCandidates.isEmpty { Text("SKILLS").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 8) }
                    ForEach(skillCandidates) { skill in
                        Button { insertSkill(skill) } label: { HStack(spacing: 10) { Image(systemName: "sparkles").foregroundStyle(.mint).frame(width: 18); VStack(alignment: .leading, spacing: 3) { HStack { Text(skill.displayName).font(.system(size: 12, weight: .medium)); Text(skill.providerLabel).font(.system(size: 10)).foregroundStyle(.mint) }; Text(skill.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer() }.padding(9).contentShape(Rectangle()) }.buttonStyle(.plain).help(skill.name).accessibilityLabel(skill.displayName + " verwenden")
                    }
                }.padding(7) }.frame(maxHeight: 280).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if mentionQuery != nil {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if store.composerContextLoading { HStack { ProgressView().controlSize(.small); Text(candidates.isEmpty ? "Apps, Plugins und Skills laden …" : "Katalog im Hintergrund aktualisieren …").font(.caption) }.padding(10) }
                        if let error = store.composerContextError {
                            HStack { Text(error).font(.caption).foregroundStyle(.orange); Spacer(); Button("Erneut laden") { Task { await store.loadComposerContext(force: true) } }.disabled(store.composerContextLoading) }.padding(10)
                        }
                        if candidates.isEmpty && !store.composerContextLoading { Text("Keine Treffer · Dateien über + auswählen").font(.caption).foregroundStyle(.secondary).padding(12) }
                        ForEach(candidates) { ref in
                            Button { insert(ref) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: ref.icon).frame(width: 17)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack { Text(ref.displayName).font(.system(size: 12, weight: .medium)); Text(ref.kind == "app" ? "App / MCP" : ref.kind == "plugin" ? "Plugin" : ref.kind == "skill" ? (ref.providerLabel.isEmpty ? "Skill" : ref.providerLabel) : "Datei").font(.system(size: 9)).foregroundStyle(.mint) }
                                        Text(ref.kind == "file" ? ref.path : ref.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                }.padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(ref.detail).accessibilityLabel(ref.name + " hinzufügen")
                        }
                    }
                }.frame(maxHeight: 210).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if !store.activity.isEmpty { Text(store.activity).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 4) }
            VStack(alignment: .leading, spacing: 8) {
                if !references.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(references) { ref in
                                HStack(spacing: 5) {
                                    Image(systemName: ref.icon); Text(ref.displayName).lineLimit(1)
                                    Button { references.removeAll { $0.id == ref.id } } label: { Image(systemName: "xmark").font(.system(size: 8)) }.buttonStyle(.plain).accessibilityLabel(ref.name + " entfernen")
                                }.font(.system(size: 10)).padding(7).background(Color.primary.opacity(0.05)).clipShape(Capsule())
                            }
                        }
                    }
                }
                ZStack(alignment: .topLeading) {
                    if text.isEmpty { Text("Nachricht an Codex …").font(.system(size: 14)).foregroundStyle(.tertiary).padding(.leading, 3).padding(.top, 6).allowsHitTesting(false) }
                    CodexComposer(store: store, draftKey: key, height: $editorHeight, send: submit, attach: attach).frame(height: editorHeight)
                }
                HStack(spacing: 12) {
                    popupButton("add", title: "+", icon: nil) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Hinzufügen").font(.caption).foregroundStyle(.secondary).padding(8)
                            popupRow("Dateien und Ordner", icon: "paperclip") { chooseFiles() }
                            popupRow("Apps, Plugins und Skills", icon: "at") { showAllReferences.toggle() }
                            popupRow("Projekt wählen", icon: "folder") { store.chooseDirectory(); Task { await store.loadComposerContext() } }
                            popupRow("Ziel dieses Chats", icon: "target") { showGoal = true }
                            Divider().padding(.vertical, 5)
                            popupRow(options.mode == "plan" ? "Planmodus ausschalten" : "Planmodus", icon: "lightbulb") { setOption { $0.mode = options.mode == "plan" ? "default" : "plan" } }
                        }.frame(width: 270)
                    }
                    popupButton("permissions", title: permissionLabel, icon: "checkmark.shield") {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Berechtigungen").font(.headline).padding(8)
                            permissionRow("Wie im Chat", detail: "Vorhandene Chat-Einstellungen verwenden", value: "inherit")
                            permissionRow("Genehmigung anfordern", detail: "Externe Aktionen vorher freigeben", value: "ask")
                            permissionRow("Für mich genehmigen", detail: "Unsichere Aktionen prüfen lassen", value: "auto")
                            popupRow("Vollzugriff …", icon: "lock.open") { showFullAccess = true }
                        }.frame(width: 330)
                    }
                    Spacer(minLength: 0)
                    popupButton("model", title: model?.name ?? "Modell", icon: nil) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Modell").font(.headline).padding(8)
                            popupRow("Einstellung des Chats", selected: options.model == nil) { setOption { $0.model = nil; $0.effort = nil } }
                            Divider().padding(.vertical, 4)
                            ForEach(store.models) { choice in
                                popupRow(choice.name, selected: choice.id == options.model) { setOption { $0.model = choice.id; $0.effort = choice.defaultEffort; $0.serviceTier = nil } }
                            }
                        }.frame(width: 265)
                    }
                    popupButton("effort", title: effortTitle, icon: nil) {
                        VStack(spacing: 14) {
                            HStack { Image(systemName: "bolt.fill").foregroundStyle(.green); Spacer(); Text(effortTitle).font(.headline).frame(width: 110); Spacer(); Button { setOption { $0.effort = nil } } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.plain).help("Chat-Einstellung verwenden") }
                            Text(model?.name ?? "Codex").font(.caption).foregroundStyle(.secondary)
                            let efforts = model?.efforts ?? ["low", "medium", "high"]
                            if efforts.count > 1 {
                                Slider(value: Binding(get: { Double(efforts.firstIndex(of: options.effort ?? store.currentEffort ?? model?.defaultEffort ?? "medium") ?? 0) }, set: { value in setOption { $0.effort = efforts[min(efforts.count - 1, max(0, Int(value.rounded())))] } }), in: 0...Double(efforts.count - 1), step: 1).tint(.green).accessibilityLabel("Denkaufwand")
                                HStack { Text(effortLabel(efforts.first!)); Spacer(); Text(effortLabel(efforts.last!)) }.font(.caption2).foregroundStyle(.secondary)
                            }
                            if let model, !model.tiers.isEmpty {
                                Divider()
                                popupRow("Standardgeschwindigkeit", selected: options.serviceTier == nil) { setOption { $0.serviceTier = nil } }
                                ForEach(model.tiers.map { $0.0 }, id: \.self) { tier in popupRow(tier == "priority" ? "Schnell" : tier, icon: "bolt", selected: options.serviceTier == tier) { setOption { $0.serviceTier = tier } } }
                            }
                        }.padding(8).frame(width: 270)
                    }
                    if store.currentTurn != nil { Button { Task { await store.interrupt() } } label: { Image(systemName: "stop.fill").font(.system(size: 10)) }.buttonStyle(.plain).accessibilityLabel("Antwort unterbrechen") }
                    Button(action: submit) { Image(systemName: store.currentTurn != nil || store.selected?.status == "active" ? "text.badge.plus" : "arrow.up").font(.system(size: 14, weight: .semibold)).foregroundStyle(enabled ? Color.white : .secondary).frame(width: 30, height: 30).background(enabled ? Color.green : Color.primary.opacity(0.06)).clipShape(Circle()) }
                        .buttonStyle(.plain).disabled(!enabled).keyboardShortcut(.return, modifiers: .command).help(store.currentTurn != nil || store.selected?.status == "active" ? "In Warteschlange stellen" : "An Codex senden").accessibilityLabel(store.currentTurn != nil || store.selected?.status == "active" ? "In Warteschlange stellen" : "An Codex senden")
                }
                if options.mode == "plan" { Text("Planmodus").font(.system(size: 10)).foregroundStyle(.mint) }
            }.padding(16).background(Color(nsColor: .controlBackgroundColor).opacity(0.85)).clipShape(RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }.frame(maxWidth: 760).frame(maxWidth: .infinity)
            .task(id: store.connected) { if store.connected { await store.loadComposerContext() } }
            .onAppear(perform: restore).onChange(of: store.selectedID) { _ in popup = nil; showAllReferences = false; files = []; showGoal = false; showFullAccess = false; restore() }
            .task(id: mentionQuery) {
                if mentionQuery != nil { await store.loadComposerContext() }
                guard let query = mentionQuery, !query.isEmpty else { files = []; return }
                do { try await Task.sleep(nanoseconds: 220_000_000) } catch { return }
                let results = await store.searchReferenceFiles(query)
                if !Task.isCancelled { files = results }
            }
            .task(id: slashQuery) { if slashQuery != nil { await store.loadComposerContext() } }
            .sheet(isPresented: $showGoal) { CodexGoalEditor(store: store) }
            .alert("Vollzugriff erlauben?", isPresented: $showFullAccess) { Button("Abbrechen", role: .cancel) {}; Button("Vollzugriff auswählen") { setOption { $0.permission = "full" } } } message: { Text("Codex erhält für diese Chat-Auswahl uneingeschränkten Datei- und Netzwerkzugriff. Die Auswahl wird beim nächsten Senden angewendet.") }
    }
    private var enabled: Bool { store.canSubmit && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !references.isEmpty) }
    private var permissionLabel: String { switch options.permission { case "ask": return "Nachfragen"; case "auto": return "Für mich genehmigen"; case "full": return "Vollzugriff"; default: return "Wie im Chat" } }
    private func popupButton<Content: View>(_ id: String, title: String, icon: String?, @ViewBuilder content: @escaping () -> Content) -> some View {
        Button { popup = popup == id ? nil : id } label: {
            HStack(spacing: 4) { if let icon { Image(systemName: icon) }; Text(title).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 8)) }.font(.system(size: 11)).frame(width: id == "effort" ? 76 : nil)
        }.buttonStyle(.plain).popover(isPresented: Binding(get: { popup == id }, set: { if !$0 { popup = nil } }), arrowEdge: .bottom) { content().padding(10) }
        .accessibilityLabel(id == "model" ? "Modell auswählen" : id == "effort" ? "Denkaufwand auswählen" : id == "add" ? "Hinzufügen" : "Berechtigungen")
    }
    private func popupRow(_ title: String, icon: String? = nil, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button { action(); popup = nil } label: {
            HStack(spacing: 9) { if let icon { Image(systemName: icon).frame(width: 18) }; Text(title); Spacer(); if selected { Image(systemName: "checkmark").foregroundStyle(.mint) } }.font(.system(size: 12)).padding(9).frame(maxWidth: .infinity, alignment: .leading).background(selected ? Color.mint.opacity(0.09) : Color.primary.opacity(0.025)).clipShape(RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func permissionRow(_ title: String, detail: String, value: String) -> some View {
        Button { setOption { $0.permission = value }; popup = nil } label: {
            HStack { VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 12, weight: .medium)); Text(detail).font(.caption2).foregroundStyle(.secondary) }; Spacer(); if options.permission == value { Image(systemName: "checkmark").foregroundStyle(.mint) } }.padding(10).background(options.permission == value ? Color.mint.opacity(0.09) : .clear).clipShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    private func effortLabel(_ effort: String) -> String { ["none": "Ohne", "minimal": "Minimal", "low": "Niedrig", "medium": "Mittel", "high": "Hoch", "xhigh": "Sehr hoch", "max": "Maximum", "ultra": "Ultra"][effort] ?? effort }
    private func setOption(_ change: (inout CodexTurnOptions) -> Void) { var value = options; change(&value); store.setTurnOptions(value, for: key) }
    private func restore() { showAllReferences = false; Task { await store.loadComposerContext() } }
    private func insert(_ ref: CodexReference) {
        if !references.contains(where: { $0.id == ref.id }) { references.append(ref) }
        if !showAllReferences, let range = text.range(of: #"@[^\s]*$"#, options: .regularExpression) { text.replaceSubrange(range, with: "@" + ref.name + " ") }
        showAllReferences = false
    }
    private func chooseFiles() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            attach(panel.urls)
        }
    }
    private func attach(_ urls: [URL]) {
        for ref in urls.filter({ $0.isFileURL }).map(CodexReference.attachment) where !references.contains(where: { $0.id == ref.id }) { references.append(ref) }
    }
    private func runCommand(_ command: String) {
        text = ""
        switch command {
        case "archive": if let id = store.selectedID { Task { await store.archive([id]) } }
        case "pin": if let id = store.selectedID { SettingsStore.shared.setChatPinned(id, enabled: !SettingsStore.shared.pinnedCodexChats.contains(id)) }
        case "fork": Task { await store.forkCurrent() }
        case "share", "review", "compact", "mcp": if let id = store.selectedID { store.openInCodex(id) }
        case "plan": setOption { $0.mode = "plan" }
        case "default": setOption { $0.mode = "default" }
        case "model": popup = "model"
        case "effort": popup = "effort"
        case "permissions": popup = "permissions"
        case "mention": showAllReferences = true
        case "new": let project = store.projects.first { $0.id == store.selected?.projectID }; let cwd = store.selected?.cwd ?? store.workingDirectory; store.newChat(in: project); if project == nil { store.workingDirectory = cwd }
        case "goal": showGoal = true
        default: break
        }
    }
    private func insertSkill(_ skill: CodexReference) {
        if !references.contains(where: { $0.id == skill.id }) { references.append(skill) }
        text = ""
    }
    private func submit() {
        if let query = slashQuery { guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; if let command = matchingCommands(query).first { runCommand(command.0); return }; if let skill = skillCandidates.first { insertSkill(skill); return } }
        if mentionQuery != nil, let first = candidates.first { insert(first); return }
        guard enabled else { return }
        let sent = text, refs = references
        Task { _ = await store.submit(sent, references: refs) }
    }
}
