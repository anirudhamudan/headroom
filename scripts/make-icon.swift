// Draws the Headroom app icon (a clay gauge on a warm off-white tile) and writes
// Assets/AppIcon.icns. Usage: swift scripts/make-icon.swift
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let clay = color(0xD97757)
let cream = color(0xFAF9F5)
let track = color(0xE9E5DA)
let ink = color(0x30302E)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024 // design on a 1024 grid

    // macOS icon tile: 824pt square inset 100pt, with a soft drop shadow.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    cream.setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    color(0xDEDCD1).setStroke()
    tilePath.lineWidth = 2 * s
    tilePath.stroke()

    // Gauge: 180° arc from left (180°) to right (0°), centred low on the tile.
    let center = NSPoint(x: 512 * s, y: 392 * s)
    let radius = 250 * s
    let width = 78 * s
    let fillFraction: CGFloat = 0.62

    func arc(from start: CGFloat, to end: CGFloat, _ c: NSColor) {
        let p = NSBezierPath()
        p.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        p.lineWidth = width
        p.lineCapStyle = .round
        c.setStroke()
        p.stroke()
    }
    let needleAngle = 180 - 180 * fillFraction
    arc(from: 180, to: 0, track)
    arc(from: 180, to: needleAngle, clay)

    // Needle and hub.
    let rad = needleAngle * .pi / 180
    let tip = NSPoint(x: center.x + cos(rad) * (radius - 70 * s), y: center.y + sin(rad) * (radius - 70 * s))
    let needle = NSBezierPath()
    needle.move(to: center)
    needle.line(to: tip)
    needle.lineWidth = 30 * s
    needle.lineCapStyle = .round
    ink.setStroke()
    needle.stroke()
    let hub = 46 * s
    ink.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("Assets/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! drawIcon(size: px).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
try! drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Assets/icon-1024.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Assets/AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "Wrote Assets/AppIcon.icns" : "iconutil failed")
