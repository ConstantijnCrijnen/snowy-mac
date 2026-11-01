import Foundation

struct ParticleHit {
    var time: Float
    var position: SIMD2<Float>
    var normal: SIMD2<Float>
    var drift: Int? = nil
}

enum ParticleCollision {
    /// Slab intersection against a radius-expanded rectangle. Continuous, including fast side crossings.
    static func hit(from start: SIMD2<Float>, to end: SIMD2<Float>, radius: Float,
                    rectangle: CGRect, cornerRadius: Float = 0) -> ParticleHit? {
        if cornerRadius > 0 {
            return roundedHit(from: start, to: end, radius: radius, rectangle: rectangle, corner: cornerRadius)
        }
        let lower = SIMD2(Float(rectangle.minX) - radius, Float(rectangle.minY) - radius)
        let upper = SIMD2(Float(rectangle.maxX) + radius, Float(rectangle.maxY) + radius)
        let delta = end - start
        if start.x > lower.x, start.x < upper.x, start.y > lower.y, start.y < upper.y {
            // A moved window can engulf existing flakes. Push them to its nearest outer face once.
            let distances = SIMD4(start.x - lower.x, upper.x - start.x, start.y - lower.y, upper.y - start.y)
            let minimum = min(min(distances.x, distances.y), min(distances.z, distances.w))
            if minimum == distances.x {
                return ParticleHit(time: 0, position: SIMD2(lower.x, start.y), normal: SIMD2(-1, 0))
            } else if minimum == distances.y {
                return ParticleHit(time: 0, position: SIMD2(upper.x, start.y), normal: SIMD2(1, 0))
            } else if minimum == distances.z {
                return ParticleHit(time: 0, position: SIMD2(start.x, lower.y), normal: SIMD2(0, -1))
            }
            return ParticleHit(time: 0, position: SIMD2(start.x, upper.y), normal: SIMD2(0, 1))
        }
        var entry: Float = 0
        var exit: Float = 1
        var normal = SIMD2<Float>(0, 0)
        for axis in 0..<2 {
            if abs(delta[axis]) < 0.00001 {
                if start[axis] < lower[axis] || start[axis] > upper[axis] { return nil }
                continue
            }
            var near = (lower[axis] - start[axis]) / delta[axis]
            var far = (upper[axis] - start[axis]) / delta[axis]
            var direction: Float = -1
            if near > far { swap(&near, &far); direction = 1 }
            if near >= entry {
                entry = near
                normal = .zero
                normal[axis] = direction
            }
            exit = min(exit, far)
            if entry > exit { return nil }
        }
        guard entry >= 0, entry <= 1, exit >= 0,
              normal.x * delta.x + normal.y * delta.y < 0 else { return nil }
        return ParticleHit(time: entry, position: start + delta * entry, normal: normal)
    }

    private static func roundedHit(from start: SIMD2<Float>, to end: SIMD2<Float>, radius: Float,
                                   rectangle: CGRect, corner: Float) -> ParticleHit? {
        let lo = SIMD2(Float(rectangle.minX), Float(rectangle.minY))
        let hi = SIMD2(Float(rectangle.maxX), Float(rectangle.maxY))
        let r = min(corner, min(hi.x - lo.x, hi.y - lo.y) / 2)
        let delta = end - start
        let center = (lo + hi) * 0.5
        let relative = start - center
        let q = SIMD2(abs(relative.x), abs(relative.y)) - ((hi - lo) * 0.5 - SIMD2(repeating: r))
        let outside = SIMD2(max(0, q.x), max(0, q.y))
        let length = sqrt(outside.x * outside.x + outside.y * outside.y)
        let distance = length + min(max(q.x, q.y), 0) - r
        if distance < radius - 0.001 {
            let sign = SIMD2<Float>(relative.x >= 0 ? 1 : -1, relative.y >= 0 ? 1 : -1)
            let normal = length > 0.0001 ? outside / length * sign
                : (q.x > q.y ? SIMD2(sign.x, 0) : SIMD2(0, sign.y))
            return ParticleHit(time: 0, position: start + normal * (radius - distance), normal: normal)
        }
        var nearest: ParticleHit?
        // Four flat faces, ending at the rounded shoulders.
        for face in 0..<4 {
            let axis = face < 2 ? 0 : 1
            let negative = face.isMultiple(of: 2)
            let direction: Float = negative ? -1 : 1
            guard delta[axis] * direction < -0.00001 else { continue }
            let coordinate = negative ? lo[axis] - radius : hi[axis] + radius
            let time = (coordinate - start[axis]) / delta[axis]
            let point = start + delta * time
            let other = 1 - axis
            if time >= 0, time <= 1, point[other] >= lo[other] + r,
               point[other] <= hi[other] - r, nearest == nil || time < nearest!.time {
                var normal = SIMD2<Float>.zero
                normal[axis] = direction
                nearest = ParticleHit(time: time, position: point, normal: normal)
            }
        }
        let a = delta.x * delta.x + delta.y * delta.y
        guard a > 0.000001 else { return nearest }
        // Four quarter circles. No square collision box outside the actual rounded contour.
        for quadrant in 0..<4 {
            let sx: Float = quadrant.isMultiple(of: 2) ? -1 : 1
            let sy: Float = quadrant < 2 ? -1 : 1
            let pivot = SIMD2(sx < 0 ? lo.x + r : hi.x - r, sy < 0 ? lo.y + r : hi.y - r)
            let offset = start - pivot
            let b = 2 * (offset.x * delta.x + offset.y * delta.y)
            let c = offset.x * offset.x + offset.y * offset.y - (r + radius) * (r + radius)
            let discriminant = b * b - 4 * a * c
            guard discriminant >= 0 else { continue }
            let time = (-b - sqrt(discriminant)) / (2 * a)
            let point = start + delta * time
            guard time >= 0, time <= 1, (point.x - pivot.x) * sx >= 0,
                  (point.y - pivot.y) * sy >= 0, nearest == nil || time < nearest!.time else { continue }
            nearest = ParticleHit(time: time, position: point, normal: (point - pivot) / (r + radius))
        }
        return nearest
    }
}
