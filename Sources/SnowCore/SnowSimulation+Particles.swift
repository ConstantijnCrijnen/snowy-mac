import Foundation

/// Decorative snowfall and continuous contacts with bodies and accumulated terrain.
extension SnowSimulation {
    func newFlake(scattered: Bool) -> SnowParticle {
        let depth = random.unit()
        let radius = 0.65 + depth * depth * 1.85
        var position = SIMD2(random.value(radius, max(radius, size.x - radius)), Float(-5))
        if scattered {
            // Density changes must not seed snow inside windows and eject it in an artificial burst.
            for _ in 0..<4 {
                let candidate = SIMD2(random.value(radius, max(radius, size.x - radius)), random.value(0, size.y))
                let occupied = bodyBuckets[bucket(at: candidate.x)].contains { index in
                    bodies[index].contains(candidate, padding: radius)
                }
                if !occupied { position = candidate; break }
            }
        }
        return SnowParticle(
            position: position,
            velocity: SIMD2(random.value(-7, 7), 20 + depth * 43),
            radius: radius,
            opacity: 0.28 + depth * 0.6,
            phase: random.value(0, .pi * 2), remainingLife: 100, mass: radius * radius * 0.45
        )
    }


    @discardableResult
    func land(from old: SIMD2<Float>, particle: SnowParticle) -> Bool {
        guard let hit = surfaceHit(from: old, to: particle.position, radius: particle.radius),
              let index = hit.drift else { return false }
        _ = drifts[index].depositMass(at: hit.position.x - drifts[index].surface.x, mass: particle.mass, snowfall: true)
        meshDirty = true
        return true
    }


    /// Integrates a bounded number of continuous contacts rather than teleporting through rectangles.
    @discardableResult
    func advanceParticle(_ particle: inout SnowParticle, dt: Float, recycleOnContact: Bool = false) -> Bool {
        var remaining = dt
        for _ in 0..<3 {
            let start = particle.position
            let end = start + particle.velocity * remaining
            var nearest = surfaceHit(from: start, to: end, radius: particle.radius)
            let halfWidth = particle.radius
            let first = bucket(at: min(start.x, end.x) - halfWidth)
            let last = max(first, bucket(at: max(start.x, end.x) + halfWidth))
            for column in first...last {
                for index in bodyBuckets[column] {
                    if let hit = ParticleCollision.hit(from: start, to: end, radius: particle.radius,
                                                       rectangle: bodies[index].bounds, cornerRadius: bodies[index].cornerRadius),
                       nearest == nil || hit.time < nearest!.time {
                        nearest = hit
                    }
                }
            }
            // Screen sides are physical boundaries for transported snow as well.
            for side in 0..<2 {
                let boundary = side == 0 ? halfWidth : size.x - halfWidth
                let normal = SIMD2<Float>(side == 0 ? 1 : -1, 0)
                let dx = end.x - start.x
                if dx * normal.x < 0 {
                    let time = (boundary - start.x) / dx
                    if time >= 0, time <= 1, nearest == nil || time < nearest!.time {
                        nearest = ParticleHit(time: time, position: start + (end - start) * time, normal: normal)
                    }
                }
            }
            guard let hit = nearest else { particle.position = end; return false }
            particle.position = hit.position + hit.normal * 0.05
            if let index = hit.drift {
                particle.mass = drifts[index].depositMass(at: hit.position.x - drifts[index].surface.x,
                                                        mass: particle.mass, snowfall: recycleOnContact)
                meshDirty = true
                if particle.mass <= 0.0001 { return true }
                // A full patch spills sideways; it does not silently destroy carried mass.
                if abs(particle.velocity.x) < 12 { particle.velocity.x = hit.position.x < size.x / 2 ? -35 : 35 }
            }
            if recycleOnContact { return true } // Snowfall keeps cycling when a pile is full.
            let dot = particle.velocity.x * hit.normal.x + particle.velocity.y * hit.normal.y
            if dot < 0 {
                particle.velocity -= hit.normal * (dot * 1.25)
                particle.velocity *= 0.86
            }
            remaining *= max(0, 1 - hit.time)
            if remaining < 0.0001 { return false }
        }
        // At most three contacts in one frame; preserve the last safe position if the space is tight.
        return false
    }


    private func surfaceHit(from start: SIMD2<Float>, to end: SIMD2<Float>, radius: Float,
                            allowEmbedded: Bool = false) -> ParticleHit? {
        let delta = end - start
        var nearest: ParticleHit?
        let first = bucket(at: min(start.x, end.x))
        let last = max(first, bucket(at: max(start.x, end.x)))
        for column in first...last {
            for index in buckets[column] {
                let drift = drifts[index]
                if allowEmbedded, end.y >= start.y {
                    let local = start.x - drift.surface.x
                    if local >= 0, local <= drift.surface.width, drift.surface.isExposed(at: local) {
                        let base = drift.surface.baseY(at: local)
                        let top = base - drift.height(at: local)
                        // A neighbour's landing can raise the cap through this cell before
                        // its tick. Absorb that physical overlap instead of requiring a new
                        // positive-time crossing and stranding a grain inside the profile.
                        if start.y <= base + 0.001, start.y + radius >= top - 0.001 {
                            let contact = SIMD2(start.x, top - radius)
                            if nearest == nil || nearest!.time > 0 || contact.y < nearest!.position.y {
                                nearest = ParticleHit(time: 0, position: contact, normal: SIMD2(0, -1), drift: index)
                            }
                            continue
                        }
                    }
                }
                let left = max(0, min(start.x, end.x) - drift.surface.x)
                let right = min(drift.surface.width, max(start.x, end.x) - drift.surface.x)
                guard right >= left,
                      max(start.y, end.y) + radius >= drift.surface.y - 30,
                      min(start.y, end.y) + radius <= drift.surface.y + drift.surface.cornerRadius + 0.01 else { continue }
                let begin = max(0, min(drift.heights.count - 2, Int(left / drift.spacing)))
                let finish = max(begin, min(drift.heights.count - 2, Int(right / drift.spacing)))
                for i in begin...finish {
                    let x0 = Float(i) * drift.spacing
                    let top0 = drift.surface.baseY(at: x0) - drift.heights[i]
                    let top1 = drift.surface.baseY(at: x0 + drift.spacing) - drift.heights[i + 1]
                    let slope = (top1 - top0) / drift.spacing
                    let approach = delta.y - slope * delta.x
                    guard approach > 0.00001 else { continue }
                    let topAtStart = top0 + slope * (start.x - drift.surface.x - x0)
                    let time = (topAtStart - radius - start.y) / approach
                    guard time >= 0, time <= 1, nearest == nil || time < nearest!.time else { continue }
                    let point = start + delta * time
                    let localX = point.x - drift.surface.x
                    guard localX >= x0 - 0.001, localX <= x0 + drift.spacing + 0.001,
                          drift.surface.isExposed(at: localX) else { continue }
                    nearest = ParticleHit(time: time, position: point, normal: SIMD2(0, -1), drift: index)
                }
            }
        }
        return nearest
    }


    func landGranularSnow(from: SIMD2<Float>, to: SIMD2<Float>, mass: Float)
        -> (remaining: Float, blocked: Bool) {
        let radius = looseSnow.cellSize * 0.45
        guard let hit = surfaceHit(from: from, to: to, radius: radius, allowEmbedded: true), let index = hit.drift else {
            return (mass, false)
        }
        let drift = drifts[index]
        let remainder = drift.depositMass(at: hit.position.x - drift.surface.x, mass: mass)
        if remainder < mass { meshDirty = true; interactionDirty = true }
        return (remainder, true)
    }
}
