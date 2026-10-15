import AVFoundation
import AppKit

final class WallpaperPlayerView: NSView {
    private let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayerTree()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayerTree()
    }

    override var isFlipped: Bool {
        true
    }

    func setPlayer(_ player: AVPlayer?) {
        playerLayer.player = player
    }

    func setAspectMode(_ mode: AspectMode) {
        switch mode {
        case .fill:
            playerLayer.videoGravity = .resizeAspectFill
        case .fit:
            playerLayer.videoGravity = .resizeAspect
        }
    }

    private func configureLayerTree() {
        wantsLayer = true
        let rootLayer = CALayer()
        rootLayer.backgroundColor = NSColor.black.cgColor
        layer = rootLayer

        playerLayer.frame = bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        playerLayer.backgroundColor = NSColor.black.cgColor
        rootLayer.addSublayer(playerLayer)
    }
}
