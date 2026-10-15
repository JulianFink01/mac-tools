import AppKit
import Foundation

struct IconSlot {
    let size: Int
    let scale: Int
    let filename: String

    var pixels: Int { size * scale }
}

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appIconDirectory = projectRoot
    .appendingPathComponent("MacTools/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let menuBarIconDirectory = projectRoot
    .appendingPathComponent("MacTools/Assets.xcassets/MenuBarIcon.imageset", isDirectory: true)

let slots = [
    IconSlot(size: 16, scale: 1, filename: "AppIcon-16.png"),
    IconSlot(size: 16, scale: 2, filename: "AppIcon-16@2x.png"),
    IconSlot(size: 32, scale: 1, filename: "AppIcon-32.png"),
    IconSlot(size: 32, scale: 2, filename: "AppIcon-32@2x.png"),
    IconSlot(size: 128, scale: 1, filename: "AppIcon-128.png"),
    IconSlot(size: 128, scale: 2, filename: "AppIcon-128@2x.png"),
    IconSlot(size: 256, scale: 1, filename: "AppIcon-256.png"),
    IconSlot(size: 256, scale: 2, filename: "AppIcon-256@2x.png"),
    IconSlot(size: 512, scale: 1, filename: "AppIcon-512.png"),
    IconSlot(size: 512, scale: 2, filename: "AppIcon-512@2x.png")
]

try FileManager.default.createDirectory(at: appIconDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: menuBarIconDirectory, withIntermediateDirectories: true)

for slot in slots {
    let image = drawAppIcon(pixels: slot.pixels)
    try writePNG(image, to: appIconDirectory.appendingPathComponent(slot.filename))
}

try writePNG(drawMenuBarIcon(pixels: 18), to: menuBarIconDirectory.appendingPathComponent("MenuBarIcon.png"))
try writePNG(drawMenuBarIcon(pixels: 36), to: menuBarIconDirectory.appendingPathComponent("MenuBarIcon@2x.png"))

print("Generated MacTools app icons in \(appIconDirectory.path)")

func drawAppIcon(pixels: Int) -> NSBitmapImageRep {
    let p = CGFloat(pixels)
    return drawBitmap(pixels: pixels) {
        NSGraphicsContext.current?.imageInterpolation = .high
        let tile = NSBezierPath(roundedRect: NSRect(x: p * 0.04, y: p * 0.04, width: p * 0.92, height: p * 0.92), xRadius: p * 0.21, yRadius: p * 0.21)
        NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.30, alpha: 1), NSColor(calibratedRed: 0.04, green: 0.10, blue: 0.17, alpha: 1)])!.draw(in: tile, angle: 90)
        // A silver Mac display, a calm blue screen, and a single tool badge.
        let monitor = NSBezierPath(roundedRect: NSRect(x: p * 0.15, y: p * 0.32, width: p * 0.70, height: p * 0.46), xRadius: p * 0.045, yRadius: p * 0.045)
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -p * 0.018); shadow.shadowBlurRadius = p * 0.04
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        NSGradient(colors: [NSColor(calibratedWhite: 0.93, alpha: 1), NSColor(calibratedWhite: 0.62, alpha: 1)])!.draw(in: monitor, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        let screen = NSBezierPath(roundedRect: NSRect(x: p * 0.18, y: p * 0.39, width: p * 0.64, height: p * 0.36), xRadius: p * 0.022, yRadius: p * 0.022)
        NSGradient(colors: [NSColor(calibratedRed: 0.19, green: 0.71, blue: 0.77, alpha: 1), NSColor(calibratedRed: 0.12, green: 0.37, blue: 0.64, alpha: 1)])!.draw(in: screen, angle: 45)
        let landscape = NSBezierPath()
        landscape.move(to: NSPoint(x: p * 0.18, y: p * 0.40))
        landscape.curve(to: NSPoint(x: p * 0.82, y: p * 0.50), controlPoint1: NSPoint(x: p * 0.38, y: p * 0.66), controlPoint2: NSPoint(x: p * 0.59, y: p * 0.33))
        landscape.line(to: NSPoint(x: p * 0.82, y: p * 0.39)); landscape.line(to: NSPoint(x: p * 0.18, y: p * 0.39)); landscape.close()
        NSColor(calibratedRed: 0.41, green: 0.91, blue: 0.84, alpha: 0.75).setFill(); landscape.fill()
        let stand = NSBezierPath(roundedRect: NSRect(x: p * 0.45, y: p * 0.22, width: p * 0.10, height: p * 0.12), xRadius: p * 0.02, yRadius: p * 0.02)
        NSColor(calibratedWhite: 0.72, alpha: 1).setFill(); stand.fill()
        let foot = NSBezierPath(roundedRect: NSRect(x: p * 0.32, y: p * 0.20, width: p * 0.36, height: p * 0.045), xRadius: p * 0.02, yRadius: p * 0.02)
        NSColor(calibratedWhite: 0.88, alpha: 1).setFill(); foot.fill()
        let badge = NSBezierPath(ovalIn: NSRect(x: p * 0.62, y: p * 0.14, width: p * 0.27, height: p * 0.27))
        NSColor(calibratedRed: 0.98, green: 0.69, blue: 0.25, alpha: 1).setFill(); badge.fill()
        if let tool = NSImage(systemSymbolName: "wrench.fill", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.23, alpha: 1)])) {
            tool.draw(in: NSRect(x: p * 0.67, y: p * 0.19, width: p * 0.17, height: p * 0.17))
        }
    }
}

func drawMenuBarIcon(pixels: Int) -> NSBitmapImageRep {
    let p = CGFloat(pixels)
    return drawBitmap(pixels: pixels) {
        if let tool = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])) {
            tool.draw(in: NSRect(x: p * 0.08, y: p * 0.08, width: p * 0.84, height: p * 0.84))
        }
    }
}

func drawBitmap(pixels: Int, draw: () -> Void) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: .alphaFirst,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    bitmap.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    draw()
    NSGraphicsContext.restoreGraphicsState()

    return bitmap
}

func writePNG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }

    try data.write(to: url, options: [.atomic])
}
