import AppKit
import CryptoKit
import IOKit
import Combine

/// Public releases contain no private endpoint configuration and never start this client.
enum PrivateMCPAccess {
    static let configuration: [String: String] = {
        #if MACTOOLS_PRIVATE_INTEGRATIONS
        guard let url = Bundle.main.url(forResource: "PrivateIntegrations", withExtension: "json"),
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode([String: String].self, from: data),
              let expected = value["device"], expected == deviceFingerprint else { return [:] }
        return value
        #else
        return [:]
        #endif
    }()
    static var enabled: Bool { !configuration.isEmpty }
    static var deviceFingerprint: String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return "" }; defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { return "" }
        return SHA256.hash(data: Data(uuid.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum PrivateMCPKind: String, CaseIterable, Identifiable, Sendable {
    case infrapilot, alphatrader
    var id: String { rawValue }
    var title: String { self == .infrapilot ? "InfraPilot" : "AlphaTrader" }
    var icon: String { self == .infrapilot ? "server.rack" : "chart.line.uptrend.xyaxis" }
    var tools: [String] { self == .infrapilot ? ["get_system_health", "get_platform_health", "get_namespace_metrics"] : ["get_operational_health", "get_leadership_status", "get_database_storage", "list_workspaces", "list_shadow_runtimes", "list_portfolio_deployments", "list_paper_runtimes", "resolve_strategy_presentations"] }
    var section: ToolNavigation.Section { self == .infrapilot ? .infrapilot : .alphaTrader }
}

struct PrivateMCPMetric: Identifiable, Equatable {
    let title: String
    let value: String
    var detail = ""
    var fraction: Double?
    var healthy: Bool?
    var id: String { title }
}
struct PrivateMCPFact: Identifiable, Equatable {
    let title: String
    let value: String
    var key: String? = nil
    var healthy: Bool? = nil
    var id: String { key ?? title }
}
/// Namespace values come from InfraPilot's authorized metrics endpoint. Missing values stay missing.
struct InfraNamespaceMetrics: Identifiable, Equatable {
    let id: String
    let pods: Int
    let claims: Int
    let cpu: Double?
    let cpuLimit: Double?
    let memory: Double?
    let memoryLimit: Double?
    let storage: Double?
    let storageLimit: Double?
    // The current InfraPilot contract exposes no per-namespace network counters.
    var network: Double? { nil }
    static func parse(_ result: [String:Any]) throws -> [Self] {
        guard result["isError"] as? Bool != true else { throw CodexFailure(message:"Namespace-Metriken nicht verfügbar.") }
        var raw: Any? = result["structuredContent"]
        if raw == nil {
            raw = (result["content"] as? [[String:Any]] ?? []).compactMap { item -> Any? in
                guard let text = item["text"] as? String else { return nil }
                return try? JSONSerialization.jsonObject(with:Data(text.utf8))
            }.first
        }
        if let object = raw as? [String:Any] {
            if let status = object["status"] as? Int, status >= 400 { throw CodexFailure(message:"Namespace-Metriken abgelehnt (HTTP \(status)).") }
            raw = object["result"] ?? object["data"] ?? object["namespaces"]
        }
        guard let rows = raw as? [[String:Any]] else { throw CodexFailure(message:"Namespace-Metriken sind unvollständig.") }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let name = row["namespace"] as? String, !name.isEmpty, seen.insert(name).inserted else { return nil }
            func number(_ key: String) -> Double? { guard let value = row[key] as? Double, value.isFinite, value >= 0 else { return nil }; return value }
            let available = row["metricsAvailable"] as? Bool == true
            return Self(id:name,pods:row["pods"] as? Int ?? 0,claims:row["persistentVolumeClaims"] as? Int ?? 0,
                cpu:available ? number("cpuMillicores").map { $0 / 1000 } : nil,
                cpuLimit:row["cpuUnlimitedContainers"] as? Int == 0 ? number("cpuLimitMillicores").map { $0 / 1000 } : nil,
                memory:available ? number("memoryBytes") : nil,
                memoryLimit:row["memoryUnlimitedContainers"] as? Int == 0 ? number("memoryLimitBytes") : nil,
                storage:row["storageUsedAvailable"] as? Bool == true ? number("storageUsedBytes") : nil,
                storageLimit:number("storageBytes"))
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}
struct InfraNamespaceSample: Identifiable, Equatable {
    let date: Date
    let values: [InfraNamespaceMetrics]
    var id: Date { date }
}

struct PrivateMCPHealth: Equatable {
    var healthy: Bool
    var title: String
    var stats: [String]
    let checkedAt: Date
    var metrics: [PrivateMCPMetric] = []
    var facts: [PrivateMCPFact] = []
    var strategies: AlphaTraderStrategySummary?
    var namespaces: [InfraNamespaceMetrics] = []
    static func bytes(_ value: Double) -> String { guard value.isFinite, value >= 0, value < Double(Int64.max) else { return "—" }; return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary) }
    static func payload(_ result: [String: Any]) throws -> [String: Any] {
        guard result["isError"] as? Bool != true else { throw CodexFailure(message: "Der Dienst hat die Health-Abfrage abgelehnt. Bitte Berechtigung und Verbindung prüfen.") }
        var data = result["structuredContent"] as? [String: Any]
        if data == nil {
            for item in result["content"] as? [[String: Any]] ?? [] {
                if let text = item["text"] as? String, let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { data = json; break }
            }
        }
        guard let data else { throw CodexFailure(message: "Der MCP liefert keine lesbaren Health-Daten.") }
        if let status = data["status"] as? Int, status >= 400 { throw CodexFailure(message: "Health-Abfrage fehlgeschlagen (HTTP \(status)).") }
        return data["result"] as? [String: Any] ?? data["data"] as? [String: Any] ?? data
    }
    static func parse(_ result: [String: Any], kind: PrivateMCPKind, now: Date = Date()) throws -> Self {
        let data = try payload(result)
        if kind == .alphatrader {
            guard let live = data["liveness"] as? String, let traffic = data["trafficReady"] as? Bool, let runtime = data["runtimeReady"] as? Bool else { throw CodexFailure(message: "Trader-Health ist unvollständig.") }
            let healthy = live == "UP" && traffic && runtime
            return Self(healthy: healthy, title: healthy ? "Trader bereit" : "Trader eingeschränkt", stats: ["Liveness " + live, "Traffic " + (traffic ? "bereit" : "nicht bereit"), "Runtime " + (runtime ? "bereit" : "nicht bereit")], checkedAt: now, metrics: [PrivateMCPMetric(title: "Liveness", value: live, detail: "Erreichbarkeit des Trader-Prozesses", healthy: live == "UP"), PrivateMCPMetric(title: "Traffic", value: traffic ? "Bereit" : "Nicht bereit", detail: "Bereitschaft für eingehende Anfragen", healthy: traffic), PrivateMCPMetric(title: "Runtime", value: runtime ? "Bereit" : "Nicht bereit", detail: "Bereitschaft der Handelslaufzeit", healthy: runtime)])
        }
        guard let machine = data["machine"] as? [String: Any], let kubernetes = data["kubernetes"] as? [String: Any], let pods = kubernetes["pods"] as? [String: Any], pods["checked"] as? Bool == true,
              let total = pods["total"] as? Int, let ready = pods["ready"] as? Int else { throw CodexFailure(message: "Cluster-Health ist unvollständig.") }
        func percent(_ name: String) -> Double? {
            guard let value = (machine[name] as? [String: Any])?["percent"] as? Double, value.isFinite, (0...100).contains(value) else { return nil }; return value
        }
        let cpu = percent("cpu"), ram = percent("memory"), storage = percent("storage")
        var stats = ["\(ready)/\(total) Pods bereit"]
        for (label, value) in [("CPU", cpu), ("RAM", ram), ("Disk", storage)] { if let value { stats.append("\(label) \(Int(value.rounded())) %") } }
        let healthy = ready == total && (pods["failed"] as? Int ?? 0) == 0 && (pods["pending"] as? Int ?? 0) == 0 && (pods["unknown"] as? Int ?? 0) == 0 && (cpu ?? 0) < 90 && (ram ?? 0) < 95 && (storage ?? 0) < 95
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let checked = (data["checkedAt"] as? String).flatMap { format.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } ?? now
        var details = Self(healthy: healthy, title: healthy ? "Cluster gesund" : "Cluster prüfen", stats: stats, checkedAt: checked)
        details.metrics.append(PrivateMCPMetric(title: "Pods bereit", value: "\(ready) / \(total)", detail: "Laufende und bereite Kubernetes-Pods", fraction: total > 0 ? Double(ready) / Double(total) : nil, healthy: ready == total))
        for (name, key, percentage) in [("CPU", "cpu", cpu), ("Arbeitsspeicher", "memory", ram), ("Speicher", "storage", storage)] {
            guard let percentage else { continue }
            let metric = machine[key] as? [String: Any] ?? [:], used = metric["used"] as? Double, total = metric["total"] as? Double
            let detail: String
            if let used, let total { detail = key == "cpu" ? String(format: "%.2f von %.0f Kernen", used, total) : Self.bytes(used) + " von " + Self.bytes(total) } else { detail = "" }
            details.metrics.append(PrivateMCPMetric(title: name, value: "\(Int(percentage.rounded())) %", detail: detail, fraction: percentage / 100, healthy: percentage < (key == "cpu" ? 90 : 95)))
        }
        for (key, label) in [("running", "Laufende Pods"), ("pending", "Wartende Pods"), ("failed", "Fehlgeschlagene Pods"), ("unknown", "Pods mit unklarem Status")] { if let value = pods[key] as? Int { details.facts.append(PrivateMCPFact(title: label, value: String(value))) } }
        if let host = machine["hostname"] as? String { details.facts.append(PrivateMCPFact(title: "Maschine", value: host)) }
        if let uptime = machine["uptimeSeconds"] as? Double, uptime.isFinite, uptime >= 0, uptime < 315_576_000 { details.facts.append(PrivateMCPFact(title: "Uptime", value: "\(Int(uptime) / 86400) Tage · \(Int(uptime) % 86400 / 3600) Std.")) }
        if let load = machine["loadAverage"] as? [Double] { details.facts.append(PrivateMCPFact(title: "Last · 1 / 5 / 15 Min.", value: load.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: " / "))) }
        if let throughput = machine["diskThroughput"] as? [String: Any] {
            for (key, label) in [("readBytesPerSecond", "Disk lesen"), ("writeBytesPerSecond", "Disk schreiben")] { if let value = throughput[key] as? Double { details.facts.append(PrivateMCPFact(title: label, value: Self.bytes(value) + "/s")) } }
        }
        return details
    }
}

/// Categories are exclusive and count deployment bindings, not strategy names or historical runtimes.
struct AlphaTraderStrategySummary: Equatable {
    var running = 0
    var waiting = 0
    var unhealthy = 0
    var starting = 0
    var paused = 0
    var unknown = 0
    var total = 0
    var unnamed = 0
    var facts: [PrivateMCPFact] = []
    private enum State: Int {
        case running, starting, waiting, unknown, unhealthy, paused
        var label: String {
            switch self {
            case .running: return "Verarbeitet Daten"
            case .starting: return "Startet / verbindet"
            case .waiting: return "Wartet"
            case .unknown: return "Status nicht eindeutig"
            case .unhealthy: return "Gestört"
            case .paused: return "Pausiert / gestoppt"
            }
        }
    }
    private static func state(_ item: [String:Any]) -> (State, String) {
        guard item["desiredState"] as? String == "RUNNING" else { return (.paused, "Gewollt pausiert oder gestoppt") }
        let observed = item["observedState"] as? String ?? "UNKNOWN"
        let heartbeat = item["heartbeat"] as? [String:Any] ?? [:]
        let activity = item["activityState"] as? String ?? heartbeat["state"] as? String ?? ""
        let heartbeatState = heartbeat["state"] as? String ?? ""
        if ["FAILED", "ERROR", "CRASHED"].contains(observed) { return (.unhealthy, "Laufzeit meldet " + observed) }
        if [activity, heartbeatState].contains("HEARTBEAT_MISSING") { return (.unhealthy, "Heartbeat fehlt") }
        if [activity, heartbeatState].contains("HEARTBEAT_STALE") { return (.unhealthy, "Heartbeat abgelaufen") }
        // Compare the server's observation time, never the local clock or the one-minute poll interval.
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ key: String) -> Date? { (heartbeat[key] as? String).flatMap { formatter.date(from:$0) ?? ISO8601DateFormatter().date(from:$0) } }
        var fresh = false
        if let checked = date("observedAt"), let last = date("lastHeartbeatAt"), let expiry = heartbeat["expiresAfterSeconds"] as? Double, expiry > 0 {
            let age = checked.timeIntervalSince(last)
            if age > expiry { return (.unhealthy, "Heartbeat abgelaufen") }
            fresh = age >= 0
        }
        if fresh {
            switch activity {
            case "PENDING_DATA": return (.waiting, "Wartet auf Marktdaten · Heartbeat aktuell")
            case "WAITING_FOR_CANDIDATES": return (.waiting, "Wartet auf passende Kandidaten · Heartbeat aktuell")
            case "WAITING_FOR_EVALUATION": return (.waiting, "Wartet auf Auswertung · Heartbeat aktuell")
            case "CONNECTING": return (.starting, "Verbindet · Heartbeat aktuell")
            default: break
            }
        }
        if observed == "DEGRADED" { return (.unhealthy, "Eingeschränkter Betrieb" + (activity.isEmpty ? "" : " · " + activity)) }
        if observed == "STARTING" || activity == "CONNECTING" { return (.starting, fresh ? "Startet · Heartbeat aktuell" : "Startet · Heartbeat noch nicht bestätigt") }
        if activity == "PROCESSING" { return (.running, "Verarbeitet Daten" + (fresh ? " · Heartbeat aktuell" : "")) }
        if observed == "RUNNING" && activity.isEmpty { return (.running, "Laufzeit meldet RUNNING") }
        return (.unknown, activity.isEmpty ? observed : activity + " · Heartbeat nicht bestätigt")
    }
    static func parse(_ rows: [(workspace: String, mode: String, runtime: [String: Any])], names: [String:String] = [:], workspaceNames: [String:String] = [:]) throws -> Self {
        var groups: [String: [(String, [String: Any])]] = [:]
        for row in rows {
            guard let id = row.runtime["strategyDeploymentId"] as? String, row.runtime["observedState"] is String, row.runtime["desiredState"] is String else { throw CodexFailure(message: "Deployment-Status ist unvollständig.") }
            groups[row.workspace + ":" + id, default: []].append((row.mode, row.runtime))
        }
        var summary = Self(); summary.total = groups.count
        for (key, records) in groups.sorted(by: { $0.key < $1.key }) {
            let active = records.filter { $0.1["desiredState"] as? String == "RUNNING" }
            // Old, deliberately stopped runtimes must not invalidate an active replacement.
            let current = active.isEmpty ? records : active
            let statuses = current.map { ($0.0, state($0.1)) }
            let status = active.isEmpty ? State.paused : statuses.map { $0.1.0 }.max(by: { $0.rawValue < $1.rawValue }) ?? .unknown
            switch status {
            case .running: summary.running += 1
            case .waiting: summary.waiting += 1
            case .starting: summary.starting += 1
            case .paused: summary.paused += 1
            case .unhealthy: summary.unhealthy += 1
            case .unknown: summary.unknown += 1
            }
            let states = statuses.map { $0.0 + " · " + $0.1.1 }
            let workspace = String(key.split(separator: ":", maxSplits: 1)[0])
            if names[key] == nil { summary.unnamed += 1 }
            let title = (workspaceNames[workspace] ?? "Workspace") + " · " + (names[key] ?? "Name nicht verfügbar")
            summary.facts.append(PrivateMCPFact(title: title, value: Array(Set(states)).sorted().joined(separator: " / "), key: key, healthy: status == .unhealthy ? false : [.running, .waiting].contains(status) ? true : nil))
        }
        return summary
    }
}

