import AppKit
import SnowCore

/// Advances disturbed strings on the existing desktop render clock.
@MainActor
final class DesktopHangingLights {
    let view: NSView
    var isEmpty: Bool { ropes.isEmpty }
    var followsIcons: Bool { ropes.contains { $0.model.anchors.contains(where: \.followsIcon) } }
    var followsWidgets: Bool {
        ropes.contains { $0.model.anchors.contains { $0.followsObject && !$0.followsIcon } }
    }

    private var desktop: SceneDesktop
    private var ropes: [Rope] = []
    private var lastFrame: TimeInterval?
    private var previousCursor: SIMD2<Float>?

    init(size: CGSize) {
        desktop = SceneDesktop(id: 0, size: size, dock: nil, anchors: [])
        view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.masksToBounds = true
        view.autoresizingMask = [.width, .height]
    }

    func configure(_ strings: [LightString]) {
        var identifiers = Set<UUID>()
        let models = strings.prefix(LightString.maximumStrings).compactMap { string -> LightString? in
            guard string.anchors.count >= 2, identifiers.insert(string.id).inserted else { return nil }
            var model = string
            model.anchors = Array(model.anchors.prefix(LightString.maximumAnchors))
            model.slack = model.usableSlack
            return model
        }
        guard models != ropes.map(\.model) else { return }
        previousCursor = nil

        var oldRopes = Dictionary(uniqueKeysWithValues: ropes.map { ($0.model.id, $0) })
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ropes = models.map { model in
            if let old = oldRopes.removeValue(forKey: model.id) {
                if old.model == model { return old }
                old.art.layer.removeFromSuperlayer()
            }
            let rope = Rope(model: model, desktop: desktop)
            view.layer?.addSublayer(rope.art.layer)
            rope.art.draw(rope.physics.positions, height: desktop.size.height)
            return rope
        }
        for removed in oldRopes.values { removed.art.layer.removeFromSuperlayer() }
        CATransaction.commit()
    }

    func updateDesktop(_ desktop: SceneDesktop, animate: Bool = true) {
        guard desktop != self.desktop else { return }
        self.desktop = desktop
        // Moving widgets still update the artwork when snowfall is paused and
        // there is no render frame to animate the transition.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for rope in ropes where rope.physics.update(in: desktop) {
            if animate { rope.physics.step(dt: 1 / 60, in: desktop.size) }
            else { rope.physics.settle(in: desktop.size) }
            rope.art.draw(rope.physics.positions, height: desktop.size.height)
        }
        CATransaction.commit()
    }

    func advance(now: TimeInterval, wind: WindSettings, cursor: SIMD2<Float>?,
                 reducedMotion: Bool, isCovered: (SIMD2<Float>) -> Bool) {
        guard !ropes.isEmpty else {
            lastFrame = nil
            previousCursor = nil
            return
        }
        let elapsed = now - (lastFrame ?? now - 1 / 30)
        if let lastFrame, elapsed < 1 / 30 - 0.002 {
            if now >= lastFrame { return }
        }
        lastFrame = now
        let oldCursor = previousCursor
        let onDesktop = cursor.flatMap { point in
            (point.x >= 0 && point.y >= 0
             && CGFloat(point.x) <= desktop.size.width && CGFloat(point.y) <= desktop.size.height) ? point : nil
        }
        previousCursor = reducedMotion ? nil : onDesktop
        if !reducedMotion, elapsed > 0, elapsed <= 0.15,
           let oldCursor, let onDesktop, onDesktop != oldCursor {
            for rope in ropes {
                rope.physics.brush(from: oldCursor, to: onDesktop, isCovered: isCovered)
            }
        }

        let hasWind = !reducedMotion && wind.speedFraction >= 0.01
        guard hasWind || ropes.contains(where: { $0.physics.isMoving }) else { return }
        let dt = min(1 / 30.0, max(1 / 120.0, elapsed))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for rope in ropes where hasWind || rope.physics.isMoving {
            if reducedMotion {
                rope.physics.settle(in: desktop.size)
            } else {
                let gust = hasWind ? 112 + 68 * sin(now * 2.05 + rope.phase) + 23 * sin(now * 3.51 + rope.phase) : 0
                let acceleration = CGPoint(x: Double(wind.vector.x) * gust, y: Double(wind.vector.y) * gust)
                rope.physics.step(dt: dt / 2, in: desktop.size, windAcceleration: acceleration)
                rope.physics.step(dt: dt / 2, in: desktop.size, windAcceleration: acceleration)
            }
            rope.art.draw(rope.physics.positions, height: desktop.size.height)
        }
        CATransaction.commit()
    }

    private final class Rope {
        let model: LightString
        var physics: HangingRope
        let art: RopeArt
        let phase: Double

        init(model: LightString, desktop: SceneDesktop) {
            self.model = model
            physics = HangingRope(model: model, desktop: desktop)
            art = RopeArt(model: model, size: desktop.size)
            phase = Double(model.id.uuid.0) * (2 * .pi / 256)
        }
    }
}

