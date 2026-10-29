import AppKit
import SwiftUI
import Combine


@MainActor extension NSPopover {
    /// Focus the popup itself; activating the entire app also raises its main window.
    func showFocused(relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge) {
        show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
        focusContent()
        DispatchQueue.main.async { [weak self] in self?.focusContent() }
    }
    private func focusContent() {
        guard isShown, let view = contentViewController?.view, let window = view.window else { return }
        window.makeKeyAndOrderFront(nil)
        func composer(in view: NSView) -> CodexComposer.Editor? {
            if let editor = view as? CodexComposer.Editor { return editor }
            return view.subviews.lazy.compactMap { composer(in: $0) }.first
        }
        if let editor = composer(in: view) { window.makeFirstResponder(editor) }
    }
}

extension Notification.Name { static let showMacToolsQuickPanel = Notification.Name("showMacToolsQuickPanel") }
extension Notification.Name { static let showPinnedCodexChat = Notification.Name("showPinnedCodexChat") }
extension Notification.Name { static let showCodexMenuStats = Notification.Name("showCodexMenuStats") }

@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var observer: NSObjectProtocol?
    private var codexObserver: NSObjectProtocol?
    private var mainSubscription: AnyCancellable?
    private var mainVisibility: StatusItemVisibility?
    private var folderVisibility: [String: StatusItemVisibility] = [:]
    private var toolVisibility: [ToolNavigation.Section: StatusItemVisibility] = [:]
    private var folderSubscription: AnyCancellable?
    private var chatSubscription: AnyCancellable?
    private var chatObserver: NSObjectProtocol?
    private var chatItems: [String: NSStatusItem] = [:]
    private var chatActions: [String: CodexPinnedChatMenu] = [:]
    private var chatVisibility: [String: StatusItemVisibility] = [:]
    private var folderItems: [String: NSStatusItem] = [:]
    private var folderActions: [String: CodexFolderMenu] = [:]
    private var toolSubscription: AnyCancellable?
    private var toolItems: [ToolNavigation.Section: NSStatusItem] = [:]
    private var toolActions: [ToolNavigation.Section: PinnedToolAction] = [:]
    private let codexPopover = NSPopover()
    private let usagePopover = NSPopover()
    private var usageLabel: CodexStatusLabel?
    private var usageSubscription: AnyCancellable?
    private var codexLabel: CodexStatusLabel?
    private var codexSubscription: AnyCancellable?
    private var remainingLabel = "—"
    private var healthSubscription: AnyCancellable?
    private var normalMenuImage: NSImage?

    init(settings: SettingsStore, library: VideoLibraryStore,
         openSection: @escaping (ToolNavigation.Section) -> Void,
         openSettings: @escaping (SettingsCategory) -> Void,
         randomWallpaper: @escaping () -> Void) {
        super.init()
        usagePopover.behavior = .transient; usagePopover.contentSize = NSSize(width: 360, height: 430)
        usagePopover.contentViewController = NSHostingController(rootView: CodexUsageView(inPopover: true).frame(width: 360, height: 430))
        usageSubscription = CodexStore.shared.$usageBuckets.combineLatest(CodexStore.shared.$usageError).sink { [weak self] buckets,error in
            let remaining = error == nil ? (buckets.first(where: { $0.id == "codex" }) ?? buckets.first)?.windows.map(\.remaining).min() : nil
            let text = remaining.map { "\(Int($0.rounded()))%" } ?? "—"
            self?.usageLabel?.valueText = text
            self?.remainingLabel = text
            self?.updateCombinedCodexLabel()
            self?.toolItems[.codexLimit]?.button?.setAccessibilityLabel("Codex-Limit, noch " + text)
        }
        codexPopover.behavior = .transient
        let statsHeight = min(740, max(500, (NSScreen.main?.visibleFrame.height ?? 810) - 70))
        codexPopover.contentSize = NSSize(width: 390, height: statsHeight)
        codexPopover.contentViewController = NSHostingController(rootView: CodexMenuStatsView(
            openChats: { [weak self] in self?.codexPopover.close(); openSection(.codex) },
            openSettings: { [weak self] in self?.codexPopover.close(); openSettings(.navigation) },
            openLimits: { [weak self] in self?.codexPopover.close(); openSection(.codexLimit) }, newChat: { [weak self] in self?.codexPopover.close(); CodexPopupController.shared.show(chatID: nil) }).frame(width: 390, height: statsHeight))
        codexSubscription = CodexStore.shared.$activityHistory.sink { [weak self] points in
            let point = points.last
            self?.codexLabel?.running = point?.running ?? 0
            self?.codexLabel?.waiting = point?.waiting ?? 0
            self?.updateCombinedCodexLabel()
        }
        chatSubscription = settings.$pinnedCodexChats.sink { [weak self] ids in
            guard let self else { return }
            for id in ids where self.chatItems[id] == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                let action = CodexPinnedChatMenu(id: id, item: item)
                self.chatItems[id] = item; self.chatActions[id] = action
                self.chatVisibility[id] = StatusItemVisibility(item: item, name: "MacTools.Chat." + id) { [weak self] in
                    guard self?.chatItems[id] === item else { return }; settings.setChatPinned(id, enabled: false)
                }
            }
            for id in Array(self.chatItems.keys) where !ids.contains(id) {
                self.chatVisibility.removeValue(forKey: id)?.invalidate()
                self.chatActions.removeValue(forKey: id)?.stop()
                if let item = self.chatItems.removeValue(forKey: id) { NSStatusBar.system.removeStatusItem(item) }
            }
        }
        chatObserver = NotificationCenter.default.addObserver(forName: .showPinnedCodexChat, object: nil, queue: .main) { [weak self] event in
            guard let id = event.object as? String else { return }
            Task { @MainActor in self?.chatActions[id]?.toggle() }
        }
        folderSubscription = settings.$pinnedCodexFolders.sink { [weak self] paths in
            guard let self else { return }
            for path in paths where self.folderItems[path] == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                let action = CodexFolderMenu(path: path, open: openSection, remove: { settings.pinnedCodexFolders.removeAll { $0 == path } })
                let menu = NSMenu(); menu.delegate = action; item.menu = menu
                item.button?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: path); item.button?.image?.isTemplate = true
                item.button?.imagePosition = .imageLeft
                item.button?.title = " " + String(CodexStore.shared.folderName(path).prefix(12)); item.button?.toolTip = path
                self.folderItems[path] = item; self.folderActions[path] = action
                self.folderVisibility[path] = StatusItemVisibility(item: item, name: "MacTools.CodexFolder." + path) { [weak self] in
                    guard self?.folderItems[path] === item else { return }
                    settings.pinnedCodexFolders.removeAll { $0 == path }
                }
            }
            for path in Array(self.folderItems.keys) where !paths.contains(path) {
                self.folderVisibility.removeValue(forKey: path)?.invalidate()
                if let item = self.folderItems.removeValue(forKey: path) { NSStatusBar.system.removeStatusItem(item) }; self.folderActions[path] = nil
            }
        }
        toolSubscription = settings.$pinnedTools.sink { [weak self] enabled in
            guard let self else { return }
            for tool in ToolNavigation.Section.pinnable {
                if enabled.contains(tool), self.toolItems[tool] == nil {
                    let item = NSStatusBar.system.statusItem(withLength: tool == .codex ? 52 : tool == .codexLimit ? 46 : NSStatusItem.squareLength)
                    let action = PinnedToolAction { [weak self] in
                        if tool == .codex { self?.toggleCodexStats() } else if tool == .codexLimit, let button = self?.toolItems[tool]?.button {
                            if self?.usagePopover.isShown == true { self?.usagePopover.close() } else { self?.usagePopover.showFocused(relativeTo: button.bounds, of: button, preferredEdge: .minY) }; CodexStore.shared.start()
                        } else { openSection(tool) }
                    }
                    self.toolItems[tool] = item; self.toolActions[tool] = action
                    item.button?.image = NSImage(systemSymbolName: tool.icon, accessibilityDescription: "MacTools · " + tool.rawValue)
                    item.button?.image?.isTemplate = true; item.button?.toolTip = "MacTools · " + tool.rawValue
                    item.button?.target = action; item.button?.action = #selector(PinnedToolAction.invoke)
                    if tool == .codex, let button = item.button {
                        button.image = nil; button.title = ""
                        let label = CodexStatusLabel(frame: button.bounds)
                        label.running = CodexStore.shared.runningCount; label.waiting = CodexStore.shared.waitingCount
                        self.codexLabel = label; button.addSubview(label)
                        self.updateCombinedCodexLabel()

                        CodexStore.shared.start()
                    }
                    if tool == .codexLimit, let button = item.button {
                        button.image = nil; button.title = ""
                        let label = CodexStatusLabel(frame: button.bounds); label.titleText = "LIMIT"; label.valueText = (CodexStore.shared.usageBuckets.first?.windows.map(\.remaining).min()).map { "\(Int($0.rounded()))%" } ?? "—"
                        if CodexStore.shared.usageError != nil { label.valueText = "—" }
                        self.usageLabel = label; button.addSubview(label); CodexStore.shared.start()
                    }
                    self.toolVisibility[tool] = StatusItemVisibility(item: item, name: "MacTools.Tool." + tool.rawValue) { [weak self] in
                        guard self?.toolItems[tool] === item else { return }
                        settings.setPinned(tool, enabled: false)
                    }
                } else if !enabled.contains(tool), let item = self.toolItems.removeValue(forKey: tool) {
                    if tool == .codex { self.codexPopover.close(); self.codexLabel = nil }
                    if tool == .codexLimit { self.usagePopover.close(); self.usageLabel = nil }
                    self.toolVisibility.removeValue(forKey: tool)?.invalidate()
                    NSStatusBar.system.removeStatusItem(item); self.toolActions.removeValue(forKey: tool)
                }
            }
        }
        if let button = statusItem.button {
            button.image = NSImage(named: "MenuBarIcon") ?? Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = true
            normalMenuImage = button.image
            button.toolTip = "MacTools · Live-Übersicht & Schnellaktionen"
            button.target = self; button.action = #selector(togglePanel)
            let drop = ToolStatusDropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.onClick = { [weak self] in self?.togglePanel() }
            drop.onTool = { tool in settings.setPinned(tool, enabled: true) }
            drop.onFolder = { settings.pinCodexFolder($0) }
            drop.onChat = { settings.setChatPinned($0, enabled: true) }
            button.addSubview(drop)
        }
        healthSubscription = PrivateMCPStore.shared.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateHealthIndicator() } }
        updateHealthIndicator()
        mainVisibility = StatusItemVisibility(item: statusItem, name: "MacTools.Main") { settings.showMainMenuIcon = false }
        mainSubscription = settings.$showMainMenuIcon.sink { [weak self] visible in self?.statusItem.isVisible = visible }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: min(900, max(520, (NSScreen.main?.visibleFrame.height ?? 680) - 40)))
        popover.contentViewController = NSHostingController(rootView: QuickPanelView(settings: settings, library: library,
            openSection: { [weak self] section in self?.popover.close(); openSection(section) },
            openSettings: { [weak self] category in self?.popover.close(); openSettings(category) },
            pin: { [weak self] in self?.popover.close(); WindowPinController.shared.toggleCurrentWindow(useMenuSelection: true) },
            randomWallpaper: randomWallpaper, closePanel: { [weak self] in self?.popover.close() }))
        observer = NotificationCenter.default.addObserver(forName: .showMacToolsQuickPanel, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.togglePanel() }
        }
        codexObserver = NotificationCenter.default.addObserver(forName: .showCodexMenuStats, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.toggleCodexStats() } }
    }

    var diagnostics: [[String: Any]] {
        [Self.describe(statusItem, name: "main")] + folderItems.map { Self.describe($0.value, name: "folder:" + $0.key) } + toolItems.map { Self.describe($0.value, name: "tool:" + $0.key.rawValue) } + chatItems.map { Self.describe($0.value, name: "chat:" + $0.key).merging(chatActions[$0.key]?.diagnostics ?? [:]) { _, latest in latest } }
    }
    static func describe(_ item: NSStatusItem, name: String) -> [String: Any] {
        let window = item.button?.window
        return ["name": name, "visible": item.isVisible, "length": item.length, "hasButton": item.button != nil, "hasWindow": window != nil, "windowVisible": window?.isVisible ?? false, "windowFrame": window.map { NSStringFromRect($0.frame) } ?? "", "buttonFrame": item.button.map { NSStringFromRect($0.frame) } ?? "", "imagePresent": item.button?.image != nil, "imageTemplate": item.button?.image?.isTemplate ?? false, "tooltip": item.button?.toolTip ?? "", "accessibilityLabel": item.button?.accessibilityLabel() ?? ""]
    }
    func shutdown() {
        chatVisibility.values.forEach { $0.invalidate() }; chatVisibility.removeAll()
        chatSubscription?.cancel(); chatActions.values.forEach { $0.stop() }; chatActions.removeAll()
        if let chatObserver { NotificationCenter.default.removeObserver(chatObserver) }
        mainVisibility?.invalidate(); mainVisibility = nil
        folderVisibility.values.forEach { $0.invalidate() }; folderVisibility.removeAll()
        toolVisibility.values.forEach { $0.invalidate() }; toolVisibility.removeAll()
        mainSubscription?.cancel(); folderSubscription?.cancel(); toolSubscription?.cancel(); codexSubscription?.cancel(); usageSubscription?.cancel()
        popover.close(); codexPopover.close(); usagePopover.close()
        for item in Array(folderItems.values) + Array(toolItems.values) + Array(chatItems.values) { NSStatusBar.system.removeStatusItem(item) }
        folderItems.removeAll(); toolItems.removeAll(); chatItems.removeAll(); NSStatusBar.system.removeStatusItem(statusItem)
        if let observer { NotificationCenter.default.removeObserver(observer) }; if let codexObserver { NotificationCenter.default.removeObserver(codexObserver) }
    }
    private func toggleCodexStats() {
        guard let button = toolItems[.codex]?.button else { return }
        if codexPopover.isShown { codexPopover.close() }
        else { CodexStore.shared.start(); codexPopover.showFocused(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
    private func updateHealthIndicator() {
        let critical = PrivateMCPStore.shared.criticalServices
        guard let button = statusItem.button, let original = normalMenuImage else { return }
        if critical.isEmpty { button.image = original; button.toolTip = "MacTools · Live-Übersicht & Schnellaktionen" }
        else {
            button.image = NSImage(size: original.size, flipped: false) { rect in original.draw(in: rect); NSColor.systemRed.setFill(); rect.fill(using: .sourceIn); return true }
            button.image?.isTemplate = false
            button.toolTip = "Kritisch: " + critical.map { $0.kind.title + " · " + ($0.error != nil ? "Nicht erreichbar" : $0.stateLabel) }.joined(separator: "; ")
        }
        button.setAccessibilityLabel(button.toolTip)
        for service in PrivateMCPStore.shared.services { toolItems[service.kind.section]?.button?.contentTintColor = service.critical ? .systemRed : nil }
    }
    private func updateCombinedCodexLabel() {
        guard let label = codexLabel else { return }
        label.titleText = label.waiting > 0 ? "CODEX · !\(label.waiting)" : "CODEX"
        label.valueText = remainingLabel + " – " + String(label.running)
        let titleWidth = (label.titleText as NSString).size(withAttributes: [.font:NSFont.systemFont(ofSize:8,weight:.medium)]).width
        let width = ceil(max(titleWidth,(label.valueText! as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)]).width)) + 8 + (label.waiting > 0 ? 8 : 0)
        toolItems[.codex]?.length = max(44, width)
        toolItems[.codex]?.button?.setAccessibilityLabel("Codex: noch " + remainingLabel + ", \(label.running) laufende Chats, \(label.waiting) warten auf dich")
        toolItems[.codex]?.button?.toolTip = "Codex · noch " + remainingLabel + " · \(label.running) laufende Chats · \(label.waiting) warten auf dich"
    }
    func revealEnabledItems() {
        if SettingsStore.shared.showMainMenuIcon { statusItem.isVisible = true }
        for item in folderItems.values { item.isVisible = true }
        for item in toolItems.values { item.isVisible = true }
        for item in chatItems.values { item.isVisible = true }
    }
    @objc private func togglePanel() {
        if popover.isShown { popover.close(); return }
        guard let button = statusItem.button else { return }
        WindowPinController.shared.prepareMenuSelection()
        popover.showFocused(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

/// Status-item views may belong to a different display than their mirrored
/// menu-bar copy. Give chat popovers a real positioning view on the clicked screen.
@MainActor final class PinnedChatPopoverAnchor: NSObject, NSPopoverDelegate {
    private static weak var active: PinnedChatPopoverAnchor?
    private let popover: NSPopover
    private var anchor: NSPanel?
    private(set) var targetScreen: NSScreen?
    init(popover:NSPopover) { self.popover=popover;super.init();popover.delegate=self }
    static func frame(at point:NSPoint, screen:NSRect, visible:NSRect, menuHeight:CGFloat) -> NSRect {
        let x = min(max(point.x,screen.minX+1),screen.maxX-1)
        let menuBottom = min(visible.maxY,screen.maxY-menuHeight)
        return NSRect(x:x-1,y:menuBottom,width:2,height:1)
    }
    func show(from button:NSStatusBarButton, at point:NSPoint) {
        Self.active?.close()
        targetScreen = NSScreen.screens.first { $0.frame.contains(point) } ?? button.window?.screen ?? NSScreen.main
        guard let screen = targetScreen else { popover.showFocused(relativeTo:button.bounds,of:button,preferredEdge:.minY);return }
        if anchor == nil {
            let panel = NSPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.isReleasedWhenClosed=false;panel.isOpaque=false;panel.backgroundColor = .clear
            panel.hasShadow=false;panel.ignoresMouseEvents=true;panel.level = .statusBar
            panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
            panel.contentView=NSView(frame:NSRect(x:0,y:0,width:2,height:1));anchor=panel
        }
        guard let anchor,let view=anchor.contentView else { return }
        anchor.setFrame(Self.frame(at:point,screen:screen.frame,visible:screen.visibleFrame,menuHeight:NSStatusBar.system.thickness),display:false)
        anchor.orderFrontRegardless();Self.active=self
        popover.showFocused(relativeTo:view.bounds,of:view,preferredEdge:.minY)
        if !popover.isShown { close() }
    }
    func close() { popover.close();anchor?.orderOut(nil);if Self.active === self { Self.active=nil } }
    func popoverDidClose(_ notification:Notification) { guard !popover.isShown else { return };anchor?.orderOut(nil);if Self.active === self { Self.active=nil } }
    var diagnostics:[String:Any] { ["targetScreen":targetScreen?.localizedName ?? "", "anchorFrame":anchor.map {NSStringFromRect($0.frame)} ?? "", "popoverFrame":popover.contentViewController?.view.window.map {NSStringFromRect($0.frame)} ?? "", "popoverScreen":popover.contentViewController?.view.window?.screen?.localizedName ?? "", "popoverKey":popover.contentViewController?.view.window?.isKeyWindow ?? false] }
}

enum CodexChatMenuAppearance {
    static func apply(to button: NSStatusBarButton, active: Bool, waiting: Bool) {
        // Tinting the entire status button can leave native menu-bar text black.
        // Keep text/highlighting under AppKit's control, including template contrast.
        button.contentTintColor = nil
        let symbol = waiting ? "exclamationmark.bubble.fill" : active ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Angehefteter Codex-Chat")
        button.image?.isTemplate = !waiting
        if waiting { button.image = button.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemBlue])) }
    }
}

