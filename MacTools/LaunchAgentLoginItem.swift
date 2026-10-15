import Foundation

enum LaunchAgentLoginItem {
    static let label = "com.julianfink.LiveWallpaper.login"
    static let launchArgument = "--livewallpaper-login-agent"

    private static var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    static var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist", isDirectory: false)
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func refreshInstalledAppPath() throws {
        guard isEnabled, Bundle.main.bundleURL.path.hasPrefix("/Applications/"),
              let executable = Bundle.main.executableURL,
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              arguments.first != executable.path else { return }
        try register()
    }

    static func register() throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw LoginAgentError.missingExecutable
        }

        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executableURL.path, launchArgument],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua"
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: [.atomic])

        try? runLaunchctl(arguments: ["bootout", userDomainServiceTarget])
        try runLaunchctl(arguments: ["bootstrap", userDomainTarget, plistURL.path])
    }

    static func unregister() throws {
        try? runLaunchctl(arguments: ["bootout", userDomainServiceTarget])

        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static var userDomainServiceTarget: String {
        "gui/\(getuid())/\(label)"
    }

    private static var userDomainTarget: String {
        "gui/\(getuid())"
    }

    private static func runLaunchctl(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LoginAgentError.launchctlFailed(message ?? "launchctl exited with status \(process.terminationStatus)")
        }
    }
}

private enum LoginAgentError: LocalizedError {
    case missingExecutable
    case launchctlFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "The app executable could not be found inside this bundle."
        case .launchctlFailed(let message):
            return message
        }
    }
}
