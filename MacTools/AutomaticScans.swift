import Foundation
import Combine
import UserNotifications

struct ScanWarning: Codable, Identifiable {
    let id: UUID
    let date: Date
    let title: String
    let detail: String
    var isSecurityFinding: Bool { title == "Verdächtige Dateien gefunden" }
    var findingPaths: [String] { isSecurityFinding ? detail.components(separatedBy: .newlines).filter { $0.hasPrefix("/") } : [] }
    var isImportant: Bool {
        title.hasPrefix("Kritisch") || ["Verdächtige Dateien gefunden", "Virenschutz nicht verfügbar"].contains(title)
    }
}

@MainActor
final class AutomaticScans: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AutomaticScans()
    @Published var enabled = UserDefaults.standard.object(forKey: "automaticScans") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "automaticScans"); if enabled { requestNotifications() }; checkSchedule() }
    }
    private static let interval: TimeInterval = 7 * 24 * 3600
    @Published private(set) var status = "Automatische Scans werden vorbereitet."
    @Published private(set) var warnings: [ScanWarning] = []
    @Published private(set) var notificationStatus = "Mitteilungsberechtigung wird geprüft."
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private enum Phase { case disk, preparingVirusScan, virus }
    private var phase: Phase?
    private var isAutomaticRun = false
    private var pipelineGeneration = UUID()
    private var lastRun = UserDefaults.standard.object(forKey: "automaticScanLastRun") as? Date
    private let warningsURL = VideoLibraryStore.appSupportDirectory.appendingPathComponent("scan-warnings.json")

    override init() {
        super.init()
        if let data = try? Data(contentsOf: warningsURL), let saved = try? JSONDecoder().decode([ScanWarning].self, from: data) {
            warnings = saved.filter(\.isImportant)
        }
    }

    func start() {
        guard timer == nil else { return }
        DiskScanStore.shared.$result.compactMap { $0 }.sink { [weak self] result in
            guard let self, DiskScanStore.shared.isScanning, !DiskScanStore.shared.resultIsProvisional else { return }
            self.inspect(result)
            if self.phase == .disk { self.startVirusScan(with: result) }
        }.store(in: &subscriptions)
        DiskScanStore.shared.$isScanning.dropFirst().sink { [weak self] scanning in
            guard !scanning, self?.phase == .disk else { return }
            self?.finishCombined()
        }.store(in: &subscriptions)
        DiskScanStore.shared.$status.dropFirst().sink { [weak self] status in
            if status.hasPrefix("Scan fehlgeschlagen:") { self?.warn("Disk-Scan fehlgeschlagen", detail: status) }
        }.store(in: &subscriptions)
        SecurityScanStore.shared.$report.compactMap { $0 }.sink { [weak self] report in
            guard SecurityScanStore.shared.isScanning, !report.cancelled else { return }
            if report.threatCount > 0 || (report.exitCode != 0 && report.exitCode != 1) {
                self?.warn(report.title, detail: report.explanation + "\n" + report.items.filter { !$0.isLimit && !$0.isTest }.prefix(10).map { $0.path }.joined(separator: "\n"))
            }
        }.store(in: &subscriptions)
        SecurityScanStore.shared.$isScanning.dropFirst().sink { [weak self] scanning in
            guard !scanning, self?.phase == .virus else { return }
            self?.finishCombined()
        }.store(in: &subscriptions)
        SecurityScanStore.shared.$issue.compactMap { $0 }.sink { [weak self] message in
            self?.warn("Virenschutz benötigt Aufmerksamkeit", detail: message)
        }.store(in: &subscriptions)
        UNUserNotificationCenter.current().delegate = self
        requestNotifications()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSchedule() }
        }
        checkSchedule()
    }

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                self?.notificationStatus = granted ? "Warnungen als macOS-Mitteilungen aktiv."
                    : "macOS-Mitteilungen nicht erlaubt; Warnungen bleiben in MacTools sichtbar."
                if error != nil { self?.notificationStatus = "macOS-Mitteilungen derzeit nicht verfügbar; Warnungen stehen in MacTools." }
            }
        }
    }

    func checkSchedule() {
        guard enabled else { status = "Automatische Scans deaktiviert."; return }
        if isAutomaticRun && MonitorBattery.read()?.isOnBattery == true {
            cancelCombined()
            lastRun = nil
            UserDefaults.standard.removeObject(forKey: "automaticScanLastRun")
            status = "Automatischer Gesamtscan pausiert bis Netzstrom verfügbar ist."
            return
        }
        guard phase == nil else { return }
        if let lastRun, Date().timeIntervalSince(lastRun) < Self.interval {
            showNextScan()
            return
        }
        if MonitorBattery.read()?.isOnBattery == true {
            status = "Automatischer Gesamtscan wartet auf Netzstrom."
            return
        }
        let startedAt = Date()
        guard startCombined(automatic: true) else {
            status = "Automatischer Gesamtscan wartet auf den laufenden Vorgang."
            return
        }
        lastRun = startedAt
        UserDefaults.standard.set(startedAt, forKey: "automaticScanLastRun")
    }

    func runNow() {
        _ = startCombined(automatic: false)
    }

    private func startCombined(automatic: Bool) -> Bool {
        guard phase == nil, !DiskScanStore.shared.isScanning, !DiskScanStore.shared.isSaving,
              !DiskScanStore.shared.isRestoring, !DiskScanStore.shared.isApplyingRemovals,
              !SecurityScanStore.shared.isScanning, !SecurityScanStore.shared.isUpdating,
              !FileActions.shared.isCleaning else { return false }
        DiskScanStore.shared.findDuplicates = true
        DiskScanStore.shared.start()
        guard DiskScanStore.shared.isScanning else { return false }
        pipelineGeneration = UUID()
        phase = .disk
        isAutomaticRun = automatic
        status = automatic ? "Automatischer Gesamtscan · Speicher und Duplikate" : "Gesamtscan · Speicher und Duplikate"
        return true
    }

    func cancelCombined() {
        pipelineGeneration = UUID()
        finishCombined()
        if DiskScanStore.shared.isScanning { DiskScanStore.shared.cancel() }
        if SecurityScanStore.shared.isScanning || SecurityScanStore.shared.isUpdating { SecurityScanStore.shared.cancel() }
    }

    private func finishCombined() {
        phase = nil
        isAutomaticRun = false
        showNextScan()
    }

    private func showNextScan() {
        if !enabled {
            status = "Automatische Scans deaktiviert."
        } else if let lastRun {
            status = "Nächster automatischer Gesamtscan: \(lastRun.addingTimeInterval(Self.interval).formatted(date: .abbreviated, time: .shortened))"
        } else {
            status = "Der erste automatische Gesamtscan steht aus."
        }
    }

    private func startVirusScan(with inventory: DiskScanResult) {
        phase = .preparingVirusScan
        status = isAutomaticRun ? "Automatischer Gesamtscan · Virenprüfung" : "Gesamtscan · Virenprüfung"
        SecurityScanStore.shared.refresh()
        guard SecurityScanStore.shared.executable != nil else {
            warn("Virenschutz nicht verfügbar", detail: "Die integrierte ClamAV-Engine fehlt im Anwendungspaket.")
            finishCombined()
            return
        }
        let generation = pipelineGeneration
        Task {
            guard pipelineGeneration == generation else { return }
            let ready = await SecurityScanStore.shared.updateSignaturesIfNeeded()
            guard pipelineGeneration == generation else { return }
            guard ready else {
                warn("Virenschutz benötigt Aufmerksamkeit", detail: SecurityScanStore.shared.status)
                finishCombined()
                return
            }
            SecurityScanStore.shared.start(root: inventory.root, inventory: inventory, inventoryIsCurrent: true)
            if SecurityScanStore.shared.isScanning { phase = .virus }
            else { finishCombined() }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                               willPresent notification: UNNotification,
                                               withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func inspect(_ result: DiskScanResult) {
        if result.volumeTotal > 0 && (result.volumeFree < 2_000_000_000) {
            warn("Kritisch wenig Speicher", detail: "Nur noch \(diskBytes(result.volumeFree)) auf dem Volume frei.")
        }
        if result.reachedLimit {
            warn("Gesamtscan konnte nicht abgeschlossen werden", detail: "Der Scan wurde vorzeitig begrenzt. Starte die Analyse erneut.")
        }
        // Individual unavailable/changing files are explained in scan details,
        // not elevated to repeated important-warning cards or notifications.

    }

    private func warn(_ title: String, detail: String) {
        guard ScanWarning(id: UUID(), date: Date(), title: title, detail: detail).isImportant else { return }
        if let last = warnings.first, last.title == title, last.detail == detail,
           Date().timeIntervalSince(last.date) < 3600 { return }
        let warning = ScanWarning(id: UUID(), date: Date(), title: title, detail: String(detail.prefix(8192)))
        warnings.insert(warning, at: 0)
        warnings = Array(warnings.prefix(50))
        try? JSONEncoder().encode(warnings).write(to: warningsURL, options: .atomic)
        let content = UNMutableNotificationContent()
        content.title = "MacTools · \(title)"
        content.body = String(detail.prefix(200))
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: warning.id.uuidString, content: content, trigger: nil))
    }
}