/// Contiguous Verlet nodes share the joints of adjacent spans. Their fixed
/// positions are refreshed from desktop metadata.
struct HangingRope {
    private let model: LightString
    private let jointNodes: [Int]
    private let jointLengths: [CGFloat]
    private let linkLengths: [CGFloat]
    private var held: [Bool]
    private var wasFollowing: [Bool]
    private var joints: [CGPoint]
    private var pins: [CGPoint?]
    private(set) var positions: [CGPoint]
    private var previous: [CGPoint]
    private var stepsRemaining = 0
    var isMoving: Bool { stepsRemaining > 0 }

    init(model: LightString, desktop: SceneDesktop) {
        self.model = model
        let joints = model.anchors.map { $0.position(in: desktop) }
        self.joints = joints
        held = joints.map { _ in true }
        wasFollowing = model.anchors.map { $0.followsObject && $0.attachedPosition(in: desktop) != nil }

        var points: [CGPoint] = []
        var cumulative: [CGFloat] = [0]
        var nodes = [0]
        var links: [CGFloat] = []
        for (start, end) in zip(joints, joints.dropFirst()) {
            let length = LightString.restLength(from: start, to: end, slack: model.usableSlack)
            let count = min(24, max(6, Int(length / 24) + 1))
            let span = LightString.saggingSpan(from: start, to: end, slack: model.usableSlack, nodeCount: count)
            points.append(contentsOf: points.isEmpty ? span[...] : span.dropFirst())
            links.append(contentsOf: repeatElement(length / CGFloat(count - 1), count: count - 1))
            cumulative.append((cumulative.last ?? 0) + length)
            nodes.append(points.count - 1)
        }
        positions = points
        previous = points
        jointNodes = nodes
        jointLengths = cumulative
        linkLengths = links
        pins = points.map { _ in nil }
        for (node, point) in zip(nodes, joints) where pins.indices.contains(node) { pins[node] = point }
    }

    /// Sample a new desktop geometry. If a fixed span is stretched past its
    /// length, release the object anchor that moved furthest during the sample.
    mutating func update(in desktop: SceneDesktop) -> Bool {
        guard jointNodes.count == joints.count, joints.count >= 2 else { return false }
        var next = joints
        var travel = joints.map { _ in CGFloat(0) }
        var changed = false
        for index in joints.indices where held[index] {
            let anchor = model.anchors[index]
            let attachment = anchor.attachedPosition(in: desktop)
            if anchor.followsObject, attachment == nil, wasFollowing[index] {
                held[index] = false
                changed = true
                continue
            }
            if attachment != nil && anchor.followsObject { wasFollowing[index] = true }
            next[index] = attachment ?? anchor.position(in: desktop)
            travel[index] = hypot(next[index].x - joints[index].x, next[index].y - joints[index].y)
            changed = changed || travel[index] > 0.25
        }

        var preceding: Int?
        for index in joints.indices where held[index] {
            if let start = preceding {
                let distance = hypot(next[index].x - next[start].x, next[index].y - next[start].y)
                let reach = jointLengths[index] - jointLengths[start]
                if distance > reach * 1.22 + 9 {
                    let movable = [start, index].filter { model.anchors[$0].followsObject && travel[$0] > 0.25 }
                    if let detached = movable.max(by: { travel[$0] < travel[$1] }) {
                        held[detached] = false
                        changed = true
                        if detached == index { continue }
                    }
                }
            }
            preceding = index
        }
        guard changed else { return false }

        for index in joints.indices {
            let node = jointNodes[index]
            if held[index] {
                joints[index] = next[index]
                pins[node] = next[index]
            } else {
                pins[node] = nil
            }
        }
        stepsRemaining = 120
        return true
    }

