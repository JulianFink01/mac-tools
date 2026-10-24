import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ImageIO

/// Uses the same card + paging pattern as the live notifications above it.
struct CodexChatRow: View {
    @ObservedObject private var store = CodexStore.shared
    @State private var page = 0
    @State private var selectedChatID: String?
    var chats: [CodexChat]? = nil
    var visibleCount = 1
    var compact = false
    var cardHeight: CGFloat = 64
    var startOffset = 0
    var maximumItems: Int? = nil
    let openChat: (String?) -> Void
    var body: some View {
        let chats = Array((self.chats ?? store.menuChats).dropFirst(startOffset).prefix(maximumItems ?? Int.max))
        let rows = min(visibleCount, max(1, chats.count))
        let pages = max(1, Int(ceil(Double(chats.count) / Double(rows))))
        let index = QuickPanelCardLayout.page(selectedID: selectedChatID, fallback: page, ids: chats.map(\.id), rows: rows)
        VStack(spacing: 8) {
            ForEach(Array(chats.dropFirst(index * rows).prefix(rows).enumerated()), id: \.element.id) { offset, chat in
                if compact {
                    VStack(alignment: .leading, spacing: 2) {
                        Button { openChat(chat.id) } label: { Text(chat.title).font(.system(size: cardHeight > 80 ? 14 : 13, weight: .semibold)).lineLimit(cardHeight > 80 ? 3 : 2).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }.buttonStyle(.plain).help(chat.title)
                        HStack(spacing: 0) {
                            Text(chat.statusLabel).font(.system(size: 10)).foregroundStyle(chat.status == "active" ? Color.blue : .secondary)
                            Spacer(minLength: 0)
                            CodexChatActions(chatID: chat.id, title: chat.title, open: { openChat(chat.id) })
                            if offset == min(rows, chats.count - index * rows) - 1 && pages > 1 { CompactCardPager(index: index, count: pages, item: "Codex-Seite", compact: true, previous: { page = max(0, index - 1); selectedChatID = chats[page * rows].id }, next: { page = min(pages - 1, index + 1); selectedChatID = chats[page * rows].id }) }
                        }.frame(height: 22)
                    }.padding(.horizontal, 10).padding(.vertical, 5).frame(height: cardHeight).frame(maxWidth: .infinity).background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)).contextMenu { Button("Neuer Chat") { openChat(nil) } }
                } else {
                HStack(spacing: 10) {
                    if !compact { Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.blue).font(.title3) }
                    Button { openChat(chat.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chat.title).font(.callout.weight(.semibold)).lineLimit(1)
                            Text(chat.statusLabel).font(.caption).foregroundStyle(chat.status == "active" ? Color.blue : .secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    VStack(spacing: 2) {
                        CodexChatActions(chatID: chat.id, title: chat.title, open: { openChat(chat.id) })
                        if offset == min(rows, chats.count - index * rows) - 1 && pages > 1 { CompactCardPager(index: index, count: pages, item: "Codex-Seite", compact: compact, previous: { page = max(0, index - 1); selectedChatID = chats[page * rows].id }, next: { page = min(pages - 1, index + 1); selectedChatID = chats[page * rows].id }) }
                    }.fixedSize(horizontal: true, vertical: false)
                }.padding(.horizontal, 12).padding(.vertical, 4).frame(height: 64).frame(maxWidth: .infinity)
                    .background(Color.blue.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }.onAppear { store.start(); selectedChatID = chats.dropFirst(index * rows).first?.id }
        .onChange(of: pages) { page = min(page, max(0, $0 - 1)) }
        .onChange(of: chats.map(\.id)) { ids in
            page = QuickPanelCardLayout.page(selectedID: selectedChatID, fallback: page, ids: ids, rows: rows)
            selectedChatID = chats.dropFirst(page * rows).first?.id
        }
        .contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 24).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            page = min(pages - 1, max(0, index + (value.translation.width < 0 ? 1 : -1))); selectedChatID = chats.dropFirst(page * rows).first?.id
        })
    }
}

struct CodexChatActions: View {
    @ObservedObject var settings: SettingsStore = .shared
    let chatID: String
    let title: String
    let open: () -> Void
    var body: some View {
        HStack(spacing: 2) {
            Button(action: open) { Image(systemName: "macwindow.on.rectangle").frame(width: 22, height: 22) }.help("In eigenem Chatfenster öffnen").accessibilityLabel(title + " in eigenem Fenster öffnen")
            Button { settings.setChatPinned(chatID, enabled: !settings.pinnedCodexChats.contains(chatID)) } label: {
                Image(systemName: "menubar.rectangle").foregroundStyle(settings.pinnedCodexChats.contains(chatID) ? Color.mint : .secondary).frame(width: 22, height: 22)
            }.help(settings.pinnedCodexChats.contains(chatID) ? "Aus Menüleiste lösen" : "In Menüleiste anheften").accessibilityLabel(title + (settings.pinnedCodexChats.contains(chatID) ? " aus Menüleiste lösen" : " in Menüleiste anheften"))
        }.font(.system(size: 12)).buttonStyle(.plain).fixedSize()
    }
}

