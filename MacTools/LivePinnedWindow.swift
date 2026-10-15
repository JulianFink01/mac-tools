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
final class LivePinnedWindow: NSObject, NSWindowDelegate, SCStreamOutput, SCStreamDelegate {
    let source: SCWindow
    let panel: NSPanel
    private let preview: PinnedPreview
    private let axWindow: AXUIElement
    private var stream: SCStream?
    private var stopped = false
    private var sourceSize: CGSize
    private let windowDisplay: VirtualWindowDisplay
    var onClose: (() -> Void)?
    var onError: ((String) -> Void)?
    var onInputIssue: ((String) -> Void)? { didSet { preview.onInputIssue = onInputIssue } }
    private(set) var frames = 0

    init(source: SCWindow, axWindow: AXUIElement) {
        self.source = source
        self.axWindow = axWindow
        windowDisplay = VirtualWindowDisplay(window: axWindow, frame: source.frame)
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
        let config = configuration(size: source.frame.size)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: source), configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        try await stream.startCapture()
        if stopped { try? await stream.stopCapture(); return }
        panel.orderFrontRegardless()
    }

    private func configuration(size: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = min(2, 4096 / max(1, size.width))
        config.width = max(2, Int(size.width * scale))
        config.height = max(2, Int(size.height * scale))
        config.scalesToFit = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        if #available(macOS 14.0, *) {
            config.ignoreShadowsSingleWindow = true
            config.ignoreGlobalClipSingleWindow = true
        }
        return config
    }

    func ensureSourcePlacement() { windowDisplay.ensurePlacement() }

    func updateSourceFrame(_ frame: CGRect) {
        preview.sourceFrame = frame
        guard frame.size != sourceSize else { return }
        sourceSize = frame.size
        let top = panel.frame.maxY
        let width = panel.contentView?.bounds.width ?? 680
        panel.contentAspectRatio = NSSize(width: max(1, frame.width), height: max(1, frame.height))
        panel.setContentSize(NSSize(width: width, height: max(120, width * frame.height / max(1, frame.width))))
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
        let config = configuration(size: frame.size)
        Task { [weak self] in try? await self?.stream?.updateConfiguration(config) }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        preview.stopInput()
        windowDisplay.stop()
        panel.orderOut(nil)
        preview.displayLayer.flushAndRemoveImage()
        let active = stream; stream = nil
        Task { try? await active?.stopCapture() }
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
    #if DEBUG
    func windowDidMove(_ notification: Notification) { preview.updateInputGeometryLabel() }
    func windowDidResize(_ notification: Notification) { preview.updateInputGeometryLabel() }
    #endif

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let entries = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = entries.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary] {
                attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
            }
            if self.preview.displayLayer.status == .failed { self.preview.displayLayer.flush() }
            if self.preview.displayLayer.isReadyForMoreMediaData {
                self.preview.displayLayer.enqueue(sampleBuffer)
                self.frames += 1
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            self.onError?(error.localizedDescription)
        }
    }
}

/// The original receives native hardware input on its own display. A local
/// cursor layer represents that same pointer inside this floating preview.
private final class PinnedPreview: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    let pid: pid_t
    let sourceWindow: AXUIElement
    let windowDisplay: VirtualWindowDisplay
    var sourceFrame: CGRect
    var onInputIssue: ((String) -> Void)? { didSet { cursor.onIssue = onInputIssue } }
    private var tracking: NSTrackingArea?
    private var inputStopped = false
    private lazy var cursor = PinnedWindowCursor(view: self, window: sourceWindow, pid: pid,
        displayID: { [weak self] in self?.windowDisplay.displayID ?? 0 },
        sourceFrame: { [weak self] in self?.sourceFrame ?? .zero })
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
    override func mouseDown(with event: NSEvent) { enter(event) }
    // The native mouse-exit caused by entering the private display is expected;
    // the observer returns it only when the translated cursor leaves the view.
    func stopInput() { inputStopped = true; cursor.stop() }
}
