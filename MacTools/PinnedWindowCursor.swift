import AppKit
import ApplicationServices

/// Native input occurs on the pinned original's private display. ScreenCaptureKit
/// includes the native cursor; this observer only handles escape and view edges.
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
    private var entryGate = PinnedCursorEntryGate()
    private lazy var forwardingSource: CGEventSource? = {
        let source = CGEventSource(stateID:.combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        let all: CGEventFilterMask = [.permitLocalMouseEvents,.permitLocalKeyboardEvents,.permitSystemDefinedEvents]
        source?.setLocalEventsFilterDuringSuppressionState(all,state:.eventSuppressionStateSuppressionInterval)
        source?.setLocalEventsFilterDuringSuppressionState(all,state:.eventSuppressionStateRemoteMouseDrag)
        return source
    }()
    #if DEBUG
    private var pointerStatus = ""
    #endif
    init(view: NSView, window: AXUIElement, pid: pid_t, displayID: @escaping () -> CGDirectDisplayID, sourceFrame: @escaping () -> CGRect) {
        self.view = view; self.displayID = displayID; sourceWindow = window; self.pid = pid; self.sourceFrame = sourceFrame
    }
    func enter(at local: CGPoint, explicitInput: Bool = false) -> Bool {
        if active { return true }
        let frame = sourceFrame()
        // Validate passive entry against the current pointer, not an AppKit
        // movement queued before the return warp. No timed re-entry lockout.
        let entryLocation: CGPoint
        if explicitInput { entryLocation = local }
        else {
            guard let view, let window = view.window, let pointer = CGEvent(source:nil)?.location else { return false }
            let screen = CGPoint(x:pointer.x, y:CGDisplayBounds(CGMainDisplayID()).height-pointer.y)
            entryLocation = view.convert(window.convertPoint(fromScreen:screen), from:nil)
        }
        let mapped = sourcePoint(entryLocation)
        guard entryGate.admit(inside:mapped != nil,explicit:explicitInput), displayID() != 0,
              CGDisplayBounds(displayID()).contains(CGPoint(x:frame.midX,y:frame.midY)),
              let view, let point = mapped else { return false }
        guard installTap() else { onIssue?("Die native Maussteuerung konnte nicht gestartet werden. Prüfe den Bedienungshilfen-Zugriff."); return false }
        previousPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        active = true; lastSourcePoint = point
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] notice in
            guard let app = notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let self, self.active else { return }
            // Switching applications must immediately return the physical cursor.
            if app.processIdentifier != self.pid,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { self.leave(restoreFocus: false) }
        }
        #if DEBUG
        let focusStart = ProcessInfo.processInfo.systemUptime
        #endif
        AXUIElementPerformAction(sourceWindow, kAXRaiseAction as CFString)
        #if DEBUG
        let raiseEnd = ProcessInfo.processInfo.systemUptime
        #endif
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        #if DEBUG
        let activationEnd = ProcessInfo.processInfo.systemUptime
        #endif
        movePointer(to:point)
        #if DEBUG
        let pointerEnd = ProcessInfo.processInfo.systemUptime
        view.setAccessibilityHelp(pointerStatus + String(format:"; raise=%.1f ms, activate=%.1f ms, move=%.1f ms",
            (raiseEnd-focusStart)*1000,(activationEnd-raiseEnd)*1000,(pointerEnd-activationEnd)*1000))
        #endif
        view.setAccessibilityValue("Native Maus auf virtueller Fläche aktiv. Escape beendet die Bedienung.")
        return true
    }
    private func installTap() -> Bool {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); return true }
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
        // Button events remain completely native. Only actual pointer motion
        // decides whether to leave the view, never a queued click location.
        guard [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type) else { return }
        let frame = sourceFrame()
        lastSourcePoint = event.location
        let delta = CGPoint(x:CGFloat(event.getIntegerValueField(.mouseEventDeltaX)), y:CGFloat(event.getIntegerValueField(.mouseEventDeltaY)))
        guard PinnedCursorGeometry.exitPoint(at:event.location,delta:delta,frame:frame) != nil else { return }
        // An old event from the physical desktop may reach the observer after
        // entry. Only leave if the pointer is actually at/outside a source edge.
        let current = CGEvent(source:nil)?.location ?? event.location
        lastSourcePoint = current
        if let outside = PinnedCursorGeometry.exitPoint(at: current, delta: delta, frame: frame) {
            lastSourcePoint = outside; leave()
        }
    }
    private var scale: CGFloat {
        guard let view else { return 1 }
        let frame = sourceFrame()
        return min(view.bounds.width / max(1,frame.width), view.bounds.height / max(1,frame.height))
    }
    private func sourcePoint(_ local: CGPoint) -> CGPoint? {
        guard let view else { return nil }
        return PinnedCursorGeometry.sourcePoint(local, bounds:view.bounds, frame:sourceFrame())
    }
    /// AppKit may already have routed the entering click to the preview before
    /// the pointer crosses to the private display. Preserve that click instead
    /// of consuming it. Subsequent hardware input goes directly to the original.
    func forwardPreviewEvent(_ event: NSEvent, at local: CGPoint) {
        guard enter(at: local, explicitInput: true), let point = sourcePoint(local), let original = event.cgEvent else { return }
        // A preview-routed gesture can arrive at a new position while native
        // control is already active. Scroll routing uses the actual pointer.
        movePointer(to:point)
        if event.type == .scrollWheel {
            // Do not copy AppKit's old destination-window annotations.
            guard let forwarded = CGEvent(scrollWheelEvent2Source:forwardingSource,
                units:event.hasPreciseScrollingDeltas ? .pixel : .line, wheelCount:2,
                wheel1:Int32(clamping:Int(event.scrollingDeltaY)),
                wheel2:Int32(clamping:Int(event.scrollingDeltaX)),wheel3:0) else { return }
            forwarded.location = point
            forwarded.flags = original.flags
            for field: CGEventField in [.scrollWheelEventScrollPhase, .scrollWheelEventMomentumPhase, .scrollWheelEventScrollCount,
                                       .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2] {
                forwarded.setIntegerValueField(field, value: original.getIntegerValueField(field))
            }
            for field: CGEventField in [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2] {
                forwarded.setDoubleValueField(field, value: original.getDoubleValueField(field))
            }
            forwarded.post(tap: .cghidEventTap)
            #if DEBUG
            view?.setAccessibilityValue("Scroll forwarded source=\(point) dy=\(event.scrollingDeltaY)")
            #endif
            return
        }
        guard
              let forwarded = CGEvent(mouseEventSource: forwardingSource, mouseType: original.type, mouseCursorPosition: point,
                                      mouseButton: CGMouseButton(rawValue: UInt32(event.buttonNumber)) ?? .left) else { return }
        forwarded.flags = original.flags
        forwarded.setIntegerValueField(.mouseEventClickState, value: Int64(event.clickCount))
        forwarded.setDoubleValueField(.mouseEventPressure, value: Double(event.pressure))
        forwarded.post(tap: .cghidEventTap)
        #if DEBUG
        view?.setAccessibilityValue("Forwarded \(original.type.rawValue) local=\(local) source=\(point)")
        #endif
    }
    func leave(restoreFocus: Bool = true) {
        guard active else { return }
        active = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }; activationObserver = nil
        if let view, let window = view.window {
            let frame = sourceFrame(), factor = scale
            let local = CGPoint(x:(view.bounds.width-frame.width*factor)/2+(lastSourcePoint.x-frame.minX)*factor,
                                y:(view.bounds.height-frame.height*factor)/2+(lastSourcePoint.y-frame.minY)*factor)
            let returned = PinnedCursorGeometry.returnPoint(local, bounds:view.bounds,source:lastSourcePoint,frame:frame,
                inset:1 / max(1,window.backingScaleFactor))
            entryGate.returned(inside:PinnedCursorGeometry.sourcePoint(returned,bounds:view.bounds,frame:frame) != nil)
            let inWindow = view.convert(returned, to:nil)
            let screen = window.convertPoint(toScreen: inWindow)
            let height = NSScreen.screens.first?.frame.maxY ?? 0
            movePointer(to:CGPoint(x:screen.x,y:height-screen.y))
            view.setAccessibilityValue("Native Maus zurück auf dem normalen Bildschirm.")
        }
        if restoreFocus, let previousPID, previousPID != pid { NSRunningApplication(processIdentifier:previousPID)?.activate(options:[]) }
        previousPID = nil
    }
    private func movePointer(to point: CGPoint) {
        // CGWarp has no event source. On macOS versions where re-association
        // alone fails, it freezes the cursor for 250 ms despite live HID deltas.
        // Scope the legacy compatibility setting to this call, as Wine does in
        // macdrv_set_cursor_position; source-level suppression covers posted
        // preview clicks/scrolls separately. Never leave the setting at zero.
        _ = MTSetCursorWarpSuppression(0)
        let warp = CGWarpMouseCursorPosition(point)
        _ = MTSetCursorWarpSuppression(0.25)
        // Match SDL/GLFW's Cocoa cursor path: a warp can temporarily suppress
        // native movement. Re-associate immediately, before any other work.
        let resume = CGAssociateMouseAndMouseCursorPosition(1)
        #if DEBUG
        pointerStatus = "Mausübergabe: warp=\(warp.rawValue), resume=\(resume.rawValue)"
        view?.setAccessibilityHelp(pointerStatus)
        #endif
    }
    func previewExited() {
        guard !active, let view, let window = view.window, let pointer = CGEvent(source:nil)?.location else { return }
        let screen = CGPoint(x:pointer.x,y:CGDisplayBounds(CGMainDisplayID()).height-pointer.y)
        let local = view.convert(window.convertPoint(fromScreen:screen),from:nil)
        _ = entryGate.admit(inside:sourcePoint(local) != nil,explicit:false)
    }
    func stop() {
        leave()
        if let tap { CGEvent.tapEnable(tap:tap,enable:false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(),runLoopSource,.commonModes) }
        tap = nil; runLoopSource = nil
    }
    deinit { if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }; if let tap { CFMachPortInvalidate(tap) } }
}