struct CodexChatsView: View {
    @ObservedObject var store: CodexStore = .shared
    var popupMode = false
    var menuMode = false
    var popupPin: Binding<Bool> = .constant(true)
    @State private var popupSidebarWidth = 260.0
    @State private var popupSidebarVisible = false
    @ObservedObject private var settings = SettingsStore.shared
    @State private var filter = ""
    @State private var expanded = Set<String>()
    @State private var collapsedFolders = Set<String>()
    @State private var followLive = true
    @State private var activityExpansion = CodexActivityExpansionState()
    @State private var loadingOlder = false
    @State private var visibleMessageID: String?
    @StateObject private var transcriptScroll = CodexTranscriptScrollState()
    @State private var showScheduled = false
    @State private var showGoal = false
    @AppStorage("codexChatSidebarWidth") private var chatSidebarWidth = 260.0
    @State private var droppingFiles = false
    @AppStorage("codexChatSidebarVisible") private var chatSidebarVisible = true
    private var roots: [CodexChat] { store.listedChats.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) } }
    private var folders: [String] { store.orderedFolders(roots) }
    private var sidebarVisible: Bool { menuMode ? false : popupMode ? popupSidebarVisible : chatSidebarVisible }
    var body: some View {
        NativeSidebarSplit(width: popupMode ? $popupSidebarWidth : $chatSidebarWidth, expanded: sidebarVisible) {
            sidebar
        } detail: {
            if showScheduled {
                CodexScheduledChatsView(openChat: { id in showScheduled = false; Task { await store.select(id) } }, close: { showScheduled = false })
            } else {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.4)
                if let error = store.error {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(error).font(.caption).textSelection(.enabled)
                        Spacer()
                        Button { store.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Hinweis schließen")
                    }.padding(12).background(Color.orange.opacity(0.07))
                }
                transcript
                if let goal = store.selectedGoal {
                    CodexGoalStrip(store: store, goal: goal, edit: { showGoal = true }).id(store.selectedID)
                        .frame(maxWidth: 760).frame(maxWidth: .infinity).padding(.horizontal, 28).padding(.bottom, 8)
                }
                if let id = store.selectedID, !(store.nativeQueuedMessages[id] ?? []).isEmpty {
                    CodexNativeQueueStrip(store: store, threadID: id).frame(maxWidth: 760).frame(maxWidth: .infinity).padding(.horizontal, 28).padding(.bottom, 8)
                }
                if let id = store.selectedID, !(store.queuedMessages[id] ?? []).isEmpty {
                    CodexQueueStrip(store: store, threadID: id).frame(maxWidth: 760).frame(maxWidth: .infinity).padding(.horizontal, 28).padding(.bottom, 8)
                }
                if !store.asyncQuestions.isEmpty {
                    ScrollView { VStack(spacing:10) { ForEach(store.asyncQuestions) { question in CodexAsyncQuestionView(question:question,store:store) } } }
                        .frame(height:min(300,CGFloat(store.asyncQuestions.reduce(0) { $0 + 180 + $1.options.count * 42 }))).padding(.horizontal,28).padding(.bottom,8)
                }
                CodexChatComposer(store: store).padding(.horizontal, 28).padding(.bottom, 20)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $droppingFiles) { providers in
                    let key = store.selectedID ?? "new"
                    ChatAttachments.load(providers) { urls in
                        var refs = store.references[key] ?? []
                        for ref in urls.map(CodexReference.attachment) where !refs.contains(where: { $0.id == ref.id }) { refs.append(ref) }
                        store.references[key] = refs
                        NotificationCenter.default.post(name: .codexAttachmentsChanged, object: key)
                    }
                    return true
                }
                .overlay { if droppingFiles { RoundedRectangle(cornerRadius: 16).stroke(Color.mint, style: StrokeStyle(lineWidth: 2, dash: [8])).padding(10).allowsHitTesting(false) } }
            }
        }.background(Color(nsColor: .windowBackgroundColor)).onAppear { store.start() }.task(id: store.selectedID) { await store.loadGoal() }.sheet(isPresented: $showGoal) { CodexGoalEditor(store: store) }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Codex").font(.title3.weight(.semibold))
                Spacer()
                Button { Task { await store.reconnect() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Verbindung aktualisieren").disabled(store.connecting)
            }.padding(.top, 20)
            Button { showScheduled = false; store.newChat() } label: {
                Label("Neuer Chat", systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }.buttonStyle(.plain).disabled(store.sending)
            Button { showScheduled = true } label: { Label("Geplante Chats", systemImage: "calendar.badge.clock").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).font(.callout)
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Chats suchen", text: $filter).textFieldStyle(.plain) }
                .padding(9).background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 8))
            Button(store.showingArchived ? "Alle Chats anzeigen" : "Archiv öffnen") { Task { await store.showArchive(!store.showingArchived) } }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            Text(store.showingArchived ? "ARCHIVIERTE CHATS" : "ALLE CHATS · STUNDENWEISE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if roots.isEmpty { Text(store.connecting ? "Chats werden geladen …" : "Keine Chats gefunden.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 12) }
                    ForEach(folders, id: \.self) { folder in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                            Button {
                                if collapsedFolders.contains(folder) { collapsedFolders.remove(folder) } else { collapsedFolders.insert(folder) }
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: collapsedFolders.contains(folder) ? "folder" : "folder.fill")
                                    Text(store.folderName(folder)).lineLimit(1).foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                    Text("\(roots.filter { store.folder(for: $0) == folder }.count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                                    Image(systemName: collapsedFolders.contains(folder) ? "chevron.right" : "chevron.down").font(.system(size: 8))
                                }.font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.vertical, 9)
                            }.buttonStyle(.plain).help(folder).accessibilityLabel("Ordner " + store.folderName(folder))
                            Button { showScheduled = false; store.newChat(inFolder: folder) } label: { Image(systemName: "plus").font(.system(size: 11)).frame(width: 22, height: 28) }.buttonStyle(.plain).foregroundStyle(.secondary).help("Neuer Chat in " + store.folderName(folder)).accessibilityLabel("Neuer Chat in " + store.folderName(folder)).disabled(store.sending)
                            }
                            .onDrag { NSItemProvider(object: (ToolDrop.folderPrefix + folder) as NSString) }
                            .contextMenu {
                                Button("Neuer Chat in " + store.folderName(folder)) { showScheduled = false; store.newChat(inFolder: folder) }.disabled(store.sending)
                                Toggle("In Mac-Menüleiste anheften", isOn: Binding(get: { settings.pinnedCodexFolders.contains(folder) }, set: { enabled in if enabled { settings.pinCodexFolder(folder) } else { settings.pinnedCodexFolders.removeAll { $0 == folder } } }))
                                Toggle("In App-Favoriten anheften", isOn: Binding(get: { settings.sidebarCodexFolders.contains(folder) }, set: { settings.setSidebarFolder(folder, enabled: $0) }))
                                Button(store.showingArchived ? "Chats wiederherstellen" : "Chats archivieren") { Task { await store.archive(roots.filter { store.folder(for: $0) == folder }.map(\.id), archived: !store.showingArchived) } }
                                Menu("Chats in Projekt verschieben") { ForEach(store.projects) { project in Button(project.name) { Task { await store.move(roots.filter { store.folder(for: $0) == folder }.map(\.id), to: project) } } } }
                            }
                            if !collapsedFolders.contains(folder) {
                            ForEach(roots.filter { store.folder(for: $0) == folder }) { chat in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Button {
                                    if expanded.contains(chat.id) { expanded.remove(chat.id) }
                                    else { expanded.insert(chat.id); Task { await store.loadSubagents(chat.id) } }
                                } label: { Image(systemName: expanded.contains(chat.id) ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 13, height: 24) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Subagenten von " + chat.title)
                                Button { Task { await store.select(chat.id) } } label: {
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(chat.title).font(.system(size: 12, weight: store.selectedID == chat.id ? .semibold : .regular)).foregroundStyle(chat.status == "active" ? Color.green : Color.secondary).lineLimit(2)
                                            Text(URL(fileURLWithPath: chat.cwd).lastPathComponent).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(.vertical, 10).padding(.trailing, 7)
                                }.buttonStyle(.plain).disabled(store.sending)
                                .onDrag { NSItemProvider(object: (ToolDrop.chatPrefix + chat.id) as NSString) }
                                .contextMenu {
                                    Toggle("In Menüleiste anheften", isOn: Binding(get: { settings.pinnedCodexChats.contains(chat.id) }, set: { settings.setChatPinned(chat.id, enabled: $0) }))
                                    if settings.pinnedCodexChats.contains(chat.id) { Button("Menüleisten-Chat öffnen") { NotificationCenter.default.post(name: .showPinnedCodexChat, object: chat.id) } }
                                    Button(store.showingArchived ? "Wiederherstellen" : "Archivieren") { Task { await store.archive([chat.id], archived: !store.showingArchived) } }.disabled(chat.status == "active")
                                    Menu("In Projekt verschieben") { ForEach(store.projects) { project in Button(project.name) { Task { await store.move([chat.id], to: project) } } } }
                                }
                                CodexChatActions(chatID: chat.id, title: chat.title, open: { CodexPopupController.shared.show(chatID: chat.id) }).padding(.trailing, 5)
                            }.padding(.leading, 6).background(store.selectedID == chat.id ? Color.primary.opacity(0.07) : .clear).clipShape(RoundedRectangle(cornerRadius: 8))
                            if expanded.contains(chat.id) {
                                let agents = store.subagents[chat.id] ?? []
                                if let error = store.agentErrors[chat.id] { Text(error).font(.system(size: 10)).foregroundStyle(.orange).padding(.leading, 30).padding(.vertical, 6) }
                                else if agents.isEmpty { Text(store.loadingAgentRoots.contains(chat.id) ? "Lädt …" : "Keine Subagenten").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 30).padding(.vertical, 6) }
                                ForEach(agents) { agent in
                                    Button { Task { await store.select(agent.id) } } label: {
                                        HStack(spacing: 7) {
                                            Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(agent.agentName ?? agent.title).font(.system(size: 11)).foregroundStyle(agent.status == "active" ? Color.green : Color.secondary).lineLimit(1)
                                                if let role = agent.agentRole { Text(role).font(.system(size: 9)).foregroundStyle(.secondary) }
                                            }
                                            Spacer(minLength: 0)
                                        }.padding(.vertical, 8).padding(.horizontal, 8).background(store.selectedID == agent.id ? Color.primary.opacity(0.07) : .clear).clipShape(RoundedRectangle(cornerRadius: 7))
                                    }.buttonStyle(.plain).padding(.leading, 22).disabled(store.sending)
                                }
                            }
                        }
                    }
                            }
                        }
                    }
                }.background(ScrollIndicatorHider())
            }.scrollIndicators(.hidden)
            if store.listCursor != nil {
                Button("Weitere Chats laden") { Task { await store.refresh(older: true) } }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Circle().fill(store.connected ? Color.green : Color.secondary).frame(width: 5, height: 5)
                Text(store.connecting ? "Verbindet …" : store.desktopConnected ? "Codex Desktop verbunden" : store.connected ? "Codex verbunden" : "Nicht verbunden").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.bottom, 16)
        }.padding(.horizontal, 12).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }
    private var header: some View {
        HStack(spacing: 12) {
            if !menuMode {
            Button { withAnimation(.easeInOut(duration: 0.2)) { if popupMode { popupSidebarVisible.toggle() } else { chatSidebarVisible.toggle() } } } label: { Image(systemName: "sidebar.left") }.buttonStyle(.plain)
                .help(sidebarVisible ? "Chatliste ausblenden" : "Chatliste einblenden").accessibilityLabel(sidebarVisible ? "Chatliste ausblenden" : "Chatliste einblenden")
            if !sidebarVisible {
                Button { store.newChat() } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.plain).help("Neuer Chat").accessibilityLabel("Neuer Chat")
            }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(store.selected?.title ?? "Neuer Chat").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    if store.selectedID == nil { newChatProjectMenu }
                    else {
                        Image(systemName: "folder").font(.system(size: 10))
                        Text(store.selected.flatMap { store.project(for: $0)?.name } ?? URL(fileURLWithPath: store.selected?.cwd ?? store.workingDirectory).lastPathComponent).font(.system(size: 11))
                    }
                    if store.selected?.status == "active" { Text("· arbeitet").font(.system(size: 11)).foregroundStyle(.green) }
                }.foregroundStyle(.secondary)
            }
            Spacer()
            if store.selected?.status == "active" || store.currentTurn != nil {
                Toggle("Live folgen", isOn: $followLive).toggleStyle(.switch).controlSize(.mini).font(.system(size: 10)).tint(.green)
            }
            Button { showGoal = true } label: { Image(systemName: "target") }.buttonStyle(.plain).help("Ziel dieses Chats").accessibilityLabel("Ziel dieses Chats")
            if popupMode {
                Button { popupPin.wrappedValue.toggle() } label: { Image(systemName: popupPin.wrappedValue ? "pin.fill" : "pin") }.buttonStyle(.plain)
                    .help(popupPin.wrappedValue ? "Immer im Vordergrund ausschalten" : "Immer im Vordergrund einschalten").accessibilityLabel(popupPin.wrappedValue ? "Immer im Vordergrund ausschalten" : "Immer im Vordergrund einschalten")
            } else {
                Button { CodexPopupController.shared.show(chatID: store.selectedID) } label: { Image(systemName: "macwindow.on.rectangle") }.buttonStyle(.plain).help("In eigenem Chatfenster öffnen").accessibilityLabel("In eigenem Chatfenster öffnen")
            }
            if let id = store.selectedID {
                Button { settings.setChatPinned(id, enabled: !settings.pinnedCodexChats.contains(id)) } label: { Image(systemName: "menubar.rectangle").foregroundStyle(settings.pinnedCodexChats.contains(id) ? Color.mint : Color.secondary) }.buttonStyle(.plain).help(settings.pinnedCodexChats.contains(id) ? "Chat aus Menüleiste entfernen" : "Chat in Menüleiste anheften").accessibilityLabel(settings.pinnedCodexChats.contains(id) ? "Chat aus Menüleiste entfernen" : "Chat in Menüleiste anheften")
                Button { store.openInCodex(id) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.plain).help("In Codex öffnen")
            }
        }.padding(.horizontal, 28).padding(.vertical, 18)
    }
    private var newChatProjectMenu: some View {
        Menu {
            Button { store.selectNewChatProject(nil) } label: { Label("Ohne Projekt", systemImage: store.newChatProjectID == nil ? "checkmark" : "folder") }
            if !store.projects.isEmpty { Divider() }
            ForEach(store.projects) { project in
                Button { store.selectNewChatProject(project) } label: { Label(project.name, systemImage: store.newChatProjectID == project.id ? "checkmark" : "folder") }.disabled(project.paths.isEmpty)
            }
            Divider()
            Button("Anderen Ordner auswählen …") { store.chooseDirectory() }
        } label: {
            Label("Projekt: " + (store.newChatProject?.name ?? (store.workingDirectory == NSHomeDirectory() ? "Ohne Projekt" : URL(fileURLWithPath: store.workingDirectory).lastPathComponent)), systemImage: "folder").font(.system(size: 11)).lineLimit(1)
        }.menuStyle(.borderlessButton).fixedSize(horizontal: true, vertical: false).disabled(store.sending).help("Projekt für den neuen Chat auswählen").accessibilityLabel("Projekt für neuen Chat auswählen")
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if store.hasOlderNativeHistory || store.olderCursor != nil { Button(loadingOlder ? "Ältere Nachrichten werden geladen …" : "Ältere Nachrichten laden") { loadOlderHistory(proxy) }.disabled(loadingOlder).font(.caption).buttonStyle(.plain).foregroundStyle(.secondary) }
                    if store.loadingHistory && store.messages.isEmpty { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 40) }
                    if store.messages.isEmpty && !store.loadingHistory {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(store.selectedID == nil ? "Woran arbeiten wir?" : "Dieser Chat ist bereit.").font(.system(size: 25, weight: .semibold))
                            Text(store.selectedID == nil ? "Schreibe eine Nachricht, um zu beginnen." : "Der Verlauf erscheint hier.").font(.callout).foregroundStyle(.secondary)
                        }.padding(.top, 90).padding(.bottom, 50)
                    }
                    ForEach(blocks) { block in
                        Group {
                        if block.activity {
                            CodexActivityGroup(messages: block.messages, threadID: store.selectedID ?? "new", expansion: $activityExpansion)
                        } else if let message = block.messages.first {
                            HStack {
                                if message.role == "Du" { Spacer(minLength: 40) }
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(message.images) { image in CodexChatImage(source: image.source) }
                                    if !message.text.isEmpty { CodexMessageBody(text: message.text).equatable() }
                                }
                                    .padding(message.role == "Du" ? 14 : 0)
                                    .background(message.role == "Du" ? Color.primary.opacity(0.065) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: message.role == "Du" ? 16 : 0))
                                if message.role != "Du" { Spacer(minLength: 0) }
                            }
                        }
                        }.id(block.id)
                    }
                    ForEach(store.prompts.filter { $0.threadID == store.selectedID }) { prompt in CodexPromptView(prompt: prompt, store: store) }
                    Color.clear.frame(height: 1).id("end")
                }.modifier(CodexTranscriptTargets()).frame(maxWidth: 760, alignment: .leading).padding(.horizontal, 28).padding(.vertical, 26).frame(maxWidth: .infinity)
                    .background(CodexTranscriptScrollObserver(state:transcriptScroll,
                        canLoadOlder: !loadingOlder && !store.loadingHistory && (store.hasOlderNativeHistory || store.olderCursor != nil),
                        historyRevision: "\(store.selectedID ?? "new"):\(store.messages.first?.id ?? "empty"):\(store.olderCursor ?? "")",
                        scrolled:{ atBottom in followLive = atBottom },reachedTop:{ loadOlderHistory(proxy) }))
                    .background(GeometryReader { geometry in Color.clear.onChange(of: geometry.size.height) { _ in scrollToLatest(proxy) } })
            }.modifier(CodexInitialScrollAnchor()).modifier(CodexTranscriptPosition(id: $visibleMessageID))
                .background(GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size.height) { _ in
                        scrollToLatest(proxy)
                    }
                })
                .task(id: "\(store.selectedID ?? "new"):\(store.presentationRevision):\(store.loadingHistory):\(store.messages.last?.id ?? "empty")") {
                    guard followLive, !transcriptScroll.userPaused else { return }
                    await Task.yield()
                    for _ in 0..<3 {
                        guard !Task.isCancelled, followLive, !transcriptScroll.userPaused else { return }
                        scrollToLatest(proxy)
                        do { try await Task.sleep(nanoseconds: 60_000_000) } catch { return }
                    }
                }
                .onAppear { beginTranscript(proxy) }
                .onChange(of: store.messages.last?.id) { _ in scrollToLatest(proxy) }
                .onChange(of: store.prompts.filter { $0.threadID == store.selectedID }.map(\.id)) { _ in scrollToLatest(proxy) }
                .onChange(of: store.messages.last?.text) { _ in scrollToLatest(proxy) }
                .onChange(of: store.selectedID) { _ in beginTranscript(proxy) }
                .onChange(of: store.presentationRevision) { _ in beginTranscript(proxy) }
                .onChange(of: followLive) { value in if value { transcriptScroll.userPaused = false; scrollToLatest(proxy) } }
        }
    }
    @discardableResult private func loadOlderHistory(_ proxy: ScrollViewProxy) -> Bool {
        guard !loadingOlder, !store.loadingHistory, store.hasOlderNativeHistory || store.olderCursor != nil else { return false }
        let id = store.selectedID, anchor = blocks.first(where: { !$0.activity })?.id ?? blocks.first?.id
        loadingOlder = true; transcriptScroll.userPaused = true; followLive = false
        Task {
            if store.hasOlderNativeHistory { await store.loadOlderNativeHistory() } else { await store.loadHistory(older:true) }
            if store.selectedID == id {
                await Task.yield()
                if #available(macOS 14, *) { /* SwiftUI preserves the visible message ID across prepends. */ }
                else if let anchor { proxy.scrollTo(anchor,anchor:.top) }
            }
            loadingOlder = false
        }
        return true
    }
    private func beginTranscript(_ proxy: ScrollViewProxy) {
        transcriptScroll.userPaused = false; transcriptScroll.automaticUntil = Date().addingTimeInterval(2); followLive = true; scrollToLatest(proxy)
    }
    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard followLive, !transcriptScroll.userPaused else { return }
        transcriptScroll.automaticUntil = max(transcriptScroll.automaticUntil, Date().addingTimeInterval(0.35))
        DispatchQueue.main.async { if followLive && !transcriptScroll.userPaused { proxy.scrollTo("end", anchor: .bottom) } }
    }
    private struct Block: Identifiable { let id: String; let activity: Bool; var messages: [CodexMessage] }
    private var blocks: [Block] {
        var result: [Block] = []
        for message in store.messages {
            let isActivity = message.kind == "activity"
            if isActivity, result.last?.activity == true { result[result.count - 1].messages.append(message) }
            else { result.append(Block(id: message.id, activity: isActivity, messages: [message])) }
        }
        var used = Set<String>()
        return result.map { block in
            guard block.activity else { return block }
            let anchor = activityExpansion.groupAnchor(thread:store.selectedID ?? "new",ids:block.messages.map(\.id))
            let id = "activities:" + (used.insert(anchor).inserted ? anchor : block.id)
            return Block(id:id,activity:true,messages:block.messages)
        }
    }
}