@MainActor final class CodexPinnedChatMenu: NSObject {
    private let id: String
    private weak var item: NSStatusItem?
    let store: CodexStore
    private let popover = NSPopover()
    private lazy var positioning = PinnedChatPopoverAnchor(popover:popover)
    private var subscriptions = Set<AnyCancellable>()
    private var warming: Task<Void, Never>?
    init(id: String, item: NSStatusItem, store supplied: CodexStore? = nil) {
        self.id = id; self.item = item
        store = supplied ?? CodexStore(defaults: UserDefaults(suiteName: "com.julianfink.MacTools.MenuChat." + id)!, followAllChats: false, queue: .shared)
        super.init()
        store.prepareSelection(id)
        item.button?.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Angehefteter Codex-Chat")
        item.button?.image?.isTemplate = true; item.button?.imagePosition = .imageLeft
        item.button?.target = self; item.button?.action = #selector(toggle)
        popover.behavior = .transient
        let height = min(680, max(400, (NSScreen.main?.visibleFrame.height ?? 760) - 70))
        popover.contentSize = NSSize(width: 560, height: height)
        popover.contentViewController = Self.contentController(store: store, size: popover.contentSize)
        CodexStore.shared.objectWillChange.merge(with: store.objectWillChange).receive(on: RunLoop.main).sink { [weak self] _ in self?.updateLabel() }.store(in: &subscriptions)
        updateLabel(); warm()
    }
    static func contentController(store: CodexStore, size: NSSize) -> NSViewController {
        let controller = NSHostingController(rootView: CodexChatsView(store: store, menuMode: true).frame(width: size.width, height: size.height))
        // NSPopover owns this fixed frame. Deriving min/ideal/max constraints
        // from its changing ScrollViews creates a sizing feedback loop on macOS.
        controller.sizingOptions = []
        controller.preferredContentSize = size
        controller.view.setFrameSize(size)
        return controller
    }
    private func updateLabel() {
        let chat = store.selected ?? CodexStore.shared.liveChats.first { $0.id == id }
        let waiting = store.waitingChatIDs.contains(id) || CodexStore.shared.waitingChatIDs.contains(id)
        let status = waiting ? "Wartet auf deine Eingabe" : chat?.statusLabel ?? "Live-Chat öffnen"
        item?.button?.title = " " + String((chat?.title ?? "Codex-Chat").prefix(18))
        if let button = item?.button { CodexChatMenuAppearance.apply(to: button, active: chat?.status == "active", waiting: waiting) }
        item?.button?.toolTip = (chat?.title ?? "Codex-Chat") + " · " + status
        item?.button?.setAccessibilityLabel("Live-Chat " + (chat?.title ?? id) + " · " + status)
    }
    private func warm() {
        guard warming == nil else { return }
        store.primeConversation(id, from: .shared); store.start()
        warming = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(25)
            while !self.store.connected && Date() < deadline && !Task.isCancelled {
                if !self.store.connecting { await self.store.connect() }
                else { do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return } }
            }
            if !Task.isCancelled && self.store.connected { await self.store.finishSelection(self.id) }
            self.warming = nil
        }
    }
    @objc func toggle() {
        guard let button = item?.button else { return }
        let clickPoint = NSEvent.mouseLocation
        if popover.isShown { positioning.close(); return }
        if !store.connected { warm() }
        store.presentationRevision += 1
        positioning.show(from:button,at:clickPoint)
    }
    // Keep the follower and transcript warm while this chat remains pinned.
    func stop() { warming?.cancel(); warming = nil; positioning.close(); store.stop() }
    var diagnostics: [String: Any] {
        func editor(in view: NSView) -> CodexComposer.Editor? {
            if let editor = view as? CodexComposer.Editor { return editor }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let draft = store.drafts[store.selectedID ?? "new"] ?? ""
        let native = popover.contentViewController.flatMap { editor(in: $0.view) }?.string
        return ["chatId": id, "popoverShown": popover.isShown, "selectedChatId": store.selectedID as Any? ?? NSNull(), "messageCount": store.messages.count, "imageCount": store.messages.reduce(0) { $0 + $1.images.count }, "connected": store.connected, "queuedCount": (store.queuedMessages[id] ?? []).count + (store.nativeQueuedMessages[id] ?? []).count, "draftCharacters": draft.count, "nativeDraftCharacters": native.map { $0.count } as Any? ?? NSNull(), "nativeDraftMatches": native.map { $0 == draft } as Any? ?? NSNull(), "sending": store.sending, "hasError": store.error != nil].merging(positioning.diagnostics) {_,new in new}
    }
}

