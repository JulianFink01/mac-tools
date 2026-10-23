import AppKit
import ApplicationServices
import ScreenCaptureKit
import AVFoundation
import Darwin
import Carbon

private final class PinnedInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One independently retained live panel per selected source window. No recording or uploads.
@MainActor
final class LivePinnedWindow: NSObject, NSWindowDelegate, SCStreamDelegate {
    let source: SCWindow
    let panel: NSPanel
    private let preview: PinnedPreview
    private let axWindow: AXUIElement
    private var stream: SCStream?
    private var stopped = false
    private var ready = false
    private var sourceSize: CGSize
    private var frameOutput: PinnedFrameOutput?
    private var configurationTask: Task<Void, Never>?
    private let windowDisplay: VirtualWindowDisplay
    var onClose: (() -> Void)?
    var onError: ((String) -> Void)?
    var onInputIssue: ((String) -> Void)? { didSet { preview.onInputIssue = onInputIssue } }

    init(source: SCWindow, axWindow: AXUIElement) {
        self.source = source
        self.axWindow = axWindow
        windowDisplay = VirtualWindowDisplay(window: axWindow, frame: source.frame, safeMode: source.frame.width > 1536 || source.frame.height > 960)
        sourceSize = source.frame.size
        let width = min(680, max(280, source.frame.width))
        let height = max(160, width * source.frame.height / max(1, source.frame.width))
        panel = PinnedInputPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        preview = PinnedPreview(pid: source.owningApplication!.processID, window: axWindow, display: windowDisplay, sourceFrame: source.frame)
        super.init()
        panel.title = "Live · " + (source.owningApplication?.applicationName ?? "Fenster") + " · " + (source.title ?? "")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.sharingType = .readOnly
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true
        panel.contentMinSize = NSSize(width: 240, height: 120)
        panel.contentAspectRatio = NSSize(width: max(1, source.frame.width), height: max(1, source.frame.height))
        panel.contentView = preview
        panel.delegate = self
        let original = NSButton(title: "Original öffnen", target: self, action: #selector(openOriginal))
        original.bezelStyle = .rounded
        original.frame = NSRect(x: 0, y: 0, width: 128, height: 24)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = original
        accessory.layoutAttribute = .right
        panel.addTitlebarAccessoryViewController(accessory)
        panel.center()
        // Offset additional panels instead of hiding them underneath the previous one.
        let offset = CGFloat(WindowPinController.shared.pinnedWindows.count % 6) * 28
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + offset, y: panel.frame.minY - offset))
    }

    @objc func openOriginal() {
        guard let pid = source.owningApplication?.processID else { return }
        // Opening the original ends pinning and removes its private display.
        // A native original and its preview must never remain side by side.
        stop()
        onClose?()
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
    }

    func start() async throws {
        try await windowDisplay.start()
        preview.sourceFrame = windowDisplay.sourceFrame
        sourceSize = windowDisplay.sourceFrame.size
        let config = configuration(size: sourceSize)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: source), configuration: config, delegate: self)
        self.stream = stream
        let output = PinnedFrameOutput(layer: preview.displayLayer)
        frameOutput = output
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        if stopped { try? await stream.stopCapture(); return }
        ready = true
        preview.startInput()
        panel.orderFrontRegardless()
    }

    func show() { if ready && !stopped { panel.makeKeyAndOrderFront(nil) } }

    private func configuration(size: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // Capture enough pixels for the visible Retina preview, rather than
        // processing a full 4K original for a 680-point floating window.
        let visible = preview.bounds.size
        let factor = min(2, 2560 / max(1, visible.width), 2160 / max(1, visible.height))
        let width = max(480, visible.width * factor)
        let ratio = size.height / max(1, size.width)
        config.width = max(2, Int(min(size.width * 2, width)))
        config.height = max(2, Int(CGFloat(config.width) * ratio))
        config.scalesToFit = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3
        config.showsCursor = true
        config.capturesAudio = false
        if #available(macOS 14.0, *) {
            config.ignoreShadowsSingleWindow = true
            config.ignoreGlobalClipSingleWindow = true
        }
        return config
    }

    func ensureSourcePlacement() { windowDisplay.ensurePlacement() }

    func updateSourceFrame(_ frame: CGRect) {
        guard ready else { return }
        preview.sourceFrame = frame
        #if DEBUG
        preview.updateInputGeometryLabel()
        #endif
        guard frame.size != sourceSize else { return }
        sourceSize = frame.size
        let top = panel.frame.maxY
        let width = panel.contentView?.bounds.width ?? 680
        panel.contentAspectRatio = NSSize(width: max(1, frame.width), height: max(1, frame.height))
        panel.setContentSize(NSSize(width: width, height: max(120, width * frame.height / max(1, frame.width))))
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
        scheduleConfiguration()
    }

    private func scheduleConfiguration() {
        configurationTask?.cancel()
        guard !stopped, stream != nil else { return }
        configurationTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 150_000_000); try Task.checkCancellation() }
            catch { return }
            guard let self, !self.stopped else { return }
            try? await self.stream?.updateConfiguration(self.configuration(size: self.sourceSize))
        }
    }
    func windowDidResize(_ notification: Notification) {
        scheduleConfiguration()
        #if DEBUG
        preview.updateInputGeometryLabel()
        #endif
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        configurationTask?.cancel(); configurationTask = nil
        preview.stopInput()
        windowDisplay.stop()
        panel.orderOut(nil)
        frameOutput?.stop(); frameOutput = nil
        let active = stream; stream = nil
        Task { try? await active?.stopCapture() }
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
    #if DEBUG
    func windowDidMove(_ notification: Notification) { preview.updateInputGeometryLabel() }
    #endif

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            self.onError?(error.localizedDescription)
        }
    }
}

