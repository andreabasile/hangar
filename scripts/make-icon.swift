// Draws the app icon ("prompt + spark") with plain NSBezierPath and builds Resources/AppIcon.icns.
// SF Symbols are not used: their licence forbids them in app icons.
//   swift scripts/make-icon.swift [preview-folder]     (the folder gets the 1024 and 16 px PNGs)
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let preview = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The macOS icon shape: a superellipse (n = 5) is close to Apple's continuous-corner squircle.
func squircle(_ rect: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2, n = 5.0
    for step in 0...720 {
        let t = Double(step) / 720 * 2 * .pi
        let x = a * copysign(pow(abs(cos(t)), 2 / n), cos(t)), y = b * copysign(pow(abs(sin(t)), 2 / n), sin(t))
        let point = NSPoint(x: rect.midX + x, y: rect.midY + y)
        step == 0 ? path.move(to: point) : path.line(to: point)
    }
    path.close()
    return path
}

/// Points are given top-left based, as in the design spec; AppKit draws bottom-left based.
func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: 1024 - y) }

func drawIcon() {
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(tile)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x1C1F26).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: color(0x3A3F4B), ending: color(0x1C1F26))?.draw(in: shape, angle: -90)
    // a soft highlight along the top edge
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.14), ending: NSColor.white.withAlphaComponent(0))?
        .draw(in: NSRect(x: tile.minX, y: tile.maxY - 260, width: tile.width, height: 260), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let chevron = NSBezierPath()
    chevron.move(to: p(300, 360))
    chevron.line(to: p(470, 512))
    chevron.line(to: p(300, 664))
    chevron.lineWidth = 72
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    NSColor.white.setStroke()
    chevron.stroke()

    // four-point sparkle: tips on the axes, sides curving in towards the centre
    let center = p(660, 600), outer: CGFloat = 118, pull: CGFloat = 0.18
    let tips = [NSPoint(x: 0, y: outer), NSPoint(x: outer, y: 0), NSPoint(x: 0, y: -outer), NSPoint(x: -outer, y: 0)]
    let spark = NSBezierPath()
    spark.move(to: NSPoint(x: center.x + tips[0].x, y: center.y + tips[0].y))
    for index in 0..<4 {
        let from = tips[index], to = tips[(index + 1) % 4]
        let control = NSPoint(x: center.x + (from.x + to.x) * pull, y: center.y + (from.y + to.y) * pull)
        spark.curve(to: NSPoint(x: center.x + to.x, y: center.y + to.y), controlPoint1: control, controlPoint2: control)
    }
    spark.close()
    color(0xFF9F0A).setFill()
    spark.fill()
}

func png(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return data
}

let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
// drawn at every size rather than scaled down, so the 16 px icon stays crisp
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try png(size: points * scale).write(to: iconset.appending(path: name))
}
let output = root.appending(path: "Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
if let preview {
    try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
    try png(size: 1024).write(to: preview.appending(path: "icon-1024.png"))
    try png(size: 16).write(to: preview.appending(path: "icon-16.png"))
    try png(size: 32).write(to: preview.appending(path: "icon-32.png"))
}
print("ok: \(output.path)")
