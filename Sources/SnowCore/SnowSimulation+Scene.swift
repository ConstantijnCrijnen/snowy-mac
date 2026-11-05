import Foundation

/// Atomic scene updates, support profiles, physical bodies and cached corner wind.
extension SnowSimulation {
    public func updateBodies(_ input: [SolidBody]) {
        let valid = Array(input.prefix(DesktopSceneBuilder.maximumBodies).filter {
            let rect = $0.bounds
            return rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
                && rect.width > 0 && rect.height > 0 && rect.width <= 100_000 && rect.height <= 100_000
                && abs(rect.minX) < 100_000 && abs(rect.minY) < 100_000
        })
        guard valid != bodies else { return }
        let changes = BodyChanges.classify(old: bodies, new: valid)
        bodies = valid
        cornerWindDirty = true
        for i in bodyBuckets.indices { bodyBuckets[i].removeAll(keepingCapacity: true) }
        for (index, body) in bodies.enumerated() {
            let start = bucket(at: Float(body.bounds.minX) - 32)
            let end = max(start, bucket(at: Float(body.bounds.maxX) + 32))
            for i in start...end { bodyBuckets[i].append(index) }
        }
        looseSnow.setBodies(valid)
        pendingAppearances = changes.appeared
        eraseCoveredSnow(inside: changes.appeared)
        eraseReleasedSnow(inside: changes.appeared)
        for body in changes.appeared { looseSnow.erase(inside: body) }
        for motion in changes.moved {
            let pitch = looseSnow.maximumActive > 0 ? looseSnow.cellSize : 3
            let marginX = min(pitch * 0.5, size.x * 0.5)
            let marginY = min(pitch * 0.5, size.y * 0.5)
            for i in snowReleases.indices {
                let padding = max(pitch * 0.65, snowReleases[i].height * 0.5)
                if let displaced = motion.displacedPosition(of: snowReleases[i].position, padding: padding) {
                    snowReleases[i].position = SIMD2(max(marginX, min(size.x - marginX, displaced.x)),
                                                     max(marginY, min(size.y - marginY, displaced.y)))
                }
            }
            looseSnow.push(by: motion.old, to: motion.new)
            pushSupportedSnow(with: motion)
        }
        // Ambient flakes recycle; accumulated snow follows the opening/motion distinction above.
        for i in flakes.indices {
            if bodyBuckets[bucket(at: flakes[i].position.x)].contains(where: { bodies[$0].contains(flakes[i].position) }) {
                flakes[i] = newFlake(scattered: false)
            }
        }
        meshDirty = true
        if !batchingScene { rebuildMesh() }
    }


    func bucket(at x: Float) -> Int {
        max(0, min(buckets.count - 1, Int(x / bucketWidth)))
    }


    public func updateSurfaces(_ input: [Surface]) {
        looseSnow.beginFrame()
        updateSurfaces(input, windBodies: bodies)
    }


    func updateSurfaces(_ input: [Surface], windBodies: [SolidBody]) {
        // Geometry is external process data. Reject malformed or implausible sizes before allocation.
        var identifiers: Set<UInt64> = []
        let surfaces = input.prefix(256).filter { surface in
            surface.x.isFinite && surface.y.isFinite && surface.width.isFinite
                && surface.width >= surface.minimumWidth && surface.width <= size.x + 1
                && surface.x >= -1 && surface.x + surface.width <= size.x + 1
                && surface.y >= 0 && surface.y <= size.y
                && surface.visibleSpans.count <= 128
                && surface.snowfallSpans.count <= 128
                && surface.snowfallSpans.allSatisfy { $0.lower.isFinite && $0.upper.isFinite
                    && $0.lower >= 0 && $0.upper <= surface.width && $0.upper > $0.lower }
                && surface.visibleSpans.allSatisfy {
                    $0.lower.isFinite && $0.upper.isFinite && $0.lower >= 0
                        && $0.upper <= surface.width && $0.upper > $0.lower
                }
                && identifiers.insert(surface.id).inserted
        }.prefix(min(budget.surfaces, budget.cells / 5)).map { surface -> Surface in
            var value = surface
            value.visibleSpans = value.visibleSpans.compactMap {
                let lower = max(0, $0.lower), upper = min(value.width, $0.upper)
                return upper > lower ? Span(lower, upper) : nil
            }
            return value
        }
        guard surfaces != lastSurfaces else { return }
        lastSurfaces = surfaces
        cornerWindDirty = true
        let old = Dictionary(drifts.map { ($0.surface.id, $0) }, uniquingKeysWith: { first, _ in first })
        let incomingIDs = Set(surfaces.map(\.id))
        for drift in drifts where !incomingIDs.contains(drift.surface.id) {
            retainReleasedSnow(from: drift, coveredBy: windBodies)
        }
        var next: [SnowDrift] = []
        next.reserveCapacity(surfaces.count)
        let requests = surfaces.map { min(512, max(5, Int(ceil($0.width / 4)) + 1)) }
        let extraDemand = max(1, requests.reduce(0, +) - surfaces.count * 5)
        let extraBudget = max(0, budget.cells - surfaces.count * 5)
        for (index, surface) in surfaces.enumerated() {
            // Share samples across all edges, so background windows don't get starved by wide front windows.
            let count = min(requests[index], 5 + (requests[index] - 5) * extraBudget / extraDemand)
            let drift: SnowDrift
            if let previous = old[surface.id] {
                if previous.heights.count == count && previous.surface.width == surface.width
                    && previous.surface.cornerRadius == surface.cornerRadius {
                    previous.surface = surface
                    drift = previous
                } else {
                    drift = SnowDrift(surface: surface, cellCount: count)
                    drift.copySnow(from: previous)
                    releaseTrimmedDockSnow(from: previous, to: drift)
                }
            } else {
                // The initial dusting is incoming snowfall too. Use the incoming scene's
                // walls, without clearing any existing snow when wind changes later.
                let effects = WindCorners.effects(for: surface, cellCount: count,
                                                  bodies: windBodies, wind: wind.velocity)
                drift = SnowDrift(surface: surface, cellCount: count, windEffects: effects)
            }
            next.append(drift)
        }
        drifts = next
        for i in buckets.indices { buckets[i].removeAll(keepingCapacity: true) }
        for (index, drift) in drifts.enumerated() {
            let start = max(0, min(buckets.count - 1, Int(drift.surface.x / bucketWidth)))
            let end = max(start, min(buckets.count - 1, Int((drift.surface.x + drift.surface.width) / bucketWidth)))
            for bucket in start...end { buckets[bucket].append(index) }
        }
        meshDirty = true
        eraseCoveredSnow(inside: pendingAppearances)
        pendingAppearances.removeAll(keepingCapacity: true)
        if !batchingScene { applySnowReleases(); rebuildMesh() }
    }


