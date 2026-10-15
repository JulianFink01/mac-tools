import AppKit
import CoreGraphics
import Foundation

// Read the WindowServer's actual levels for one explicitly selected process.
// This does not capture pixels or change any application's windows.
guard CommandLine.arguments.count == 3, let pid = Int(CommandLine.arguments[1]),
      ["floating", "normal"].contains(CommandLine.arguments[2]) else {
    fputs("usage: window-level-check PID floating|normal\n", stderr)
    exit(64)
}
guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    fputs("WindowServer metadata unavailable\n", stderr); exit(2)
}
let windows = info.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
let rows = windows.map { ["window": $0[kCGWindowNumber as String] as? Int ?? -1,
                         "level": $0[kCGWindowLayer as String] as? Int ?? -1] }
print(String(data: try JSONSerialization.data(withJSONObject: rows, options: .sortedKeys), encoding: .utf8)!)
guard !windows.isEmpty else { fputs("No visible windows for the requested process\n", stderr); exit(3) }
let hasFloatingWindow = rows.contains { $0["level"] == NSWindow.Level.floating.rawValue }
let expected = CommandLine.arguments[2] == "floating"
guard hasFloatingWindow == expected else { fputs("Unexpected floating-window state\n", stderr); exit(1) }
print("PASS: actual WindowServer level matches \(CommandLine.arguments[2])")
