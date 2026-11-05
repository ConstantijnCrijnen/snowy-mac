import AppKit
import SnowCore

/// Placement shared by the editor and the click-through desktop layer. All
/// coordinates are in display-local points, with Y increasing down.
enum DecorationPlacement {
    static func frame(for prop: PlacedDecoration, piece: DecorationPiece,
                      desktopSize: CGSize, dock: CGRect?) -> CGRect {
        let rail = rail(for: prop.support, desktopSize: desktopSize, dock: dock)
        let scale = prop.scale.isFinite ? min(1.6, max(0.65, prop.scale)) : 1
        let pixel = min(3 * scale, rail.width / CGFloat(piece.width), rail.maxY / CGFloat(piece.solidBottom))
        guard pixel.isFinite, pixel > 0 else { return .zero }
        let width = CGFloat(piece.width) * pixel
        let normalizedX = prop.x.isFinite ? min(1, max(0, prop.x)) : 0.5
        let left = min(rail.maxX - width, max(rail.minX, desktopSize.width * normalizedX - width / 2))
        return CGRect(x: left, y: rail.maxY - CGFloat(piece.solidBottom) * pixel,
                      width: width, height: CGFloat(piece.height) * pixel)
    }

    static func support(at point: CGPoint, dock: CGRect?) -> DecorationSupport {
        guard let dock, !dock.isEmpty else { return .floor }
        return dock.insetBy(dx: -6, dy: -24).contains(point) ? .dock : .floor
    }

    static func rail(for support: DecorationSupport, desktopSize: CGSize, dock: CGRect?) -> CGRect {
        let screen = CGRect(origin: .zero, size: desktopSize)
        if support == .dock, let dock {
            let visible = dock.intersection(screen)
            if !visible.isEmpty, visible.minY > 0 {
                // Leave the tapered Dock shoulders clear.
                let inset = min(6, visible.width * 0.1)
                return CGRect(x: visible.minX + inset, y: 0, width: visible.width - 2 * inset, height: visible.minY)
            }
        }
        return screen
    }
}

/// Static nearest-neighbor sprites and small silhouette colliders. Only active
/// cursor pushes update positions on the existing snow render clock.
@MainActor
final class DesktopDecorations {
    let view: NSView
    var isEmpty: Bool { sprites.isEmpty }

    private let size: CGSize
    private var configured: [PlacedDecoration] = []
    private var sprites: [Sprite] = []
    private var dock: CGRect?
    private var nextBodyID: UInt64 = 1 << 60
    private var hasPushableProps = false
    private var previousPointer: SIMD2<Float>?
    private var lastFrame: TimeInterval?

    private struct Sprite {
        var prop: PlacedDecoration
        let piece: DecorationPiece
        let layer: CALayer
        let bodyID: UInt64
        /// Conservative silhouette strips in source pixels, widest first.
        let bands: [CGRect]
        var frame: CGRect
        var velocity: CGFloat = 0

        var pixel: CGFloat { frame.width / CGFloat(piece.width) }

        func bounds(for band: CGRect) -> CGRect {
            CGRect(x: frame.minX + band.minX * pixel, y: frame.minY + band.minY * pixel,
                   width: band.width * pixel, height: band.height * pixel)
        }
    }

    init(size: CGSize) {
        self.size = size
        view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.masksToBounds = true
        view.autoresizingMask = [.width, .height]
    }

    func configure(props: [PlacedDecoration]) {
        let props = Array(props.prefix(DecorationScene.maxProps))
        guard props != configured else { return }
        configured = props
        let previous = Dictionary(uniqueKeysWithValues: sprites.map { ($0.prop.id, $0) })
        var ids = Set<UUID>()
        sprites = props.compactMap { prop -> Sprite? in
            guard ids.insert(prop.id).inserted, let piece = DecorationCatalog.piece(prop.assetID) else { return nil }
            let frame = DecorationPlacement.frame(for: prop, piece: piece, desktopSize: size, dock: dock)
            if var sprite = previous[prop.id], sprite.prop.assetID == prop.assetID {
                let movedInEditor = sprite.prop.x != prop.x || sprite.prop.scale != prop.scale || sprite.prop.support != prop.support
                sprite.prop = prop
                if movedInEditor { sprite.frame = frame }
                if movedInEditor || !prop.pushes { sprite.velocity = 0 }
                return sprite
            }
            let layer = CALayer()
            layer.contents = piece.image
            layer.magnificationFilter = .nearest
            layer.minificationFilter = .nearest
            defer { nextBodyID += 8 }
            return Sprite(prop: prop, piece: piece, layer: layer, bodyID: nextBodyID,
                          bands: Self.silhouetteBands(for: piece), frame: frame)
        }
        hasPushableProps = sprites.contains { $0.prop.pushes }
        previousPointer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.sublayers = sprites.map(\.layer)
        for sprite in sprites { positionLayer(for: sprite) }
        CATransaction.commit()
    }

