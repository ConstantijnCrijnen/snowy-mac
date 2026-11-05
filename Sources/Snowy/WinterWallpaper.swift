import CoreGraphics
import Foundation

/// Snowy's original starter artwork. Each image is drawn only when previewed or applied.
enum WinterWallpaper: String, CaseIterable, Sendable {
    case blueHour = "blue-hour"
    case alpenglow

    var title: String {
        switch self {
        case .blueHour: "Blue Hour"
        case .alpenglow: "Alpenglow"
        }
    }

    func makeImage(width: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: width * 9 / 16,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let scale = CGFloat(width) / 1_600
        context.scaleBy(x: scale, y: scale)
        let blue = self == .blueHour
        let sky = blue ? [0x0b1c38, 0x2d5578, 0x8ca7b2] : [0x201c38, 0x57496a, 0xb57e84]
        if let gradient = CGGradient(colorsSpace: space, colors: sky.map { color($0) } as CFArray,
                                     locations: [0, 0.65, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 650, y: 900),
                                       end: CGPoint(x: 1_030, y: 250),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }

        let moon = blue ? CGPoint(x: 1_220, y: 687) : CGPoint(x: 384, y: 561)
        let moonlight = blue ? 0xe3edf0 : 0xffd3ab
        if let glow = CGGradient(colorsSpace: space,
                                 colors: [color(moonlight, opacity: 0.17), color(moonlight, opacity: 0)] as CFArray,
                                 locations: [0, 1]) {
            context.drawRadialGradient(glow, startCenter: moon, startRadius: 0,
                                       endCenter: moon, endRadius: 124, options: [])
        }
        context.setFillColor(color(moonlight, opacity: 0.91))
        context.fillEllipse(in: CGRect(x: moon.x - 29, y: moon.y - 29, width: 58, height: 58))
        for index in 0..<62 {
            let x = (index * 233 + 53) % 1_600
            let y = (index * index * 27 + index * 89) % 420 + 470
            let size = index.isMultiple(of: 9) ? 3 : 1
            let opacity = CGFloat((index * 13) % 5 + 1) * (blue ? 0.12 : 0.07)
            context.setFillColor(color(0xe6edff, opacity: opacity))
            context.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
        }

        polygon(context, [(0, 237), (168, 306), (318, 280), (562, 425), (690, 325), (784, 348),
                          (899, 256), (1_079, 350), (1_272, 288), (1_469, 407), (1_600, 325),
                          (1_600, 0), (0, 0)], blue ? 0x3b5673 : 0x735971)
        polygon(context, [(377, 316), (562, 425), (690, 325), (598, 353), (556, 338), (527, 365)],
                blue ? 0x92a7bc : 0xc69c9a)
        polygon(context, [(1_311, 312), (1_469, 407), (1_600, 325), (1_515, 345),
                          (1_456, 332), (1_446, 355)], blue ? 0x889fb7 : 0xc69899)
        polygon(context, [(0, 210), (192, 254), (357, 178), (517, 227), (641, 196),
                          (895, 284), (1_066, 219), (1_169, 241), (1_335, 179), (1_600, 250),
                          (1_600, 0), (0, 0)], blue ? 0x263d58 : 0x463d56)

        let hill = CGMutablePath()
        hill.move(to: CGPoint(x: 0, y: 126))
        hill.addQuadCurve(to: CGPoint(x: 780, y: 83), control: CGPoint(x: 370, y: 32))
        hill.addQuadCurve(to: CGPoint(x: 1_600, y: 128), control: CGPoint(x: 1_223, y: 142))
        hill.addLines(between: [CGPoint(x: 1_600, y: 0), .zero])
        hill.closeSubpath()
        context.addPath(hill)
        context.setFillColor(color(blue ? 0x1b2e48 : 0x322c46))
        context.fillPath()

        for index in 0..<24 {
            let x = CGFloat(index * 47 + (index * 73) % 32) + (blue ? 2 : 485)
            let y = CGFloat((index * 29) % 47 + 89)
            let height = CGFloat((index * 37) % 88 + 30)
            tree(context, x: x, y: y, height: height, fill: blue ? 0x182c42 : 0x2d263e)
        }
        if !blue { cabin(context) }
        return context.makeImage()
    }

    private func tree(_ context: CGContext, x: CGFloat, y: CGFloat, height: CGFloat, fill: Int) {
        for tier in 0..<3 {
            let base = y + CGFloat(tier) * height * 0.23
            let spread = height * (0.21 - CGFloat(tier) * 0.035)
            polygon(context, [(x - spread, base), (x + 1, base + height * 0.53), (x + spread, base)], fill)
        }
    }

    private func cabin(_ context: CGContext) {
        context.setFillColor(color(0x2a263d))
        context.fill(CGRect(x: 271, y: 82, width: 83, height: 44))
        polygon(context, [(257, 121), (309, 161), (368, 121)], 0x352a40)
        polygon(context, [(258, 122), (309, 164), (368, 122), (353, 122), (309, 151), (272, 122)], 0x97899a)
        context.setFillColor(color(0xe5a771))
        context.fill(CGRect(x: 282, y: 97, width: 12, height: 11))
        context.fill(CGRect(x: 329, y: 97, width: 12, height: 11))
    }

    private func polygon(_ context: CGContext, _ points: [(CGFloat, CGFloat)], _ fill: Int) {
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(color(fill))
        context.fillPath()
    }

    private func color(_ rgb: Int, opacity: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: opacity)
    }
}