private struct CodexInitialScrollAnchor: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.defaultScrollAnchor(.bottom, for: .initialOffset) }
        else if #available(macOS 14, *) { content.defaultScrollAnchor(.bottom) }
        else { content }
    }
}
private struct CodexTranscriptTargets: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14, *) { content.scrollTargetLayout() } else { content }
    }
}
private struct CodexTranscriptPosition: ViewModifier {
    @Binding var id: String?
    func body(content: Content) -> some View {
        if #available(macOS 14, *) { content.scrollPosition(id: $id) } else { content }
    }
}

private final class CodexTranscriptScrollState: ObservableObject {
    var userPaused = false
    var automaticUntil = Date.distantPast
}
private struct CodexTranscriptScrollObserver: NSViewRepresentable {
    let state: CodexTranscriptScrollState
    var canLoadOlder = false
    var historyRevision = ""
    let scrolled: (Bool) -> Void
    var reachedTop: () -> Bool = { false }
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) {
        view.state = state; view.scrolled = scrolled; view.reachedTop = reachedTop
        view.configurePaging(available: canLoadOlder, revision: historyRevision)
        view.scheduleAttachment()
    }
    final class Observer: NSView {
        var scrolled: ((Bool) -> Void)?
        var reachedTop: (() -> Bool)?
        private var topTriggered = false
        private var canLoadOlder = false
        private var historyRevision = ""
        func configurePaging(available: Bool, revision: String) {
            let becameAvailable = available && !canLoadOlder
            let revisionChanged = historyRevision != revision
            if revisionChanged { historyRevision = revision; topTriggered = false }
            canLoadOlder = available
            if available && (becameAvailable || revisionChanged) { schedulePositionRead() }
        }
        var state: CodexTranscriptScrollState?
        private var monitor: Any?
        private var boundsObserver: NSObjectProtocol?
        private var positionRead: DispatchWorkItem?
        private var scrollEndRead: DispatchWorkItem?
        private weak var observedScroll: NSScrollView?
        private var lastDocumentHeight: CGFloat = 0
        private var lastViewportHeight: CGFloat = 0
        private var lastOrigin: CGFloat = 0
        private var lastProgress: Double = 0
        private var scrollingUp = false
        private var draggingScrollbar = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleAttachment() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleAttachment() }
        override func layout() { super.layout(); attach() }
        func scheduleAttachment() { DispatchQueue.main.async { [weak self] in self?.attach() } }
        private func attach() {
            guard window != nil, let scroll = enclosingScrollView else { return }
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseUp]) { [weak self] event in
                    guard let self, event.window === self.window, let scroll = self.observedScroll else { return event }
                    let inside = scroll.bounds.contains(scroll.convert(event.locationInWindow, from:nil))
                    if event.type == .leftMouseDown {
                        guard let bar = scroll.verticalScroller, bar.bounds.contains(bar.convert(event.locationInWindow,from:nil)) else { return event }
                        self.draggingScrollbar = true; self.scrollingUp = false
                        self.state?.userPaused = true; self.scrolled?(false)
                        return event
                    }
                    if event.type == .leftMouseUp {
                        guard self.draggingScrollbar else { return event }
                        self.draggingScrollbar = false
                    } else if !inside { return event }
                    self.scrollEndRead?.cancel()
                    if event.type == .scrollWheel, event.scrollingDeltaY > 0 {
                        self.scrollingUp = true; self.state?.userPaused = true; self.scrolled?(false)
                    } else if event.type == .leftMouseUp || event.scrollingDeltaY < 0 {
                        self.scrollingUp = false
                    }
                    let work = DispatchWorkItem { [weak self] in self?.readPosition(userInitiated:true) }
                    self.scrollEndRead = work
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:work)
                    return event
                }
            }
            guard observedScroll !== scroll else { return }
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            observedScroll = scroll
            let clip = scroll.contentView; clip.postsBoundsChangedNotifications = true
            lastDocumentHeight = scroll.documentView?.bounds.height ?? 0; lastViewportHeight = clip.bounds.height; lastOrigin = clip.bounds.minY; lastProgress = scroll.verticalScroller?.doubleValue ?? 0
            boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.schedulePositionRead() }
        }
        private func schedulePositionRead() {
            guard positionRead == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.positionRead = nil; self?.readPosition(userInitiated: false) }
            positionRead = work
            // Wait for both document and viewport geometry after a disclosure or lazy-row layout.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: work)
        }
        private func readPosition(userInitiated: Bool) {
            guard let scroll = observedScroll, let document = scroll.documentView else { return }
            let visible = scroll.contentView.bounds
            let changedGeometry = abs(document.bounds.height - lastDocumentHeight) > 1 || abs(visible.height - lastViewportHeight) > 1
            let moved = abs(visible.minY - lastOrigin) > 1
            let progress = scroll.verticalScroller?.doubleValue
            let movedUp = !changedGeometry && moved && (progress.map { $0 < lastProgress - 0.0001 } ?? (document.isFlipped ? visible.minY < lastOrigin : visible.minY > lastOrigin))
            lastDocumentHeight = document.bounds.height; lastViewportHeight = visible.height; lastOrigin = visible.minY; if let progress { lastProgress = progress }
            // Trackpad/scrollbar accessibility events need not carry this NSWindow.
            // A real upward viewport movement must still leave live-follow mode.
            if movedUp, let state, Date() > state.automaticUntil {
                scrollingUp = true
                state.userPaused = true
                DispatchQueue.main.async { [weak self] in self?.scrolled?(false) }
            }
            if !changedGeometry, moved, !movedUp, let state, Date() > state.automaticUntil { scrollingUp = false }
            let distance = progress.map { CGFloat(1 - $0) * max(0, document.bounds.height - visible.height) } ?? (document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY)
            let atBottom = distance <= 32 && !scrollingUp
            // Lazy rows can finish measuring during a user's return to the bottom.
            let topDistance = progress.map { CGFloat($0) * max(0,document.bounds.height-visible.height) } ?? visible.minY
            // Start before the reader hits the edge, while there is still a
            // viewport of content available to cover the request/layout latency.
            let preloadDistance: CGFloat
            if #available(macOS 14, *) { preloadDistance = max(600, visible.height * 1.5) } else { preloadDistance = 45 }
            if topDistance > preloadDistance * 1.5 { topTriggered = false }
            if userInitiated, canLoadOlder { topTriggered = false }
            if topDistance <= preloadDistance, state?.userPaused == true, canLoadOlder, !topTriggered {
                topTriggered = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.canLoadOlder, self.state?.userPaused == true, self.reachedTop?() == true else { self.topTriggered = false; return }
                }
            }
            // Geometry changes from prepending, expanding a command or loading
            // an image are not a user returning to the live end of the chat.
            guard userInitiated || draggingScrollbar || (state?.userPaused == true && !changedGeometry && moved) else { return }
            state?.userPaused = !atBottom
            DispatchQueue.main.async { [weak self] in self?.scrolled?(atBottom) }
        }
        deinit { positionRead?.cancel(); scrollEndRead?.cancel(); if let monitor { NSEvent.removeMonitor(monitor) }; if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }
    }
}

