import ScreenSaver
import AVFoundation
import AppKit

@objc(MacToolsScreenSaverView)
final class MacToolsScreenSaverView: ScreenSaverView {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private let videoLayer = AVPlayerLayer()
    private var message: NSTextField?
    private var previewImage: NSImage?
    private var previewGenerator: AVAssetImageGenerator?
    private var previewGravity: AVLayerVideoGravity = .resizeAspectFill

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        if !isPreview {
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(videoLayer)
        }
        animationTimeInterval = 1.0 / 30.0
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
        message?.frame = NSRect(x: 20, y: max(0, bounds.midY - 30), width: max(0, bounds.width - 40), height: 60)
    }

    override func startAnimation() {
        super.startAnimation()
        message?.removeFromSuperview(); message = nil
        // The host has its own preferences domain; the module domain is shared with MacTools.
        guard let defaults = ScreenSaverDefaults(forModuleWithName: "com.julianfink.MacTools.ScreenSaver") else { return }
        defaults.synchronize()
        guard let path = defaults.string(forKey: "videoPath"), FileManager.default.isReadableFile(atPath: path) else {
            showMessage("MacTools öffnen und ein Video als Wallpaper auswählen.")
            return
        }
        previewGravity = defaults.string(forKey: "aspectMode") == "fit" ? .resizeAspect : .resizeAspectFill
        if isPreview {
            // System Settings snapshots classic savers offscreen; AVPlayerLayer is not
            // reliably captured there. Draw a real video thumbnail through AppKit.
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 360)
            previewGenerator = generator
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 0.2, preferredTimescale: 600))]) { [weak self] _, image, _, _, _ in
                guard let image else { return }
                DispatchQueue.main.async {
                    guard let self, self.isAnimating else { return }
                    self.previewImage = NSImage(cgImage: image, size: .zero)
                    self.needsDisplay = true
                }
            }
            return
        }
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
        videoLayer.player = queue
        videoLayer.videoGravity = defaults.string(forKey: "aspectMode") == "fit" ? .resizeAspect : .resizeAspectFill
        videoLayer.frame = bounds
        queue.play()
    }

    override func stopAnimation() {
        previewGenerator?.cancelAllCGImageGeneration()
        previewGenerator = nil
        player?.pause()
        videoLayer.player = nil
        looper = nil
        player = nil
        super.stopAnimation()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isPreview else { super.draw(dirtyRect); return }
        NSColor.black.setFill(); dirtyRect.fill()
        guard let image = previewImage, image.size.width > 0, image.size.height > 0 else { return }
        let widthScale = bounds.width / image.size.width
        let heightScale = bounds.height / image.size.height
        let scale = previewGravity == .resizeAspect ? min(widthScale, heightScale) : max(widthScale, heightScale)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let frame = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: frame)
    }

    override func animateOneFrame() {
        // AVFoundation drives the video; no per-frame rendering work is needed here.
        if player?.currentItem?.status == .failed && message == nil {
            showMessage("Das ausgewählte Video konnte nicht abgespielt werden.")
        }
    }

    private func showMessage(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
        message = label
        needsLayout = true
    }
}
