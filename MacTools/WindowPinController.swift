import AppKit
import ApplicationServices
import Carbon
import Combine
import SwiftUI
import ScreenCaptureKit

struct AvailablePinWindow: Identifiable {
    let id: CGWindowID
    let title: String
    let application: String
}

struct PinnedWindowSummary: Identifiable {
    let id: UUID
    let title: String
    let application: String
    let isLive: Bool
}

@MainActor
final class WindowPinController: ObservableObject {
    static let shared = WindowPinController()
    @Published private(set) var isPinned = false
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenCapturePermission = false
    @Published private(set) var isStarting = false
    @Published private(set) var pinnedWindows: [PinnedWindowSummary] = []
    @Published private(set) var manualAccessibilityCheckAt: Date?
    @Published private(set) var windowTitle = ""
    @Published private(set) var status = "Kein Fenster angeheftet."
    @Published private(set) var nativeLevelStatus = ""
    @Published private(set) var shortcutTitle = UserDefaults.standard.string(forKey: "pinShortcutTitle") ?? "⌥⌘P"
    private enum Selection {
        case own(NSWindow)
        case external(pid_t, AXUIElement?, CGWindowID? = nil)
        case pinned(UUID)
    }
    private enum Target {
        case own(NSWindow, NSWindow.Level)
        case original(pid_t, AXUIElement, CGWindowID, Int32)
        case live(pid_t, AXUIElement, LivePinnedWindow)
    }
    @Published private(set) var availableWindows: [AvailablePinWindow] = []
    @Published private(set) var isLoadingWindows = false
    private var selectableWindows: [SCWindow] = []
    private var targets: [UUID: Target] = [:]
    private var pending: Task<Void, Never>?
    private var startGeneration = UUID()
    private var menuSelection: Selection?
    private var lastExternalPID: pid_t?
    private var lastExternalWindow: AXUIElement?
    private var onFailure: (() -> Void)?
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var lastShortcutUptime: TimeInterval = -1