/// A single measured text block avoids NSButtonCell's different baselines for two fonts.
/// The parent status button retains native highlighting, accessibility and mouse handling.
final class CodexStatusLabel: NSView {
    var titleText = "CODEX" { didSet { needsDisplay = true } }
    var valueText: String? { didSet { needsDisplay = true } }
    var running = 0 { didSet { if running != oldValue { needsDisplay = true } } }
    var waiting = 0 { didSet { if waiting != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); autoresizingMask = [.width, .height]; setAccessibilityElement(false) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let title = NSAttributedString(string: titleText, attributes: [.font: NSFont.systemFont(ofSize: 8, weight: .medium), .foregroundColor: waiting > 0 ? NSColor.systemBlue : NSColor.labelColor])
        let value = NSAttributedString(string: valueText ?? String(running), attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor])
        let top = (bounds.height - title.size().height - value.size().height + 1) / 2
        title.draw(at: NSPoint(x: (bounds.width - title.size().width) / 2, y: top))
        value.draw(at: NSPoint(x: (bounds.width - value.size().width) / 2, y: top + title.size().height - 1))
        if waiting > 0 { NSColor.systemBlue.setFill(); NSBezierPath(ovalIn: NSRect(x: bounds.width - 7, y: top + title.size().height + 3, width: 4, height: 4)).fill() }
    }
}

