// Renders the GitHub Float app icon: `swift Icon/make_icon.swift Icon/AppIcon.png`
// A task card floating up, carried by a balloon.
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

// Shadow on the "ground": the card is floating.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 30, color: NSColor.black.withAlphaComponent(0.5).cgColor)
NSColor.black.withAlphaComponent(0.28).setFill()
NSBezierPath(ovalIn: NSRect(x: 512 - 180, y: 128, width: 360, height: 60)).fill()
ctx.restoreGState()

let balloon = NSRect(x: 600, y: 680, width: 200, height: 225)
let card = NSRect(x: 210, y: 205, width: 470, height: 375)

// Balloon string.
let string = NSBezierPath()
string.lineWidth = 10
string.move(to: NSPoint(x: balloon.midX, y: balloon.minY - 20))
string.curve(to: NSPoint(x: card.maxX - 70, y: card.maxY - 4),
             controlPoint1: NSPoint(x: balloon.midX + 25, y: balloon.minY - 60),
             controlPoint2: NSPoint(x: card.maxX - 90, y: card.maxY + 40))
NSColor.white.withAlphaComponent(0.85).setStroke()
string.stroke()

// Task card: three statuses (awaiting review / being reviewed / approved).
ctx.saveGState()
shadow(-20, 40, 0.35)
NSColor.white.setFill()
NSBezierPath(roundedRect: card, xRadius: 60, yRadius: 60).fill()
ctx.restoreGState()
for (i, c) in [rgb(0xf0883e), rgb(0x388bfd), rgb(0x2ea043)].enumerated() {
    let y = card.maxY - 112 - CGFloat(i) * 100
    c.setFill()
    NSBezierPath(ovalIn: NSRect(x: card.minX + 50, y: y, width: 62, height: 62)).fill()
    rgb(0xd0d7de).setFill()
    NSBezierPath(roundedRect: NSRect(x: card.minX + 138, y: y + 14, width: [250, 190, 220][i], height: 34),
                 xRadius: 17, yRadius: 17).fill()
}

// Balloon.
ctx.saveGState()
shadow(-14, 30, 0.4)
NSGradient(colors: [rgb(0xff9a6b), rgb(0xf0583e)])!.draw(in: NSBezierPath(ovalIn: balloon), angle: -60)
ctx.restoreGState()
let knot = NSBezierPath()
knot.move(to: NSPoint(x: balloon.midX - 16, y: balloon.minY - 22))
knot.line(to: NSPoint(x: balloon.midX + 16, y: balloon.minY - 22))
knot.line(to: NSPoint(x: balloon.midX, y: balloon.minY + 4))
knot.close()
rgb(0xf0583e).setFill()
knot.fill()
NSColor.white.withAlphaComponent(0.45).setFill()
NSBezierPath(ovalIn: NSRect(x: balloon.minX + 50, y: balloon.maxY - 110, width: 50, height: 75)).fill()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