    private func eraseCoveredSnow(inside appeared: [SolidBody]) {
        guard !appeared.isEmpty else { return }
        var changed = false
        for drift in drifts {
            for i in drift.heights.indices where drift.heights[i] > 0 {
                let localX = Float(i) * drift.spacing
                let x = drift.surface.x + localX
                let base = drift.surface.baseY(at: localX)
                let top = base - drift.heights[i]
                var covered: Float = 0
                for body in appeared {
                    guard body.id != drift.surface.id,
                          !drift.surface.isElevated || body.isElevated,
                          x >= Float(body.bounds.minX), x <= Float(body.bounds.maxX) else { continue }
                    let edge = min(x - Float(body.bounds.minX), Float(body.bounds.maxX) - x)
                    let r = body.cornerRadius
                    let inset = edge < r ? r - sqrt(max(0, r * r - (r - edge) * (r - edge))) : 0
                    let low = Float(body.bounds.minY) + inset
                    let high = Float(body.bounds.maxY) - inset
                    if low <= base, high >= base {
                        // No supported column can remain inside a window that covers its base.
                        covered = drift.heights[i]
                        break
                    }
                    covered = max(covered, max(0, min(base, high) - max(top, low)))
                }
                if covered > 0 {
                    drift.heights[i] = max(0, drift.heights[i] - covered)
                    changed = true
                }
            }
        }
        if changed { meshDirty = true; interactionDirty = true }
    }


    private func pushSupportedSnow(with motion: BodyMotion) {
        let padding = looseSnow.cellSize * 0.65
        for drift in drifts where drift.surface.id != motion.new.id
            && (!drift.surface.isElevated || motion.new.isElevated) {
            let swept = motion.old.bounds.union(motion.new.bounds).insetBy(dx: -CGFloat(padding), dy: -CGFloat(padding))
            guard swept.maxX >= CGFloat(drift.surface.x), swept.minX <= CGFloat(drift.surface.x + drift.surface.width),
                  swept.maxY >= CGFloat(drift.surface.y - 32),
                  swept.minY <= CGFloat(drift.surface.y + drift.surface.cornerRadius) else { continue }
            for i in drift.heights.indices where drift.heights[i] > 0 {
                let original = drift.heights[i]
                let localX = Float(i) * drift.spacing
                let x = drift.surface.x + localX
                let base = drift.surface.baseY(at: localX)
                let layers = max(1, Int(ceil(original / max(1, looseSnow.cellSize))))
                let thickness = original / Float(layers)
                for layer in 0..<layers {
                    let point = SIMD2(x, base - (Float(layer) + 0.5) * thickness)
                    guard let displaced = motion.displacedPosition(of: point, padding: padding) else { continue }
                    let mass = thickness * drift.spacing
                    let remaining = looseSnow.add(mass: mass, at: displaced, direction: motion.direction(at: point))
                    drift.heights[i] -= (mass - remaining) / drift.spacing
                }
            }
        }
        interactionDirty = true
    }


    /// Wind/body work is cached at the profile resolution, rather than scanning every wall
    /// for every snow sample each frame. Maximum pile heights stay unchanged.
    func refreshCornerWind() {
        guard cornerWindDirty else { return }
        cornerWindDirty = false
        for drift in drifts {
            let effects = WindCorners.effects(for: drift.surface, cellCount: drift.heights.count,
                                              bodies: bodies, wind: wind.velocity)
            drift.applyCornerWind(effects)
        }
    }
}