final class MonitorWidgetLabel: NSView {
    let metric: MonitorMetric
    var value = "—" { didSet { if oldValue != value { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    init(metric: MonitorMetric, frame: NSRect) {
        self.metric = metric
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let label = NSAttributedString(string: metric.title.uppercased(), attributes: [.font: NSFont.systemFont(ofSize: 8, weight: .medium), .foregroundColor: NSColor.labelColor])
        let number = NSAttributedString(string: value, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor])
        let labelSize = label.size(), numberSize = number.size()
        let spacing: CGFloat = -1
        let height = labelSize.height + numberSize.height + spacing
        let top = (bounds.height - height) / 2
        label.draw(at: NSPoint(x: (bounds.width - labelSize.width) / 2, y: top))
        number.draw(at: NSPoint(x: (bounds.width - numberSize.width) / 2, y: top + labelSize.height + spacing))
    }
}

struct MonitorWidgetPreview: NSViewRepresentable {
    let metric: MonitorMetric
    @ObservedObject private var monitor = SystemMonitor.shared
    func makeNSView(context: Context) -> MonitorWidgetLabel {
        MonitorWidgetLabel(metric: metric, frame: NSRect(x: 0, y: 0, width: 42, height: NSStatusBar.system.thickness))
    }
    func updateNSView(_ view: MonitorWidgetLabel, context: Context) {
        view.value = monitorPercent(metric.value(in: monitor.reading)).replacingOccurrences(of: " ", with: "")
    }
}

@MainActor
final class MonitorMenuWidgets: NSObject {
    private var items: [MonitorMetric: NSStatusItem] = [:]
    private var labels: [MonitorMetric: MonitorWidgetLabel] = [:]
    private var visibility: [MonitorMetric: StatusItemVisibility] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private let settings: SettingsStore
    private let openMonitor: () -> Void
    private let openSettings: () -> Void
    private let popover = NSPopover()
    private var detailController: NSHostingController<MonitorDetailView>?
    private var selected: MonitorMetric?
    func revealEnabledItems() { for item in items.values { item.isVisible = true } }

    var diagnostics: [[String: Any]] { items.map { MenuBarController.describe($0.value, name: "metric:" + $0.key.rawValue) } }
    func shutdown() {
        visibility.values.forEach { $0.invalidate() }; visibility.removeAll()
        subscriptions.removeAll(); popover.close(); detailController = nil
        items.values.forEach { NSStatusBar.system.removeStatusItem($0) }; items.removeAll(); labels.removeAll()
    }
    init(settings: SettingsStore, openMonitor: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.settings = settings; self.openMonitor = openMonitor; self.openSettings = openSettings
        super.init()
        popover.behavior = .transient
        popover.animates = false
        settings.$enabledMonitorWidgets.sink { [weak self] metrics in self?.synchronize(metrics) }.store(in: &subscriptions)
        SystemMonitor.shared.$reading.sink { [weak self] reading in self?.update(reading) }.store(in: &subscriptions)
    }
    private func synchronize(_ enabled: Set<MonitorMetric>) {
        for metric in MonitorMetric.allCases {
            if enabled.contains(metric), items[metric] == nil {
                let item = NSStatusBar.system.statusItem(withLength: 42)
                items[metric] = item
                visibility[metric] = StatusItemVisibility(item: item, name: "MacTools.Metric." + metric.rawValue) { [weak self] in
                    guard self?.items[metric] === item else { return }
                    self?.settings.setWidget(metric, enabled: false)
                }
                if let button = item.button {
                    button.target = self; button.action = #selector(widgetClicked(_:))
                    button.image = nil; button.imagePosition = .noImage
                    button.title = ""
                    let label = MonitorWidgetLabel(metric: metric, frame: button.bounds)
                    labels[metric] = label
                    button.addSubview(label)
                    button.setAccessibilityLabel("MacTools " + metric.title)
                }
            } else if !enabled.contains(metric), let item = items.removeValue(forKey: metric) {
                if selected == metric { popover.close(); selected = nil }
                visibility.removeValue(forKey: metric)?.invalidate()
                labels.removeValue(forKey: metric)
                NSStatusBar.system.removeStatusItem(item)
            }
        }
        update(SystemMonitor.shared.reading)
    }
    private func update(_ reading: SystemReading?) {
        for (metric, item) in items {
            guard let button = item.button else { continue }
            let value = monitorPercent(metric.value(in: reading)).replacingOccurrences(of: " ", with: "")
            labels[metric]?.value = value
            button.toolTip = "MacTools · " + metric.title + " " + value + " · " + metric.settingsDetail
            button.setAccessibilityValue(value)
        }
    }
    @objc private func widgetClicked(_ sender: NSStatusBarButton) {
        guard let metric = items.first(where: { $0.value.button === sender })?.key else { return }
        show(metric, from: sender)
    }
    func show(_ metric: MonitorMetric, from sender: NSStatusBarButton) {
        if popover.isShown && selected == metric { popover.close(); selected = nil; return }
        popover.close(); selected = metric
        let detail = MonitorDetailView(metric: metric,
            openMonitor: { [weak self] in self?.popover.close(); self?.openMonitor() },
            openSettings: { [weak self] in self?.popover.close(); self?.openSettings() })
        popover.contentSize = NSSize(width: 360, height: metric == .ram || metric == .cpu ? 700 : 580)
        if let controller = detailController {
            controller.rootView = detail
        } else {
            let controller = NSHostingController(rootView: detail)
            controller.sizingOptions = []
            detailController = controller
            popover.contentViewController = controller
        }
        detailController?.preferredContentSize = popover.contentSize
        detailController?.view.setFrameSize(popover.contentSize)
        popover.showFocused(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
}

struct QuickPanelView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var library: VideoLibraryStore
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var disk = DiskScanStore.shared
    @ObservedObject private var security = SecurityScanStore.shared
    @ObservedObject private var window = WindowPinController.shared
    @ObservedObject private var warnings = AutomaticScans.shared
    @ObservedObject private var audio = NowPlayingStore.shared
    @ObservedObject private var containers = ContainerStore.shared
    @ObservedObject private var codex = CodexStore.shared
    @ObservedObject var privateMCP: PrivateMCPStore = .shared
    @State private var contentHeight: CGFloat = 500
    let openSection: (ToolNavigation.Section) -> Void
    let openSettings: (SettingsCategory) -> Void
    let pin: () -> Void
    let randomWallpaper: () -> Void
    var closePanel: (() -> Void)? = nil
    var startsEditing = false
    @State private var editingWidgets = false
    @State private var draggedWidget: QuickPanelWidget?
    @State private var selectedMetric: MonitorMetric?
    @State private var selectedEvent = 0
    @State private var eventTab = "Alle"
    @State private var selectedEventID: String?
    @State private var showControlError = false
    @State private var featuredHealth = false
    @State private var interactingWithEvents = false
    @State private var menuChats: [CodexChat] = []
    @State private var codexVisibilityTask: Task<Void, Never>?
    @State private var multipleRunningChats = false
    @State private var codexRowsTask: Task<Void, Never>?
    @AppStorage("dismissedQuickScanAt") private var dismissedQuickScanAt = 0.0
    private var points: [MonitorPoint] { Array(monitor.history.suffix(60)) }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.18)) { editingWidgets.toggle() } } label: { Image(systemName: editingWidgets ? "checkmark.circle.fill" : "slider.horizontal.3") }.buttonStyle(.plain).help("Widgets bearbeiten").accessibilityLabel("Widgets bearbeiten")
                Label("Live", systemImage: "circle.fill").font(.caption2).foregroundStyle(.green)
                Button { openSection(.monitoring) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.plain).help("Systemmonitor öffnen")
            }
            if let result = disk.summary, result.completedAt.timeIntervalSince1970 > dismissedQuickScanAt, Date().timeIntervalSince(result.completedAt) < 900 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.mint)
                    Text("Scan abgeschlossen · \(result.fileCount.formatted()) Dateien").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    Button { dismissedQuickScanAt = result.completedAt.timeIntervalSince1970 } label: { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 24, height: 24) }.buttonStyle(.plain).accessibilityLabel("Scan-Mitteilung schließen")
                }.padding(.horizontal, 8).padding(.vertical, 3)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(QuickPanelWidget.rows(visibleWidgets, usagePlacement: effectiveLimitPlacement), id: \.self) { row in
                        if !editingWidgets, row.contains(.codexLimit), row.contains(.codex), effectiveLimitPlacement == "chats" {
                            HStack(spacing: 10) {
                                CodexUsageWidget(featured: true, height: 144) { openSection(.codexLimit) }.frame(width: 164)
                                CodexChatRow(chats: menuChats, visibleCount: cardCounts.codex, compact: true, cardHeight: cardCounts.codex > 1 ? 68 : 144) { id in closePanel?(); CodexPopupController.shared.show(chatID: id) }
                            }.frame(height: 144)
                        } else { HStack(spacing: row.first?.group == 1 ? 6 : 10) { ForEach(row) { widget in editableWidget(widget) } } }
                    }
                    if editingWidgets {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Widgets hierher ziehen · − entfernt sie").font(.caption).foregroundStyle(.secondary)
                            ForEach(QuickPanelWidget.allCases.filter { !settings.quickPanelWidgets.contains($0) }) { widget in
                                HStack {
                                    Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                                    Text(widget.title).font(.caption)
                                    Spacer()
                                    Button { withAnimation { settings.quickPanelWidgets.append(widget) } } label: { Image(systemName: "plus.circle.fill").foregroundStyle(.mint) }.buttonStyle(.plain).accessibilityLabel(widget.title + " hinzufügen")
                                }.padding(9).background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 8))
                                .onDrag { draggedWidget = widget; return NSItemProvider(object: ("mactools-widget:" + widget.rawValue) as NSString) }
                            }
                            Button("Fertig") { withAnimation { editingWidgets = false } }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                        }.padding(.top, 10)
                    }
                }.background(ScrollIndicatorHider()).background(GeometryReader { proxy in Color.clear.onAppear { contentHeight = proxy.size.height }.onChange(of: proxy.size.height) { contentHeight = $0 } })
            }.scrollIndicators(.hidden)
            HStack {
                Button { openSection(.disk) } label: {
                    Label((security.currentFindings?.threatCount ?? 0) > 0 ? "Funde prüfen" : security.criticalMessages(root: disk.root).isEmpty ? "Disk & Sicherheit" : "\(security.criticalMessages(root: disk.root).count) Warnungen", systemImage: "shield")
                }.buttonStyle(.plain).font(.caption)
                Spacer()
                Button { randomWallpaper() } label: { Image(systemName: "shuffle").font(.caption) }.buttonStyle(.plain).disabled(library.videos.isEmpty).help("Video wechseln").accessibilityLabel("Video wechseln")
                Button { openSettings(.general) } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Einstellungen")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.plain).help("MacTools beenden")
            }.foregroundStyle(.secondary)
        }.padding(16).frame(width: 420, height: panelHeight, alignment: .top).background(Color(nsColor: .windowBackgroundColor))
            .task { await security.refreshCurrentFindings(legacyPaths: warnings.warnings.flatMap(\.findingPaths)) }
            .onAppear { if startsEditing { editingWidgets = true }; audio.start(); containers.start(); codex.start(); menuChats = codex.menuChats; multipleRunningChats = codex.menuChats.filter { $0.status == "active" }.count > 1 }
            .onChange(of: codex.menuChats) { chats in
                codexVisibilityTask?.cancel()
                if !chats.isEmpty { menuChats = chats }
                else { codexVisibilityTask = Task { do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }; if codex.menuChats.isEmpty { menuChats = [] } } }
            }.onChange(of: codex.menuChats.filter { $0.status == "active" }.count > 1) { multiple in
                codexRowsTask?.cancel()
                if multiple { multipleRunningChats = true }
                else { codexRowsTask = Task { do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }; if codex.menuChats.filter({ $0.status == "active" }).count <= 1 { multipleRunningChats = false } } }
            }.onDisappear { codexVisibilityTask?.cancel(); codexRowsTask?.cancel() }
            .onChange(of: audio.error) { if $0 != nil { showControlError = true } }
            .onChange(of: containers.error) { if $0 != nil { showControlError = true } }
            .alert("Aktion nicht abgeschlossen", isPresented: $showControlError) {
                Button("OK") { audio.error = nil; containers.error = nil }
            } message: { Text(containers.error ?? audio.error ?? "Bitte erneut versuchen.") }
            .sheet(item: $selectedMetric) { metric in
                VStack(spacing: 0) {
                    MonitorDetailView(metric: metric)
                    Button("Zurück") { selectedMetric = nil }.keyboardShortcut(.cancelAction).padding(.bottom, 14)
                }
            }
    }
    private var effectiveLimitPlacement: String { if settings.codexLimitPlacement == "chats" && !visibleWidgets.contains(.codex) || settings.codexLimitPlacement == "metrics" && !visibleWidgets.contains(where: { $0.group == 1 }) { return "separate" }; return settings.codexLimitPlacement }
    private var availableHeight: CGFloat { min(900, max(520, (NSScreen.main?.visibleFrame.height ?? 680) - 40)) }
    private var panelHeight: CGFloat { startsEditing ? 620 : min(availableHeight, max(340, contentHeight + 94)) }
    private var visibleWidgets: [QuickPanelWidget] { settings.quickPanelWidgets.filter { editingWidgets || ($0 != .codex || !menuChats.isEmpty) && ($0 != .liveFeed || !events.isEmpty) } }
    private var cardCounts: (codex: Int, events: Int) { editingWidgets ? (1, 1) : QuickPanelCardLayout.counts(widgets: visibleWidgets, height: availableHeight - 94, multipleRunningChats: multipleRunningChats, eventCount: events.count, compactVolume: settings.quickPanelCompactVolume, eventTabs: settings.quickPanelEventTabs, usagePlacement: effectiveLimitPlacement, volumeCount: monitor.reading?.volumes.count ?? 1) }
    @ViewBuilder private func editableWidget(_ widget: QuickPanelWidget) -> some View {
        if editingWidgets {
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(widget.title).font(.system(size: 9)).lineLimit(1)
                    if widget == .codexLimit { Menu { Button("Eigene Zeile") { settings.codexLimitPlacement = "separate" }; Button("Neben Codex-Chats") { settings.codexLimitPlacement = "chats" }; Button("Neben Messwerten") { settings.codexLimitPlacement = "metrics" } } label: { Image(systemName: "rectangle.split.2x1") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Codex-Limit-Zeile") }
                    if widget == .volume { Menu { Button("Standard") { settings.quickPanelCompactVolume = false }; Button("Kompakt") { settings.quickPanelCompactVolume = true } } label: { Image(systemName: "rectangle.compress.vertical") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Speicherkachel-Darstellung") }
                    Spacer(minLength: 0)
                    Button { withAnimation(.easeInOut(duration: 0.18)) { settings.quickPanelWidgets.removeAll { $0 == widget } } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel(widget.title + " entfernen")
                }
                quickWidget(widget).allowsHitTesting(false)
            }.padding(5).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.mint.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4])))
            .onDrag { draggedWidget = widget; return NSItemProvider(object: ("mactools-widget:" + widget.rawValue) as NSString) }
            .onDrop(of: [.text], delegate: QuickWidgetDrop(target: widget, settings: settings, dragged: $draggedWidget))
        } else { quickWidget(widget) }
    }
    @ViewBuilder private func quickWidget(_ widget: QuickPanelWidget) -> some View {
        switch widget {
        case .liveFeed: liveEvents
        case .codex: CodexChatRow(chats: menuChats, visibleCount: cardCounts.codex, compact: effectiveLimitPlacement == "chats" && visibleWidgets.contains(.codexLimit)) { id in closePanel?(); CodexPopupController.shared.show(chatID: id) }
        case .codexLimit: CodexUsageWidget(compact: effectiveLimitPlacement != "separate", height: effectiveLimitPlacement == "separate" ? 64 : effectiveLimitPlacement == "metrics" ? 86 : 64) { openSection(.codexLimit) }
        case .cpu: metricButton(.cpu, title: "CPU", value: monitorPercent(monitor.reading?.point.cpu), color: .cyan, key: \.cpu, detail: "Gesamte CPU-Auslastung")
        case .ram: metricButton(.ram, title: "RAM", value: monitorPercent(monitor.reading?.point.memory), color: .purple, key: \.memory, detail: "Arbeitsspeicher")
        case .gpu: metricButton(.gpu, title: "GPU", value: monitorPercent(monitor.reading?.point.gpu), color: .mint, key: \.gpu, detail: monitor.reading?.gpuName ?? "GPU-Auslastung")
        case .disk: metricButton(.disk, title: "Disk", value: monitorRate(monitor.reading?.point.diskRead), color: .orange, key: \.diskRead, detail: "Schreiben " + monitorRate(monitor.reading?.point.diskWrite), percent: false)
        case .volume:
            MonitorVolumesWidget(volumes: monitor.reading?.volumes ?? [], inline: settings.quickPanelCompactVolume) { volume in
                DiskVolumeStore.shared.selectVolume(path: volume.path); closePanel?(); openSection(.disk)
            }.contextMenu {
                Button("Standarddarstellung") { settings.quickPanelCompactVolume = false }
                Button("Kompakte Darstellung") { settings.quickPanelCompactVolume = true }
            }
        case .pin: quickButton("Fenster anheften / lösen", icon: window.isPinned ? "pin.slash" : "pin.fill", color: .blue, action: pin)
        case .scan: quickButton(disk.isScanning ? "Scan öffnen" : "Speicher scannen", icon: "magnifyingglass", color: .cyan) {
            if !disk.isScanning && !security.isScanning && !security.isUpdating { warnings.runNow() }; openSection(.disk)
        }
        case .monitor: quickButton("Systemmonitor", icon: "waveform.path.ecg", color: .mint) { openSection(.monitoring) }
        case .wallpaper: quickButton(settings.isPaused ? "Hintergrund starten" : "Hintergrund pausieren", icon: settings.isPaused ? "play.fill" : "pause.fill", color: .purple) { settings.setPaused(!settings.isPaused) }.disabled(library.videos.isEmpty)
        }
    }
    private struct LiveEvent: Identifiable {
        let id: String
        let priority: Int
        let title: String
        let detail: String
        let icon: String
        let color: Color
        let section: ToolNavigation.Section
        var pinID: UUID? = nil
        var fraction: Double? = nil
        var applicationURL: URL? = nil
        var track: PlayingAudio? = nil
        var container: RunningContainer? = nil
        var healthMetrics: [PrivateMCPMetric] = []
    }
    private var events: [LiveEvent] {
        var values: [LiveEvent] = []
        if let current = security.currentFindings, current.threatCount > 0 {
            values.append(LiveEvent(id: "threats", priority: 100, title: "\(current.threatCount) verdächtige Dateien", detail: "Funde in Disk & Sicherheit prüfen", icon: "shield.lefthalf.filled", color: .red, section: .disk))
        }
        if disk.isScanning || disk.isSaving || security.isScanning || security.isUpdating {
            values.append(LiveEvent(id: "scan", priority: 90, title: disk.isScanning ? "Scan läuft · \(disk.progress.files.formatted()) Dateien" : "Virenschutz läuft", detail: disk.isScanning ? disk.progress.phase : security.status, icon: "waveform.path", color: .cyan, section: .disk, fraction: disk.isScanning ? disk.progress.fraction : security.progressFraction))
        }
        for item in window.pinnedWindows {
            values.append(LiveEvent(id: item.id.uuidString, priority: 80, title: item.application + " · angeheftet", detail: item.title, icon: "pin.fill", color: .blue, section: .windows, pinID: item.id))
        }
        if let volume = monitor.reading?.volumes.first, volume.free < 2_000_000_000 {
            values.append(LiveEvent(id: "disk", priority: 70, title: "Kritisch wenig Speicher", detail: diskBytes(volume.free) + " frei", icon: "externaldrive.badge.exclamationmark", color: .orange, section: .disk))
        }
        for item in audio.playing {
            values.append(LiveEvent(id: "audio-" + item.id, priority: 60, title: item.headline, detail: item.detail, icon: "music.note", color: .green, section: .monitoring, applicationURL: item.applicationURL, track: item))
        }
        for service in privateMCP.services where service.enabled {
            values.append(LiveEvent(id: "private-" + service.id, priority: service.critical ? 95 : 65, title: service.kind.title + " · " + service.stateLabel,
                detail: service.health?.stats.joined(separator: " · ") ?? "MCP-Verbindung konfigurieren und anmelden", icon: service.kind.icon,
                color: service.critical ? .red : service.stale ? .orange : .mint, section: service.kind.section, healthMetrics: service.health?.metrics ?? []))
        }
        for item in containers.containers {
            values.append(LiveEvent(id: "container-" + item.id, priority: 40, title: item.name, detail: containers.refreshError == nil ? item.detail : "Letzter bestätigter Stand · " + item.detail, icon: "shippingbox", color: .blue, section: .containers, container: item))
        }
        return values.sorted { $0.priority == $1.priority ? $0.id < $1.id : $0.priority > $1.priority }
    }
    private var liveEvents: some View {
        let matching = events.filter { event in
            guard settings.quickPanelEventTabs else { return true }
            switch eventTab { case "Musik": return event.track != nil; case "Container": return event.container != nil; case "System": return event.track == nil && event.container == nil; default: return true }
        }
        let empty = LiveEvent(id: "empty-" + eventTab, priority: 0, title: eventTab == "Musik" ? "Keine Musikwiedergabe" : eventTab == "Container" ? "Keine laufenden Container" : "Keine aktuellen Ereignisse", detail: "Die Ansicht aktualisiert sich automatisch", icon: eventTab == "Musik" ? "music.note" : eventTab == "Container" ? "shippingbox" : "checkmark.circle", color: .secondary, section: eventTab == "Container" ? .containers : .monitoring)
        let values = matching.isEmpty ? [empty] : matching
        let expandedHealth = featuredHealth && cardCounts.events >= 3 && values.contains { !$0.healthMetrics.isEmpty }
        let capacity = min(cardCounts.events - (expandedHealth ? 1 : 0), values.count)
        let eventPages = QuickPanelCardLayout.eventPages(ids: values.map(\.id), containerIDs: Set(values.filter { $0.container != nil }.map(\.id)), rows: capacity)
        let pages = eventPages.count
        let page = selectedEventID.flatMap { id in eventPages.firstIndex { $0.contains(id) } } ?? min(selectedEvent, pages - 1)
        let shown = eventPages[page].compactMap { id in values.first { $0.id == id } }
        let rows = shown.count
        let reservedRows = min(cardCounts.events, values.count)
        let reservedHeight = CGFloat(reservedRows * 64 + max(0, reservedRows - 1) * 10 + (pages > 1 ? 32 : 0) + (settings.quickPanelEventTabs ? 36 : 0))
        let featuredID = expandedHealth ? shown.first(where: { !$0.healthMetrics.isEmpty })?.id : nil
        return VStack(spacing: 8) {
            if settings.quickPanelEventTabs {
                HStack(spacing: 4) {
                    ForEach(["Alle", "Musik", "Container", "System"], id: \.self) { tab in
                        Button { eventTab = tab; selectedEvent = 0; selectedEventID = nil } label: {
                            HStack(spacing: 5) { Image(systemName: tab == "Alle" ? "square.grid.2x2" : tab == "Musik" ? "music.note" : tab == "Container" ? "shippingbox" : "waveform.path.ecg").font(.system(size: 10)); Text(tab).font(.system(size: 10, weight: .medium)) }
                                .foregroundStyle(eventTab == tab ? Color.primary : .secondary).frame(maxWidth: .infinity).frame(height: 28)
                                .background(eventTab == tab ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityLabel("Livefilter " + tab).accessibilityAddTraits(eventTab == tab ? .isSelected : [])
                    }
                }.padding(4).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { offset, event in
            HStack(spacing: 10) {
                if let url = event.applicationURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
                } else { Image(systemName: event.icon).foregroundStyle(event.color).font(.title3) }
                Button {
                    if let url = event.applicationURL { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
                    else { openSection(event.section) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(event.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(event.detail)
                        if event.id == featuredID {
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(event.healthMetrics.filter { !["Liveness", "Traffic", "Runtime"].contains($0.title) }.prefix(3)) { metric in VStack(alignment: .leading, spacing: 4) { Text(metric.value).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(metric.healthy == false ? Color.red : .primary); Text(metric.title).font(.system(size: 9)).foregroundStyle(.secondary) } }
                            }.padding(.top, 10)
                        }
                        if let fraction = event.fraction { ProgressView(value: fraction).tint(event.color) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                VStack(spacing: 2) {
                    if let track = event.track, track.canControl {
                        HStack(spacing: 10) {
                            playbackButton("backward.end.fill", label: "Vorheriger Titel", command: .previous, track: track)
                            playbackButton(track.isPlaying ? "pause.fill" : "play.fill", label: track.isPlaying ? "Pausieren" : "Wiedergabe", command: .playPause, track: track)
                            playbackButton("forward.end.fill", label: "Nächster Titel", command: .next, track: track)
                        }.disabled(audio.commandRunning)
                    } else if let container = event.container {
                        Button { Task { await containers.stop(container) } } label: {
                            Image(systemName: containers.stopping.contains(container.id) ? "hourglass" : "stop.fill").frame(width: 24, height: 24)
                        }.buttonStyle(.plain).disabled(containers.stopping.contains(container.id)).help(container.name + " stoppen").accessibilityLabel(container.name + " stoppen")
                    } else if let id = event.pinID {
                        Button("Lösen") { window.unpin(id: id) }.controlSize(.small).accessibilityLabel(event.title + " lösen")
                    } else { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                }.fixedSize(horizontal: true, vertical: false)
            }.padding(.horizontal, 12).padding(.vertical, 4).frame(height: event.id == featuredID ? 136 : 64).frame(maxWidth: .infinity)
                .background(event.color.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if pages > 1 {
                HStack {
                    Text("Live-Ereignisse").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    CompactCardPager(index: page, count: pages, item: "Live-Ereignisse · Seite", previous: { selectedEvent = max(0, page - 1); selectedEventID = eventPages[selectedEvent].first }, next: { selectedEvent = min(pages - 1, page + 1); selectedEventID = eventPages[selectedEvent].first })
                }.padding(.horizontal, 6).frame(height: 22)
            }
        }.frame(height: reservedHeight, alignment: .top).onHover { interactingWithEvents = $0 }
        .task { while !Task.isCancelled { do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }; if !interactingWithEvents && !editingWidgets { featuredHealth.toggle() } } }
        .contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 24).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            selectedEvent = min(pages - 1, max(0, page + (value.translation.width < 0 ? 1 : -1))); selectedEventID = eventPages[selectedEvent].first
        }).onAppear { selectedEventID = eventPages[page].first }
        .onChange(of: values.map(\.id)) { ids in
            selectedEvent = selectedEventID.flatMap { id in eventPages.firstIndex { $0.contains(id) } } ?? min(selectedEvent, pages - 1)
            selectedEventID = eventPages[selectedEvent].first
        }
    }

    private func playbackButton(_ icon: String, label: String, command: NowPlayingStore.Command, track: PlayingAudio) -> some View {
        Button { Task { await audio.control(command, track: track) } } label: {
            Image(systemName: icon).font(.system(size: 12)).frame(width: 20, height: 26)
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    private func metricButton(_ metric: MonitorMetric, title: String, value: String, color: Color, key: KeyPath<MonitorPoint, Double?>, detail: String, percent: Bool = true) -> some View {
        Button { selectedMetric = metric } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(color)
                ViewThatFits(in: .horizontal) {
                    Text(value.replacingOccurrences(of: " %", with: "%")).font(.system(size: 16, weight: .semibold, design: .rounded)).fixedSize()
                    VStack(alignment: .leading, spacing: 0) {
                        Text(value.components(separatedBy: " ").first ?? value).font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text(value.components(separatedBy: " ").dropFirst().joined(separator: " ")).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }.monospacedDigit().frame(height: 32, alignment: .top)
                MonitorTrend(points: points, key: key, color: color, percent: percent, compact: true).frame(height: 20)
            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.18), lineWidth: 1))
        }.buttonStyle(.plain).frame(minWidth: 0, maxWidth: .infinity).help(detail).accessibilityLabel(title + " " + value + ". " + detail)
    }

    private func quickButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(color)
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(12).frame(maxWidth: .infinity).background(color.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }
}

@MainActor private final class PinnedToolAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}

private final class ToolStatusDropView: NSView {
    var onTool: ((ToolNavigation.Section) -> Void)?
    var onClick: (() -> Void)?
    var onFolder: ((String) -> Void)?
    var onChat: ((String) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.string]) }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true { return nil }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { nextResponder?.mouseDown(with: event) } else { onClick?() }
    }
    private func tool(_ sender: NSDraggingInfo) -> ToolNavigation.Section? {
        guard let text = sender.draggingPasteboard.string(forType: .string), text.hasPrefix(ToolDrop.prefix), let tool = ToolNavigation.Section(rawValue: String(text.dropFirst(ToolDrop.prefix.count))), ToolNavigation.Section.pinnable.contains(tool) else { return nil }
        return tool
    }
    private func folder(_ sender: NSDraggingInfo) -> String? { guard let text = sender.draggingPasteboard.string(forType: .string), text.hasPrefix(ToolDrop.folderPrefix) else { return nil }; let path = String(text.dropFirst(ToolDrop.folderPrefix.count)); return path.hasPrefix("/") ? path : nil }
    private func chat(_ sender: NSDraggingInfo) -> String? { guard let text = sender.draggingPasteboard.string(forType: .string), text.hasPrefix(ToolDrop.chatPrefix) else { return nil }; let id = String(text.dropFirst(ToolDrop.chatPrefix.count)); return UUID(uuidString: id) != nil ? id : nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { tool(sender) == nil && folder(sender) == nil && chat(sender) == nil ? [] : .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { tool(sender) != nil || folder(sender) != nil || chat(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { if let tool = tool(sender) { onTool?(tool); return true }; if let path = folder(sender) { onFolder?(path); return true }; if let id = chat(sender) { onChat?(id); return true }; return false }
}

@MainActor private final class CodexFolderMenu: NSObject, NSMenuDelegate {
    let path: String
    let open: (ToolNavigation.Section) -> Void
    let remove: () -> Void
    init(path: String, open: @escaping (ToolNavigation.Section) -> Void, remove: @escaping () -> Void) { self.path = path; self.open = open; self.remove = remove }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let store = CodexStore.shared
        let running = store.liveChats.filter { store.folder(for: $0) == path && $0.status == "active" }.sorted { $0.updatedAt > $1.updatedAt }
        if running.isEmpty { let item = menu.addItem(withTitle: "Keine laufenden Chats", action: nil, keyEquivalent: ""); item.isEnabled = false }
        for chat in running {
            let item = menu.addItem(withTitle: chat.title, action: #selector(openChat(_:)), keyEquivalent: ""); item.target = self; item.representedObject = chat.id
        }
        menu.addItem(.separator()); let item = menu.addItem(withTitle: "Aus Menüleiste entfernen", action: #selector(unpin), keyEquivalent: ""); item.target = self
    }
    @objc private func openChat(_ item: NSMenuItem) { guard let id = item.representedObject as? String else { return }; Task { await CodexStore.shared.select(id); open(.codex) } }
    @objc private func unpin() { remove() }
}

/// User Cmd-drag removal is observable. Persist it before a metric/settings refresh
/// has a chance to recreate the item; ordinary teardown invalidates this observer.
@MainActor final class StatusItemVisibility {
    private var observation: NSKeyValueObservation?
    private var removalReported = false
    init(item: NSStatusItem, name: String, userRemoval: @escaping @MainActor () -> Bool = { MenuBarRemovalGesture.shared.recent }, removed: @escaping () -> Void) {
        _ = MenuBarRemovalGesture.shared
        item.autosaveName = name
        item.behavior.insert(.removalAllowed)
        item.isVisible = true
        observation = item.observe(\.isVisible, options: [.old, .new]) { [weak self, weak item] _, change in
            guard change.oldValue != change.newValue else { return }
            Task { @MainActor in
                guard let self, let item else { return }
                if item.isVisible { self.removalReported = false; return }
                guard userRemoval(), !self.removalReported else { return }
                self.removalReported = true; removed()
            }
        }
    }
    func invalidate() { observation?.invalidate(); observation = nil }
}

@MainActor private final class MenuBarRemovalGesture {
    static let shared = MenuBarRemovalGesture()
    private var lastCommandDrag = Date.distantPast
    private var global: Any?
    private var local: Any?
    var recent: Bool { Date().timeIntervalSince(lastCommandDrag) < 1.5 }
    private init() {
        global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            if event.modifierFlags.contains(.command) { self?.lastCommandDrag = Date() }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            if event.modifierFlags.contains(.command) { self?.lastCommandDrag = Date() }; return event
        }
    }
}
