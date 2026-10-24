import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings: SettingsStore
    private let library: VideoLibraryStore
    private lazy var wallpaperController = WallpaperController(settings: settings, library: library)
    private var menuBarController: MenuBarController?
    private let toolBridge = MacToolsBridgeServer()
    private var monitorWidgets: MonitorMenuWidgets?
    private var cancellables = Set<AnyCancellable>()
    private var mainWindow: NSWindow?
    private let navigation = ToolNavigation()
    private var pausedForSystemSleep = false

    override init() {
        settings = .shared; library = .shared
        super.init()
    }

    init(settings: SettingsStore, library: VideoLibraryStore) {
        self.settings = settings; self.library = library
        super.init()
    }

    var wallpaperPlaybackSnapshot: [(seconds: TimeInterval, rate: Float)] { wallpaperController.playbackSnapshot }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if shouldTerminateLoginAgentDuplicate() {
            NSApp.terminate(nil)
            return
        }

        terminateDuplicateInstances()
        do { try LaunchAgentLoginItem.refreshInstalledAppPath() }
        catch { settings.loginItemError = error.localizedDescription }
        NSApp.setActivationPolicy(.accessory)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) { NSApp.applicationIconImage = image }

        configureMenuBar()
        PrivateMCPStore.shared.start()
        WindowPinController.shared.start(onFailure: { [weak self] in self?.presentMainWindow(section: .windows) })
        if !UserDefaults.standard.bool(forKey: "codexLimitWidgetAdded26") {
            if !settings.quickPanelWidgets.contains(.codexLimit) { let index = settings.quickPanelWidgets.firstIndex(of: .codex).map { $0 + 1 } ?? 0; settings.quickPanelWidgets.insert(.codexLimit, at: index) }
            UserDefaults.standard.set(true, forKey: "codexLimitWidgetAdded26")
        }
        CodexPopupController.shared.start()
        do { try toolBridge.start(open: { [weak self] section in self?.presentMainWindow(section: section) }, menuStatus: { [weak self] in self?.menuStatus ?? [:] }, restoreMenu: { [weak self] in self?.configureMenuBar() }) } catch { NSLog("MacTools MCP: %@", error.localizedDescription) }
        bindState()
        registerNotifications()
        wallpaperController.start()
        synchronizeScreenSaver()
        AutomaticScans.shared.start()
        SystemMonitor.shared.start()
        NowPlayingStore.shared.start()
        ContainerStore.shared.start()
        AppManagerStore.shared.refresh()

        if !CommandLine.arguments.contains(LaunchAgentLoginItem.launchArgument) {
            presentMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentMainWindow(section: navigation.section)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private var menuStatus: [String: Any] {
        ["mainScreen": NSScreen.main.map { NSStringFromRect($0.frame) } ?? "", "screens": NSScreen.screens.map { ["name": $0.localizedName, "frame": NSStringFromRect($0.frame)] }, "mainEnabled": settings.showMainMenuIcon, "metricsEnabled": settings.enabledMonitorWidgets.map(\.rawValue).sorted(), "toolsEnabled": settings.pinnedTools.map(\.rawValue).sorted(), "items": (menuBarController?.diagnostics ?? []) + (monitorWidgets?.diagnostics ?? [])]
    }
    private func configureMenuBar() {
        menuBarController?.shutdown(); monitorWidgets?.shutdown()
        menuBarController = nil; monitorWidgets = nil
        menuBarController = MenuBarController(
            settings: settings,
            library: library,
            openSection: { [weak self] section in self?.presentMainWindow(section: section) },
            openSettings: { [weak self] category in self?.presentSettings(category) },
            randomWallpaper: { [weak self] in self?.selectRandomWallpaper() }
        )

        monitorWidgets = MonitorMenuWidgets(settings: settings,
            openMonitor: { [weak self] in self?.presentMainWindow(section: .monitoring) },
            openSettings: { [weak self] in self?.presentSettings(.monitoring) })
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            if let directory = try? LocalToolBridge.directory("app") { try? LocalToolBridge.write(self.menuStatus, to: directory.appendingPathComponent("menu-state.json")) }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        menuBarController?.revealEnabledItems()
        monitorWidgets?.revealEnabledItems()
        settings.refreshStartAtLoginStatus()
        WindowPinController.shared.refreshAccessibilityPermission()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !CodexQueueRepository.shared.hasLocalWork {
            guard InfraTerminalStore.shared.sessions.contains(where: { $0.running }) else { return .terminateNow }
            let alert = NSAlert(); alert.messageText = "SSH-Sitzungen sind noch geöffnet"
            alert.informativeText = "Beim Beenden werden die Terminal-Verbindungen und ihre laufenden Programme geschlossen."
            alert.addButton(withTitle: "Weiterlaufen lassen"); alert.addButton(withTitle: "Sitzungen schließen und beenden")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "MacTools führt noch Codex-Chats aus"
        alert.informativeText = "Ein Beenden würde diese Arbeit unterbrechen. Lass MacTools bis zum Abschluss geöffnet oder beende den betroffenen Chat gezielt. Chats, die im Original-Codex laufen, sind davon nicht betroffen."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Weiterlaufen lassen")
        alert.addButton(withTitle: "Trotzdem beenden")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        PrivateMCPStore.shared.stop()
        InfraTerminalStore.shared.stop()
        menuBarController?.shutdown(); monitorWidgets?.shutdown()
        NowPlayingStore.shared.stop()
        ContainerStore.shared.stop()
        CodexPopupController.shared.stop()
        CodexStore.shared.stop()
        SystemMonitor.shared.stop()
        DiskScanStore.shared.cancel()
        DiskVolumeStore.shared.stop()
        SecurityScanStore.shared.cancel()
        WindowPinController.shared.stop()
        wallpaperController.closeAllWindows()
    }

    private func terminateDuplicateInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let duplicates = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentPID }

        duplicates.forEach { app in
            if !app.terminate() {
                app.forceTerminate()
            }
        }
    }

    private func shouldTerminateLoginAgentDuplicate() -> Bool {
        guard CommandLine.arguments.contains(LaunchAgentLoginItem.launchArgument),
              let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != currentPID }
    }

    // @Published emits before its property is stored. Deliver on the next run-loop
    // turn so player and screensaver read the updated pause/video/aspect values.
    func bindState() {
        settings.$currentVideoID
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.wallpaperController.applyCurrentVideo()
                self?.synchronizeScreenSaver()
            }
            .store(in: &cancellables)

        settings.$aspectMode
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.wallpaperController.updateAspectMode()
                self?.synchronizeScreenSaver()
            }
            .store(in: &cancellables)

        settings.$isPaused
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] isPaused in
                if isPaused {
                    self?.wallpaperController.pausePlayback()
                } else {
                    self?.wallpaperController.resumePlayback()
                }
            }
            .store(in: &cancellables)

        library.$videos
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] videos in
                guard let self else { return }
                if let currentVideoID = self.settings.currentVideoID,
                   !videos.contains(where: { $0.id == currentVideoID }) {
                    self.settings.setCurrentVideo(videos.first?.id)
                }
            }
            .store(in: &cancellables)
    }

    private func registerNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private func synchronizeScreenSaver() {
        ScreenSaverSupport.synchronize(video: library.video(with: settings.currentVideoID), aspect: settings.aspectMode)
    }

    func presentMainWindow(section: ToolNavigation.Section = .tools) {
        navigation.section = section
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = MacToolsView(navigation: navigation)
        let hostingView = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacTools"
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 1240, height: 760)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        // A retained NSWindow keeps its hosting view alive. Remove tool pages so
        // their onDisappear handlers release inventories and detail subscriptions.
        navigation.section = .tools
    }

    func presentSettings(_ category: SettingsCategory = .general) {
        navigation.openSettings(category)
        presentMainWindow(section: .settings)
    }

    private func selectRandomWallpaper() {
        guard let random = library.randomVideo(excluding: settings.currentVideoID) else { return }
        settings.setCurrentVideo(random.id)
        settings.setPaused(false)
    }

    @objc private func screenConfigurationChanged() {
        wallpaperController.handleScreenConfigurationChanged()
    }

    @objc private func workspaceWillSleep() {
        pausedForSystemSleep = !settings.isPaused
        wallpaperController.pausePlayback()
    }

    @objc private func workspaceDidWake() {
        guard pausedForSystemSleep else { return }
        pausedForSystemSleep = false
        wallpaperController.resumePlayback()
    }
}

