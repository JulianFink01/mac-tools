import AppKit
import Combine

struct RunningContainer: Identifiable, Equatable {
    let containerID: String
    let name: String
    let image: String
    let ports: String
    let runtime: String
    var id: String { runtime + ":" + containerID }
    var detail: String { runtime + " · " + (ports.isEmpty ? "Keine veröffentlichten Ports" : ports) }
    static func parse(_ output: String, runtime: String) -> [RunningContainer] {
        let records: [[String: Any]]
        if let data = output.data(using: .utf8), let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] { records = array }
        else { records = output.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } }
        return records.compactMap { json in
            guard let id = json["ID"] as? String ?? json["Id"] as? String, !id.isEmpty, id.allSatisfy({ $0.isHexDigit }) else { return nil }
            let name = json["Names"] as? String ?? (json["Names"] as? [String])?.joined(separator: ", ") ?? String(id.prefix(12))
            let bindings = (json["Ports"] as? [[String: Any]] ?? []).map { port -> String in
                let host = port["host_ip"] as? String ?? "0.0.0.0"
                let external = (port["host_port"] as? NSNumber)?.stringValue ?? ""
                let internalPort = (port["container_port"] as? NSNumber)?.stringValue ?? ""
                let proto = port["protocol"] as? String ?? "tcp"
                return (external.isEmpty || external == "0" ? "" : host + ":" + external + " → ") + internalPort + "/" + proto
            }.joined(separator: ", ")
            return RunningContainer(containerID: id, name: name, image: json["Image"] as? String ?? "", ports: json["Ports"] as? String ?? bindings, runtime: runtime)
        }
    }
    /// Only an authoritative, complete response may replace the previous snapshot.
    static func snapshot(_ output: String, runtime: String) -> [RunningContainer]? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [] }
        let count: Int
        if let data = text.data(using: .utf8), let records = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] { count = records.count }
        else {
            let lines = text.split(separator: "\n")
            guard lines.allSatisfy({ line in
                guard let data = String(line).data(using: .utf8) else { return false }
                return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
            }) else { return nil }
            count = lines.count
        }
        let parsed = parse(text, runtime: runtime)
        return parsed.count == count ? parsed : nil
    }
}

@MainActor
final class ContainerStore: ObservableObject {
    static let shared = ContainerStore()
    @Published private(set) var containers: [RunningContainer] = []
    @Published private(set) var stopping = Set<String>()
    @Published var error: String?
    @Published private(set) var refreshError: String?
    @Published private(set) var refreshedAt: Date?
    private var task: Task<Void, Never>?
    private var refreshing = false
    private let runtimeCommands: [(String, URL)]?
    init(runtimeCommands: [(String, URL)]? = nil) { self.runtimeCommands = runtimeCommands }
    private var runtimes: [(String, URL)] {
        runtimeCommands ?? ([("Docker", ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]),
         ("Podman", ["/opt/homebrew/bin/podman", "/usr/local/bin/podman", NSHomeDirectory() + "/.local/bin/podman"])]
            .compactMap { name, paths in paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { (name, URL(fileURLWithPath: $0)) } })
    }
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
    func refresh() async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        var found: [RunningContainer] = [], failed: [String] = []
        let available = runtimes
        for (name, executable) in available {
            let response = await LocalCommand.run(executable, arguments: ["ps", "--no-trunc", "--format", name == "Podman" ? "json" : "{{json .}}"])
            if response.status == 0, let snapshot = RunningContainer.snapshot(response.output, runtime: name) { found += snapshot }
            else {
                found += containers.filter { $0.runtime == name }
                failed.append(name)
            }
        }
        // A temporarily unavailable CLI is not evidence that its containers stopped.
        let unavailable = containers.filter { item in !available.contains { $0.0 == item.runtime } }
        found += unavailable
        failed += Set(unavailable.map(\.runtime)).sorted()
        let ordered = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if containers != ordered { containers = ordered }
        refreshError = failed.isEmpty ? nil : failed.joined(separator: ", ") + " vorübergehend nicht erreichbar · letzter bestätigter Stand"
        if failed.isEmpty { refreshedAt = Date() }
    }

    func stop(_ container: RunningContainer) async {
        guard !stopping.contains(container.id), containers.contains(where: { $0.id == container.id }), let executable = runtimes.first(where: { $0.0 == container.runtime })?.1 else { return }
        stopping.insert(container.id); error = nil; defer { stopping.remove(container.id) }
        let result = await LocalCommand.run(executable, arguments: ["stop", "--time", "10", container.containerID], timeout: 20)
        if result.status != 0 { error = "\(container.name) konnte nicht gestoppt werden: " + String(result.error.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)) }
        await refresh()
        if result.status == 0 && containers.contains(where: { $0.id == container.id }) { error = "Der Stopp von \(container.name) ist noch nicht bestätigt." }
    }
}
