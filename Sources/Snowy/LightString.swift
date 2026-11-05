import Foundation

enum LightPalette: String, Codable, CaseIterable, Identifiable, Sendable {
    case classic, warmWhite, peppermint, frost

    var id: Self { self }

    var title: String {
        switch self {
        case .classic: "Classic Multicolor"
        case .warmWhite: "Warm White"
        case .peppermint: "Peppermint"
        case .frost: "Frost"
        }
    }

    var colors: [UInt32] {
        switch self {
        case .classic: [0xFF5969, 0xFFD778, 0x67E3AC, 0x68B7FF, 0xDE95FF]
        case .warmWhite: [0xFFEBC2, 0xFFD788, 0xFFF4DF]
        case .peppermint: [0xFF5367, 0xFFF4DC, 0xFF838A]
        case .frost: [0x80C9FF, 0xD7F6FF, 0x9EB0FF, 0xEEF7FF]
        }
    }
}

struct LightAnchor: Codable, Equatable, Sendable {
    enum Edge: String, Codable, CaseIterable, Sendable {
        case top, left, right, bottom

        func position(fraction: CGFloat, in bounds: CGRect) -> CGPoint {
            switch self {
            case .top: CGPoint(x: bounds.minX + fraction * bounds.width, y: bounds.minY)
            case .bottom: CGPoint(x: bounds.minX + fraction * bounds.width, y: bounds.maxY)
            case .left: CGPoint(x: bounds.minX, y: bounds.minY + fraction * bounds.height)
            case .right: CGPoint(x: bounds.maxX, y: bounds.minY + fraction * bounds.height)
            }
        }

        func fraction(near point: CGPoint, in bounds: CGRect) -> CGFloat {
            switch self {
            case .top, .bottom: Self.unit((point.x - bounds.minX) / max(1, bounds.width))
            case .left, .right: Self.unit((point.y - bounds.minY) / max(1, bounds.height))
            }
        }

        static func unit(_ value: CGFloat) -> CGFloat { value.isFinite ? min(1, max(0, value)) : 0 }
    }

    enum Attachment: Codable, Equatable, Sendable {
        case desktop(edge: Edge, fraction: Double)
        case object(id: String, edge: Edge, fraction: Double)
    }

    /// The editor stores a normalized position even when a point is attached.
    /// It remains useful when an icon is hidden or a widget is unavailable.
    var fallback: CGPoint
    var attachment: Attachment?

    init(fallback: CGPoint, attachment: Attachment? = nil) {
        self.fallback = fallback
        self.attachment = attachment
    }

    static func snapped(near point: CGPoint, in desktop: SceneDesktop, distance: CGFloat = 28) -> Self {
        var closestPoint = point
        var closestAttachment: Attachment?
        var closestDistance = max(0, distance)
        let screen = CGRect(origin: .zero, size: desktop.size)

        func consider(_ edge: Edge, bounds: CGRect, id: String?) {
            guard !bounds.isEmpty else { return }
            let fraction = edge.fraction(near: point, in: bounds)
            let candidate = edge.position(fraction: fraction, in: bounds)
            let delta = hypot(point.x - candidate.x, point.y - candidate.y)
            guard delta <= closestDistance, closestAttachment == nil || delta < closestDistance else { return }
            closestDistance = delta
            closestPoint = candidate
            closestAttachment = id.map { .object(id: $0, edge: edge, fraction: fraction) }
                ?? .desktop(edge: edge, fraction: fraction)
        }

        for target in desktop.anchors {
            for edge in Edge.allCases { consider(edge, bounds: target.bounds, id: target.id) }
        }
        for edge in [Edge.top, .left, .right] { consider(edge, bounds: screen, id: nil) }

        let fallback = CGPoint(x: Edge.unit(closestPoint.x / max(1, desktop.size.width)),
                               y: Edge.unit(closestPoint.y / max(1, desktop.size.height)))
        return Self(fallback: fallback, attachment: closestAttachment)
    }

    func position(in desktop: SceneDesktop) -> CGPoint {
        attachedPosition(in: desktop)
            ?? CGPoint(x: Edge.unit(fallback.x) * desktop.size.width,
                       y: Edge.unit(fallback.y) * desktop.size.height)
    }

    func attachedPosition(in desktop: SceneDesktop) -> CGPoint? {
        switch attachment {
        case .desktop(let edge, let fraction):
            return edge.position(fraction: Edge.unit(fraction), in: CGRect(origin: .zero, size: desktop.size))
        case .object(let id, let edge, let fraction):
            guard let object = desktop.anchors.first(where: { $0.id == id }) else { return nil }
            return edge.position(fraction: Edge.unit(fraction), in: object.bounds)
        case nil:
            return nil
        }
    }

    var followsObject: Bool {
        if case .object = attachment { return true }
        return false
    }

    var followsIcon: Bool {
        if case .object(let id, _, _) = attachment { return id.hasPrefix("icon:") }
        return false
    }
}

struct LightString: Codable, Equatable, Sendable, Identifiable {
    static let maximumStrings = 6
    static let maximumAnchors = 6
    static let slackRange = 0.04...0.65
    static let dragIdentifier = "snowy:string-lights"

    var id: UUID
    var anchors: [LightAnchor]
    var palette: LightPalette
    var slack: Double

    init(id: UUID = UUID(), anchors: [LightAnchor], palette: LightPalette = .classic, slack: Double = 0.22) {
        self.id = id
        self.anchors = anchors
        self.palette = palette
        self.slack = slack
    }

