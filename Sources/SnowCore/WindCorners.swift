import Foundation

/// Cached incoming-snowfall multipliers for one height-profile sample. Sheltered samples
/// remain normal physical supports for manually pushed and previously settled snow.
public struct CornerWindEffect: Equatable, Sendable {
    public var depositionScale: Float
    public var capacityScale: Float
    public var clear: Bool

    public static let neutral = CornerWindEffect(depositionScale: 1, capacityScale: 1, clear: false)

    public init(depositionScale: Float, capacityScale: Float, clear: Bool) {
        self.depositionScale = depositionScale
        self.capacityScale = capacityScale
        self.clear = clear
    }
}

/// Geometry-only corner accumulation, in display-local points. Wind is a velocity in
/// points/second, matching WindSettings.velocity. Build a profile only when wind or
/// geometry changes, then reuse its scalars during normal accumulation and settling.
public enum WindCorners {
    private static let maximumSamples = 512
    private static let pileBand: Float = 28
    private static let fadeWidth: Float = 4

    /// The direct-snowfall shadow grows from calm to 96 points at full horizontal wind.
    public static func clearRadius(for wind: SIMD2<Float>) -> Float {
        let strength = horizontalStrength(wind)
        return strength > 0.01 ? strength * 96 : 0
    }

    public static func effects(for surface: Surface, cellCount: Int, bodies: [SolidBody],
                               wind: SIMD2<Float>) -> [CornerWindEffect] {
        let count = max(0, min(maximumSamples, cellCount))
        guard count > 0 else { return [] }
        guard surface.x.isFinite, surface.y.isFinite, surface.width.isFinite, surface.width > 0,
              abs(surface.x) < 100_000, abs(surface.y) < 100_000, surface.width <= 100_000,
              surface.cornerRadius.isFinite, horizontalStrength(wind) > 0.01 else {
            return Array(repeating: .neutral, count: count)
        }
        let walls = bodies.prefix(DesktopSceneBuilder.maximumBodies).filter {
            $0.id != surface.id && BodyChanges.valid($0)
                && (!surface.releasesSnowWhenRemoved || $0.isElevated)
                && Float($0.bounds.minY) <= surface.y + surface.cornerRadius + 0.5
                && Float($0.bounds.maxY) >= surface.y - pileBand
        }
        return (0..<count).map { index in
            let localX = count == 1 ? surface.width * 0.5 : surface.width * (Float(index) / Float(count - 1))
            let point = SIMD2(surface.x + localX, surface.baseY(at: localX))
            return effect(at: point, walls: walls, wind: wind)
        }
    }

    public static func effect(at point: SIMD2<Float>, supportID: UInt64, bodies: [SolidBody],
                              wind: SIMD2<Float>) -> CornerWindEffect {
        guard point.x.isFinite, point.y.isFinite, horizontalStrength(wind) > 0.01 else { return .neutral }
        let walls = bodies.prefix(DesktopSceneBuilder.maximumBodies).filter {
            $0.id != supportID && BodyChanges.valid($0)
        }
        return effect(at: point, walls: walls, wind: wind)
    }

    private static func horizontalStrength(_ wind: SIMD2<Float>) -> Float {
        guard wind.x.isFinite, wind.y.isFinite else { return 0 }
        return min(1, abs(wind.x) / 80)
    }

    private static func effect(at point: SIMD2<Float>, walls: [SolidBody],
                               wind: SIMD2<Float>) -> CornerWindEffect {
        let strength = horizontalStrength(wind)
        guard strength > 0.01 else { return .neutral }
        var suppression: Float = 1
        var accumulationBoost: Float = 0
        var capacityBoost: Float = 0
        var clear = false
        for body in walls {
            let rect = body.bounds
            let minY = Float(rect.minY), maxY = Float(rect.maxY)
            guard minY < point.y - 0.5, maxY >= point.y - pileBand else { continue }
            // A wall ending inside the pile band has a weaker effect than a full-height wall.
            let contact = min(1, max(0, (maxY - point.y + pileBand) / pileBand))
                * min(1, (point.y - minY) / pileBand)
            guard contact > 0 else { continue }
            let sampleY = max(minY, min(maxY, point.y))
            let radius = body.cornerRadius
            let edge = max(0, min(sampleY - minY, maxY - sampleY))
            let inset = edge < radius ? radius - sqrt(max(0, radius * radius - (radius - edge) * (radius - edge))) : 0
            let left = Float(rect.minX) + inset
            let right = Float(rect.maxX) - inset
            let side: Float
            let distance: Float
            if point.x <= left {
                side = -1
                distance = left - point.x
            } else if point.x >= right {
                side = 1
                distance = point.x - right
            } else {
                // Interior visibility/coverage is handled by the scene; it isn't a wind corner.
                continue
            }
            let reach = clearRadius(for: wind) * contact
            if side * wind.x > 0 {
                // The sheltered/downwind corner stays clear through the requested radius.
                if distance <= reach {
                    clear = true
                    suppression = 0
                } else if distance < reach + fadeWidth {
                    let t = (distance - reach) / fadeWidth
                    suppression = min(suppression, t * t * (3 - 2 * t))
                }
            } else if distance < reach {
                let t = 1 - distance / max(0.001, reach)
                let shape = t * t * (3 - 2 * t)
                accumulationBoost = max(accumulationBoost, strength * contact * shape * 1.25)
                capacityBoost = max(capacityBoost, strength * contact * shape * 0.6)
            }
        }
        // A nearby clear wake wins over another wall's deposition boost. Multiple walls do
        // not multiply each other into an unbounded mound or a large per-frame computation.
        return CornerWindEffect(depositionScale: (1 + accumulationBoost) * suppression,
                                capacityScale: (1 + capacityBoost) * suppression, clear: clear)
    }
}