/// Independent native chat windows with a configurable global shortcut.
@MainActor final class CodexPopupController: ObservableObject {
    static let shared = CodexPopupController()
    @Published private(set) var shortcutTitle = UserDefaults.standard.string(forKey: "codexPopupShortcutTitle") ?? "⌥⌘C"
    @Published private(set) var shortcutError: String?
    private var windows: [UUID: CodexChatWindowController] = [:]
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var stopping = false

    func start() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x4D544348, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<CodexPopupController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in controller.show() }; return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        registerShortcut()
        for value in UserDefaults.standard.stringArray(forKey: "codexOpenChatWindows") ?? [] {
            if let id = UUID(uuidString: value) { makeWindow(id: id, chatID: nil, restoring: true) }
        }
    }
    @discardableResult func show(chatID: String? = nil) -> UUID {
        if let chatID, let existing = windows.values.first(where: { !$0.isOpen && $0.store.selectedID == chatID }) {
            existing.present(); saveOpenWindows(); return existing.id
        }
        return makeWindow(id: UUID(), chatID: chatID, restoring: false)
    }
    @discardableResult private func makeWindow(id: UUID, chatID: String?, restoring: Bool) -> UUID {
        let controller = CodexChatWindowController(id: id, chatID: chatID, restoring: restoring)
        controller.onClose = { [weak self] in self?.saveOpenWindows() }
        windows[id] = controller; controller.present(); saveOpenWindows(); return id
    }
    private func saveOpenWindows() {
        guard !stopping else { return }
        UserDefaults.standard.set(windows.values.filter(\.isOpen).map { $0.id.uuidString }.sorted(), forKey: "codexOpenChatWindows")
    }
    var diagnostics: [[String: Any]] { windows.values.filter(\.isOpen).sorted { $0.id.uuidString < $1.id.uuidString }.map(\.diagnostics) }
    func pin(_ id: UUID, enabled: Bool) -> Bool { guard let window = windows[id], window.isOpen else { return false }; window.alwaysOnTop = enabled; return true }
    func close(_ id: UUID) -> Bool { guard let window = windows[id], window.isOpen else { return false }; window.window?.performClose(nil); return true }
    func stop() {
        saveOpenWindows(); stopping = true
        windows.values.forEach { $0.stop() }
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }

    func beginRecording() { if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil }
    func cancelRecording() { registerShortcut() }
    func setShortcut(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else {
            shortcutError = "Verwende mindestens ⌘, ⌥ oder ⌃."; registerShortcut(); return
        }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        var candidate: EventHotKeyRef?
        let result = RegisterEventHotKey(UInt32(event.keyCode), modifiers, EventHotKeyID(signature: 0x4D544348, id: 1), GetApplicationEventTarget(), 0, &candidate)
        guard result == noErr else { shortcutError = "Diese Kombination ist bereits belegt oder nicht verfügbar (\(result))."; registerShortcut(); return }
        hotKey = candidate
        let special = [49: "Leertaste", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let title = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + (special[Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Taste \(event.keyCode)")
        let defaults = UserDefaults.standard
        defaults.set(Int(event.keyCode), forKey: "codexPopupShortcutKeyCode"); defaults.set(Int(modifiers), forKey: "codexPopupShortcutModifiers"); defaults.set(title, forKey: "codexPopupShortcutTitle")
        shortcutTitle = title; shortcutError = nil
    }
    private func registerShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        let defaults = UserDefaults.standard
        let key = UInt32(max(0, defaults.object(forKey: "codexPopupShortcutKeyCode") as? Int ?? 8))
        let modifiers = UInt32(max(0, defaults.object(forKey: "codexPopupShortcutModifiers") as? Int ?? (cmdKey | optionKey)))
        let result = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x4D544348, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { shortcutError = "Das Tastenkürzel ist nicht verfügbar (\(result)). Wähle eine andere Kombination." }
    }
}

/// One view model, draft namespace and native window level per chat window.
@MainActor final class CodexChatWindowController: NSWindowController, NSWindowDelegate, ObservableObject {
    let id: UUID
    let store: CodexStore
    @Published var alwaysOnTop: Bool
    private(set) var isOpen = false
    var onClose: (() -> Void)?
    private let sessionDefaults: UserDefaults
    private var subscriptions = Set<AnyCancellable>()
    private var opening: Task<Void, Never>?
    private var stopped = true

    init(id: UUID, chatID: String?, restoring: Bool = false, defaults: UserDefaults? = nil) {
        self.id = id
        let preferences = defaults ?? UserDefaults(suiteName: "com.julianfink.MacTools.ChatWindow." + id.uuidString)!
        sessionDefaults = preferences
        store = CodexStore(defaults: preferences, followAllChats: false, queue: defaults == nil ? .shared : nil)
        alwaysOnTop = preferences.object(forKey: "alwaysOnTop") as? Bool ?? SettingsStore.shared.chatPopupAlwaysOnTop
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Neuer Codex-Chat"; window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentMinSize = NSSize(width: 620, height: 500)
        window.setFrameAutosaveName("MacTools.CodexChat." + id.uuidString)
        window.center(); window.delegate = self
        window.contentView = NSHostingView(rootView: CodexChatWindowRoot(controller: self))
        if let selected = chatID ?? (restoring ? preferences.string(forKey: "selectedChatID") : nil) { store.prepareSelection(selected) }
        store.workingDirectory = preferences.string(forKey: "workingDirectory") ?? NSHomeDirectory()
        $alwaysOnTop.removeDuplicates().sink { [weak self] enabled in
            self?.window?.level = enabled ? .floating : .normal
            self?.sessionDefaults.set(enabled, forKey: "alwaysOnTop")
        }.store(in: &subscriptions)
        store.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            guard let self else { return }
            self.window?.title = self.store.selected?.title ?? "Neuer Codex-Chat"
            self.sessionDefaults.set(self.store.selectedID, forKey: "selectedChatID")
            self.sessionDefaults.set(self.store.workingDirectory, forKey: "workingDirectory")
            self.stopIfHiddenAndIdle()
        }.store(in: &subscriptions)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() {
        opening?.cancel(); isOpen = true; stopped = false
        store.presentationRevision += 1
        NSApp.activate(ignoringOtherApps:true); window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, window.isVisible, window.isKeyWindow, window.attachedSheet == nil else { return }
            func findEditor(_ view: NSView) -> CodexComposer.Editor? {
                if let editor = view as? CodexComposer.Editor { return editor }
                for child in view.subviews { if let editor = findEditor(child) { return editor } }
                return nil
            }
            if let root = window.contentView, let editor = findEditor(root) { window.makeFirstResponder(editor) }
        }
        store.start()
        opening = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(25)
            while !self.store.connected && Date() < deadline {
                if !self.store.connecting { await self.store.connect() }
                else { do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return } }
                if Task.isCancelled { return }
            }
            if let id = self.store.selectedID, !Task.isCancelled { await self.store.finishSelection(id); await self.store.loadGoal() }
        }
    }
    func windowWillClose(_ notification: Notification) { isOpen = false; opening?.cancel(); stopIfHiddenAndIdle(); onClose?() }
    private func stopIfHiddenAndIdle() {
        guard !isOpen, !stopped, !store.hasPendingWork, store.selected?.status != "active" else { return }
        stopped = true; store.stop()
    }
    func stop() { opening?.cancel(); stopped = true; store.stop() }
    var diagnostics: [String: Any] {
        ["id": id.uuidString, "chatId": store.selectedID as Any? ?? NSNull(), "title": store.selected?.title ?? "Neuer Chat", "alwaysOnTop": alwaysOnTop, "nativeLevel": window?.level.rawValue ?? 0, "visible": window?.isVisible ?? false, "desktopConnected":store.desktopConnected,"desktopOwner":store.selectedIsDesktopOwned,"keyWindow":window?.isKeyWindow ?? false,"appActive":NSApp.isActive,"firstResponder":window?.firstResponder.map { String(describing:type(of:$0)) } ?? "none", "draftCharacters": store.drafts[store.selectedID ?? "new"]?.count ?? 0, "workingDirectory": store.workingDirectory]
    }
}
private struct CodexChatWindowRoot: View {
    @ObservedObject var controller: CodexChatWindowController
    var body: some View { CodexChatsView(store: controller.store, popupMode: true, popupPin: $controller.alwaysOnTop) }
}

