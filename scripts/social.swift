// Draws the GitHub social preview (1280×640) from the 1024 icon.
//   swift scripts/social.swift icon.png docs/social.png
// SPDX-License-Identifier: MIT

import AppKit

let w: CGFloat = 1280, h: CGFloat = 640
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGradient(starting: NSColor(white: 1, alpha: 1), ending: NSColor(white: 0.93, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

NSImage(contentsOfFile: CommandLine.arguments[1])!.draw(in: NSRect(x: 70, y: 150, width: 340, height: 340))

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top: CGFloat) {
    let style = NSMutableParagraphStyle(); style.lineSpacing = 6
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                               .foregroundColor: color, .paragraphStyle: style])
        .draw(in: NSRect(x: 450, y: top - 400, width: 760, height: 400))
}
text("Mando", size: 96, weight: .bold, color: NSColor(white: 0.1, alpha: 1), top: 490)
text("Volume and brightness keys for HDMI and DisplayPort monitors on Mac.",
     size: 40, weight: .regular, color: NSColor(white: 0.25, alpha: 1), top: 360)
text("Free · Open source · Works with Apple and Logitech keyboards",
     size: 26, weight: .medium, color: NSColor(srgbRed: 0.85, green: 0.38, blue: 0.08, alpha: 1), top: 210)

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