@MainActor final class PrivateMCPService: ObservableObject, Identifiable {
    nonisolated let kind: PrivateMCPKind
    nonisolated var id: String { kind.rawValue }
    @Published private(set) var endpoint: String
    @Published private(set) var enabled: Bool
    @Published private(set) var health: PrivateMCPHealth?
    @Published private(set) var error: String?
    @Published private(set) var detailWarning: String?
    @Published private(set) var busy = false
    @Published private(set) var needsLogin = false
    @Published private(set) var signingIn = false
    @Published private(set) var authorizationURL: URL?
    private let defaults: UserDefaults
    private var client: NativeMCPClient?
    private let permitted: Bool
    private var polling: Task<Void, Never>?
    private var detailConsumers = Set<UUID>()
    private var platformFacts: [PrivateMCPFact] = []
    private var leadershipFact: PrivateMCPFact?
    private var namespaceAttempt = Date.distantPast
    private var platformAttempt = Date.distantPast
    private var leadershipAttempt = Date.distantPast
    private var namesAttempt = Date.distantPast
    private var strategyNames: [String:String] = [:]
    private var strategyRows: [(workspace:String,mode:String,runtime:[String:Any])] = []
    private var strategyWorkspaceNames: [String:String] = [:]
    func setDetailsVisible(_ visible: Bool, consumer: UUID) {
        if visible { detailConsumers.insert(consumer) } else { detailConsumers.remove(consumer) }
    }
    func refreshDetails() async {
        guard permitted, enabled, !detailConsumers.isEmpty, !busy, !signingIn, var snapshot = health else { return }
        busy = true; defer { busy = false }
        await loadDetails(into:&snapshot)
        health = snapshot
    }
    private func loadDetails(into snapshot: inout PrivateMCPHealth) async {
        guard !detailConsumers.isEmpty else { return }
        let now = Date()
        if kind == .infrapilot {
            if now.timeIntervalSince(platformAttempt) >= 900 {
                platformAttempt = now
                do {
                    let platform = try PrivateMCPHealth.payload(try await call("get_platform_health"))
                    platformFacts = [("version","Version"),("clusterMode","Cluster-Modus")].compactMap { key,label in (platform[key] as? String).map { PrivateMCPFact(title:label,value:$0) } }
                } catch { detailWarning = "Plattformdetails aktuell nicht verfügbar." }
            }
            guard !detailConsumers.isEmpty else { return }
            if now.timeIntervalSince(namespaceAttempt) >= 60 {
                namespaceAttempt = now
                do {
                    snapshot.namespaces = try InfraNamespaceMetrics.parse(try await call("get_namespace_metrics"))
                    namespaceWarning = nil
                    let sample = InfraNamespaceSample(date:now,values:snapshot.namespaces)
                    namespaceHistory = Array((namespaceHistory.filter { now.timeIntervalSince($0.date) < 3600 } + [sample]).suffix(60))
                } catch { namespaceWarning = "Namespace-Metriken konnten nicht aktualisiert werden. Vorhandene Werte zeigen den letzten bestätigten Stand." }
            }
            snapshot.facts.removeAll { ["Version","Cluster-Modus"].contains($0.title) }; snapshot.facts += platformFacts
        } else {
            if now.timeIntervalSince(leadershipAttempt) >= 900 {
                leadershipAttempt = now
                do {
                    let result = try PrivateMCPHealth.payload(try await call("get_leadership_status"))
                    if let state = result["state"] as? String { leadershipFact = PrivateMCPFact(title:"Leadership",value:state) }
                } catch { detailWarning = "Leadership-Details aktuell nicht verfügbar." }
            }
            guard !detailConsumers.isEmpty else { return }
            if now.timeIntervalSince(namesAttempt) >= 900, !strategyRows.isEmpty {
                namesAttempt = now
                for workspace in Set(strategyRows.map(\.workspace)).sorted() {
                    guard !detailConsumers.isEmpty else { break }
                    let ids = Set(strategyRows.filter { $0.workspace == workspace }.compactMap { $0.runtime["strategyDeploymentId"] as? String }).sorted()
                    for start in stride(from:0,to:ids.count,by:100) {
                        do {
                            let result = try PrivateMCPHealth.payload(try await call("resolve_strategy_presentations",arguments:["workspaceId":workspace,"body":["strategyDeploymentIds":Array(ids[start..<min(ids.count,start+100)])]]))
                            var byHash: [String:String] = [:]
                            for item in result["presentations"] as? [[String:Any]] ?? [] { if let hash = item["contentHash"] as? String, let name = item["displayName"] as? String, !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { byHash[hash] = name } }
                            for item in result["deploymentBindings"] as? [[String:Any]] ?? [] { if let id = item["strategyDeploymentId"] as? String, let hash = item["contentHash"] as? String, let name = byHash[hash] { strategyNames[workspace + ":" + id] = name } }
                        } catch { detailWarning = "Strategienamen aktuell nicht verfügbar." }
                    }
                }
                snapshot.strategies = try? AlphaTraderStrategySummary.parse(strategyRows,names:strategyNames,workspaceNames:strategyWorkspaceNames)
            }
            if let leadershipFact { snapshot.facts.removeAll { $0.title == "Leadership" }; snapshot.facts.append(leadershipFact) }
        }
    }
    init(kind: PrivateMCPKind, defaults: UserDefaults = .standard, client: NativeMCPClient? = nil, permitted: Bool = PrivateMCPAccess.enabled) {
        self.kind = kind; self.defaults = defaults; self.permitted = permitted
        endpoint = defaults.string(forKey: "privateMCP.\(kind.rawValue).endpoint") ?? PrivateMCPAccess.configuration[kind.rawValue] ?? ""
        enabled = permitted && (defaults.object(forKey: "privateMCP.\(kind.rawValue).enabled") as? Bool ?? true)
        self.client = client
    }
    var critical: Bool { enabled && (needsLogin || error != nil || health?.healthy == false || (health != nil && stale) || strategyStatusUnavailable) }
    @Published private(set) var strategyStatusUnavailable = false
    var stale: Bool { needsLogin || signingIn || error != nil || health.map { Date().timeIntervalSince($0.checkedAt) > 180 } ?? true }
    var stateLabel: String { !enabled ? "Pausiert" : signingIn ? "Anmeldung läuft …" : needsLogin ? "Anmeldung erforderlich" : health == nil ? (busy ? "Verbindung wird geprüft …" : "Noch nicht verbunden") : stale ? "Letzter bestätigter Stand" : health!.title }
    func start() {
        guard permitted, enabled, polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }; await self.refresh()
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            }
        }
    }
    func stop() { polling?.cancel(); polling = nil; client?.cancel(); signingIn = false; authorizationURL = nil }
    func setEnabled(_ value: Bool) { guard permitted else { return }; enabled = value; defaults.set(value, forKey: "privateMCP.\(id).enabled"); if value { start() } else { stop() } }
    static func validatedEndpoint(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw CodexFailure(message: "Bitte eine HTTPS-MCP-Adresse ohne Zugangsdaten oder URL-Parameter eingeben.") }; return url
    }
    func configure(_ text: String) throws {
        guard permitted else { throw CodexFailure(message: "Diese Integration ist auf diesem Mac nicht freigeschaltet.") }
        let url = try Self.validatedEndpoint(text)
        guard url.absoluteString != endpoint else { return }
        stop(); client = nil
        platformFacts = []; leadershipFact = nil; strategyNames = [:]; strategyRows = []; strategyWorkspaceNames = [:]; namespaceHistory = []; namespaceWarning = nil
        namespaceAttempt = .distantPast; platformAttempt = .distantPast; leadershipAttempt = .distantPast; namesAttempt = .distantPast
        endpoint = url.absoluteString; defaults.set(endpoint, forKey: "privateMCP.\(id).endpoint"); health = nil; error = nil; needsLogin = false; start()
    }
    private func transport() throws -> NativeMCPClient {
        guard permitted, enabled else { throw CodexFailure(message: "Diese private Verbindung ist nicht freigeschaltet.") }
        if let client { return client }
        let client = NativeMCPClient(endpoint: try Self.validatedEndpoint(endpoint)); self.client = client; return client
    }
    @Published private(set) var namespaceHistory: [InfraNamespaceSample] = []
    @Published private(set) var namespaceWarning: String?
    func refresh() async {
        guard permitted, enabled, !busy, !signingIn else { return }
        busy = true; defer { busy = false }
        do {
            let tool = kind == .infrapilot ? "get_system_health" : "get_operational_health"
            let result = try await call(tool)
            var snapshot = try PrivateMCPHealth.parse(result, kind: kind)
            needsLogin = false
            var missing: [String] = []
            if kind == .infrapilot {
                snapshot.namespaces = health?.namespaces ?? []
                snapshot.facts += platformFacts
            } else {
                if let leadershipFact { snapshot.facts.append(leadershipFact) }
                do {
                    let storage = try PrivateMCPHealth.payload(try await call("get_database_storage"))
                    guard let used = storage["usedBytes"] as? Double, used.isFinite, used >= 0 else { throw CodexFailure(message: "Datenbankgröße fehlt") }
                    guard let validCapacity = storage["capacityBytes"] as? Double, validCapacity.isFinite, validCapacity > 0 else { throw CodexFailure(message: "Datenbankkapazität nicht prüfbar") }
                    let capacity: Double? = validCapacity
                    let fraction = capacity.flatMap { $0.isFinite && $0 > 0 ? min(1, used / $0) : nil }
                    snapshot.metrics.append(PrivateMCPMetric(title: "PostgreSQL", value: PrivateMCPHealth.bytes(used), detail: capacity.map { "von " + PrivateMCPHealth.bytes($0) } ?? "Kapazität nicht verfügbar", fraction: fraction, healthy: fraction.map { $0 < 0.85 }))
                    if let fraction, fraction >= 0.85 { snapshot.healthy = false; snapshot.title = "Datenbankspeicher knapp" }
                } catch { missing.append("Datenbankspeicher"); snapshot.healthy = false; snapshot.title = "Datenbankspeicher nicht prüfbar" }
            }
            if kind == .alphatrader {
                do {
                    let summary = try await strategySummary()
                    snapshot.strategies = summary; strategyStatusUnavailable = false
                    snapshot.stats = ["\(summary.total) Deployments", "\(summary.running) aktiv · \(summary.waiting) wartend", "\(summary.unhealthy) gestört"]
                    snapshot.metrics.insert(PrivateMCPMetric(title: "Aktive Deployments", value: String(summary.running), detail: "Verarbeiten Daten · PAPER und SHADOW"), at: 0)
                    snapshot.metrics.insert(PrivateMCPMetric(title: "Gestörte Deployments", value: String(summary.unhealthy), detail: "Fehler oder fehlender / abgelaufener Heartbeat", healthy: summary.unhealthy == 0), at: 1)
                    snapshot.metrics.insert(PrivateMCPMetric(title: "Wartende Deployments", value: String(summary.waiting), detail: "Heartbeat aktuell · warten auf Daten oder Auswertung"), at: 1)
                    snapshot.facts += [PrivateMCPFact(title: "Deployments insgesamt", value: String(summary.total)), PrivateMCPFact(title: "Im Start / Verbindungsaufbau", value: String(summary.starting)), PrivateMCPFact(title: "Pausiert / gestoppt", value: String(summary.paused)), PrivateMCPFact(title: "Status nicht eindeutig", value: String(summary.unknown))]
                    if summary.unhealthy > 0 { snapshot.healthy = false; snapshot.title = "Deployments prüfen" }
                } catch {
                    strategyStatusUnavailable = true; snapshot.healthy = false; snapshot.title = "Strategie-Status nicht verfügbar"; missing.append("Strategie-Status (" + error.localizedDescription + ")")
                    snapshot.stats.insert("Strategie-Status nicht verfügbar", at: 0)
                }
            }
            if kind == .alphatrader, let storage = snapshot.metrics.first(where: { $0.title == "PostgreSQL" }), let fraction = storage.fraction { snapshot.stats.append("DB \(Int((fraction * 100).rounded())) %") }
            detailWarning = missing.isEmpty ? nil : missing.joined(separator: ", ") + " aktuell nicht verfügbar. Die Basis-Health wurde bestätigt."
            await loadDetails(into:&snapshot)
            health = snapshot; error = nil
        } catch NativeMCPClient.Failure.loginRequired { needsLogin = true; error = nil }
        catch { self.error = "Verbindung oder Health-Abfrage fehlgeschlagen. " + error.localizedDescription }
    }
    private func strategySummary() async throws -> AlphaTraderStrategySummary {
        let workspaces = try PrivateMCPHealth.payload(try await call("list_workspaces"))
        guard let values = workspaces["workspaces"] as? [[String: Any]] else { throw CodexFailure(message: "Arbeitsbereiche fehlen.") }
        var rows: [(workspace: String, mode: String, runtime: [String: Any])] = []
        var workspaceNames: [String:String] = [:]
        for workspace in values {
            guard let id = workspace["workspaceId"] as? String else { throw CodexFailure(message: "Arbeitsbereich ohne Kennung.") }
            workspaceNames[id] = workspace["displayName"] as? String
            let shadow = try PrivateMCPHealth.payload(try await call("list_shadow_runtimes", arguments: ["workspaceId": id, "limit": 100]))
            let deployments = try PrivateMCPHealth.payload(try await call("list_portfolio_deployments", arguments: ["workspaceId": id, "limit": 100]))
            guard let runtimes = shadow["runtimes"] as? [[String: Any]], runtimes.count < 100,
                  let portfolios = deployments["portfolioDeployments"] as? [[String: Any]], portfolios.count < 100 else { throw CodexFailure(message: "Strategie-Liste unvollständig oder begrenzt.") }
            rows += runtimes.map { (id, "SHADOW", $0) }
            var paperIDs = Set<String>()
            for portfolio in portfolios where portfolio["executionMode"] as? String == "PAPER" {
                guard let allocations = portfolio["allocations"] as? [[String: Any]] else { throw CodexFailure(message: "PAPER-Zuordnung fehlt.") }
                for allocation in allocations { guard let strategy = allocation["strategyDeploymentId"] as? String else { throw CodexFailure(message: "Strategie-Zuordnung fehlt.") }; paperIDs.insert(strategy) }
            }
            for strategy in paperIDs.sorted() {
                let paper = try PrivateMCPHealth.payload(try await call("list_paper_runtimes", arguments: ["workspaceId": id, "strategyDeploymentId": strategy, "limit": 100]))
                guard let runtimes = paper["runtimes"] as? [[String: Any]], runtimes.count < 100 else { throw CodexFailure(message: "PAPER-Status unvollständig.") }
                rows += runtimes.map { (id, "PAPER", $0) }
            }
        }
        strategyRows = rows; strategyWorkspaceNames = workspaceNames
        return try AlphaTraderStrategySummary.parse(rows,names:strategyNames,workspaceNames:workspaceNames)
    }
    private func call(_ tool: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        guard permitted, enabled, kind.tools.contains(tool) else { throw CodexFailure(message: "Nur die freigegebenen Health-Werkzeuge sind verfügbar.") }
        return try await transport().call(tool, arguments: arguments)
    }
    func signIn() async {
        guard permitted, enabled, !signingIn, !busy else { return }
        signingIn = true; error = nil
        defer { signingIn = false; authorizationURL = nil }
        do {
            try await transport().signIn { [weak self] url in self?.authorizationURL = url; NSWorkspace.shared.open(url) }
            needsLogin = false
            // Refresh after clearing the UI's sign-in flag.
            signingIn = false; await refresh()
        } catch is CancellationError { }
        catch { needsLogin = true; self.error = "Anmeldung konnte nicht abgeschlossen werden. " + error.localizedDescription }
    }

}

@MainActor final class PrivateMCPStore: ObservableObject {
    static let shared = PrivateMCPStore()
    let services: [PrivateMCPService]
    private var subscriptions = Set<AnyCancellable>()
    init(services supplied: [PrivateMCPService]? = nil) {
        services = supplied ?? (PrivateMCPAccess.enabled ? PrivateMCPKind.allCases.map { PrivateMCPService(kind: $0) } : [])
        for service in services { service.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions) }
    }
    func start() { services.forEach { $0.start() } }
    func stop() { services.forEach { $0.stop() } }
    var criticalServices: [PrivateMCPService] { services.filter(\.critical) }
    func service(_ kind: PrivateMCPKind) -> PrivateMCPService? { services.first { $0.kind == kind } }
}