private struct CodexMessageBody: View, Equatable {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let replies = CodexQuestionReply.parse(text) {
                ForEach(Array(replies.enumerated()),id:\.offset) { _,reply in
                    VStack(alignment:.leading,spacing:8) {
                        Label("Antwort auf Rückfrage",systemImage:"checkmark.bubble").font(.caption.weight(.semibold)).foregroundStyle(.mint)
                        Text(reply.question).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(reply.answer).font(.body.weight(.medium)).textSelection(.enabled)
                    }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Color.mint.opacity(0.045),in:RoundedRectangle(cornerRadius:12))
                }
            } else {
            ForEach(Array(text.components(separatedBy: "```").enumerated()), id: \.offset) { index, part in
                if index % 2 == 1 {
                    let lines = part.components(separatedBy: "\n")
                    if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mermaid" {
                        MermaidDiagram(source: lines.dropFirst().joined(separator: "\n"))
                    } else {
                    ScrollView(.horizontal) { Text(lines.dropFirst().joined(separator: "\n")).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(12) }
                        .background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                } else if !part.isEmpty {
                    MarkdownContent(source: part)
                }
            }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}

struct MarkdownContent: View {
    let source: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                if let table = block.table {
                    ScrollView(.horizontal) {
                        Grid(alignment: .topLeading, horizontalSpacing: 24, verticalSpacing: 0) {
                            ForEach(Array(table.enumerated()), id: \.offset) { index, row in
                                GridRow(alignment: .top) { ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                                    Text((try? AttributedString(markdown: cell)) ?? AttributedString(cell))
                                        .font(.system(size: 14, weight: index == 0 ? .semibold : .regular)).lineSpacing(5).textSelection(.enabled)
                                        .frame(width: table.first?.count == 2 ? (column == 0 ? 210 : 430) : 260, alignment: .topLeading)
                                        .fixedSize(horizontal: false, vertical: true).padding(.vertical, 12)
                                } }
                                if index < table.count - 1 { Divider().gridCellColumns(table.first?.count ?? 1) }
                            }
                        }.padding(12)
                    }.background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    let part = block.text
                    Text((try? AttributedString(markdown: part, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(part))
                        .font(.system(size: 14)).lineSpacing(5).textSelection(.enabled).tint(.green).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct CodexComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let send: () -> Void
    var attach: ([URL]) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let editor = Editor(frame: NSRect(x: 0, y: 0, width: 400, height: 80)); editor.delegate = context.coordinator; editor.isRichText = false; editor.isEditable = true; editor.isSelectable = true
        editor.drawsBackground = false; editor.textColor = .labelColor; editor.insertionPointColor = .labelColor; editor.font = .systemFont(ofSize: 14)
        editor.textContainerInset = NSSize(width: 3, height: 6); editor.textContainer?.lineFragmentPadding = 0; editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: 0, height: 44); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true; editor.setAccessibilityLabel("Nachricht an Codex")
        editor.attach = attach
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let editor = scroll.documentView as? Editor {
            editor.attach = attach
            if scroll.contentSize.width > 0, editor.frame.width != scroll.contentSize.width { editor.setFrameSize(NSSize(width: scroll.contentSize.width, height: editor.frame.height)) }
            if editor.string != text { editor.string = text }
            context.coordinator.resize(editor)
        }
    }
    final class Editor: NSTextView {
        var attach: ([URL]) -> Void = { _ in }
        override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.fileURL, .png, .tiff] + super.readablePasteboardTypes }
        override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
            if readAttachments(pboard) { return true }
            return super.readSelection(from: pboard, type: type)
        }
        private func readAttachments(_ board: NSPasteboard) -> Bool {
            let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            if !urls.isEmpty { attach(urls); return true }
            if let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]), let url = ChatAttachments.save(png, extension: "png") { attach([url]); return true }
            return false
        }
        override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(paste(_:)), NSPasteboard.general.canReadObject(forClasses: [NSImage.self, NSURL.self], options: nil) { return true }
            return super.validateUserInterfaceItem(item)
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "v", NSPasteboard.general.canReadObject(forClasses: [NSImage.self, NSURL.self], options: nil) { paste(self); return true }
            return super.performKeyEquivalent(with: event)
        }
        override func paste(_ sender: Any?) {
            if !readAttachments(.general) { super.paste(sender) }
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : super.draggingEntered(sender)
        }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { attach(urls); return true }
            return super.performDragOperation(sender)
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            NSApp.activate(ignoringOtherApps:true)
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(self)
            super.mouseDown(with:event)
            // Accessory-app activation completes after the original mouse event.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, window.isKeyWindow, window.attachedSheet == nil else { return }
                window.makeFirstResponder(self)
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodexComposer
        init(_ parent: CodexComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView { parent.text = view.string; resize(view) } }
        func resize(_ view: NSTextView) {
            guard let container = view.textContainer, let layout = view.layoutManager else { return }
            layout.ensureLayout(for: container)
            let height = min(150, max(44, ceil(layout.usedRect(for: container).height + 12)))
            guard abs(parent.height - height) > 1 else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.height = height }
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.shift) != true { parent.send(); return true }
            return false
        }
    }
}
private struct CodexPromptView: View {
    let prompt: CodexPrompt
    @ObservedObject var store: CodexStore
    @State private var answers: [String: String] = [:]
    private var questions: [[String: Any]] { prompt.params["questions"] as? [[String: Any]] ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !prompt.supported {
                Text("Codex benötigt eine Bestätigung im Originalchat").font(.callout.bold())
            } else if prompt.method == "item/tool/requestUserInput" {
                Label("Codex hat eine Rückfrage",systemImage:"questionmark.bubble").font(.headline).foregroundStyle(.mint)
                ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                    let id = question["id"] as? String ?? ""
                    Text(question["question"] as? String ?? "Codex benötigt eine Antwort").font(.callout)
                    if let options = question["options"] as? [[String: Any]] {
                        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                            let label = option["label"] as? String ?? ""
                            Button { answers[id] = label } label: {
                                HStack(alignment:.top,spacing:9) {
                                    Image(systemName:answers[id] == label ? "checkmark.circle.fill" : "circle").foregroundStyle(answers[id] == label ? Color.mint : .secondary)
                                    VStack(alignment:.leading,spacing:4) { Text(label).fontWeight(.medium);if let detail = option["description"] as? String,!detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) } };Spacer(minLength:0)
                                }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:9))
                            }.buttonStyle(.plain)
                        }
                    }
                    if question["isSecret"] as? Bool == true { SecureField("Deine Antwort",text:Binding(get:{answers[id] ?? ""},set:{answers[id]=$0})).textFieldStyle(.roundedBorder) }
                    else { TextField("Eigene Antwort",text:Binding(get:{answers[id] ?? ""},set:{answers[id]=$0})).textFieldStyle(.roundedBorder) }
                }
                Button("Antwort senden") {
                    let values = answers.mapValues { ["answers": [$0]] }
                    store.answer(prompt, result: ["answers": values])
                }.disabled(!store.canAnswer(prompt) || questions.contains { (answers[$0["id"] as? String ?? ""] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            } else {
                Text(prompt.method == "item/permissions/requestApproval" ? "Codex benötigt zusätzliche Berechtigungen" : "Codex benötigt eine Freigabe").font(.callout.bold())
                if let reason = prompt.params["reason"] as? String { Text(reason).font(.caption).textSelection(.enabled) }
                if let command = prompt.params["command"] as? String { Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                if let cwd = prompt.params["cwd"] as? String { Text(cwd).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                if let changes = prompt.params["changes"], let data = try? JSONSerialization.data(withJSONObject: changes, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) {
                    ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 140)
                }
                if let context = prompt.params["networkApprovalContext"] as? [String: Any], let host = context["host"] as? String { Text("Netzwerkzugriff: " + host).font(.caption).textSelection(.enabled) }
                if prompt.method == "mcpServer/elicitation/request" {
                    Text(prompt.params["message"] as? String ?? "Eingabe wird benötigt").font(.caption)
                    HStack {
                        Button("Ablehnen") { store.answer(prompt, result: ["action": "decline", "content": NSNull()]) }.disabled(!store.canAnswer(prompt))
                        if let acceptance = prompt.elicitationAcceptance {
                            Button("Annehmen") { store.answer(prompt,result:acceptance) }.buttonStyle(.borderedProminent).tint(.mint).disabled(!store.canAnswer(prompt))
                        }
                    }
                } else if prompt.method == "item/permissions/requestApproval" {
                    HStack {
                        Button("Nicht erlauben") { store.answer(prompt, result: ["permissions": [:], "scope": "turn"]) }
                        if let permissions = prompt.params["permissions"] as? [String: Any] { Button("Für diesen Turn erlauben") { store.answer(prompt, result: ["permissions":permissions, "scope":"turn"]) } }
                    }
                } else {
                    HStack {
                        Button("Ablehnen") { store.answer(prompt, result: ["decision": "decline"]) }.disabled(!store.canAnswer(prompt))
                        Button("Einmal erlauben") { store.answer(prompt, result: ["decision": "accept"]) }.disabled(!store.canAnswer(prompt))
                    }
                }
            }
            if prompt.desktop { Button("Im Originalchat öffnen") { store.openInCodex(prompt.threadID) }.font(.caption) }
            if store.answeringPrompts.contains(prompt.id) { ProgressView("Antwort wird bestätigt …").controlSize(.small) }
        }.disabled(store.answeringPrompts.contains(prompt.id)).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension Notification.Name { static let codexAttachmentsChanged = Notification.Name("codexAttachmentsChanged") }

enum ChatAttachments {
    static func save(_ data: Data, extension ext: String) -> URL? {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacTools/ChatAttachments", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext); try data.write(to: url, options: .atomic); return url } catch { return nil }
    }
    static func load(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    if let url, url.isFileURL { DispatchQueue.main.async { completion([url]) } }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let image = NSImage(data: data), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]), let url = save(png, extension: "png") else { return }
                    DispatchQueue.main.async { completion([url]) }
                }
            }
        }
    }
}

