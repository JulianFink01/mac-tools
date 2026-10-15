import AppKit
import Darwin
import ApplicationServices

/// Native original-window experiment. No capture, injection, helper, or security changes.
/// WindowServer must authorize the operation and the public window list must confirm it.
enum OriginalWindowLevel {
    private typealias Connection = @convention(c) () -> Int32
    private typealias SetLevel = @convention(c) (Int32, UInt32, Int32) -> Int32
    private static let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    static func level(of id: CGWindowID) -> Int32? {
        guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let item = windows.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == id }),
              let level = item[kCGWindowLayer as String] as? NSNumber else { return nil }
        return level.int32Value
    }
    static func set(_ level: Int32, window: CGWindowID) throws {
        guard let library, let connectionSymbol = dlsym(library, "SLSMainConnectionID"),
              let setSymbol = dlsym(library, "SLSSetWindowLevel") else { throw LevelError.unavailable }
        let connection = unsafeBitCast(connectionSymbol, to: Connection.self)
        let setLevel = unsafeBitCast(setSymbol, to: SetLevel.self)
        let previous = self.level(of: window)
        let error = setLevel(connection(), window, level)
        let observed = self.level(of: window)
        guard error == 0, observed == level else {
            if let previous, observed != previous { _ = setLevel(connection(), window, previous) }
            throw LevelError.denied(error, observed)
        }
    }
    enum LevelError: LocalizedError {
        case unavailable, denied(Int32, Int32?)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Diese macOS-Version stellt die native Fensterfunktion nicht bereit."
            case .denied(let code, let observed):
                return "macOS verweigert die schwebende Ebene des Originalfensters (WindowServer-Code \(code), tatsächliche Ebene \(observed.map(String.init) ?? "unbekannt")). Der Systemschutz wurde nicht verändert."
            }
        }
    }
}

/// Associate accessibility windows by their real WindowServer identity.
/// Frame/title matching is only a fallback on systems without this accessor.
enum NativeWindowIdentity {
    private typealias Number = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32
    private static let number: Number? = {
        guard let library = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let symbol = dlsym(library, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: Number.self)
    }()
    static func id(_ window: AXUIElement) -> CGWindowID? {
        guard let number else { return nil }
        var value: UInt32 = 0
        return number(window, &value) == 0 && value != 0 ? value : nil
    }
}
