import Foundation
@main struct ContainerChecks {
    @MainActor static func main() async throws {
        let docker = RunningContainer.parse(#"{"ID":"abc123","Names":"web","Image":"nginx","Ports":"127.0.0.1:8080->80/tcp"}"#, runtime: "Docker")
        precondition(docker.count == 1 && docker[0].ports.contains("8080"))
        let podman = RunningContainer.parse(#"[{"Id":"def456","Names":["api"],"Ports":[{"host_ip":"127.0.0.1","host_port":3000,"container_port":80,"protocol":"tcp"}]}]"#, runtime: "Podman")
        precondition(podman.count == 1 && podman[0].ports == "127.0.0.1:3000 → 80/tcp")
        precondition(RunningContainer.parse(#"{"ID":"--all","Names":"bad"}"#, runtime: "Docker").isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mactools-container-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("docker"), output = directory.appendingPathComponent("out"), status = directory.appendingPathComponent("status")
        let script = "#!/bin/sh\ncat '" + output.path + "'\nexit $(cat '" + status.path + "')\n"
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let fixture = ContainerStore(runtimeCommands: [("Docker", cli)])
        try "0".write(to: status, atomically: true, encoding: .utf8)
        try #"{"ID":"abc123","Names":"web","Image":"nginx"}"#.write(to: output, atomically: true, encoding: .utf8)
        await fixture.refresh(); precondition(fixture.containers.count == 1 && fixture.refreshError == nil)
        try "1".write(to: status, atomically: true, encoding: .utf8)
        try "".write(to: output, atomically: true, encoding: .utf8)
        await fixture.refresh(); precondition(fixture.containers.count == 1 && fixture.refreshError != nil && fixture.error == nil)
        try "0".write(to: status, atomically: true, encoding: .utf8)
        try "truncated invalid json".write(to: output, atomically: true, encoding: .utf8)
        await fixture.refresh(); precondition(fixture.containers.count == 1 && fixture.refreshError != nil)
        try "[]".write(to: output, atomically: true, encoding: .utf8)
        await fixture.refresh(); precondition(fixture.containers.isEmpty && fixture.refreshError == nil)
        precondition(RunningContainer.snapshot("", runtime: "Docker") == [])
        print("PASS: real CLI failure and malformed output preserve the last confirmed containers; successful empty response clears them")
        let store = ContainerStore()
        await store.refresh()
        precondition(store.containers.contains { $0.name == "infrapilot-v2-control-plane" && $0.ports.contains("65018") })
        if let id = ProcessInfo.processInfo.environment["MACTOOLS_TEST_CONTAINER"] {
            guard let own = store.containers.first(where: { $0.containerID == id && $0.name.hasPrefix("mactools-qa-") }) else { fatalError("Own temporary test container missing") }
            await store.stop(own)
            precondition(store.error == nil && !store.containers.contains { $0.containerID == id }, store.error ?? "still running")
            print("PASS: actual temporary container stop and engine readback; existing container untouched")
        }
        print("PASS: Docker/Podman formats, invalid ID rejection, live Docker name and published port")
    }
}
