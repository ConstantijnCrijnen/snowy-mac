import Foundation

/// Glove and shovel interaction with attached profiles and the shared granular field.
extension SnowSimulation {
    func sweep(from start: SIMD2<Float>, to end: SIMD2<Float>, dt: Float) {
        let delta = end - start
        let travel = hypot(delta.x, delta.y)
        let hard = tool == .shovel
        guard hard || travel > 0.01 else { return }
        let radius = tool.radius
        let strength: Float = hard ? 1 : min(0.7, travel / (radius * 1.2))
        for drift in drifts {
            guard max(start.x, end.x) + radius >= drift.surface.x,
                  min(start.x, end.x) - radius <= drift.surface.x + drift.surface.width,
                  max(start.y, end.y) + radius >= drift.surface.y - 32,
                  min(start.y, end.y) - radius <= drift.surface.y + drift.surface.cornerRadius + 2 else { continue }
            for i in drift.heights.indices where drift.heights[i] > 0.001 {
                let localX = Float(i) * drift.spacing
                guard drift.surface.isExposed(at: localX) else { continue }
                let base = drift.surface.baseY(at: localX)
                let point = SIMD2(drift.surface.x + localX, base - drift.heights[i] * 0.5)
                let nearest = Geometry.closestPoint(to: point, on: start, end)
                let dx = point.x - nearest.x
                guard abs(dx) < radius else { continue }
                let reach = sqrt(max(0, radius * radius - dx * dx))
                let top = base - drift.heights[i]
                let overlap = max(0, min(base, nearest.y + reach) - max(top, nearest.y - reach))
                guard overlap > 0 else { continue }
                // The shovel moves the entire intersected column out of its rigid exclusion area.
                // The glove releases just the volume contacted during this movement.
                let removed = hard ? drift.heights[i] : min(drift.heights[i], overlap * strength)
                let mass = removed * drift.spacing
                let direction = travel > 0.01 ? delta / travel : point - end
                let ingress = SIMD2(point.x, min(point.y, base - looseSnow.cellSize * 0.65))
                let unplaced = looseSnow.add(mass: mass, at: ingress, direction: direction,
                                             excludingCircle: (center: end, radius: radius))
                drift.heights[i] -= (mass - unplaced) / drift.spacing
                if drift.surface.releasesSnowWhenRemoved, unplaced > 0.0001 {
                    // Above another app the desktop material field is solid. Keep pushing
                    // along Spotlight's attached cap instead of deleting or launching snow.
                    let side: Float = abs(delta.x) > 0.01 ? (delta.x > 0 ? 1 : -1)
                        : (point.x < end.x ? -1 : 1)
                    let target = end.x + side * (radius + drift.spacing) - drift.surface.x
                    drift.heights[i] -= unplaced / drift.spacing
                    let remainder = drift.depositMass(at: target, mass: unplaced, direction: side)
                    drift.heights[i] += remainder / drift.spacing
                }
                meshDirty = true
                interactionDirty = true
            }
        }
        looseSnow.brush(from: start, to: end, radius: radius, hard: hard)
    }
}
