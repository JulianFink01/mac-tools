import AppKit

final class WallpaperWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        title = "MacTools Desktop Window"
        setFrame(screen.frame, display: true)
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        // Public APIs do not provide a perfect "replace the Finder desktop wallpaper
        // but stay below desktop icons" layer. This level is the closest public-API
        // compromise: above the static desktop background, below normal app windows.
        let desktopLevel = CGWindowLevelForKey(.desktopWindow)
        level = NSWindow.Level(rawValue: Int(desktopLevel + 1))

        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}
