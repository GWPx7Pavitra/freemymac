// Draws the app icon at one size: a storage stack breaking out of jail bars.
// Usage: swift make-icon.swift <pixels> <output.png>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let pixels = Int(arguments[1]) else {
    fputs("usage: make-icon <pixels> <output.png>\n", stderr)
    exit(2)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext
context.setShouldAntialias(true)

// Everything below is laid out on a 1024-unit canvas, with y pointing up.
let scale = CGFloat(pixels) / 1024
context.scaleBy(x: scale, y: scale)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha).cgColor
}

func fillVertical(_ path: CGPath, top: UInt32, bottom: UInt32) {
    let box = path.boundingBox
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: box.midX, y: box.maxY),
                               end: CGPoint(x: box.midX, y: box.minY), options: [])
    context.restoreGState()
}

// The tile, on Apple's icon grid.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
fillVertical(tilePath, top: 0x2E343B, bottom: 0x121417)

// The storage stack, in convict orange.
let center: CGFloat = 512
let radiusX: CGFloat = 158
let radiusY: CGFloat = 50
let segmentHeight: CGFloat = 104
let segmentGap: CGFloat = 18
let stackBottom: CGFloat = 322

for index in 0..<3 {
    let bottom = stackBottom + CGFloat(index) * (segmentHeight + segmentGap)
    let top = bottom + segmentHeight
    let body = CGMutablePath()
    body.move(to: CGPoint(x: center - radiusX, y: top))
    body.addLine(to: CGPoint(x: center - radiusX, y: bottom))
    body.addArc(center: .zero, radius: 1, startAngle: .pi, endAngle: 2 * .pi, clockwise: false,
                transform: CGAffineTransform(translationX: center, y: bottom).scaledBy(x: radiusX, y: radiusY))
    body.addLine(to: CGPoint(x: center + radiusX, y: top))
    body.closeSubpath()
    fillVertical(body, top: 0xF47B2B, bottom: 0xC9520F)

    let lid = CGPath(ellipseIn: CGRect(x: center - radiusX, y: top - radiusY, width: radiusX * 2, height: radiusY * 2), transform: nil)
    context.addPath(lid)
    context.setFillColor(color(index == 2 ? 0xFFB070 : 0xE8651C))
    context.fillPath()

    // A drive light on each layer, so it reads as hardware.
    context.setFillColor(color(0xFFF3E6))
    context.fillEllipse(in: CGRect(x: center + 82, y: bottom + 14, width: 30, height: 30))
}

// The bars, in front of the stack. The middle one is gone, and its neighbours
// are bent apart to let the stack out.
func bar(_ path: CGPath, width: CGFloat) {
    let stroked = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    fillVertical(stroked, top: 0xE6EBF0, bottom: 0x8E98A3)
}

let railTop: CGFloat = 802
let railBottom: CGFloat = 222
let barWidth: CGFloat = 40

for x: CGFloat in [214, 810] {
    let straight = CGMutablePath()
    straight.move(to: CGPoint(x: x, y: railTop))
    straight.addLine(to: CGPoint(x: x, y: railBottom))
    bar(straight, width: barWidth)
}

for (attach, bow): (CGFloat, CGFloat) in [(372, 300), (652, 724)] {
    let bent = CGMutablePath()
    bent.move(to: CGPoint(x: attach, y: railTop))
    bent.addCurve(to: CGPoint(x: bow, y: 512),
                  control1: CGPoint(x: attach, y: 700), control2: CGPoint(x: bow, y: 640))
    bent.addCurve(to: CGPoint(x: attach, y: railBottom),
                  control1: CGPoint(x: bow, y: 384), control2: CGPoint(x: attach, y: 324))
    bar(bent, width: barWidth)
}

for y in [railTop, railBottom] {
    let rail = CGMutablePath()
    rail.move(to: CGPoint(x: 176, y: y))
    rail.addLine(to: CGPoint(x: 848, y: y))
    bar(rail, width: 52)
}

// A soft edge highlight, which helps the tile hold up on dark Docks.
context.addPath(tilePath)
context.setStrokeColor(color(0xFFFFFF, 0.12))
context.setLineWidth(6)
context.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