    var usableSlack: Double {
        slack.isFinite ? min(Self.slackRange.upperBound, max(Self.slackRange.lowerBound, slack)) : 0.22
    }

    static func placed(near point: CGPoint, in desktop: SceneDesktop) -> Self {
        let width = max(1, desktop.size.width)
        let height = max(1, desktop.size.height)
        let center = min(width * 0.82, max(width * 0.18, point.x))
        let top = min(height * 0.90, max(0, point.y))
        let reach = min(width * 0.32, min(center, width - center))
        return Self(anchors: [
            .snapped(near: CGPoint(x: center - reach, y: top), in: desktop),
            .snapped(near: CGPoint(x: center, y: min(height, top + min(90, height * 0.15))), in: desktop),
            .snapped(near: CGPoint(x: center + reach, y: top), in: desktop),
        ])
    }

    func previewPoints(in desktop: SceneDesktop) -> [CGPoint] {
        let anchors = anchors.prefix(Self.maximumAnchors).map { $0.position(in: desktop) }
        var points: [CGPoint] = []
        for (start, end) in zip(anchors, anchors.dropFirst()) {
            let span = Self.saggingSpan(from: start, to: end, slack: usableSlack, nodeCount: 17)
            points.append(contentsOf: points.isEmpty ? span[...] : span.dropFirst())
        }
        return points
    }

    static func restLength(from start: CGPoint, to end: CGPoint, slack: Double) -> CGFloat {
        max(14, hypot(end.x - start.x, end.y - start.y)) * (1 + slack)
    }

    /// The static preview approximates a slack span, then samples it by arc
    /// length so the same curve gives the live solver a well-spaced start.
    static func saggingSpan(from start: CGPoint, to end: CGPoint,
                            slack: Double, nodeCount: Int) -> [CGPoint] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        let target = restLength(from: start, to: end, slack: slack)
        let direction = dx < 0 ? -1.0 : 1.0
        let normal = distance > 1
            ? CGPoint(x: -dy / distance * direction, y: abs(dx) / distance)
            : CGPoint(x: 0, y: 1)

        func point(_ t: CGFloat, sag: CGFloat) -> CGPoint {
            let weight = 4 * t * (1 - t) * sag
            return CGPoint(x: start.x + dx * t + normal.x * weight, y: start.y + dy * t + normal.y * weight)
        }

        let sampleCount = 24
        func distances(sag: CGFloat) -> [CGFloat] {
            var lengths = [CGFloat(0)]
            var last = start
            for index in 1...sampleCount {
                let next = point(CGFloat(index) / CGFloat(sampleCount), sag: sag)
                lengths.append(lengths[lengths.count - 1] + hypot(next.x - last.x, next.y - last.y))
                last = next
            }
            return lengths
        }

        var low = CGFloat(0)
        var high = target / 2
        for _ in 0..<10 {
            let middle = (low + high) / 2
            if (distances(sag: middle).last ?? 0) < target { low = middle }
            else { high = middle }
        }
        let sag = (low + high) / 2
        let distances = distances(sag: sag)
        let length = distances[sampleCount]
        var sample = 1
        var points = [start]
        for index in 1..<(nodeCount - 1) {
            let target = length * CGFloat(index) / CGFloat(nodeCount - 1)
            while sample < sampleCount && distances[sample] < target { sample += 1 }
            let fraction = (target - distances[sample - 1]) / max(0.001, distances[sample] - distances[sample - 1])
            points.append(point((CGFloat(sample - 1) + fraction) / CGFloat(sampleCount), sag: sag))
        }
        points.append(end)
        return points
    }

    struct Bulb {
        var point: CGPoint
        var width: CGFloat
        var height: CGFloat
        var colorIndex: Int
    }

    /// Spacing, lamp sizes and colors stay stable while a string moves.
    func bulbs(along points: [CGPoint]) -> [Bulb] {
        guard points.count >= 2 else { return [] }
        var lengths: [CGFloat] = [0]
        lengths.reserveCapacity(points.count)
        for (start, end) in zip(points, points.dropFirst()) {
            lengths.append(lengths[lengths.count - 1] + hypot(end.x - start.x, end.y - start.y))
        }
        let total = lengths[lengths.count - 1]
        let spacing = max(15, total / 110)
        var seed = id.uuid
        var state = withUnsafeBytes(of: &seed) { bytes in
            bytes.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
        }
        func random() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return CGFloat(state >> 40) / CGFloat(1 << 24)
        }

        let colorCount = palette.colors.count
        var bulbs: [Bulb] = []
        bulbs.reserveCapacity(min(120, Int(total / spacing)))
        var next = min(total / 2, 5 + spacing * 0.4)
        var segment = 1
        while next < total - 2 && bulbs.count < 120 {
            while segment < lengths.count - 1 && lengths[segment] < next { segment += 1 }
            let a = points[segment - 1]
            let b = points[segment]
            let fraction = (next - lengths[segment - 1]) / max(0.001, lengths[segment] - lengths[segment - 1])
            let point = CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
            let width = 3.0 + random() * 1.7
            bulbs.append(Bulb(point: point, width: width, height: width * (1.35 + random() * 0.45),
                              colorIndex: min(colorCount - 1, Int(random() * CGFloat(colorCount)))))
            next += spacing * (0.78 + random() * 0.55)
        }
        return bulbs
    }
}
