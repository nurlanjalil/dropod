// Draws the app icon, "Layers" in the Ocean colourway: three offset white cards on a blue tile.
// Designed on a 100-unit canvas (see design/icons-layers.html), drawn here at 1024 px.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: an 824 px tile centred in 1024. The design's tile is 88 units wide at (6, 6),
// with y pointing down, so map design units onto that.
let unit: CGFloat = 824 / 88
let transform = NSAffineTransform()
transform.translateX(by: 0, yBy: CGFloat(size))
transform.scaleX(by: 1, yBy: -1)
transform.translateX(by: 100 - 6 * unit, yBy: 100 - 6 * unit)
transform.scale(by: unit)
transform.concat()

func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// The tile: light blue at the top left to deep blue at the bottom right.
let tile = rounded(6, 6, 88, 88, 21)
NSGraphicsContext.saveGraphicsState()
tile.addClip()
NSGradient(starting: color(0x6fb2ff), ending: color(0x2f6fe8))!
    .draw(from: NSPoint(x: 6, y: 6), to: NSPoint(x: 94, y: 94), options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
NSGraphicsContext.restoreGraphicsState()

// Three cards, back to front, with a soft shadow for depth.
let shadow = NSShadow()
shadow.shadowColor = color(0x0b2a6b, 0.18)
shadow.shadowBlurRadius = 2.2
shadow.shadowOffset = NSSize(width: 0, height: -1)  // drawn in a flipped space: this points down
NSGraphicsContext.saveGraphicsState()
shadow.set()
color(0xffffff, 0.40).setFill(); rounded(38, 20, 42, 34, 8).fill()
color(0xffffff, 0.68).setFill(); rounded(29, 31, 42, 34, 8).fill()
color(0xffffff, 1.00).setFill(); rounded(20, 42, 42, 34, 8).fill()
NSGraphicsContext.restoreGraphicsState()

// Two lines on the front card.
color(0x6f9ff0).setFill()
rounded(27, 51, 22, 3.6, 1.8).fill()
rounded(27, 59, 16, 3.6, 1.8).fill()

// A soft shine across the top half, and a faint light edge.
NSGraphicsContext.saveGraphicsState()
tile.addClip()
NSGradient(starting: color(0xffffff, 0.30), ending: color(0xffffff, 0))!
    .draw(from: NSPoint(x: 50, y: 6), to: NSPoint(x: 50, y: 6 + 88 * 0.45), options: [])
NSGraphicsContext.restoreGraphicsState()
color(0xffffff, 0.16).setStroke()
let edge = rounded(6.5, 6.5, 87, 87, 20.5)
edge.lineWidth = 1
edge.stroke()

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
