import AppKit
import CoreGraphics

@main struct WindowOrderCheck {
    static func main() {
        if let front = NSWorkspace.shared.frontmostApplication {
            print("Frontmost: \(front.localizedName ?? "App") PID \(front.processIdentifier)")
        }
        let allowed = Set(CommandLine.arguments.dropFirst().compactMap(Int32.init))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for (order, window) in windows.enumerated() {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, allowed.contains(pid) else { continue }
            print("order=\(order) pid=\(pid) id=\(window[kCGWindowNumber as String] ?? "?") level=\(window[kCGWindowLayer as String] ?? "?")")
        }
    }
}