struct CodexPopupShortcutRecorder: NSViewRepresentable {
    @ObservedObject private var controller = CodexPopupController.shared
    func makeNSView(context: Context) -> CodexPopupShortcutButton {
        let button = CodexPopupShortcutButton(); button.bezelStyle = .rounded
        button.target = button; button.action = #selector(CodexPopupShortcutButton.record)
        return button
    }
    func updateNSView(_ view: CodexPopupShortcutButton, context: Context) { if !view.recording { view.title = controller.shortcutTitle + " · ändern" } }
}
final class CodexPopupShortcutButton: NSButton {
    var recording = false
    override var acceptsFirstResponder: Bool { true }
    @objc func record() { CodexPopupController.shared.beginRecording(); recording = true; title = "Tastenkürzel drücken … (Esc bricht ab)"; window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { CodexPopupController.shared.cancelRecording() } else { CodexPopupController.shared.setShortcut(event) }
        recording = false; title = CodexPopupController.shared.shortcutTitle + " · ändern"
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { guard recording else { return super.performKeyEquivalent(with: event) }; keyDown(with: event); return true }
    override func resignFirstResponder() -> Bool {
        if recording { recording = false; CodexPopupController.shared.cancelRecording(); title = CodexPopupController.shared.shortcutTitle + " · ändern" }
        return super.resignFirstResponder()
    }
}