    /// Pick the first visible intersection along a swept pointer sample. Only
    /// nodes near the contact receive momentum, and pins remain fixed.
    @discardableResult
    mutating func brush(from start: SIMD2<Float>, to end: SIMD2<Float>,
                        isCovered: (SIMD2<Float>) -> Bool) -> Bool {
        let motion = end - start
        let travel = hypot(motion.x, motion.y)
        guard travel >= 2, travel <= 260, positions.count >= 2 else { return false }
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }

        var firstHit: Float = .infinity
        var contact: Float?
        for index in linkLengths.indices {
            let a = positions[index]
            let b = positions[index + 1]
            let base = SIMD2(Float(a.x), Float(a.y))
            let link = SIMD2(Float(b.x - a.x), Float(b.y - a.y))
            let denominator = cross(motion, link)
            guard abs(denominator) > 0.001 else { continue }
            let offset = base - start
            let t = cross(offset, link) / denominator
            let u = cross(offset, motion) / denominator
            guard t > 0.001, t <= 1, t < firstHit, u >= 0, u <= 1,
                  !isCovered(start + t * motion) else { continue }
            firstHit = t
            contact = Float(index) + u
        }
        guard let contact else { return false }
        let impulse = motion / travel * min(2.8, 1.5 + travel * 0.035)
        let low = max(0, Int(contact.rounded(.down)) - 2)
        let high = min(positions.count - 1, Int(contact.rounded(.up)) + 2)
        var nudged = false
        for index in low...high where pins[index] == nil {
            let weight = max(0, 1 - abs(Float(index) - contact) / 2.6)
            guard weight > 0 else { continue }
            previous[index].x -= CGFloat(impulse.x * weight)
            previous[index].y -= CGFloat(impulse.y * weight)
            nudged = true
        }
        if nudged { stepsRemaining = max(stepsRemaining, 72) }
        return nudged
    }

    mutating func step(dt: TimeInterval, in bounds: CGSize, windAcceleration: CGPoint = .zero) {
        if windAcceleration != .zero { stepsRemaining = max(stepsRemaining, 60) }
        guard isMoving, positions.count >= 2 else { return }
        stepsRemaining -= 1
        let accelerationX = windAcceleration.x * dt * dt
        let accelerationY = (510 + windAcceleration.y) * dt * dt
        for index in positions.indices where pins[index] == nil {
            let point = positions[index]
            let velocity = CGPoint(x: (point.x - previous[index].x) * 0.91,
                                   y: (point.y - previous[index].y) * 0.91)
            previous[index] = point
            positions[index] = CGPoint(x: point.x + velocity.x + accelerationX,
                                       y: point.y + velocity.y + accelerationY)
        }
        for iteration in 0..<6 {
            for index in positions.indices {
                if let pin = pins[index] { positions[index] = pin }
            }
            if iteration.isMultiple(of: 2) {
                for index in linkLengths.indices { constrainLink(at: index) }
            } else {
                for index in linkLengths.indices.reversed() { constrainLink(at: index) }
            }
        }
        for index in positions.indices where pins[index] == nil {
            let point = positions[index]
            positions[index] = CGPoint(x: min(bounds.width, max(0, point.x)),
                                       y: min(bounds.height - 5, max(0, point.y)))
        }
    }

    mutating func settle(in bounds: CGSize) {
        for _ in 0..<36 { step(dt: 1 / 60, in: bounds) }
        stepsRemaining = 0
    }

    private mutating func constrainLink(at index: Int) {
        let next = index + 1
        let movableA = pins[index] == nil
        let movableB = pins[next] == nil
        guard movableA || movableB else { return }
        let a = positions[index]
        let b = positions[next]
        let dx = b.x - a.x
        let dy = b.y - a.y
        let distance = hypot(dx, dy)
        guard distance > 0.001 else { return }
        let fraction = (distance - linkLengths[index]) / distance * (movableA && movableB ? 0.5 : 1)
        if movableA { positions[index] = CGPoint(x: a.x + dx * fraction, y: a.y + dy * fraction) }
        if movableB { positions[next] = CGPoint(x: b.x - dx * fraction, y: b.y - dy * fraction) }
    }
}

