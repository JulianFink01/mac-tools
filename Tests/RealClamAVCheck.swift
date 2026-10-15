import Foundation
@main
struct RealClamAVCheck {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let report = try ClamAVRunner().run(executable: root.appendingPathComponent("Vendor/ClamAV/bin/clamscan"),
            root: root.appendingPathComponent("build/virus-fixture"),
            extraArguments: ["--database=\(root.appendingPathComponent("build/clamav-database").path)",
                             "--cvdcertsdir=\(root.appendingPathComponent("Vendor/ClamAV/etc/certs").path)"])
        precondition(report.exitCode == 1 && report.findings.count == 1)
        precondition(report.findings[0].contains("Eicar-Test-Signature"))
        print("PASS: packaged engine plus real signatures detects harmless EICAR via the application's process runner")
        print(report.output)
    }
}
