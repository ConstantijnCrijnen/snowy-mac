import Foundation

/// Reconstruct a connected snow outline from occupied cells. No mass-scaled particle sprites.
final class GranularContour {
    private var visited: [UInt32]
    private var generation: UInt32 = 0
    private let stride: Int

    init(field: GranularSnow) {
        stride = field.columns + 1
        visited = Array(repeating: 0, count: (field.columns + 1) * (field.rows + 1))
    }

    func append(field: GranularSnow, to mesh: inout [SnowVertex], limit: Int) {
        guard !field.active.isEmpty, field.columns > 0 else { return }
        generation &+= 1
        if generation == 0 {
            for i in visited.indices { visited[i] = 0 }
            generation = 1
        }
        let values = field.mass
        let columns = field.columns, rows = field.rows, step = field.cellSize
        func density(_ x: Int, _ y: Int) -> Float {
            guard x >= 0, x < columns, y >= 0, y < rows else { return 0 }
            let index = y * columns + x
            return min(1, values[index] / max(0.001, field.capacity(of: index)))
        }
        let level: Float = 0.2
        for index in field.active where values[index] > 0 {
            let cx = index % columns, cy = index / columns
            for dy in 0...1 {
                for dx in 0...1 {
                    let x = cx - dx, y = cy - dy
                    let marker = (y + 1) * stride + x + 1
                    guard visited[marker] != generation else { continue }
                    visited[marker] = generation
                    let va = density(x, y), vb = density(x + 1, y)
                    let vc = density(x + 1, y + 1), vd = density(x, y + 1)
                    let bits = (va >= level ? 1 : 0) | (vb >= level ? 2 : 0)
                        | (vc >= level ? 4 : 0) | (vd >= level ? 8 : 0)
                    guard bits != 0 else { continue }
                    let a = SIMD2((Float(x) + 0.5) * step, (Float(y) + 0.5) * step)
                    let b = a + SIMD2(step, 0), c = a + SIMD2(step, step), d = a + SIMD2(0, step)
                    func edge(_ p: SIMD2<Float>, _ q: SIMD2<Float>, _ first: Float, _ second: Float) -> SIMD2<Float> {
                        let delta = second - first
                        let t = abs(delta) < 0.0001 ? 0.5 : max(0, min(1, (level - first) / delta))
                        return p + (q - p) * t
                    }
                    let t = edge(a, b, va, vb), r = edge(b, c, vb, vc)
                    let bottom = edge(c, d, vc, vd), l = edge(d, a, vd, va)
                    let shade = max(0.3, min(1, 0.76 + (vc + vd - va - vb) * 0.22))
                    func triangle(_ p: SIMD2<Float>, _ q: SIMD2<Float>, _ z: SIMD2<Float>) {
                        guard mesh.count + 3 <= limit else { return }
                        mesh.append(SnowVertex(position: p, material: SIMD2(shade, 1)))
                        mesh.append(SnowVertex(position: q, material: SIMD2(shade, 1)))
                        mesh.append(SnowVertex(position: z, material: SIMD2(shade, 1)))
                    }
                    switch bits {
                    case 1: triangle(a, t, l)
                    case 2: triangle(b, r, t)
                    case 4: triangle(c, bottom, r)
                    case 8: triangle(d, l, bottom)
                    case 3: triangle(a, b, r); triangle(a, r, l)
                    case 6: triangle(t, b, c); triangle(t, c, bottom)
                    case 12: triangle(l, r, c); triangle(l, c, d)
                    case 9: triangle(a, t, bottom); triangle(a, bottom, d)
                    case 5: triangle(a, t, l); triangle(c, bottom, r)
                    case 10: triangle(b, r, t); triangle(d, l, bottom)
                    case 7: triangle(a, b, c); triangle(a, c, bottom); triangle(a, bottom, l)
                    case 11: triangle(a, b, r); triangle(a, r, bottom); triangle(a, bottom, d)
                    case 13: triangle(a, t, r); triangle(a, r, c); triangle(a, c, d)
                    case 14: triangle(t, b, c); triangle(t, c, d); triangle(t, d, l)
                    default: triangle(a, b, c); triangle(a, c, d)
                    }
                }
            }
        }
    }
}