    func reset() {
        previousPointer = nil
        for index in sprites.indices {
            let sprite = sprites[index]
            sprites[index].frame = DecorationPlacement.frame(for: sprite.prop, piece: sprite.piece,
                                                              desktopSize: size, dock: dock)
            sprites[index].velocity = 0
        }
        updateLayers()
    }

    func updateDock(_ bounds: CGRect?) {
        guard dock != bounds else { return }
        dock = bounds
        guard sprites.contains(where: { $0.prop.support == .dock }) else { return }
        for index in sprites.indices where sprites[index].prop.support == .dock {
            let sprite = sprites[index]
            var placement = sprite.prop
            placement.x = sprite.frame.midX / max(1, size.width)
            sprites[index].frame = DecorationPlacement.frame(for: placement, piece: sprite.piece,
                                                              desktopSize: size, dock: dock)
            sprites[index].velocity = 0
        }
        updateLayers()
    }

    private func positionLayer(for sprite: Sprite) {
        sprite.layer.bounds = CGRect(origin: .zero, size: sprite.frame.size)
        sprite.layer.position = CGPoint(x: sprite.frame.midX, y: size.height - sprite.frame.midY)
    }

    private func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sprite in sprites { positionLayer(for: sprite) }
        CATransaction.commit()
    }

    private static func silhouetteBands(for piece: DecorationPiece) -> [CGRect] {
        var tops = Array(repeating: piece.height, count: piece.width)
        var bottoms = Array(repeating: 0, count: piece.width)
        for y in 0..<piece.height {
            for x in 0..<piece.width where piece.alpha[y * piece.width + x] > 0 {
                tops[x] = min(tops[x], y)
                bottoms[x] = y + 1
            }
        }
        let bandCount = min(6, max(1, piece.width / 4))
        return (0..<bandCount).compactMap { index -> CGRect? in
            var left = piece.width * index / bandCount
            var right = piece.width * (index + 1) / bandCount
            while left < right && bottoms[left] == 0 { left += 1 }
            while right > left && bottoms[right - 1] == 0 { right -= 1 }
            guard left < right, let top = tops[left..<right].max(),
                  let bottom = bottoms[left..<right].min(), top < bottom else { return nil }
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }.sorted { first, second in
            first.width == second.width ? first.minY < second.minY : first.width > second.width
        }
    }

    func advance(cursor: SIMD2<Float>?, now: TimeInterval, reducedMotion: Bool,
                 occluders: [SolidBody], isCoveredByOwnWindow: (SIMD2<Float>) -> Bool) -> Bool {
        guard hasPushableProps else { return false }
        let elapsed = now - (lastFrame ?? now)
        defer {
            lastFrame = now
            previousPointer = cursor
        }
        guard elapsed > 0, elapsed <= 0.15 else {
            // Resume with settled props after an interrupted or paused render clock.
            for index in sprites.indices { sprites[index].velocity = 0 }
            return false
        }
        let dt = CGFloat(elapsed)
        var pushed: Int?
        if let cursor, let start = previousPointer {
            let delta = cursor - start
            let horizontal = abs(delta.x)
            if horizontal >= max(1.5, Float(dt) * 55), horizontal > abs(delta.y) * 0.45, horizontal < 220 {
                pushed = sprites.indices.reversed().first { index in
                    guard sprites[index].prop.pushes else { return false }
                    return sprites[index].bands.contains { band in
                        let rect = sprites[index].bounds(for: band).insetBy(dx: -5, dy: -4)
                        let center = SIMD2(Float(rect.midX), Float(rect.midY))
                        let contact = Geometry.closestPoint(to: center, on: start, cursor)
                        return rect.contains(CGPoint(x: CGFloat(contact.x), y: CGFloat(contact.y)))
                            && !occluders.contains { $0.contains(contact) } && !isCoveredByOwnWindow(contact)
                    }
                }
                if let pushed {
                    let speed = CGFloat(delta.x) / dt * 0.74
                    sprites[pushed].velocity = min(680, max(-680, speed))
                }
            }
        }

        var changed = false
        for index in sprites.indices where sprites[index].velocity != 0 {
            let velocity = sprites[index].velocity
            guard !reducedMotion || pushed == index else {
                sprites[index].velocity = 0
                continue
            }
            let x = sprites[index].frame.minX
            let offset = slide(for: index, by: velocity * dt)
            if abs(offset) > 0.001 {
                sprites[index].frame.origin.x = x + offset
                changed = true
            }
            let remaining = velocity * exp(-11 * dt)
            sprites[index].velocity = reducedMotion || abs(remaining) < 8 || abs(offset - velocity * dt) > 0.001
                ? 0 : remaining
        }
        if changed { updateLayers() }
        return changed
    }

    private func slide(for index: Int, by distance: CGFloat) -> CGFloat {
        let sprite = sprites[index]
        let frame = sprite.frame
        let rail = DecorationPlacement.rail(for: sprite.prop.support, desktopSize: size, dock: dock)
        var travel = min(rail.maxX - frame.maxX, max(rail.minX - frame.minX, distance))
        for other in sprites where other.prop.id != sprite.prop.id {
            guard frame.maxY > other.frame.minY + 0.5, frame.minY < other.frame.maxY - 0.5 else { continue }
            // Existing overlaps from a composed scene can separate in either outward direction.
            if travel > 0, other.frame.midX > frame.midX {
                travel = min(travel, max(0, other.frame.minX - frame.maxX))
            } else if travel < 0, other.frame.midX < frame.midX {
                travel = max(travel, min(0, other.frame.maxX - frame.minX))
            }
        }
        return travel
    }

    func scene(with snapshot: DisplaySnapshot, budget: SimulationBudget) -> DesktopScene {
        var surfaces = snapshot.surfaces
        var bodies = snapshot.bodies
        let freeBodies = DesktopSceneBuilder.maximumBodies - bodies.count
        let freeSurfaces = min(budget.surfaces, budget.cells / 5) - surfaces.count
        guard !sprites.isEmpty, freeBodies > 0 else { return DesktopScene(surfaces: surfaces, bodies: bodies) }

        // Give every prop a wide primary strip before adding silhouette detail.
        // Stable per-prop IDs let the snow solver distinguish slides from new props.
        var decorations: [SolidBody] = []
        let screen = CGRect(origin: .zero, size: size)
        for band in 0..<6 {
            for sprite in sprites where sprite.bands.indices.contains(band) {
                let rect = sprite.bounds(for: sprite.bands[band]).intersection(screen)
                guard !rect.isEmpty else { continue }
                decorations.append(SolidBody(id: sprite.bodyID + UInt64(band), bounds: rect))
                if decorations.count == freeBodies { break }
            }
            if decorations.count == freeBodies { break }
        }
        bodies.append(contentsOf: decorations)

        for index in surfaces.indices where surfaces[index].id == DesktopSceneBuilder.groundID || surfaces[index].isDock {
            let surface = surfaces[index]
            for body in decorations where body.bounds.minY < CGFloat(surface.y) {
                let span = Span(Float(body.bounds.minX) - surface.x, Float(body.bounds.maxX) - surface.x)
                surfaces[index].snowfallSpans = Geometry.subtract(span, from: surfaces[index].snowfallSpans)
                if body.bounds.maxY >= CGFloat(surface.y) - 0.5 {
                    surfaces[index].visibleSpans = Geometry.subtract(span, from: surfaces[index].visibleSpans)
                }
            }
        }
        var count = 0
        for body in decorations where count < freeSurfaces {
            let rect = body.bounds
            let width = Float(rect.width)
            var visible = [Span(0, width)]
            var snowfall = visible
            for other in bodies where other.id != body.id && other.bounds.minY < rect.minY {
                let obstruction = Span(Float(other.bounds.minX - rect.minX), Float(other.bounds.maxX - rect.minX))
                snowfall = Geometry.subtract(obstruction, from: snowfall)
                if other.bounds.maxY > rect.minY - 20 { visible = Geometry.subtract(obstruction, from: visible) }
            }
            let surface = Surface(id: body.id, x: Float(rect.minX), y: Float(rect.minY), width: width,
                                  visibleSpans: visible, snowfallSpans: snowfall,
                                  releasesSnowWhenRemoved: true, isElevated: false)
            guard !visible.isEmpty, width >= surface.minimumWidth else { continue }
            surfaces.append(surface)
            count += 1
        }
        return DesktopScene(surfaces: surfaces, bodies: bodies)
    }
}
