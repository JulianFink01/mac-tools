import AppKit
import ApplicationServices
import ScreenCaptureKit
import AVFoundation

private final class PinnedInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A pixel-matched live view while another app is active. Interaction belongs to
/// the original window: pointer entry hands off without synthesizing input.
@MainActor
final class LivePinnedWindow: NSObject, NSWindowDelegate, SCStreamDelegate {
    let source: SCWindow
    let panel: NSPanel
    private let preview = PinnedPreview(frame: .zero)
    private let axWindow: AXUIElement
    private var stream: SCStream?
    private var stopped = false
    private var ready = false
    private var sourceFrame: CGRect
    private var frameOutput: PinnedFrameOutput?
    private var configurationTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var firstFrame = false
    var onHover: (() -> Void)?
    var onClose: (() -> Void)?
    var onError: ((String) -> Void)?

    init(source: SCWindow, axWindow: AXUIElement) {
        self.source = source
        self.axWindow = axWindow
        sourceFrame = source.frame
        panel = PinnedInputPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Live · " + (source.owningApplication?.applicationName ?? "Fenster") + " · " + (source.title ?? "")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = preview
        panel.delegate = self
        preview.onOpen = { [weak self] in self?.openOriginal() }
        preview.onHover = { [weak self] in
            self?.onHover?()
            self?.openOriginal()
        }
        syncFrame(source.frame)
    }

    private func syncFrame(_ frame: CGRect) {
        // AX/CG coordinates start at the primary display's top-left, AppKit at its bottom-left.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        panel.setFrame(NSRect(x: frame.minX, y: primaryTop - frame.maxY,
                              width: frame.width, height: frame.height), display: true)
    }

    @objc func openOriginal() {
        guard !stopped, let pid = source.owningApplication?.processID else { return }
        // Deliberate one-time user action. Never invoked from a monitor/timer.
        panel.orderOut(nil)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        let result = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        if result != .success { onError?("Das Originalfenster konnte nicht geöffnet werden.") }
    }

    func start() async throws {
        let filter = SCContentFilter(desktopIndependentWindow: source)
        let stream = SCStream(filter: filter, configuration: configuration(), delegate: self)
        self.stream = stream
        let output = PinnedFrameOutput(layer: preview.displayLayer)
        output.onFirstFrame = { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.firstFrame = true
                self.refreshVisibility()
            }
        }
        frameOutput = output
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        if stopped { try? await stream.stopCapture(); return }
        ready = true
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refreshVisibility() } }
        refreshVisibility()
    }

    func show() {
        refreshVisibility()
        if panel.isVisible { panel.makeKeyAndOrderFront(nil) }
    }

    private func refreshVisibility() {
        guard ready, firstFrame, !stopped else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == source.owningApplication?.processID {
            panel.orderOut(nil)
        } else {
            // Read the current geometry before revealing after a move/resize in the source app.
            if let frame = currentFrame() { updateSourceFrame(frame) }
            if !panel.isVisible {
                preview.armHover()
                panel.orderFrontRegardless()
            }
        }
    }

    private func currentFrame() -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    private func configuration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = panel.screen?.backingScaleFactor ?? 2
        config.width = max(2, Int(ceil(sourceFrame.width * scale)))
        config.height = max(2, Int(ceil(sourceFrame.height * scale)))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        if #available(macOS 14.0, *) {
            config.shouldBeOpaque = false
            config.ignoreShadowsSingleWindow = true
            config.ignoreGlobalClipSingleWindow = true
        }
        return config
    }

    func updateSourceFrame(_ frame: CGRect) {
        guard !stopped, frame.width > 0, frame.height > 0 else { return }
        let oldScale = panel.screen?.backingScaleFactor
        let changedSize = sourceFrame.size != frame.size
        sourceFrame = frame
        syncFrame(frame)
        if changedSize || oldScale != panel.screen?.backingScaleFactor { scheduleConfiguration() }
    }

    private func scheduleConfiguration() {
        configurationTask?.cancel()
        guard !stopped, stream != nil else { return }
        configurationTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000); try Task.checkCancellation() }
            catch { return }
            guard let self, !self.stopped else { return }
            do { try await self.stream?.updateConfiguration(self.configuration()) }
            catch { self.onError?(error.localizedDescription) }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        configurationTask?.cancel(); configurationTask = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        panel.orderOut(nil)
        frameOutput?.stop(); frameOutput = nil
        let active = stream; stream = nil
        Task { try? await active?.stopCapture() }
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            self.onError?(error.localizedDescription)
        }
    }
}

private final class PinnedPreview: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    var onOpen: (() -> Void)?
    var onHover: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var revealedAt = NSEvent.mouseLocation
    private var handedOff = false
    func armHover() { revealedAt = NSEvent.mouseLocation; handedOff = false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    private func handOffOnHover() {
        // Appearing under a stationary pointer must not undo an intentional app switch.
        // Dragging across the view must not steal the ongoing drag from another app.
        guard !handedOff, let window, window.isVisible, NSEvent.pressedMouseButtons == 0,
              NSEvent.mouseLocation != revealedAt,
              NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber else { return }
        handedOff = true
        onHover?()
    }
    override func mouseEntered(with event: NSEvent) { handOffOnHover() }
    override func mouseMoved(with event: NSEvent) { handOffOnHover() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        displayLayer.isOpaque = false
        displayLayer.backgroundColor = NSColor.clear.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Live-Ansicht. Maus darüber bewegen, um das Originalfenster zu bedienen.")
        toolTip = "Maus darüber bewegen öffnet das Original. Beim App-Wechsel bleibt die Live-Ansicht oben."
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); displayLayer.frame = bounds }
    override func mouseDown(with event: NSEvent) { onOpen?() }
    override func rightMouseDown(with event: NSEvent) { onOpen?() }
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }
}

/// Video delivery is independent of pointer drawing and AX window monitoring.
/// On macOS 14+ Apple's renderer explicitly supports background enqueueing.
private final class PinnedFrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "MacTools.pinned.frames", qos: .userInteractive)
    private let render: (CMSampleBuffer) -> Void
    private let clear: () -> Void
    var onFirstFrame: (() -> Void)?
    private var deliveredFirstFrame = false
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
        if !deliveredFirstFrame { deliveredFirstFrame = true; onFirstFrame?() }
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
