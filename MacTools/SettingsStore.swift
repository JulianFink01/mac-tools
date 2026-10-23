import Combine
import Foundation
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var codexLimitPlacement: String { didSet { defaults.set(codexLimitPlacement, forKey: "codexLimitPlacement") } }
    @Published var currentVideoID: UUID? {
        didSet {
            if let currentVideoID {
                defaults.set(currentVideoID.uuidString, forKey: Keys.currentVideoID)
            } else {
                defaults.removeObject(forKey: Keys.currentVideoID)
            }
        }
    }

    @Published var isPaused: Bool {
        didSet {
            defaults.set(isPaused, forKey: Keys.isPaused)
        }
    }

    @Published var aspectMode: AspectMode {
        didSet {
            defaults.set(aspectMode.rawValue, forKey: Keys.aspectMode)
        }
    }

    @Published var wantsStartAtLogin: Bool {
        didSet {
            defaults.set(wantsStartAtLogin, forKey: Keys.wantsStartAtLogin)
        }
    }

    @Published var quickPanelCompactVolume: Bool { didSet { defaults.set(quickPanelCompactVolume, forKey: "quickPanelCompactVolume") } }
    @Published var quickPanelEventTabs: Bool { didSet { defaults.set(quickPanelEventTabs, forKey: "quickPanelEventTabs") } }
    @Published var quickPanelWidgets: [QuickPanelWidget] {
        didSet { defaults.set(quickPanelWidgets.map(\.rawValue), forKey: "quickPanelWidgets") }
    }
    func moveQuickWidget(_ widget: QuickPanelWidget, to index: Int) {
        guard let old = quickPanelWidgets.firstIndex(of: widget) else { return }
        var values = quickPanelWidgets; values.remove(at: old); values.insert(widget, at: max(0, min(index, values.count))); quickPanelWidgets = values
    }

    @Published var showMainMenuIcon: Bool { didSet { defaults.set(showMainMenuIcon, forKey: "showMainMenuIcon") } }
    @Published var chatPopupAlwaysOnTop: Bool { didSet { defaults.set(chatPopupAlwaysOnTop, forKey: "chatPopupAlwaysOnTop") } }
    @Published var sidebarCodexFolders: [String] { didSet { defaults.set(sidebarCodexFolders, forKey: "sidebarCodexFolders") } }
    @Published var sidebarEntryOrder: [String] { didSet { defaults.set(sidebarEntryOrder, forKey: "sidebarEntryOrder") } }
    var sidebarEntries: [SidebarEntry] {
        let enabled = sidebarFavorites.map(SidebarEntry.tool) + sidebarCodexFolders.map(SidebarEntry.folder)
        let byID = Dictionary(enabled.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        return (sidebarEntryOrder + enabled.map(\.id)).compactMap { id in guard seen.insert(id).inserted else { return nil }; return byID[id] }
    }
    func setSidebarFolder(_ path: String, enabled: Bool) {
        if enabled { if !sidebarCodexFolders.contains(path) { sidebarCodexFolders.append(path) } }
        else { sidebarCodexFolders.removeAll { $0 == path } }
    }
    func moveSidebarEntry(_ entry: SidebarEntry, before target: SidebarEntry? = nil) {
        switch entry { case .tool(let tool): setSidebarFavorite(tool, enabled: true); case .folder(let path): setSidebarFolder(path, enabled: true) }
        guard entry != target else { return }
        var ids = sidebarEntries.map(\.id); ids.removeAll { $0 == entry.id }
        ids.insert(entry.id, at: target.flatMap { ids.firstIndex(of: $0.id) } ?? ids.count)
        sidebarEntryOrder = ids
    }
    @Published var sidebarOrder: [ToolNavigation.Section] { didSet { defaults.set(sidebarOrder.map(\.rawValue), forKey: "sidebarFavoriteOrder") } }
    var sidebarFavorites: [ToolNavigation.Section] {
        let ordered = sidebarOrder.filter { sidebarTools.contains($0) && ToolNavigation.Section.pinnable.contains($0) }
        return ordered + ToolNavigation.Section.pinnable.filter { sidebarTools.contains($0) && !ordered.contains($0) }
    }
    func moveSidebar(_ tool: ToolNavigation.Section, before target: ToolNavigation.Section) {
        guard tool != target else { return }
        setSidebarFavorite(tool, enabled: true)
        var ordered = sidebarFavorites; ordered.removeAll { $0 == tool }
        ordered.insert(tool, at: ordered.firstIndex(of: target) ?? ordered.count); sidebarOrder = ordered
    }
    @Published var sidebarTools: Set<ToolNavigation.Section> {
        didSet { defaults.set(sidebarTools.map(\.rawValue).sorted(), forKey: "sidebarFavoriteTools") }
    }
    func setSidebarFavorite(_ tool: ToolNavigation.Section, enabled: Bool) {
        guard !enabled || ToolNavigation.Section.pinnable.contains(tool) else { return }
        if enabled { if !sidebarOrder.contains(tool) { sidebarOrder.append(tool) }; sidebarTools.insert(tool) } else { sidebarTools.remove(tool) }
    }

    @Published var pinnedCodexChats: [String] { didSet { defaults.set(pinnedCodexChats, forKey: "pinnedCodexChats") } }
    func setChatPinned(_ id: String, enabled: Bool) {
        if enabled { if !pinnedCodexChats.contains(id) { pinnedCodexChats.append(id) } }
        else { pinnedCodexChats.removeAll { $0 == id } }
    }
    @Published var pinnedCodexFolders: [String] { didSet { defaults.set(pinnedCodexFolders, forKey: "pinnedCodexFolders") } }
    func pinCodexFolder(_ path: String) { if !pinnedCodexFolders.contains(path) { pinnedCodexFolders.append(path) } }
    @Published var pinnedTools: Set<ToolNavigation.Section> {
        didSet { defaults.set(pinnedTools.map(\.rawValue).sorted(), forKey: "pinnedMenuTools") }
    }
    func setPinned(_ tool: ToolNavigation.Section, enabled: Bool) {
        guard !enabled || ToolNavigation.Section.pinnable.contains(tool) else { return }
        if enabled { pinnedTools.insert(tool) } else { pinnedTools.remove(tool) }
    }

    @Published var enabledMonitorWidgets: Set<MonitorMetric> {
        didSet { defaults.set(enabledMonitorWidgets.map(\.rawValue).sorted(), forKey: "monitorMenuWidgets") }
    }

    func setWidget(_ metric: MonitorMetric, enabled: Bool) {
        if enabled { enabledMonitorWidgets.insert(metric) } else { enabledMonitorWidgets.remove(metric) }
    }

    @Published var loginItemError: String?
    @Published private(set) var loginItemStatus: SMAppService.Status
    @Published private(set) var usesLaunchAgentFallback: Bool

    private let defaults: UserDefaults

    private enum Keys {
        static let currentVideoID = "currentVideoID"
        static let isPaused = "isPaused"
        static let aspectMode = "aspectMode"
        static let wantsStartAtLogin = "wantsStartAtLogin"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.codexLimitPlacement = defaults.string(forKey: "codexLimitPlacement") ?? "chats"
        quickPanelCompactVolume = defaults.bool(forKey: "quickPanelCompactVolume")
        quickPanelEventTabs = defaults.bool(forKey: "quickPanelEventTabs")
        quickPanelWidgets = defaults.stringArray(forKey: "quickPanelWidgets").map { { var seen = Set<QuickPanelWidget>(); return $0.compactMap(QuickPanelWidget.init(rawValue:)).filter { seen.insert($0).inserted } }($0) } ?? QuickPanelWidget.allCases
        showMainMenuIcon = defaults.object(forKey: "showMainMenuIcon") as? Bool ?? true
        chatPopupAlwaysOnTop = defaults.object(forKey: "chatPopupAlwaysOnTop") as? Bool ?? true
        sidebarCodexFolders = defaults.stringArray(forKey: "sidebarCodexFolders") ?? []
        sidebarEntryOrder = defaults.stringArray(forKey: "sidebarEntryOrder") ?? []
        sidebarOrder = (defaults.stringArray(forKey: "sidebarFavoriteOrder") ?? []).compactMap(ToolNavigation.Section.init(rawValue:)).filter { ToolNavigation.Section.pinnable.contains($0) }
        sidebarTools = defaults.stringArray(forKey: "sidebarFavoriteTools").map { Set($0.compactMap(ToolNavigation.Section.init(rawValue:)).filter { ToolNavigation.Section.pinnable.contains($0) }) } ?? [.monitoring, .disk, .codex]
        pinnedCodexChats = defaults.stringArray(forKey: "pinnedCodexChats") ?? []
        pinnedCodexFolders = defaults.stringArray(forKey: "pinnedCodexFolders") ?? []
        pinnedTools = Set((defaults.stringArray(forKey: "pinnedMenuTools") ?? []).compactMap(ToolNavigation.Section.init(rawValue:)).filter { ToolNavigation.Section.pinnable.contains($0) })
        enabledMonitorWidgets = defaults.stringArray(forKey: "monitorMenuWidgets").map { Set($0.compactMap(MonitorMetric.init(rawValue:))) } ?? Set(MonitorMetric.allCases)

        if let idString = defaults.string(forKey: Keys.currentVideoID) {
            currentVideoID = UUID(uuidString: idString)
        } else {
            currentVideoID = nil
        }

        isPaused = defaults.object(forKey: Keys.isPaused) as? Bool ?? false

        if let rawAspectMode = defaults.string(forKey: Keys.aspectMode),
           let storedAspectMode = AspectMode(rawValue: rawAspectMode) {
            aspectMode = storedAspectMode
        } else {
            aspectMode = .fill
        }

        let status = SMAppService.mainApp.status
        let storedLoginPreference = defaults.object(forKey: Keys.wantsStartAtLogin) as? Bool
        let fallbackEnabled = status == .notFound && LaunchAgentLoginItem.isEnabled
        usesLaunchAgentFallback = fallbackEnabled
        wantsStartAtLogin = storedLoginPreference ?? (status == .enabled || fallbackEnabled)
        loginItemStatus = status
    }

    func setCurrentVideo(_ id: UUID?) {
        currentVideoID = id
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    func setAspectMode(_ mode: AspectMode) {
        aspectMode = mode
    }

    func setStartAtLogin(_ enabled: Bool) {
        loginItemError = nil
        loginItemStatus = SMAppService.mainApp.status
        usesLaunchAgentFallback = loginItemStatus == .notFound && LaunchAgentLoginItem.isEnabled

        do {
            if enabled {
                switch loginItemStatus {
                case .enabled:
                    wantsStartAtLogin = true
                case .requiresApproval:
                    wantsStartAtLogin = true
                    SMAppService.openSystemSettingsLoginItems()
                case .notRegistered:
                    try SMAppService.mainApp.register()
                    loginItemStatus = SMAppService.mainApp.status
                    wantsStartAtLogin = true
                case .notFound:
                    try LaunchAgentLoginItem.register()
                    usesLaunchAgentFallback = true
                    wantsStartAtLogin = true
                @unknown default:
                    try SMAppService.mainApp.register()
                    loginItemStatus = SMAppService.mainApp.status
                    wantsStartAtLogin = true
                }
            } else {
                if usesLaunchAgentFallback {
                    try LaunchAgentLoginItem.unregister()
                    usesLaunchAgentFallback = false
                } else if loginItemStatus == .enabled || loginItemStatus == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
                loginItemStatus = SMAppService.mainApp.status
                wantsStartAtLogin = false
            }
        } catch {
            loginItemError = error.localizedDescription
            loginItemStatus = SMAppService.mainApp.status
            usesLaunchAgentFallback = loginItemStatus == .notFound && LaunchAgentLoginItem.isEnabled
            wantsStartAtLogin = loginItemStatus == .enabled || usesLaunchAgentFallback
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func refreshStartAtLoginStatus() {
        loginItemStatus = SMAppService.mainApp.status
        usesLaunchAgentFallback = loginItemStatus == .notFound && LaunchAgentLoginItem.isEnabled
        wantsStartAtLogin = loginItemStatus == .enabled || usesLaunchAgentFallback || (wantsStartAtLogin && loginItemStatus == .requiresApproval)
        if loginItemStatus != .notFound {
            loginItemError = nil
        }
    }

    var isLoginItemAvailable: Bool {
        true
    }

    var loginItemStatusText: String {
        if usesLaunchAgentFallback {
            return "MacTools startet bei der Anmeldung. macOS zeigt den Autostart unter „Im Hintergrund erlauben“ an."
        }

        switch loginItemStatus {
        case .enabled:
            return "MacTools startet bei der Anmeldung."
        case .requiresApproval:
            return "Der Autostart muss noch in den Systemeinstellungen erlaubt werden."
        case .notRegistered:
            return "Der automatische Start bei der Anmeldung ist ausgeschaltet."
        case .notFound:
            return "MacTools verwendet für diese lokale App-Version eine Autostart-Datei. macOS zeigt sie unter „Im Hintergrund erlauben“ an."
        @unknown default:
            return "Der Autostart-Status konnte nicht ermittelt werden."
        }
    }

    var appBundlePath: String {
        Bundle.main.bundleURL.path
    }
}