struct MarkdownBlock {
    var text = ""
    var table: [[String]]?
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n")
        var result: [MarkdownBlock] = [], plain: [String] = [], index = 0
        func cells(_ line: String) -> [String] {
            var value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("|") { value.removeFirst() }; if value.hasSuffix("|") { value.removeLast() }
            return value.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func flush() { if !plain.isEmpty { result.append(MarkdownBlock(text: plain.joined(separator: "\n"))); plain = [] } }
        while index < lines.count {
            if index + 1 < lines.count, lines[index].contains("|"), lines[index + 1].contains("|"), cells(lines[index + 1]).allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) {
                flush(); var rows = [cells(lines[index])]; index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty { rows.append(cells(lines[index])); index += 1 }
                result.append(MarkdownBlock(table: rows))
            } else { plain.append(lines[index]); index += 1 }
        }
        flush(); return result
    }
}

struct MermaidDiagram: View {
    let source: String
    @State private var height: CGFloat = 240
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Label("Diagramm", systemImage: "point.3.connected.trianglepath.dotted").foregroundStyle(.secondary); Spacer(); Button { MermaidDiagramWindow.show(source) } label: { Label("Vergrößern", systemImage: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain).accessibilityLabel("Diagramm vergrößern") }.font(.caption).padding(12)
            MermaidWebView(source: source, height: $height).frame(height: height).frame(maxWidth: .infinity)
        }.background(Color.primary.opacity(0.025)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor private enum MermaidDiagramWindow {
    private static var windows: [MermaidDiagramWindowController] = []
    static func closed(_ controller: MermaidDiagramWindowController) { windows.removeAll { $0 === controller } }
    static func show(_ source: String) {
        windows.removeAll { $0.window?.isVisible != true }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Codex · Diagramm"; window.minSize = NSSize(width: 600, height: 400); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: MermaidExpandedView(source: source))
        let controller = MermaidDiagramWindowController(window: window); window.delegate = controller; windows.append(controller)
        window.center(); controller.showWindow(nil); window.makeKeyAndOrderFront(nil)
    }
}
@MainActor private final class MermaidDiagramWindowController: NSWindowController, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        MermaidDiagramWindow.closed(self)
    }
}
private struct MermaidExpandedView: View {
    let source: String
    @State private var height: CGFloat = 600
    @State private var zoom = 1.0
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Diagramm").font(.headline); Spacer(); Button("−") { zoom = max(0.25, zoom - 0.25) }.accessibilityLabel("Diagramm verkleinern"); Text(zoom, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 50); Button("+") { zoom = min(3, zoom + 0.25) }.accessibilityLabel("Diagramm vergrößern"); Button("100 %") { zoom = 1 } }.padding(12)
            Divider()
            MermaidWebView(source: source, height: $height, zoom: zoom).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct MermaidWebView: NSViewRepresentable {
    let source: String
    @Binding var height: CGFloat
    var zoom: Double = 1
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "size")
        let web = WKWebView(frame: .zero, configuration: config); web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.zoom != zoom { context.coordinator.zoom = zoom; web.pageZoom = zoom }
        guard context.coordinator.source != source else { return }; context.coordinator.source = source
        let encoded = try? JSONSerialization.data(withJSONObject: [source])
        let payload = encoded?.base64EncodedString() ?? "W10="
        let resource = Bundle.main.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Mermaid")
        let script = resource.flatMap { try? String(contentsOf: $0) } ?? ""
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data:; font-src data:"><style>:root{color-scheme:dark light}body{margin:0;padding:16px;font:13px -apple-system;color:#bbb;overflow:auto}#graph{width:max-content;min-width:100%}svg{max-width:none!important;height:auto}pre{white-space:pre-wrap}</style></head><body><div id="graph"></div><script>\(script)</script><script>
        const source=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(payload)'),c=>c.charCodeAt(0))))[0];
        async function draw(){try{mermaid.initialize({startOnLoad:false,theme:matchMedia('(prefers-color-scheme:dark)').matches?'dark':'default',securityLevel:'strict',suppressErrorRendering:true});const result=await mermaid.render('diagram',source);document.getElementById('graph').innerHTML=result.svg;}catch(e){const pre=document.createElement('pre');pre.textContent='Diagramm: '+e.message+'\\n'+source;document.getElementById('graph').replaceChildren(pre);}window.webkit.messageHandlers.size.postMessage(document.documentElement.scrollHeight);}
        draw();new ResizeObserver(()=>window.webkit.messageHandlers.size.postMessage(document.documentElement.scrollHeight)).observe(document.getElementById('graph'));
        </script></body></html>
        """
        web.loadHTMLString(html, baseURL: nil)
    }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { web.configuration.userContentController.removeScriptMessageHandler(forName: "size"); web.stopLoading() }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MermaidWebView
        var source: String?
        var zoom: Double = 1
        init(_ parent: MermaidWebView) { self.parent = parent }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? NSNumber else { return }
            let height = min(900, max(80, CGFloat(value.doubleValue)))
            if abs(parent.height - height) > 1 { parent.height = height }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.navigationType == .other && navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
        }
    }
}

struct CodexAsyncQuestionView: View {
    let question: CodexAsyncQuestion
    @ObservedObject var store: CodexStore
    @State private var answer = ""
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Label("Rückfrage von Codex",systemImage:"questionmark.bubble").font(.caption.weight(.semibold)).foregroundStyle(.mint);Spacer();if store.answeringAsyncQuestions.contains(question.id) { ProgressView().controlSize(.small) } }
            Text(question.title).font(.callout.weight(.medium)).textSelection(.enabled)
            ForEach(Array(question.options.enumerated()),id:\.offset) { _,option in
                Button { answer = option } label: {
                    HStack { Image(systemName:answer == option ? "checkmark.circle.fill" : "circle");Text(option);Spacer() }.font(.callout).foregroundStyle(answer == option ? Color.mint : .primary).padding(10).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:9))
                }.buttonStyle(.plain)
            }
            HStack { TextField("Eigene Antwort",text:$answer).textFieldStyle(.roundedBorder).accessibilityLabel("Antwort auf Rückfrage")
                Button("Antwort senden") { let value = answer;Task { _ = await store.answerAsync(question,answer:value) } }.buttonStyle(.borderedProminent).tint(.mint).disabled(answer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || store.sending)
            }
        }.padding(16).frame(maxWidth:760,alignment:.leading).frame(maxWidth:.infinity).background(Color.mint.opacity(0.05),in:RoundedRectangle(cornerRadius:14)).disabled(store.answeringAsyncQuestions.contains(question.id))
    }
}
