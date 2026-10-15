import AppKit
import ApplicationServices

/// A retained display per pinned original. Its removal returns the window to
/// the real desktop, including on cancellation or a failed stream startup.
@MainActor final class VirtualWindowDisplay {
    private static var active: [CGDirectDisplayID: VirtualWindowDisplay] = [:]
    static var lastRestoration = "Noch kein Fenster zurückgeholt."
    private var object: UnsafeMutableRawPointer?
    private(set) var displayID: CGDirectDisplayID = 0
    private let window: AXUIElement
    private let savedFrame: CGRect
    private var moved = false
    private(set) var debugSummary = ""
    private(set) var sourceFrame: CGRect
    init(window: AXUIElement, frame: CGRect) {
        self.window = window; savedFrame = frame; sourceFrame = frame
    }
    func start() async throws {
        let width = UInt32(max(1280, ceil(savedFrame.width + 120)))
        let height = UInt32(max(960, ceil(savedFrame.height + 120)))
        guard let object = MTCreateWindowDisplay(width, height) else { throw issue("Die virtuelle Fensterfläche konnte nicht angelegt werden.") }
        self.object = object; displayID = MTWindowDisplayID(object)
        do {
            for _ in 0..<60 {
                try Task.checkCancellation()
                if CGDisplayIsActive(displayID) != 0, NSScreen.screens.contains(where: { Self.id($0) == displayID }) { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard CGDisplayIsActive(displayID) != 0 else { throw issue("Die virtuelle Fensterfläche wurde nicht registriert.") }
            // macOS may choose the unscaled default. Explicitly select the
            // Retina mode belonging to this display; physical displays remain untouched.
            if let all = CGDisplayCopyAllDisplayModes(displayID, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] { debugSummary = all.map { "\($0.width)x\($0.height)px\($0.pixelWidth)x\($0.pixelHeight)" }.joined(separator:",") }
            if let modes = CGDisplayCopyAllDisplayModes(displayID, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode],
               let retina = modes.first(where: { $0.width == Int(width) && $0.height == Int(height) && $0.pixelWidth >= Int(width)*2 }) {
                guard CGDisplaySetDisplayMode(displayID, retina, nil) == .success else { throw issue("Die Retina-Auflösung konnte nicht aktiviert werden.") }
            }
            for _ in 0..<20 {
                if let screen = NSScreen.screens.first(where: { Self.id($0) == displayID }), screen.backingScaleFactor >= 2 { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try Task.checkCancellation()
            let bounds = CGDisplayBounds(displayID)
            guard bounds.width >= savedFrame.width, bounds.height >= savedFrame.height else { throw issue("Die Fensterfläche ist für dieses Fenster zu klein.") }
            Self.active[displayID] = self
            // Arrange only owned displays to the right of the physical desktop.
            // Never rely on cached positions of a previous virtual screen.
            let physical = NSScreen.screens.filter { Self.active[Self.id($0)] == nil }.map { CGDisplayBounds(Self.id($0)) }
            var right = physical.map(\.maxX).max() ?? 0
            var expected: [CGDirectDisplayID: CGFloat] = [:]
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else { throw issue("Die Fensterfläche konnte nicht angeordnet werden.") }
            for id in Self.active.keys.sorted() {
                expected[id] = right
                guard CGConfigureDisplayOrigin(config,id,Int32(ceil(right)),0) == .success else { CGCancelDisplayConfiguration(config); throw issue("Die Fensterfläche konnte nicht angeordnet werden.") }
                right += CGDisplayBounds(id).width
            }
            guard CGCompleteDisplayConfiguration(config,.forSession) == .success else { throw issue("Die Fensterflächen konnten nicht angeordnet werden.") }
            right = expected[displayID] ?? right
            for _ in 0..<40 {
                try Task.checkCancellation()
                if abs(CGDisplayBounds(displayID).minX - right) < 2 { break }
                try await Task.sleep(nanoseconds:50_000_000)
            }
            let placed = CGDisplayBounds(displayID)
            guard placed.minX >= right - 1 else { throw issue("Die virtuelle Fläche liegt noch im sichtbaren Arbeitsbereich.") }
            var point = CGPoint(x: placed.minX + 60, y: placed.minY + 60)
            guard let position = AXValueCreate(.cgPoint, &point),
                  AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success else {
                throw issue("Dieses Programm erlaubt das Verschieben seines Fensters nicht.")
            }
            moved = true
            sourceFrame = CGRect(origin: point, size: savedFrame.size)
            // Adding a display can make macOS reposition windows belonging to
            // an earlier display. Re-anchor every retained original after registration.
            for owner in Self.active.values { owner.ensurePlacement() }
        } catch { stop(); throw error }
    }
    func ensurePlacement() {
        guard moved, displayID != 0, CGDisplayIsActive(displayID) != 0 else { return }
        var raw: CFTypeRef?, point = CGPoint.zero
        guard AXUIElementCopyAttributeValue(window,kAXPositionAttribute as CFString,&raw) == .success, let raw,
              AXValueGetValue(unsafeBitCast(raw,to:AXValue.self),.cgPoint,&point) else { return }
        let bounds = CGDisplayBounds(displayID)
        if !bounds.contains(CGRect(origin:point,size:sourceFrame.size)) {
            point = CGPoint(x:bounds.minX+60,y:bounds.minY+60)
            if let value = AXValueCreate(.cgPoint,&point) { AXUIElementSetAttributeValue(window,kAXPositionAttribute as CFString,value) }
        }
        sourceFrame.origin = point
    }
    func stop() {
        if moved {
            var point = savedFrame.origin
            // A monitor could have been unplugged during pinning. Keep the
            // restored title bar reachable on a currently physical display.
            let screens = NSScreen.screens.filter { Self.id($0) != displayID }
            let rectangles = screens.map { CGDisplayBounds(Self.id($0)) }
            if !rectangles.contains(where: { $0.contains(CGPoint(x: point.x + 30,y: point.y + 12)) }), let first = rectangles.first { point = CGPoint(x: first.minX + 60,y: first.minY + 60) }
            if let position = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) }
        }
        #if DEBUG
        var raw: CFTypeRef?, actual = CGPoint.zero
        if AXUIElementCopyAttributeValue(window,kAXPositionAttribute as CFString,&raw) == .success, let raw {
            AXValueGetValue(unsafeBitCast(raw,to:AXValue.self),.cgPoint,&actual)
        }
        Self.lastRestoration = "Zurückgeholt: AX=\(actual), vorher=\(savedFrame.origin), Fläche=\(displayID)"
        #endif
        moved = false
        Self.active.removeValue(forKey:displayID)
        if let object { MTReleaseWindowDisplay(object) }
        object = nil; displayID = 0
        Task { @MainActor in
            // Display removal notifications are asynchronous as well.
            try? await Task.sleep(nanoseconds:100_000_000)
            for owner in Self.active.values { owner.ensurePlacement() }
        }
    }
    private static func id(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    private func issue(_ message: String) -> NSError { NSError(domain: "MacTools.WindowDisplay",code: 1,userInfo: [NSLocalizedDescriptionKey: message]) }
}
