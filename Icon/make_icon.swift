// Renders the GitHub Float app icon: `swift Icon/make_icon.swift Icon/AppIcon.png`
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// macOS icon grid: 824pt squircle centered in 1024.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
rgb(0x0d1117).setFill()
tilePath.fill()
ctx.restoreGState()

ctx.saveGState()
tilePath.addClip()
NSGradient(colors: [rgb(0x6e40c9), rgb(0x2f3d9e), rgb(0x0d1117)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: tile, angle: -65)

// Back panel (the stack).
let back = NSRect(x: 265, y: 300, width: 520, height: 470)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.3).cgColor)
NSColor.white.withAlphaComponent(0.22).setFill()
NSBezierPath(roundedRect: back, xRadius: 56, yRadius: 56).fill()
ctx.restoreGState()

// Front floating panel.
let panel = NSRect(x: 205, y: 225, width: 540, height: 500)
let panelPath = NSBezierPath(roundedRect: panel, xRadius: 60, yRadius: 60)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 50, color: NSColor.black.withAlphaComponent(0.45).cgColor)
rgb(0xf6f8fa).setFill()
panelPath.fill()
ctx.restoreGState()

// Panel header bar with window controls.
ctx.saveGState()
panelPath.addClip()
rgb(0xe6e9ef).setFill()
NSRect(x: panel.minX, y: panel.maxY - 92, width: panel.width, height: 92).fill()
ctx.restoreGState()
for (i, c) in [rgb(0xff5f57), rgb(0xfebc2e), rgb(0x28c840)].enumerated() {
    c.setFill()
    NSBezierPath(ovalIn: NSRect(x: panel.minX + 46 + CGFloat(i) * 46, y: panel.maxY - 62, width: 30, height: 30)).fill()
}

// Task rows: status dot + title line + PR pill (awaiting / being reviewed / approved).
let rows: [(NSColor, CGFloat)] = [(rgb(0xf0883e), 0.78), (rgb(0x388bfd), 0.62), (rgb(0x2ea043), 0.70)]
for (i, row) in rows.enumerated() {
    let y = panel.maxY - 170 - CGFloat(i) * 118
    row.0.setFill()
    NSBezierPath(ovalIn: NSRect(x: panel.minX + 48, y: y - 4, width: 44, height: 44)).fill()
    rgb(0x30363d, 0.85).setFill()
    NSBezierPath(roundedRect: NSRect(x: panel.minX + 118, y: y + 16, width: (panel.width - 170) * row.1, height: 24),
                 xRadius: 12, yRadius: 12).fill()
    row.0.withAlphaComponent(0.35).setFill()
    NSBezierPath(roundedRect: NSRect(x: panel.minX + 118, y: y - 20, width: 150, height: 22),
                 xRadius: 11, yRadius: 11).fill()
}

// "Eye" badge: keeping watch on your reviews.
let badge = NSRect(x: 600, y: 170, width: 230, height: 230)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.4).cgColor)
NSGradient(colors: [rgb(0xa371f7), rgb(0x6e40c9)])!.draw(in: NSBezierPath(ovalIn: badge), angle: -90)
ctx.restoreGState()
NSColor.white.withAlphaComponent(0.9).setStroke()
let ring = NSBezierPath(ovalIn: badge.insetBy(dx: 6, dy: 6))
ring.lineWidth = 10
ring.stroke()

let cx = badge.midX, cy = badge.midY
let eye = NSBezierPath()
eye.move(to: NSPoint(x: cx - 78, y: cy))
eye.curve(to: NSPoint(x: cx + 78, y: cy), controlPoint1: NSPoint(x: cx - 40, y: cy + 62), controlPoint2: NSPoint(x: cx + 40, y: cy + 62))
eye.curve(to: NSPoint(x: cx - 78, y: cy), controlPoint1: NSPoint(x: cx + 40, y: cy - 62), controlPoint2: NSPoint(x: cx - 40, y: cy - 62))
NSColor.white.setFill()
eye.fill()
rgb(0x0d1117).setFill()
NSBezierPath(ovalIn: NSRect(x: cx - 30, y: cy - 30, width: 60, height: 60)).fill()
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: cx + 2, y: cy + 6, width: 16, height: 16)).fill()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
