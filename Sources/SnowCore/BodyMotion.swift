import Foundation

/// A persistent window changes its boundaries; it does not become a newly appearing eraser.
public struct BodyMotion: Sendable {
    public let old: SolidBody
    public let new: SolidBody

    public init(old: SolidBody, new: SolidBody) {
        self.old = old
        self.new = new
    }

    /// Relative continuous contact for material carried by another moving support. The
    /// contact time selects the first obstacle; placement follows its final outer face.
    func contact(from start: SIMD2<Float>, to end: SIMD2<Float>, radius: Float) -> ParticleHit? {
        guard Self.valid(start), Self.valid(end), radius.isFinite, radius >= 0,
              BodyChanges.valid(old), BodyChanges.valid(new) else { return nil }
        if isTranslation {
            guard var hit = ParticleCollision.hit(from: start, to: end - translation, radius: radius,
                rectangle: old.bounds, cornerRadius: old.cornerRadius) else { return nil }
            hit.position += translation
            hit.position = outsideNewFace(hit.position, normal: hit.normal, padding: radius)
            return hit
        }
        let travel = end - start
        let relativeNew = SolidBody(id: new.id,
            bounds: new.bounds.offsetBy(dx: -CGFloat(travel.x), dy: -CGFloat(travel.y)),
            cornerRadius: new.cornerRadius, isElevated: new.isElevated)
        let relative = BodyMotion(old: old, new: relativeNew)
        guard let hit = relative.resizeContact(at: start, padding: radius) else { return nil }
        let point = outsideNewFace(start + travel * hit.time, normal: hit.normal, padding: radius)
        return ParticleHit(time: hit.time, position: point, normal: hit.normal)
    }

    public var leadingDirection: SIMD2<Float> {
        let translation = SIMD2(Float(new.bounds.midX - old.bounds.midX),
                                Float(new.bounds.midY - old.bounds.midY))
        let length = hypot(translation.x, translation.y)
        if length > 0.0001 { return translation / length }
        let growth = outwardFaceMotion
        var largest: Float = 0
        var direction = SIMD2<Float>.zero
        for face in 0..<4 where growth[face] > largest {
            largest = growth[face]
            direction = Self.normal(for: face)
        }
        return direction
    }

    /// The local entering face matters when a centered resize expands in multiple directions.
    public func direction(at point: SIMD2<Float>, padding: Float = 0) -> SIMD2<Float> {
        guard Self.valid(point), padding.isFinite, padding >= 0, padding <= 100_000,
              BodyChanges.valid(old), BodyChanges.valid(new) else { return .zero }
        if isTranslation {
            let delta = translation
            if let hit = ParticleCollision.hit(from: point, to: point - delta, radius: padding,
                                                rectangle: old.bounds, cornerRadius: old.cornerRadius) {
                return hit.normal
            }
        } else if let contact = resizeContact(at: point, padding: padding) {
            return contact.normal
        }
        return leadingDirection
    }

    /// Returns the point carried just beyond an entering boundary, including boundaries that
    /// crossed the point completely between snapshots. Nil means the motion did not touch it.
    public func displacedPosition(of point: SIMD2<Float>, padding: Float = 0) -> SIMD2<Float>? {
        guard old.id == new.id, Self.valid(point), padding.isFinite, padding >= 0, padding <= 100_000,
              BodyChanges.valid(old), BodyChanges.valid(new), old != new else { return nil }
        if isTranslation {
            guard let hit = ParticleCollision.hit(from: point, to: point - translation, radius: padding,
                                                   rectangle: old.bounds, cornerRadius: old.cornerRadius) else { return nil }
            return hit.position + translation + hit.normal * 0.05
        }
        guard let contact = resizeContact(at: point, padding: padding) else { return nil }
        return outsideNewFace(point, normal: contact.normal, padding: padding)
    }

    private var translation: SIMD2<Float> {
        SIMD2(Float(new.bounds.minX - old.bounds.minX), Float(new.bounds.minY - old.bounds.minY))
    }

    private var isTranslation: Bool {
        abs(new.bounds.width - old.bounds.width) < 0.0001
            && abs(new.bounds.height - old.bounds.height) < 0.0001
            && abs(new.cornerRadius - old.cornerRadius) < 0.0001
    }

    /// Left, right, top and bottom outward growth (negative values are retreating faces).
    private var outwardFaceMotion: SIMD4<Float> {
        SIMD4(Float(old.bounds.minX - new.bounds.minX), Float(new.bounds.maxX - old.bounds.maxX),
              Float(old.bounds.minY - new.bounds.minY), Float(new.bounds.maxY - old.bounds.maxY))
    }

