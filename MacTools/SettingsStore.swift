import Combine
import Foundation
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

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
