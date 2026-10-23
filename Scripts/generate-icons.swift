import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Two opposing arcs and a central ribbon form a compact abstract orbit.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor { CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha) }
func mark() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 330, y: 660)); p.addLine(to: CGPoint(x: 270, y: 600)); p.addQuadCurve(to: CGPoint(x: 270, y: 530), control: CGPoint(x: 235, y: 565)); p.addLine(to: CGPoint(x: 530, y: 270)); p.addQuadCurve(to: CGPoint(x: 600, y: 270), control: CGPoint(x: 565, y: 235)); p.addLine(to: CGPoint(x: 660, y: 330))
    p.move(to: CGPoint(x: 694, y: 364)); p.addLine(to: CGPoint(x: 754, y: 424)); p.addQuadCurve(to: CGPoint(x: 754, y: 494), control: CGPoint(x: 789, y: 459)); p.addLine(to: CGPoint(x: 494, y: 754)); p.addQuadCurve(to: CGPoint(x: 424, y: 754), control: CGPoint(x: 459, y: 789)); p.addLine(to: CGPoint(x: 364, y: 694))
    p.move(to: CGPoint(x: 410, y: 614)); p.addLine(to: CGPoint(x: 614, y: 410))
    return p
}
func draw(size: Int, template: Bool, to path: String) throws {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
    if template {
        ctx.scaleBy(x: CGFloat(size) / 680, y: CGFloat(size) / 680); ctx.translateBy(x: -172, y: -172)
        ctx.addPath(mark()); ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(94); ctx.setStrokeColor(color(0)); ctx.strokePath()
    } else {
        ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        let tile = CGPath(roundedRect: CGRect(x: 70, y: 70, width: 884, height: 884), cornerWidth: 204, cornerHeight: 204, transform: nil)
        ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 32, color: color(0, 0.25)); ctx.addPath(tile); ctx.setFillColor(color(0x13212D)); ctx.fillPath(); ctx.restoreGState()
        ctx.saveGState(); ctx.addPath(tile); ctx.clip()
        let base = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0x243A48), color(0x131923), color(0x10131D)] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(base, start: CGPoint(x: 100, y: 940), end: CGPoint(x: 800, y: 70), options: [])
        let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0x49DDC9, 0.18), color(0x49DDC9, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 760), startRadius: 0, endCenter: CGPoint(x: 300, y: 760), endRadius: 700, options: [])
        ctx.restoreGState()
        ctx.addPath(tile); ctx.setStrokeColor(color(0xFFFFFF, 0.10)); ctx.setLineWidth(2); ctx.strokePath()
        ctx.saveGState(); ctx.addPath(mark()); ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(94); ctx.replacePathWithStrokedPath(); ctx.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0x73F4D5), color(0x54BEEB), color(0xA59AF6)] as CFArray, locations: [0, 0.52, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 250, y: 780), end: CGPoint(x: 800, y: 220), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]); ctx.restoreGState()
    }
    let url = root.appendingPathComponent(path)
    let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, ctx.makeImage()!, nil); precondition(CGImageDestinationFinalize(output))
}
for points in [16, 32, 128, 256, 512] {
    try draw(size: points, template: false, to: "MacTools/Assets.xcassets/AppIcon.appiconset/AppIcon-\(points).png")
    try draw(size: points * 2, template: false, to: "MacTools/Assets.xcassets/AppIcon.appiconset/AppIcon-\(points)@2x.png")
}
try draw(size: 18, template: true, to: "MacTools/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.png")
try draw(size: 36, template: true, to: "MacTools/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon@2x.png")
print("Generated matching app and template menu icons")