    private func resizeContact(at point: SIMD2<Float>, padding: Float) -> (time: Float, normal: SIMD2<Float>)? {
        // Solve the time interval in which the linearly changing bounding rectangle covers
        // this stationary point, then refine only its rounded entry. Work is strictly bounded.
        let previous = SIMD4(Float(old.bounds.minX) - padding, Float(old.bounds.maxX) + padding,
                             Float(old.bounds.minY) - padding, Float(old.bounds.maxY) + padding)
        let current = SIMD4(Float(new.bounds.minX) - padding, Float(new.bounds.maxX) + padding,
                            Float(new.bounds.minY) - padding, Float(new.bounds.maxY) + padding)
        var enter: Float = 0
        var exit: Float = 1
        var enteringNormal = SIMD2<Float>.zero
        for face in 0..<4 {
            let axis = face < 2 ? 0 : 1
            let lower = face.isMultiple(of: 2)
            // Both forms are a*t <= b.
            let a = lower ? current[face] - previous[face] : previous[face] - current[face]
            let b = lower ? point[axis] - previous[face] : previous[face] - point[axis]
            if abs(a) < 0.00001 {
                if b < 0 { return nil }
            } else if a < 0 {
                let time = b / a
                if time >= enter { enter = time; enteringNormal = Self.normal(for: face) }
            } else {
                exit = min(exit, b / a)
            }
        }
        guard enter <= exit, exit >= 0, enter <= 1 else { return nil }
        enter = max(0, enter)
        exit = min(1, exit)
        let oldContains = old.contains(point, padding: padding)
        if oldContains, !new.contains(point, padding: padding) { return nil } // A retreating face releases snow.
        var outsideTime = enter
        var insideTime: Float?
        for sample in 0...8 {
            let time = enter + (exit - enter) * Float(sample) / 8
            if interpolated(at: time).contains(point, padding: padding + 0.001) {
                insideTime = time
                break
            }
            outsideTime = time
        }
        guard var insideTime else { return nil }
        if !oldContains {
            for _ in 0..<8 {
                let middle = (outsideTime + insideTime) * 0.5
                if interpolated(at: middle).contains(point, padding: padding + 0.001) { insideTime = middle }
                else { outsideTime = middle }
            }
        }
        if enteringNormal == .zero || oldContains {
            // A body already engulfing a cell, or a centered resize, uses the nearest growing
            // face. Shrinking faces must never pull grains back into the window.
            let distances = SIMD4(abs(point.x - current.x), abs(point.x - current.y),
                                  abs(point.y - current.z), abs(point.y - current.w))
            let growth = outwardFaceMotion
            var nearest = Float.infinity
            for face in 0..<4 where growth[face] > 0.0001 && distances[face] < nearest {
                nearest = distances[face]
                enteringNormal = Self.normal(for: face)
            }
            if enteringNormal == .zero, new.cornerRadius < old.cornerRadius {
                for face in 0..<4 where distances[face] < nearest {
                    nearest = distances[face]
                    enteringNormal = Self.normal(for: face)
                }
            }
            if enteringNormal == .zero { return nil }
        }
        return (insideTime, enteringNormal)
    }

    private func interpolated(at t: Float) -> SolidBody {
        let value = CGFloat(t)
        return SolidBody(id: new.id, bounds: CGRect(
            x: old.bounds.minX + (new.bounds.minX - old.bounds.minX) * value,
            y: old.bounds.minY + (new.bounds.minY - old.bounds.minY) * value,
            width: old.bounds.width + (new.bounds.width - old.bounds.width) * value,
            height: old.bounds.height + (new.bounds.height - old.bounds.height) * value),
            cornerRadius: old.cornerRadius + (new.cornerRadius - old.cornerRadius) * t)
    }

    private func outsideNewFace(_ point: SIMD2<Float>, normal: SIMD2<Float>, padding: Float) -> SIMD2<Float> {
        var result = point
        let rect = new.bounds
        let r = new.cornerRadius
        let expanded = r + padding
        if abs(normal.x) >= abs(normal.y) {
            let centerY = max(Float(rect.minY) + r, min(point.y, Float(rect.maxY) - r))
            let dy = point.y - centerY
            let arc = sqrt(max(0, expanded * expanded - dy * dy))
            result.x = normal.x < 0 ? Float(rect.minX) + r - arc - 0.05
                : Float(rect.maxX) - r + arc + 0.05
        } else {
            let centerX = max(Float(rect.minX) + r, min(point.x, Float(rect.maxX) - r))
            let dx = point.x - centerX
            let arc = sqrt(max(0, expanded * expanded - dx * dx))
            result.y = normal.y < 0 ? Float(rect.minY) + r - arc - 0.05
                : Float(rect.maxY) - r + arc + 0.05
        }
        return result
    }

    private static func normal(for face: Int) -> SIMD2<Float> {
        switch face {
        case 0: SIMD2(-1, 0)
        case 1: SIMD2(1, 0)
        case 2: SIMD2(0, -1)
        default: SIMD2(0, 1)
        }
    }

    private static func valid(_ point: SIMD2<Float>) -> Bool {
        point.x.isFinite && point.y.isFinite && abs(point.x) < 200_000 && abs(point.y) < 200_000
    }
}

public enum BodyChanges {
    public static func classify(old: [SolidBody], new: [SolidBody])
        -> (appeared: [SolidBody], moved: [BodyMotion], removed: [SolidBody]) {
        let previous = sanitized(old)
        let current = sanitized(new)
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let currentIDs = Set(current.map(\.id))
        var appeared: [SolidBody] = []
        var moved: [BodyMotion] = []
        for body in current {
            if let prior = previousByID[body.id] {
                if body != prior { moved.append(BodyMotion(old: prior, new: body)) }
            } else { appeared.append(body) }
        }
        return (appeared, moved, previous.filter { !currentIDs.contains($0.id) })
    }

    private static func sanitized(_ input: [SolidBody]) -> [SolidBody] {
        var identifiers: Set<UInt64> = []
        return input.prefix(DesktopSceneBuilder.maximumBodies).filter {
            valid($0) && identifiers.insert($0.id).inserted
        }
    }

    static func valid(_ body: SolidBody) -> Bool {
        let rect = body.bounds
        return rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
            && abs(rect.minX) < 100_000 && abs(rect.minY) < 100_000
            && rect.width > 0 && rect.height > 0 && rect.width <= 100_000 && rect.height <= 100_000
            && body.cornerRadius.isFinite && body.cornerRadius >= 0
            && body.cornerRadius <= Float(min(rect.width, rect.height) / 2)
    }
}