    func start(onFailure: @escaping () -> Void) {
        guard handler == nil else { return }
        self.onFailure = onFailure
        refreshAccessibilityPermission()
        captureFrontmostApplication()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in
            self?.captureFrontmostApplication()
            self?.refreshAccessibilityPermission()
        } }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<WindowPinController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in controller.performShortcutAction() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        registerShortcut()

    }

    func stop() {
        unpin()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }

    // Menu tracking can change focus. Keep the selection from before it opens.
    func prepareMenuSelection() {
        refreshAccessibilityPermission()
        // A menu click can temporarily activate MacTools. Never pin its transient popover.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let pid = lastExternalPID {
            menuSelection = .external(pid, focusedWindow(pid: pid) ?? lastExternalWindow)
        } else { menuSelection = currentSelection() }
    }

    func toggleCurrentWindow(useMenuSelection: Bool = false) {
        let selection = useMenuSelection ? menuSelection : currentSelection()
        menuSelection = nil
        pin(selection)
    }

    // The tool-page button explicitly refers to the last external window.
    func toggle() {
        captureFrontmostApplication()
        pin(lastExternalPID.map { Selection.external($0, lastExternalWindow) })
    }

    func toggleMacToolsWindow() {
        guard let window = currentMacToolsWindow else {
            fail("Öffne zuerst das MacTools-Fenster, das du anheften möchtest."); return
        }
        pin(.own(window))
    }

    private func performShortcutAction() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastShortcutUptime > 0.15 else { return }
        lastShortcutUptime = now
        toggleCurrentWindow()
    }

    private func pin(_ selection: Selection?) {
        refreshAccessibilityPermission()
        guard let selection else { fail("Aktiviere das gewünschte Fenster und nutze danach das Menü oder Tastenkürzel."); return }
        switch selection {
        case .pinned(let id): unpin(id: id)
        case .own(let window):
            if let id = targets.first(where: { if case .own(let existing, _) = $0.value { return existing === window }; return false })?.key {
                unpin(id: id); return
            }
            let id = UUID(), previousLevel = window.level
            window.level = .floating
            window.orderFrontRegardless()
            targets[id] = .own(window, previousLevel)
            pinnedWindows.append(PinnedWindowSummary(id: id, title: window.title, application: "MacTools", isLive: false))
            refreshPinnedState()
        case .external(let pid, let capturedWindow, let requestedID):
            guard hasAccessibilityPermission else { fail("Für die Fensterwahl und Bedienung fehlt der Fensterzugriff. Öffne die Tool-Einstellungen."); return }
            guard hasScreenCapturePermission else {
                fail("Für die eindeutige Fensterliste fehlt noch die macOS-Bildschirmfreigabe. Für die interaktive Fensteransicht wird Bildschirmaufnahme benötigt."); return
            }
            guard !isStarting else { status = "Das gewählte Fenster wird gerade angeheftet …"; return }
            guard let window = capturedWindow ?? focusedWindow(pid: pid), let frame = Self.frame(window) else {
                fail("Das ausgewählte Fenster ist nicht erreichbar. Wähle es erneut aus."); return
            }
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            // Creating the preview must not activate or raise the original.
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
            let title = value as? String ?? ""
            isStarting = true
            let generation = UUID(); startGeneration = generation
            pending = Task { [weak self] in
                guard let self else { return }
                defer { if self.startGeneration == generation { self.isStarting = false; self.pending = nil } }
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    try Task.checkCancellation()
                    guard self.startGeneration == generation else { return }
                    let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
                    // Require an unambiguous match to the original selection, never switch to a new focused window.
                    let matches = candidates.filter {
                        abs($0.frame.minX - frame.minX) < 4 && abs($0.frame.minY - frame.minY) < 4
                        && abs($0.frame.width - frame.width) < 4 && abs($0.frame.height - frame.height) < 4
                    }
                    let titled = matches.filter { $0.title == title }
                    let selectedSource: SCWindow?
                    if let exactID = requestedID ?? NativeWindowIdentity.id(window) { selectedSource = candidates.first { $0.windowID == exactID } }
                    else { selectedSource = titled.count == 1 ? titled.first : matches.count == 1 ? matches.first : nil }
                    guard let source = selectedSource else {
                        self.fail("Das gewählte Fenster lässt sich nicht eindeutig zuordnen. Aktiviere es erneut und versuche es noch einmal."); return
                    }
                    if let id = self.targets.first(where: {
                        if case .original(_, _, let windowID, _) = $0.value { return windowID == source.windowID }
                        if case .live(_, _, let panel) = $0.value { return panel.source.windowID == source.windowID }; return false
                    })?.key { self.unpin(id: id); return }
                    guard let previous = OriginalWindowLevel.level(of: source.windowID) else {
                        self.fail("Das gewählte Originalfenster ist nicht mehr sichtbar."); return
                    }
                    let id = UUID()
                    var isLive = false
                    do {
                        try OriginalWindowLevel.set(Int32(CGWindowLevelForKey(.floatingWindow)), window: source.windowID)
                        self.targets[id] = .original(pid, window, source.windowID, previous)
                        self.nativeLevelStatus = "Originalfenster: schwebende Ebene bestätigt."
                    } catch {
                        self.nativeLevelStatus = error.localizedDescription
                        let panel = LivePinnedWindow(source: source, axWindow: window)
                        panel.onClose = { [weak self] in self?.unpin(id: id) }
                        panel.onInputIssue = { [weak self] issue in self?.fail(issue) }
                        panel.onError = { [weak self] error in self?.unpin(id: id); self?.fail("Fensteransicht beendet: " + error) }
                        self.targets[id] = .live(pid, window, panel)
                        do { try await panel.start()
                            #if DEBUG
                            Self.debugEvent("live-started pid=\(pid) window=\(source.windowID)")
                            #endif
                        }
                        catch { self.targets.removeValue(forKey: id); panel.stop(); throw error }
                        guard self.startGeneration == generation, !Task.isCancelled else { self.targets.removeValue(forKey: id); panel.stop(); return }
                        isLive = true
                    }
                    self.pinnedWindows.append(PinnedWindowSummary(id: id, title: title.isEmpty ? "Fenster" : title,
                        application: source.owningApplication?.applicationName ?? "App", isLive: isLive))
                    self.refreshPinnedState()
                } catch is CancellationError { }
                  catch { self.fail("Originalfenster konnte nicht angeheftet werden: " + error.localizedDescription) }
            }
        }
    }

    func refreshAvailableWindows() async {
        refreshAccessibilityPermission()
        guard hasScreenCapturePermission else { status = "Für die Fensterliste zuerst Bildschirmaufnahme freigeben."; return }
        isLoadingWindows = true
        defer { isLoadingWindows = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            selectableWindows = content.windows.filter {
                $0.windowLayer == 0 && $0.frame.width > 100 && $0.frame.height > 60
                && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
                && $0.owningApplication != nil
                && $0.owningApplication?.bundleIdentifier != "com.openai.Cua"
                && $0.title != "Software Cursor"
            }
            availableWindows = selectableWindows.map {
                AvailablePinWindow(id: $0.windowID, title: $0.title?.isEmpty == false ? $0.title! : "Fenster",
                                   application: $0.owningApplication!.applicationName)
            }.sorted { ($0.application, $0.title, $0.id) < ($1.application, $1.title, $1.id) }
        } catch { status = "Fensterliste konnte nicht geladen werden: " + error.localizedDescription }
    }

    func toggleAvailableWindow(id: CGWindowID) {
        guard let source = selectableWindows.first(where: { $0.windowID == id }), let owner = source.owningApplication else { return }
        let application = AXUIElementCreateApplication(owner.processID)
        AXUIElementSetMessagingTimeout(application, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { fail("Die App gibt ihre Fenster nicht zur Bedienung frei."); return }
        let matches = windows.filter {
            guard let frame = Self.frame($0) else { return false }
            return abs(frame.minX - source.frame.minX) < 4 && abs(frame.minY - source.frame.minY) < 4
                && abs(frame.width - source.frame.width) < 4 && abs(frame.height - source.frame.height) < 4
        }
        let titled = windows.filter {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue($0, kAXTitleAttribute as CFString, &title)
            guard let value = title as? String, let sourceTitle = source.title, !sourceTitle.isEmpty else { return false }
            return value == sourceTitle || value.hasPrefix(sourceTitle + " - ")
        }
        let exact = windows.first { NativeWindowIdentity.id($0) == source.windowID }
        guard let selected = exact ?? (matches.count == 1 ? matches.first : titled.count == 1 ? titled.first : nil) else {
            fail("Dieses Fenster ist nicht eindeutig erreichbar. Aktiviere es und nutze das Tastenkürzel."); return
        }
        pin(.external(owner.processID, selected, source.windowID))
    }

    private func refreshPinnedState() {
        isPinned = !pinnedWindows.isEmpty
        windowTitle = pinnedWindows.map { $0.application + " · " + $0.title }.joined(separator: ", ")
        status = pinnedWindows.isEmpty ? "Keine Fenster angeheftet." : "\(pinnedWindows.count) Fenster bleiben über anderen Apps sichtbar."
        if !isPinned { timer?.invalidate(); timer = nil }
        else if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.monitorPinnedWindows() } }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func openOriginal(id: UUID) {
        if case .original(let pid, let window, _, _) = targets[id] {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [])
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        else if case .own(let window, _) = targets[id] { window.makeKeyAndOrderFront(nil) }
        if case .live(_, _, let panel) = targets[id] { panel.openOriginal() }
    }

    func showPinnedView(id: UUID) {
        if case .live(_, _, let panel) = targets[id] { panel.show() }
        else { openOriginal(id: id) }
    }

    #if DEBUG
    private static func debugEvent(_ event: String) {
        let path = "/tmp/MacTools-window-debug.log"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(Data((event + "\n").utf8)); try? handle.close() }
    }
    #endif
    func unpin(id: UUID) {
        #if DEBUG
        Self.debugEvent("unpin")
        #endif
        guard let target = targets.removeValue(forKey: id) else { return }
        switch target {
        case .own(let window, let previousLevel): window.level = previousLevel
        case .original(_, _, let windowID, let previous): try? OriginalWindowLevel.set(previous, window: windowID)
        case .live(_, _, let panel): panel.stop()
        }
        pinnedWindows.removeAll { $0.id == id }
        refreshPinnedState()
    }

    func unpin() {
        startGeneration = UUID(); pending?.cancel(); pending = nil; isStarting = false
        for id in Array(targets.keys) { unpin(id: id) }
    }

    private static func frame(_ window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func fail(_ message: String) {
        status = message
        onFailure?()
    }

    private var currentMacToolsWindow: NSWindow? {
        let windows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
        return windows.first { $0.isVisible && !$0.isMiniaturized && $0.canBecomeKey
            && $0.styleMask.contains(.titled) }
    }

    private func currentSelection() -> Selection? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        if application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            guard let window = currentMacToolsWindow else { return nil }
            if let id = targets.first(where: { if case .live(_, _, let panel) = $0.value { return panel.panel == window }; return false })?.key { return .pinned(id) }
            return .own(window)
        }
        captureFrontmostApplication()
        return .external(application.processIdentifier, lastExternalWindow)
    }

    private func focusedWindow(pid: pid_t) -> AXUIElement? {
        guard hasAccessibilityPermission else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func captureFrontmostApplication() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalPID = application.processIdentifier
        lastExternalWindow = focusedWindow(pid: application.processIdentifier)
    }

    private func monitorPinnedWindows() {
        refreshAccessibilityPermission()
        for (id, target) in Array(targets) {
            switch target {
            case .own(let window, _):
                if !window.isVisible || window.isMiniaturized { unpin(id: id) }
            case .live(let pid, let window, let panel):
                panel.ensureSourcePlacement()
                var minimized: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
                if NSRunningApplication(processIdentifier: pid)?.isTerminated != false || error == .invalidUIElement
                    || (minimized as? Bool) == true || !hasScreenCapturePermission {
                    #if DEBUG
                    Self.debugEvent("live-monitor-unpin error=\(error.rawValue) minimized=\(String(describing: minimized)) capture=\(hasScreenCapturePermission)")
                    #endif
                    unpin(id: id)
                }
                else if let frame = Self.frame(window) { panel.updateSourceFrame(frame) }
            case .original(let pid, let window, let windowID, _):
                var minimized: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
                if NSRunningApplication(processIdentifier: pid)?.isTerminated != false || error == .invalidUIElement
                    || (minimized as? Bool) == true || !hasScreenCapturePermission {
                    unpin(id: id)
                } else if OriginalWindowLevel.level(of: windowID) != Int32(CGWindowLevelForKey(.floatingWindow)) {
                    unpin(id: id); status = "Die Original-App hat die Fensterebene zurückgesetzt."
                }
            }
        }
    }

    func beginShortcutRecording() {
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
    }
    func cancelShortcutRecording() { registerShortcut() }

    func setShortcut(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else {
            status = "Das Tastenkürzel benötigt mindestens ⌘, ⌥ oder ⌃."; registerShortcut(); return
        }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let title = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
            + ([122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 49: "Leertaste", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑"][Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Taste \(event.keyCode)")
        UserDefaults.standard.set(Int(event.keyCode), forKey: "pinShortcutKeyCode")
        UserDefaults.standard.set(Int(modifiers), forKey: "pinShortcutModifiers")
        UserDefaults.standard.set(title, forKey: "pinShortcutTitle")
        shortcutTitle = title
        registerShortcut()
    }

    private func registerShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        let key = UInt32(UserDefaults.standard.object(forKey: "pinShortcutKeyCode") as? Int ?? 35)
        let modifiers = UInt32(UserDefaults.standard.object(forKey: "pinShortcutModifiers") as? Int ?? (cmdKey | optionKey))
        let result = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x4D544F50, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { status = "Das Tastenkürzel konnte nicht registriert werden (\(result)). Bitte eine andere Kombination wählen." }
    }

    func refreshAccessibilityPermission(userInitiated: Bool = false) {
        // Read only: toggling a feature must never repeatedly open the system prompt.
        let trusted = AXIsProcessTrusted()
        let capture = CGPreflightScreenCaptureAccess()
        if hasScreenCapturePermission != capture { hasScreenCapturePermission = capture }
        if hasAccessibilityPermission != trusted { hasAccessibilityPermission = trusted }
        if userInitiated { manualAccessibilityCheckAt = Date() }
    }

    func revealInstalledApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func restartApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor [weak self] in
                if let error { self?.status = "MacTools konnte nicht neu gestartet werden: \(error.localizedDescription)" }
                // The new instance terminates this instance through AppDelegate.
            }
        }
    }

    func openScreenCaptureSettings() {
        // Only an explicit button opens this OS permission request.
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

struct PinShortcutRecorder: NSViewRepresentable {
    @ObservedObject var controller: WindowPinController
    func makeNSView(context: Context) -> ShortcutButton {
        let button = ShortcutButton()
        button.bezelStyle = .rounded
        button.controller = controller
        button.target = button; button.action = #selector(ShortcutButton.record)
        return button
    }
    func updateNSView(_ button: ShortcutButton, context: Context) {
        if !button.recording { button.title = controller.shortcutTitle + " · ändern" }
    }
}

final class ShortcutButton: NSButton {
    var controller: WindowPinController?
    var recording = false
    override var acceptsFirstResponder: Bool { true }
    @objc func record() {
        controller?.beginShortcutRecording()
        recording = true; title = "Tastenkürzel drücken … (Esc bricht ab)"
        window?.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode != 53 { controller?.setShortcut(event: event) }
        else { controller?.cancelShortcutRecording() }
        recording = false
        title = (controller?.shortcutTitle ?? "") + " · ändern"
    }
    override func resignFirstResponder() -> Bool {
        if recording {
            recording = false
            controller?.cancelShortcutRecording()
            title = (controller?.shortcutTitle ?? "") + " · ändern"
        }
        return super.resignFirstResponder()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
}

struct WindowToolView: View {
    var onOpenSettings: () -> Void
    @ObservedObject private var pin = WindowPinController.shared
    @State private var showWindowPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    ToolPageHeader(title: "Fenster vorn halten", description: "Behalte ein wichtiges Fenster im Blick, während du in anderen Apps arbeitest.", icon: "pin")
                    Button("Tool-Einstellungen", action: onOpenSettings)
                }
                ToolSettingsCard(title: pin.isPinned ? "Dieses Fenster bleibt vorn" : "Wähle dein Fenster", description: pin.isPinned ? pin.windowTitle : "Aktiviere zuerst das gewünschte Fenster einer anderen App.") {
                    Label(pin.isPinned ? "Angeheftet" : "Kein Fenster angeheftet", systemImage: pin.isPinned ? "pin.fill" : "macwindow")
                        .font(.headline).foregroundStyle(pin.isPinned ? Color.green : Color.secondary)
                    HStack {
                        Button("Fenster auswählen …") { showWindowPicker = true }
                            .disabled(!pin.hasAccessibilityPermission || !pin.hasScreenCapturePermission || pin.isStarting)
                        Button(pin.isStarting ? "Fenster wird angeheftet …" : "Letztes Fenster anheften / lösen") { pin.toggle() }.disabled(pin.isStarting)
                            .buttonStyle(.borderedProminent)
                        if !pin.isPinned {
                            Button("MacTools-Fenster anheften") { pin.toggleMacToolsWindow() }
                        }
                        Text("Tastenkürzel: \(pin.shortcutTitle)").foregroundStyle(.secondary)
                    }
                    ForEach(pin.pinnedWindows) { item in
                        HStack {
                            Image(systemName: item.isLive ? "rectangle.on.rectangle" : "pin.fill").foregroundStyle(.blue)
                            VStack(alignment: .leading) {
                                Text(item.application).font(.headline)
                                Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(item.isLive ? "Interaktiv" : "Schwebend").font(.caption).foregroundStyle(.green)
                            if item.isLive { Button("Ansicht öffnen") { pin.showPinnedView(id: item.id) } }
                            Button("Original öffnen") { pin.openOriginal(id: item.id) }
                            Button("Lösen") { pin.unpin(id: item.id) }
                        }.padding(10).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if !pin.pinnedWindows.isEmpty { Button("Alle Fenster lösen") { pin.unpin() } }
                    Text(pin.status).font(.callout).foregroundStyle(.secondary)
                    if !pin.hasAccessibilityPermission || !pin.hasScreenCapturePermission {
                        HStack {
                            Label("Fenstersteuerung und Bildschirmaufnahme prüfen.", systemImage: "lock.shield").foregroundStyle(.orange)
                            Spacer()
                            Button("Freigabe & Tastenkürzel", action: onOpenSettings)
                        }
                    }
                }
                ToolSettingsCard(title: "So bleibt dein Fenster im Blick", description: "Always on top über die Menüleiste oder dein Tastenkürzel.") {
                    HStack(alignment: .top, spacing: 24) {
                        step("1", "Fenster auswählen", "Klicke auf das Fenster, das du im Vordergrund behalten möchtest.")
                        step("2", "Vorn halten", "Wähle im MacTools-Menü „Aktuelles Fenster vorn halten“ oder drücke \(pin.shortcutTitle).")
                        step("3", "Wieder lösen", "Am selben Originalfenster erneut auslösen oder hier in der Liste „Lösen“ wählen.")
                    }
                    Text("Wenn macOS das Originalfenster nicht schweben lässt, öffnet MacTools eine interaktive Live-Ansicht. Klicks, Mausbewegungen, Scrollen und Tasten werden ausschließlich an das ausgewählte Fenster weitergegeben. Das Original liegt währenddessen auf einer eigenen virtuellen Fensterfläche und erhält native Maus- und Tastatureingaben. Der sichtbare Cursor bleibt in der Live-Ansicht. Mit Escape verlässt du die Bedienung. Schließen, Lösen oder Original öffnen bringt das Original zurück auf deinen Bildschirm.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !pin.nativeLevelStatus.isEmpty { DisclosureGroup("Technische Details") { Text(pin.nativeLevelStatus).font(.caption).textSelection(.enabled) } }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .windowBackgroundColor))
            .onAppear { pin.refreshAccessibilityPermission() }
            .sheet(isPresented: $showWindowPicker) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Fenster auswählen").font(.title2.bold())
                        Spacer()
                        Button("Schließen") { showWindowPicker = false }
                    }
                    Text("Wähle ein konkretes Fenster. Bereits angeheftete Fenster werden beim erneuten Wählen gelöst.")
                        .font(.callout).foregroundStyle(.secondary)
                    if pin.isLoadingWindows { ProgressView("Fenster werden geladen …") }
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(pin.availableWindows) { item in
                                Button {
                                    pin.toggleAvailableWindow(id: item.id)
                                    showWindowPicker = false
                                } label: {
                                    HStack {
                                        Image(systemName: "macwindow").foregroundStyle(.blue)
                                        VStack(alignment: .leading) {
                                            Text(item.application).font(.headline)
                                            Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        Spacer()
                                        Image(systemName: "pin")
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                        .background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    Button("Liste aktualisieren") { Task { await pin.refreshAvailableWindows() } }
                }.padding(20).frame(width: 580, height: 520).task { await pin.refreshAvailableWindows() }
            }
    }

    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(number).font(.headline).foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30).background(Color.accentColor.opacity(0.12)).clipShape(Circle())
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