private final class RopeArt {
    let layer = CALayer()
    private let model: LightString
    private let outline = CAShapeLayer()
    private let wire = CAShapeLayer()
    private let sockets = CAShapeLayer()
    private let shine = CAShapeLayer()
    private let bulbs: [CAShapeLayer]
    private let halos: [CAShapeLayer]

    init(model: LightString, size: CGSize) {
        self.model = model
        layer.frame = CGRect(origin: .zero, size: size)
        bulbs = model.palette.colors.map { Self.filled(Self.color($0)) }
        halos = model.palette.colors.map { Self.filled(Self.color($0, alpha: 0.13)) }
        for halo in halos { layer.addSublayer(halo) }
        for (stroke, color, width) in [(outline, 0x172721 as UInt32, 2.5), (wire, 0x678076, 0.9),
                                       (sockets, 0x30463D, 1.7)] {
            stroke.fillColor = nil
            stroke.strokeColor = Self.color(color)
            stroke.lineWidth = width
            stroke.lineCap = .round
            stroke.lineJoin = .round
            layer.addSublayer(stroke)
        }
        for bulb in bulbs { layer.addSublayer(bulb) }
        shine.fillColor = Self.color(0xFFFFF8, alpha: 0.72)
        layer.addSublayer(shine)
    }

    func draw(_ points: [CGPoint], height: CGFloat) {
        guard let first = points.first, let last = points.last, points.count >= 2 else { return }
        func native(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: height - point.y) }

        let cable = CGMutablePath()
        cable.move(to: native(first))
        for index in 1..<(points.count - 1) {
            let point = points[index]
            let next = points[index + 1]
            let mid = CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2)
            cable.addQuadCurve(to: native(mid), control: native(point))
        }
        cable.addLine(to: native(last))
        setPath(cable, on: outline)
        setPath(cable, on: wire)

        let sockets = CGMutablePath()
        let highlights = CGMutablePath()
        let bulbPaths = bulbs.map { _ in CGMutablePath() }
        let haloPaths = halos.map { _ in CGMutablePath() }
        for bulb in model.bulbs(along: points) {
            let root = native(bulb.point)
            sockets.move(to: root)
            sockets.addLine(to: CGPoint(x: root.x, y: root.y - 3.2))
            let rect = CGRect(x: root.x - bulb.width / 2, y: root.y - 2.3 - bulb.height,
                              width: bulb.width, height: bulb.height)
            bulbPaths[bulb.colorIndex].addEllipse(in: rect)
            haloPaths[bulb.colorIndex].addEllipse(in: rect.insetBy(dx: -3.1, dy: -3.1))
            highlights.addEllipse(in: CGRect(x: rect.midX - 0.7, y: rect.maxY - 2.1, width: 1.3, height: 1.3))
        }
        setPath(sockets, on: self.sockets)
        setPath(highlights, on: shine)
        for index in bulbs.indices {
            setPath(bulbPaths[index], on: bulbs[index])
            setPath(haloPaths[index], on: halos[index])
        }
    }

    private func setPath(_ path: CGPath, on shape: CAShapeLayer) {
        guard !path.isEmpty else {
            if shape.path != nil { shape.path = nil }
            if shape.frame != .zero { shape.frame = .zero }
            return
        }

        // Keep Core Animation's backing areas local to each strand, and keep
        // their bounds stable across small movements within a grid cell.
        let margin = shape.lineWidth / 2 + 2
        let padded = path.boundingBoxOfPath.insetBy(dx: -margin, dy: -margin)
        let grid: CGFloat = 32
        let left = (padded.minX / grid).rounded(.down) * grid
        let bottom = (padded.minY / grid).rounded(.down) * grid
        let right = (padded.maxX / grid).rounded(.up) * grid
        let top = (padded.maxY / grid).rounded(.up) * grid
        let frame = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
        if shape.frame != frame { shape.frame = frame }
        var toLocal = CGAffineTransform(translationX: -left, y: -bottom)
        shape.path = path.copy(using: &toLocal)
    }

    private static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: alpha)
    }

    private static func filled(_ color: CGColor) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = color
        return layer
    }
}
