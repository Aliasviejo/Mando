// Draws the app icon: a light control knob with a level scale.
//   swift scripts/icon.swift out.png   (1024×1024)
// SPDX-License-Identifier: MIT

import AppKit

let size: CGFloat = 1024
let accent = NSColor(srgbRed: 0.95, green: 0.44, blue: 0.11, alpha: 1)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func gray(_ v: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(white: v, alpha: a) }

// Base: macOS grid squircle (824 pt inside 1024), aluminium gradient, soft drop shadow.
let base = NSRect(x: 100, y: 100, width: 824, height: 824)
let basePath = NSBezierPath(roundedRect: base, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: gray(0, 0.30).cgColor)
gray(0.9).setFill(); basePath.fill()
ctx.restoreGState()
NSGradient(starting: gray(0.98), ending: gray(0.84))!.draw(in: basePath, angle: -90)
gray(1, 0.7).setStroke(); basePath.lineWidth = 3; basePath.stroke()

let c = CGPoint(x: 512, y: 500)

// Level scale: 11 ticks over a 270° sweep, the first 7 lit.
let ticks = 11, lit = 7
let start: CGFloat = 225, sweep: CGFloat = 270
func angle(_ i: Int) -> CGFloat { (start - sweep * CGFloat(i) / CGFloat(ticks - 1)) * .pi / 180 }
for i in 0..<ticks {
    let a = angle(i)
    let p = NSBezierPath()
    p.move(to: CGPoint(x: c.x + cos(a) * 300, y: c.y + sin(a) * 300))
    p.line(to: CGPoint(x: c.x + cos(a) * 352, y: c.y + sin(a) * 352))
    p.lineWidth = 30; p.lineCapStyle = .round
    (i < lit ? accent : gray(0.72)).setStroke(); p.stroke()
}

// Knob: shadowed disc, brushed face, inner bevel.
let r: CGFloat = 228
let knob = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: gray(0, 0.35).cgColor)
gray(0.95).setFill(); knob.fill()
ctx.restoreGState()
NSGradient(starting: gray(1), ending: gray(0.80))!.draw(in: knob, angle: -90)
let ri = r - 26
let face = NSBezierPath(ovalIn: NSRect(x: c.x - ri, y: c.y - ri, width: 2 * ri, height: 2 * ri))
NSGradient(starting: gray(0.86), ending: gray(0.99))!.draw(in: face, angle: -90)
gray(1, 0.9).setStroke(); face.lineWidth = 2; face.stroke()

// Pointer at the last lit tick.
let a = angle(lit - 1)
let pointer = NSBezierPath()
pointer.move(to: CGPoint(x: c.x + cos(a) * 70, y: c.y + sin(a) * 70))
pointer.line(to: CGPoint(x: c.x + cos(a) * (ri - 40), y: c.y + sin(a) * (ri - 40)))
pointer.lineWidth = 34; pointer.lineCapStyle = .round
accent.setStroke(); pointer.stroke()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
