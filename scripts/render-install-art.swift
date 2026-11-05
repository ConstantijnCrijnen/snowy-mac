import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Draw in logical points. Finder gets paired 1x/2x artwork; the app icon gets
// every required size from the same paths, with no raster scaling at build time.
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}
func render(_ width: Int, _ height: Int, scale: Int, to url: URL, draw: (CGContext) -> Void) throws {
    let context = CGContext(data: nil, width: width * scale, height: height * scale,
                            bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height * scale))
    context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    draw(context)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    let density = 72 * scale
    CGImageDestinationAddImage(destination, context.makeImage()!, [
        kCGImagePropertyDPIWidth: density, kCGImagePropertyDPIHeight: density
    ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}
func label(_ text: String, at point: CGPoint, size: CGFloat, ink: CGColor,
           medium: Bool = false, centered: Bool = false, in c: CGContext) {
    let font = CTFontCreateWithName((medium ? "HelveticaNeue-Medium" : "HelveticaNeue") as CFString, size, nil)
    let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: ink] as CFDictionary
    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes)!)
    c.saveGState()
    let offset = centered ? CTLineGetTypographicBounds(line, nil, nil, nil) / 2 : 0
    c.translateBy(x: point.x - offset, y: point.y)
    c.scaleBy(x: 1, y: -1)
    c.textPosition = .zero
    CTLineDraw(line, c)
    c.restoreGState()
}
func background(_ c: CGContext) {
    c.drawLinearGradient(gradient([color(0x234f75), color(0x102c4c), color(0x091c32)]),
                         start: CGPoint(x: 0, y: 0), end: CGPoint(x: 650, y: 450), options: [.drawsAfterEndLocation])
    c.drawRadialGradient(gradient([color(0x87b9e0, 0.20), color(0x87b9e0, 0)]),
                         startCenter: CGPoint(x: 130, y: 45), startRadius: 0,
                         endCenter: CGPoint(x: 130, y: 45), endRadius: 320, options: [])
    // A restrained Aqua arc and two distant, faceted ridges echo the desktop.
    c.setStrokeColor(color(0x86bfee, 0.20)); c.setLineWidth(1.2)
    c.move(to: CGPoint(x: -35, y: 320))
    c.addCurve(to: CGPoint(x: 690, y: 88), control1: CGPoint(x: 196, y: 177), control2: CGPoint(x: 418, y: 120))
    c.strokePath()
    for (ridge, ink) in [
        ([(0, 370),(96, 330),(170, 366),(241, 309),(335, 366),(435, 316),(534, 365),(602, 334),(660, 355)], color(0x5683a9, 0.19)),
        ([(0, 411),(97, 368),(205, 416),(311, 368),(410, 400),(525, 358),(660, 403)], color(0x071a2c, 0.40))
    ] {
        c.setFillColor(ink); c.beginPath(); c.move(to: CGPoint(x: 0, y: 440))
        for (x, y) in ridge { c.addLine(to: CGPoint(x: x, y: y)) }
        c.addLine(to: CGPoint(x: 660, y: 440)); c.closePath(); c.fillPath()
    }
    for index in 0..<66 {
        let x = CGFloat((index * 113 + 29) % 653)
        let y = CGFloat((index * 73 + 51) % 426)
        if (x < 350 && y < 125) || (y > 337 && x > 110 && x < 550) { continue }
        let size: CGFloat = index.isMultiple(of: 9) ? 2.8 : 1.5
        c.setFillColor(color(0xcce7ff, index.isMultiple(of: 9) ? 0.55 : 0.25))
        c.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
    }
    label("Snowy", at: CGPoint(x: 48, y: 79), size: 47, ink: color(0xf8fcff), medium: true, in: c)
    label("A little winter for your Mac.", at: CGPoint(x: 50, y: 109), size: 17, ink: color(0xc4def1), in: c)
    c.setStrokeColor(color(0xc4def1, 0.23)); c.setLineWidth(1)
    c.move(to: CGPoint(x: 49, y: 135)); c.addLine(to: CGPoint(x: 611, y: 135)); c.strokePath()
    label("Drag Snowy to Applications", at: CGPoint(x: 330, y: 168), size: 17,
          ink: color(0xe8f5ff), medium: true, centered: true, in: c)
    c.setStrokeColor(color(0xbce4ff, 0.78)); c.setLineWidth(3); c.setLineCap(.round); c.setLineJoin(.round)
    c.move(to: CGPoint(x: 285, y: 240)); c.addLine(to: CGPoint(x: 374, y: 240))
    c.move(to: CGPoint(x: 359, y: 226)); c.addLine(to: CGPoint(x: 374, y: 240))
    c.addLine(to: CGPoint(x: 359, y: 254)); c.strokePath()
    label("Then open Snowy from Applications.", at: CGPoint(x: 330, y: 361), size: 15,
          ink: color(0xe8f5ff), centered: true, in: c)
    label("macOS 14 or later", at: CGPoint(x: 330, y: 396), size: 12,
          ink: color(0xb4cde2), centered: true, in: c)
}
func icon(_ c: CGContext, size: CGFloat) {
    c.scaleBy(x: size / 1024, y: size / 1024)
    let box = CGRect(x: 118, y: 100, width: 788, height: 788)
    let shape = CGPath(roundedRect: box, cornerWidth: 198, cornerHeight: 198, transform: nil)
    c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: 29), blur: 40, color: color(0x071c38, 0.38))
    c.setFillColor(color(0x1b68ad)); c.addPath(shape); c.fillPath(); c.restoreGState()
    c.saveGState(); c.addPath(shape); c.clip()
    c.drawLinearGradient(gradient([color(0xc9f2ff), color(0x77c1ee), color(0x459fdc), color(0x165ca3)], [0, 0.45, 0.51, 1]),
                         start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 888), options: [])
    c.setFillColor(color(0xffffff, 0.38)); c.move(to: CGPoint(x: 140, y: 377))
    c.addQuadCurve(to: CGPoint(x: 884, y: 377), control: CGPoint(x: 512, y: 130))
    c.addLine(to: CGPoint(x: 884, y: 108)); c.addLine(to: CGPoint(x: 140, y: 108)); c.closePath(); c.fillPath()
    c.restoreGState()
    c.addPath(shape); c.setStrokeColor(color(0x226ea8, 0.84)); c.setLineWidth(10); c.strokePath()
    c.setStrokeColor(color(0xffffff)); c.setLineWidth(38); c.setLineCap(.round); c.setLineJoin(.round)
    for ray in 0..<6 {
        c.saveGState(); c.translateBy(x: 512, y: 497); c.rotate(by: CGFloat(ray) * .pi / 3)
        c.move(to: .zero); c.addLine(to: CGPoint(x: 0, y: -265))
        c.move(to: CGPoint(x: -84, y: -221)); c.addLine(to: CGPoint(x: 0, y: -145))
        c.addLine(to: CGPoint(x: 84, y: -221)); c.strokePath(); c.restoreGState()
    }
}
let arguments = CommandLine.arguments
if arguments.count != 3 { fatalError("Usage: render-install-art.swift background|icon output-directory") }
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
switch arguments[1] {
case "background":
    for scale in [1, 2] {
        try render(660, 440, scale: scale, to: output.appendingPathComponent(scale == 1 ? "Snowy.png" : "Snowy@2x.png"), draw: background)
    }
case "icon":
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
            try render(size, size, scale: scale, to: output.appendingPathComponent(name)) { icon($0, size: CGFloat(size)) }
        }
    }
default: fatalError("Unknown artwork type")
}
