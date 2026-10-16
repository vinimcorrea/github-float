// Renders the GitHub Float app icon: `swift Icon/make_icon.swift Icon/AppIcon.png`
// A task card floating up, carried by a hot air balloon.
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
func shadow(_ dy: CGFloat, _ blur: CGFloat, _ a: CGFloat) {
    ctx.setShadow(offset: CGSize(width: 0, height: dy), blur: blur, color: NSColor.black.withAlphaComponent(a).cgColor)
}

// macOS icon grid: 824pt squircle centered in 1024.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

ctx.saveGState()
shadow(-12, 28, 0.35)
rgb(0x1b2160).setFill()
tilePath.fill()
ctx.restoreGState()

ctx.saveGState()
tilePath.addClip()
NSGradient(colors: [rgb(0x7c4dff), rgb(0x3b4cca), rgb(0x1b2160)])!.draw(in: tile, angle: -70)

// Soft clouds for depth.
NSColor.white.withAlphaComponent(0.10).setFill()
for c in [NSRect(x: 130, y: 640, width: 220, height: 70), NSRect(x: 220, y: 680, width: 160, height: 70),
          NSRect(x: 700, y: 300, width: 240, height: 70), NSRect(x: 760, y: 335, width: 150, height: 65)] {
    NSBezierPath(roundedRect: c, xRadius: 35, yRadius: 35).fill()
}

let cx: CGFloat = 512, neck: CGFloat = 470, top: CGFloat = 880, half: CGFloat = 205, neckHalf: CGFloat = 62
let card = NSRect(x: 292, y: 160, width: 440, height: 250)

// Envelope: wide round top narrowing to the neck.
func envelope() -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: cx - neckHalf, y: neck))
    p.curve(to: NSPoint(x: cx - half, y: neck + 250), controlPoint1: NSPoint(x: cx - 120, y: neck + 60), controlPoint2: NSPoint(x: cx - half, y: neck + 150))
    p.curve(to: NSPoint(x: cx, y: top), controlPoint1: NSPoint(x: cx - half, y: neck + 350), controlPoint2: NSPoint(x: cx - 115, y: top))
    p.curve(to: NSPoint(x: cx + half, y: neck + 250), controlPoint1: NSPoint(x: cx + 115, y: top), controlPoint2: NSPoint(x: cx + half, y: neck + 350))
    p.curve(to: NSPoint(x: cx + neckHalf, y: neck), controlPoint1: NSPoint(x: cx + half, y: neck + 150), controlPoint2: NSPoint(x: cx + 120, y: neck + 60))
    p.close()
    return p
}
/// A vertical gore of the envelope, bulging out to `bulge` at its widest.
func gore(_ l: CGFloat, _ r: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: cx + l * neckHalf / half, y: neck))
    p.curve(to: NSPoint(x: cx, y: top), controlPoint1: NSPoint(x: cx + l * 1.15, y: neck + 260), controlPoint2: NSPoint(x: cx + l * 0.75, y: top + 10))
    p.curve(to: NSPoint(x: cx + r * neckHalf / half, y: neck), controlPoint1: NSPoint(x: cx + r * 0.75, y: top + 10), controlPoint2: NSPoint(x: cx + r * 1.15, y: neck + 260))
    p.close()
    return p
}

// Ropes from the neck down to the card.
let ropes = NSBezierPath()
ropes.lineWidth = 9
ropes.lineCapStyle = .round
for (from, to) in [(cx - neckHalf + 8, card.minX + 70), (cx + neckHalf - 8, card.maxX - 70)] {
    ropes.move(to: NSPoint(x: from, y: neck)); ropes.line(to: NSPoint(x: to, y: card.maxY - 6))
}
NSColor.white.withAlphaComponent(0.85).setStroke()
ropes.stroke()

// Burner band under the neck.
rgb(0x6b4a3a).setFill()
NSBezierPath(roundedRect: NSRect(x: cx - neckHalf - 4, y: neck - 26, width: 2 * (neckHalf + 4), height: 30), xRadius: 10, yRadius: 10).fill()

// Envelope with stripes.
ctx.saveGState()
shadow(-16, 34, 0.4)
rgb(0xf0583e).setFill()
envelope().fill()
ctx.restoreGState()
ctx.saveGState()
envelope().addClip()
NSGradient(colors: [rgb(0xff9a6b), rgb(0xf0583e)])!.draw(in: envelope(), angle: -60)
rgb(0xfff4e8).setFill()
gore(-70, 70).fill()
rgb(0xffd166).setFill()
gore(-260, -150).fill()
gore(150, 260).fill()
// Shading on the right for volume.
NSGradient(colors: [NSColor.black.withAlphaComponent(0), NSColor.black.withAlphaComponent(0.18)])!
    .draw(in: NSRect(x: cx, y: neck, width: half, height: top - neck), angle: 0)
ctx.restoreGState()

// Task card as the basket: three statuses (awaiting review / being reviewed / approved).
ctx.saveGState()
shadow(-20, 40, 0.35)
NSColor.white.setFill()
NSBezierPath(roundedRect: card, xRadius: 48, yRadius: 48).fill()
ctx.restoreGState()
for (i, c) in [rgb(0xf0883e), rgb(0x388bfd), rgb(0x2ea043)].enumerated() {
    let y = card.maxY - 82 - CGFloat(i) * 66
    c.setFill()
    NSBezierPath(ovalIn: NSRect(x: card.minX + 42, y: y, width: 46, height: 46)).fill()
    rgb(0xd0d7de).setFill()
    NSBezierPath(roundedRect: NSRect(x: card.minX + 112, y: y + 11, width: [250, 190, 220][i], height: 24),
                 xRadius: 12, yRadius: 12).fill()
}
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
