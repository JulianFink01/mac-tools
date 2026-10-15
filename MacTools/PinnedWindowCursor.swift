import AppKit
import ApplicationServices

/// Native input occurs on the pinned original’s private display. The visible
/// pointer is a layer of the preview, never a separate always-front window.
final class PinnedWindowCursor {
    weak var view: NSView?
    var sourceFrame: () -> CGRect
    let displayID: () -> CGDirectDisplayID
    var onIssue: ((String) -> Void)?
    let sourceWindow: AXUIElement
    let pid: pid_t
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var previousPID: pid_t?
    private var active = false
    private var activationObserver: NSObjectProtocol?
    private var lastSourcePoint = CGPoint.zero
    private let cursorLayer = CAShapeLayer()
    init(view: NSView, window: AXUIElement, pid: pid_t, displayID: @escaping () -> CGDirectDisplayID, sourceFrame: @escaping () -> CGRect) {
        self.view = view; self.displayID = displayID; sourceWindow = window; self.pid = pid; self.sourceFrame = sourceFrame
        let path = CGMutablePath()
        path.move(to: .zero)
        for point in [CGPoint(x:0,y:18),CGPoint(x:4,y:14),CGPoint(x:8,y:21),CGPoint(x:11,y:19),CGPoint(x:7,y:12),CGPoint(x:13,y:12)] { path.addLine(to: point) }
        path.closeSubpath()
        cursorLayer.path = path; cursorLayer.fillColor = NSColor.black.cgColor
        cursorLayer.strokeColor = NSColor.white.cgColor; cursorLayer.lineWidth = 1.2
        cursorLayer.zPosition = 100; cursorLayer.isHidden = true
        view.layer?.addSublayer(cursorLayer)
    }
    func enter(at local: CGPoint) -> Bool {
        if active { return true }
        let frame = sourceFrame()
        guard displayID() != 0, CGDisplayBounds(displayID()).contains(CGPoint(x:frame.midX,y:frame.midY)),
              let view, let point = sourcePoint(local) else { return false }
        guard installTap() else { onIssue?("Die native Maussteuerung konnte nicht gestartet werden. Prüfe den Bedienungshilfen-Zugriff."); return false }
        previousPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        active = true; lastSourcePoint = point
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] notice in
            guard let app = notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let self, self.active else { return }
            // Switching applications must immediately return the physical cursor.
            if app.processIdentifier != self.pid { self.leave(restoreFocus: false) }
        }
        AXUIElementPerformAction(sourceWindow, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        CGWarpMouseCursorPosition(point)
        draw(at: point)
        view.setAccessibilityValue("Native Maus auf virtueller Fläche aktiv. Escape beendet die Bedienung.")
        return true
    }
    private func installTap() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged,.leftMouseDown,.rightMouseDown,.leftMouseUp,.rightMouseUp,.keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
            if let context { Unmanaged<PinnedWindowCursor>.fromOpaque(context).takeUnretainedValue().observe(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }
    private func observe(type: CGEventType, event: CGEvent) {
        guard active else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; return
        }
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { leave() }
            return
        }
        lastSourcePoint = event.location
        // A single transition back to the real desktop at the view edge.
        if !sourceFrame().contains(event.location) { leave(); return }
        draw(at: event.location)
    }
    private var scale: CGFloat {
        guard let view else { return 1 }
        let frame = sourceFrame()
        return min(view.bounds.width / max(1,frame.width), view.bounds.height / max(1,frame.height))
    }
    private func sourcePoint(_ local: CGPoint) -> CGPoint? {
        guard let view else { return nil }
        let frame = sourceFrame(), factor = scale
        let x = (local.x-(view.bounds.width-frame.width*factor)/2)/factor
        let y = (local.y-(view.bounds.height-frame.height*factor)/2)/factor
        guard x>=0,y>=0,x<frame.width,y<frame.height else { return nil }
        return CGPoint(x:frame.minX+x,y:frame.minY+y)
    }
    private func draw(at point: CGPoint) {
        guard let view else { return }
        let frame = sourceFrame(), factor = scale
        let local = CGPoint(x:(view.bounds.width-frame.width*factor)/2+(point.x-frame.minX)*factor,
                            y:(view.bounds.height-frame.height*factor)/2+(point.y-frame.minY)*factor)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cursorLayer.position = local; cursorLayer.isHidden = false
        CATransaction.commit()
    }
    func leave(restoreFocus: Bool = true) {
        guard active else { return }
        active = false; cursorLayer.isHidden = true
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }; activationObserver = nil
        if let view, let window = view.window {
            let frame = sourceFrame(), factor = scale
            let local = CGPoint(x:(view.bounds.width-frame.width*factor)/2+(lastSourcePoint.x-frame.minX)*factor,
                                y:(view.bounds.height-frame.height*factor)/2+(lastSourcePoint.y-frame.minY)*factor)
            let inWindow = view.convert(local, to:nil)
            let screen = window.convertPoint(toScreen: inWindow)
            let height = NSScreen.screens.first?.frame.maxY ?? 0
            CGWarpMouseCursorPosition(CGPoint(x:screen.x,y:height-screen.y))
            view.setAccessibilityValue("Native Maus zurück auf dem normalen Bildschirm.")
        }
        if restoreFocus, let previousPID, previousPID != pid { NSRunningApplication(processIdentifier:previousPID)?.activate(options:[]) }
        previousPID = nil
    }
    func stop() {
        leave()
        if let tap { CGEvent.tapEnable(tap:tap,enable:false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(),runLoopSource,.commonModes) }
        tap = nil; runLoopSource = nil
    }
    deinit { if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }; if let tap { CFMachPortInvalidate(tap) } }
}
