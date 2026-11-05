import Foundation

/// Connected snow geometry for the shared desktop and Spotlight rendering passes.
extension SnowSimulation {
    public func rebuildMesh() {
        mesh.removeAll(keepingCapacity: true)
        elevatedMeshRanges.removeAll(keepingCapacity: true)
        for drift in drifts {
            let surface = drift.surface
            let start = mesh.count
            for span in surface.visibleSpans {
                let first = max(0, min(drift.heights.count - 2, Int(span.lower / drift.spacing)))
                let last = max(first, min(drift.heights.count - 2, Int(span.upper / drift.spacing)))
                for i in first...last {
                    let left = max(span.lower, Float(i) * drift.spacing)
                    let right = min(span.upper, Float(i + 1) * drift.spacing)
                    guard right > left else { continue }
                    let h0 = drift.height(at: left), h1 = drift.height(at: right)
                    guard max(h0, h1) > 0.025 else { continue }
                    // Bounds on mesh writes are independent of window count and supplied spans.
                    guard mesh.count + 12 <= budget.cells * 12 else { break }
                    let x0 = surface.x + left, x1 = surface.x + right
                    let y0 = surface.baseY(at: left), y1 = surface.baseY(at: right)
                    let bottom0 = SnowVertex(position: SIMD2(x0, y0 + 0.4), material: SIMD2(0, 0.88))
                    let bottom1 = SnowVertex(position: SIMD2(x1, y1 + 0.4), material: SIMD2(0, 0.88))
                    let top0 = SnowVertex(position: SIMD2(x0, y0 - h0), material: SIMD2(1, 1))
                    let top1 = SnowVertex(position: SIMD2(x1, y1 - h1), material: SIMD2(1, 1))
                    quad(bottom0, bottom1, top0, top1)
                    quad(top0, top1,
                         SnowVertex(position: top0.position - SIMD2(0, 0.8), material: SIMD2(1, 0)),
                         SnowVertex(position: top1.position - SIMD2(0, 0.8), material: SIMD2(1, 0)))
                }
            }
            if surface.isElevated, mesh.count > start {
                if let previous = elevatedMeshRanges.last, previous.upperBound == start {
                    elevatedMeshRanges[elevatedMeshRanges.count - 1] = previous.lowerBound..<mesh.count
                } else { elevatedMeshRanges.append(start..<mesh.count) }
            }
        }
        contour.append(field: looseSnow, to: &mesh, limit: budget.maximumSnowVertices)
        meshRevision &+= 1
        meshDirty = false
        interactionDirty = false
        geometryAge = 0
    }


    private func quad(_ a: SnowVertex, _ b: SnowVertex, _ c: SnowVertex, _ d: SnowVertex) {
        mesh.append(a)
        mesh.append(b)
        mesh.append(c)
        mesh.append(b)
        mesh.append(d)
        mesh.append(c)
    }
}
