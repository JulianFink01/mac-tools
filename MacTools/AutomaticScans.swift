import Foundation
import Combine
import UserNotifications

struct ScanWarning: Codable, Identifiable {
    let id: UUID
    let date: Date
    let title: String
    let detail: String
    var isImportant: Bool {
        !["Disk-Scan unvollständig", "Prüfung mit Einschränkungen", "Testdatei erkannt – Schutzprüfung erfolgreich"].contains(title)
    }
}

@MainActor
final class AutomaticScans: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AutomaticScans()
    @Published var enabled = UserDefaults.standard.object(forKey: "automaticScans") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "automaticScans"); if enabled { requestNotifications() }; checkSchedule() }
    }
    @Published var intervalHours = UserDefaults.standard.object(forKey: "scanIntervalHours") as? Int ?? 24 {
        didSet { UserDefaults.standard.set(intervalHours, forKey: "scanIntervalHours"); checkSchedule() }
    }
    @Published private(set) var status = "Automatische Scans werden vorbereitet."
    @Published private(set) var warnings: [ScanWarning] = []
    @Published private(set) var notificationStatus = "Mitteilungsberechtigung wird geprüft."
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var pendingVirusScan = false
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
            guard DiskScanStore.shared.isScanning, !DiskScanStore.shared.resultIsProvisional else { return }
            self?.inspect(result)
            if self?.pendingVirusScan == true {
                self?.pendingVirusScan = false
                self?.startVirusScan(root: result.root, inventory: result)
            }
        }.store(in: &subscriptions)
        DiskScanStore.shared.$isScanning.dropFirst().sink { [weak self] scanning in
            guard !scanning, let self, self.pendingVirusScan else { return }
            self.pendingVirusScan = false
            self.showNextScan()
        }.store(in: &subscriptions)
        DiskScanStore.shared.$status.dropFirst().sink { [weak self] status in
            if status.hasPrefix("Scan fehlgeschlagen:") { self?.warn("Disk-Scan fehlgeschlagen", detail: status) }
        }.store(in: &subscriptions)
        SecurityScanStore.shared.$report.compactMap { $0 }.sink { [weak self] report in
            guard SecurityScanStore.shared.isScanning else { return }
            self?.showNextScan()
            guard !report.cancelled else { return }
            if report.threatCount > 0 || (report.exitCode != 0 && report.exitCode != 1) {
                self?.warn(report.title, detail: report.explanation + "\n" + report.items.prefix(10).map { $0.path }.joined(separator: "\n"))
            }
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
        let interval = TimeInterval(max(1, intervalHours) * 3600)
        if let lastRun, Date().timeIntervalSince(lastRun) < interval {
            status = "Nächster automatischer Scan: \(lastRun.addingTimeInterval(interval).formatted(date: .abbreviated, time: .shortened))"
            return
        }
        guard !DiskScanStore.shared.isScanning, !DiskScanStore.shared.isRestoring, !DiskScanStore.shared.isSaving, !DiskScanStore.shared.isApplyingRemovals, !SecurityScanStore.shared.isScanning,
              !SecurityScanStore.shared.isUpdating, !FileActions.shared.isCleaning else {
            status = "Automatischer Scan wartet auf den laufenden Vorgang."
            return
        }
        lastRun = Date()
        UserDefaults.standard.set(lastRun, forKey: "automaticScanLastRun")
        status = "Automatischer Scan läuft: \(DiskScanStore.shared.root.path)"
        pipelineGeneration = UUID()
        pendingVirusScan = true
        DiskScanStore.shared.findDuplicates = true
        DiskScanStore.shared.start()
    }

    func runNow() {
        guard !DiskScanStore.shared.isScanning, !DiskScanStore.shared.isSaving, !DiskScanStore.shared.isRestoring,
              !SecurityScanStore.shared.isScanning, !SecurityScanStore.shared.isUpdating else { return }
        pipelineGeneration = UUID(); pendingVirusScan = true
        status = "Gesamtscan · Speicher, Duplikate und Virenprüfung"
        DiskScanStore.shared.findDuplicates = true
        DiskScanStore.shared.start()
    }
    func cancelCombined() {
        pipelineGeneration = UUID(); pendingVirusScan = false
        if DiskScanStore.shared.isScanning { DiskScanStore.shared.cancel() }
        if SecurityScanStore.shared.isScanning || SecurityScanStore.shared.isUpdating { SecurityScanStore.shared.cancel() }
    }

    private func showNextScan() {
        if let lastRun {
            status = "Nächster automatischer Scan: \(lastRun.addingTimeInterval(TimeInterval(max(1, intervalHours) * 3600)).formatted(date: .abbreviated, time: .shortened))"
        }
    }

    private func startVirusScan(root: URL, inventory: DiskScanResult? = nil) {
        status = "Automatische Virenprüfung läuft …"
        SecurityScanStore.shared.refresh()
        guard SecurityScanStore.shared.executable != nil else {
            warn("Virenschutz nicht verfügbar", detail: "Die integrierte ClamAV-Engine fehlt im Anwendungspaket.")
            showNextScan()
            return
        }
        let generation = pipelineGeneration
        Task {
            if await SecurityScanStore.shared.updateSignaturesIfNeeded() {
                guard pipelineGeneration == generation else { return }
                SecurityScanStore.shared.start(root: root, inventory: inventory)
            } else {
                warn("Virenschutz benötigt Aufmerksamkeit", detail: SecurityScanStore.shared.status)
                showNextScan()
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                               willPresent notification: UNNotification,
                                               withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func inspect(_ result: DiskScanResult) {
        if result.volumeTotal > 0 && (result.volumeFree < 10_000_000_000 || Double(result.volumeFree) / Double(result.volumeTotal) < 0.1) {
            warn("Wenig freier Speicher", detail: "Nur noch \(diskBytes(result.volumeFree)) auf dem Volume frei.")
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