/// Escape/app switching waits for an actual exit; boundary crossing does not
/// impose a time limit on the next real entry. Explicit clicks always work.
struct PinnedCursorEntryGate {
    private var requiresExit = false
    mutating func returned(inside: Bool) { requiresExit = inside }
    mutating func admit(inside: Bool, explicit: Bool) -> Bool {
        if !inside { requiresExit = false; return false }
        if explicit { requiresExit = false }
        return !requiresExit
    }
}

/// Pure edge rules shared by entry/exit handling and regression checks.
enum PinnedCursorGeometry {
    static func sourcePoint(_ local: CGPoint, bounds: CGRect, frame: CGRect) -> CGPoint? {
        guard !bounds.isEmpty, !frame.isEmpty else { return nil }
        let factor = min(bounds.width/frame.width,bounds.height/frame.height)
        let x = (local.x-bounds.minX-(bounds.width-frame.width*factor)/2)/factor
        let y = (local.y-bounds.minY-(bounds.height-frame.height*factor)/2)/factor
        guard x>=0,y>=0,x<frame.width,y<frame.height else { return nil }
        return CGPoint(x:frame.minX+x,y:frame.minY+y)
    }
    static func exitPoint(at point: CGPoint, delta: CGPoint, frame: CGRect) -> CGPoint? {
        guard !frame.isEmpty else { return point }
        if !frame.contains(point) { return point }
        // macOS clamps the native pointer at display edges. An outward motion
        // still needs to leave the preview even when its location cannot move.
        if delta.x < 0 && point.x <= frame.minX + 1 { return CGPoint(x: frame.minX - 1, y: point.y) }
        if delta.x > 0 && point.x >= frame.maxX - 1 { return CGPoint(x: frame.maxX + 1, y: point.y) }
        if delta.y < 0 && point.y <= frame.minY + 1 { return CGPoint(x: point.x, y: frame.minY - 1) }
        if delta.y > 0 && point.y >= frame.maxY - 1 { return CGPoint(x: point.x, y: frame.maxY + 1) }
        return nil
    }
    static func returnPoint(_ local: CGPoint, bounds: CGRect, source: CGPoint, frame: CGRect, inset: CGFloat = 0.5) -> CGPoint {
        var result = local
        if source.x < frame.minX { result.x = bounds.minX - inset }
        if source.x >= frame.maxX { result.x = bounds.maxX + inset }
        if source.y < frame.minY { result.y = bounds.minY - inset }
        if source.y >= frame.maxY { result.y = bounds.maxY + inset }
        return result
    }
}