/// The original receives native hardware input on its own display, including
/// its native cursor captured by ScreenCaptureKit.
private final class PinnedPreview: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    let pid: pid_t
    let sourceWindow: AXUIElement
    let windowDisplay: VirtualWindowDisplay
    var sourceFrame: CGRect
    var onInputIssue: ((String) -> Void)? { didSet { cursor.onIssue = onInputIssue } }
    private var tracking: NSTrackingArea?
    private var inputStopped = true
    private lazy var cursor: PinnedWindowCursor = {
        let value = PinnedWindowCursor(view: self, window: sourceWindow, pid: pid,
            displayID: { [weak self] in self?.windowDisplay.displayID ?? 0 },
            sourceFrame: { [weak self] in self?.sourceFrame ?? .zero })
        return value
    }()
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }
    init(pid: pid_t, window: AXUIElement, display: VirtualWindowDisplay, sourceFrame: CGRect) {
        self.pid = pid; sourceWindow = window; windowDisplay = display; self.sourceFrame = sourceFrame
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Angeheftetes Live-Fenster. Native Bedienung auf eigener Fensterfläche. Escape kehrt zum normalen Bildschirm zurück.")
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout(); displayLayer.frame = bounds
        #if DEBUG
        updateInputGeometryLabel()
        #endif
    }
    #if DEBUG
    func updateInputGeometryLabel() {
        let mode = CGDisplayCopyDisplayMode(windowDisplay.displayID)
        setAccessibilityLabel("Angeheftetes Live-Fenster. DEBUG source=\(NSStringFromRect(sourceFrame)) display=\(windowDisplay.displayID) modes=\(windowDisplay.debugSummary) mode=\(mode.map { "\($0.width)x\($0.height) pixels=\($0.pixelWidth)x\($0.pixelHeight)" } ?? "none")")
    }
    #endif
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    private func enter(_ event: NSEvent) {
        guard !inputStopped else { return }
        _ = cursor.enter(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseEntered(with event: NSEvent) { enter(event) }
    override func mouseMoved(with event: NSEvent) { enter(event) }
    override func mouseExited(with event: NSEvent) { cursor.previewExited() }
    private func forward(_ event: NSEvent) {
        guard !inputStopped else { return }
        cursor.forwardPreviewEvent(event, at: convert(event.locationInWindow, from:nil))
    }
    override func mouseDown(with event: NSEvent) { forward(event) }
    override func mouseUp(with event: NSEvent) { forward(event) }
    override func rightMouseDown(with event: NSEvent) { forward(event) }
    override func rightMouseUp(with event: NSEvent) { forward(event) }
    override func otherMouseDown(with event: NSEvent) { forward(event) }
    override func otherMouseUp(with event: NSEvent) { forward(event) }
    override func mouseDragged(with event: NSEvent) { forward(event) }
    override func rightMouseDragged(with event: NSEvent) { forward(event) }
    override func otherMouseDragged(with event: NSEvent) { forward(event) }
    override func scrollWheel(with event: NSEvent) { forward(event) }
    // The native mouse-exit caused by entering the private display is expected;
    // the observer returns it only when the translated cursor leaves the view.
    func startInput() {
        inputStopped = false
    }
    func stopInput() { inputStopped = true; cursor.stop() }
}

/// Video delivery is independent of pointer drawing and AX window monitoring.
/// On macOS 14+ Apple's renderer explicitly supports background enqueueing.
private final class PinnedFrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "MacTools.pinned.frames", qos: .userInteractive)
    private let render: (CMSampleBuffer) -> Void
    private let clear: () -> Void
    private var stopped = false // accessed only on queue
    init(layer: AVSampleBufferDisplayLayer) {
        if #available(macOS 14.0, *) {
            let renderer = layer.sampleBufferRenderer
            render = { buffer in
                if renderer.status == .failed { renderer.flush() }
                let ready = renderer.isReadyForMoreMediaData
                if ready { renderer.enqueue(buffer) }
            }
            clear = { renderer.flush(removingDisplayedImage: true, completionHandler: nil) }
        } else {
            let legacy = LegacyPinnedFrames(layer: layer)
            render = { legacy.submit($0) }
            clear = { legacy.stop() }
        }
        super.init()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, type == .screen, buffer.isValid else { return }
        let entries = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary:false) as? [[SCStreamFrameInfo: Any]]
        let raw = entries?.first?[.status] as? Int
        guard let raw, SCFrameStatus(rawValue: raw) == .complete else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        render(buffer)
    }
    func stop() { queue.async { self.stopped = true; self.clear() } }
}

/// macOS 13 fallback: keep a single pending image instead of a main-queue backlog.
private final class LegacyPinnedFrames: @unchecked Sendable {
    private let layer: AVSampleBufferDisplayLayer
    private let lock = NSLock()
    private var latest: CMSampleBuffer?
    private var scheduled = false
    private var stopped = false
    init(layer: AVSampleBufferDisplayLayer) { self.layer = layer }
    func submit(_ buffer: CMSampleBuffer) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        latest = buffer
        guard !scheduled else { lock.unlock(); return }
        scheduled = true; lock.unlock()
        DispatchQueue.main.async {
            self.lock.lock(); let value = self.stopped ? nil : self.latest
            self.latest = nil; self.scheduled = false; self.lock.unlock()
            guard let value else { return }
            if self.layer.status == .failed { self.layer.flush() }
            if self.layer.isReadyForMoreMediaData { self.layer.enqueue(value) }
        }
    }
    func stop() {
        lock.lock(); stopped = true; latest = nil; lock.unlock()
        DispatchQueue.main.async { self.layer.flushAndRemoveImage() }
    }
}
