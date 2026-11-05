import Foundation

/// Material ownership across moving supports, wall contacts, retirement and bounded retries.
extension SnowSimulation {
    func persistentBodyMotions(to input: [SolidBody]) -> [BodyMotion] {
        let next = Dictionary(input.prefix(DesktopSceneBuilder.maximumBodies)
            .filter { BodyChanges.valid($0) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return bodies.compactMap { old in next[old.id].map { BodyMotion(old: old, new: $0) } }
    }


    func captureCarriedSnowCollisions(to input: [Surface], motions: [BodyMotion]) {
        let surfaces = Dictionary(input.prefix(256).filter {
            $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.width >= $0.minimumWidth
                && $0.width <= size.x + 1 && $0.x >= -1 && $0.x + $0.width <= size.x + 1
                && $0.y >= 0 && $0.y <= size.y && $0.cornerRadius.isFinite
        }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pitch = looseSnow.maximumActive > 0 ? looseSnow.cellSize : 3
        let marginX = min(pitch * 0.5, size.x * 0.5)
        let marginY = min(pitch * 0.5, size.y * 0.5)
        for source in drifts {
            let old = source.surface
            guard let next = surfaces[old.id], old.x != next.x || old.y != next.y
                    || old.width != next.width || old.cornerRadius != next.cornerRadius else { continue }
            let band = CGRect(x: CGFloat(min(old.x, next.x)), y: CGFloat(min(old.y, next.y) - 32),
                width: CGFloat(max(old.x + old.width, next.x + next.width) - min(old.x, next.x)),
                height: CGFloat(abs(next.y - old.y) + max(old.cornerRadius, next.cornerRadius) + 32))
            let obstacles = motions.filter {
                $0.old.id != old.id && $0.old.isElevated == old.isElevated
                    && $0.new.isElevated == next.isElevated
                    && $0.old.bounds.union($0.new.bounds).insetBy(dx: -CGFloat(pitch), dy: -CGFloat(pitch)).intersects(band)
            }
            guard !obstacles.isEmpty else { continue }
            for i in source.heights.indices where source.heights[i] > 0.0001 {
                let localX = Float(i) * source.spacing
                guard localX <= next.width else { continue }
                let height = source.heights[i]
                guard height.isFinite else { continue }
                let layers = max(1, Int(ceil(min(28, height) / 3)))
                let thickness = height / Float(layers)
                let radius = max(pitch * 0.75, min(thickness, source.spacing) * 0.5)
                var removed: Float = 0
                for layer in 0..<layers {
                    let offset = (Float(layer) + 0.5) * thickness
                    let start = SIMD2(old.x + localX, old.baseY(at: localX) - offset)
                    let end = SIMD2(next.x + localX, next.baseY(at: localX) - offset)
                    guard hypot(end.x - start.x, end.y - start.y) > 0.0001 else { continue }
                    var nearest: ParticleHit?
                    for obstacle in obstacles {
                        if let hit = obstacle.contact(from: start, to: end, radius: radius),
                           nearest == nil || hit.time < nearest!.time { nearest = hit }
                    }
                    if let hit = nearest {
                        let point = SIMD2(max(marginX, min(size.x - marginX, hit.position.x)),
                                          max(marginY, min(size.y - marginY, hit.position.y)))
                        retainRelease(SnowRelease(position: point, height: thickness,
                            mass: thickness * source.spacing), in: &carriedContacts)
                        removed += thickness
                    }
                }
                source.heights[i] = max(0, height - removed)
            }
        }
    }


    /// Capture area before its attached profile follows the window into another solid. The
    /// recipient is the first existing support crossed, not whichever window is last in the list.
    func captureSupportTransfers(to input: [Surface], motions: [BodyMotion]) {
        let incoming = Dictionary(input.prefix(256).filter {
            $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.width > 0
        }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for source in drifts {
            guard let next = incoming[source.surface.id], next.y > source.surface.y + 0.001 else { continue }
            for i in source.heights.indices where source.heights[i] > 0.0001 {
                guard supportTransfers.count < budget.cells else { return }
                let localX = Float(i) * source.spacing
                guard localX <= next.width else { continue }
                let oldBase = source.surface.baseY(at: localX), newBase = next.baseY(at: localX)
                var firstTime: Float = .infinity
                var receiver: Surface?
                var receiverLocalX: Float = 0
                for target in drifts where target.surface.id != source.surface.id {
                    guard target.surface.isElevated == source.surface.isElevated else { continue }
                    guard let destination = incoming[target.surface.id] else { continue }
                    var crossingLocal = source.surface.x + localX - target.surface.x
                    var time: Float = 0
                    var valid = true
                    for _ in 0..<3 {
                        let sample = max(0, min(target.surface.width, crossingLocal))
                        let oldTargetBase = target.surface.baseY(at: sample)
                        let newTargetBase = destination.baseY(at: max(0, min(destination.width, crossingLocal)))
                        let height = target.height(at: sample)
                        let before = oldBase - (oldTargetBase - height)
                        let after = newBase - (newTargetBase - height)
                        guard oldBase <= oldTargetBase + 0.01, after >= -0.001,
                              after - before > 0.001 else { valid = false; break }
                        time = max(0, min(1, -before / (after - before)))
                        let sourceX = source.surface.x + (next.x - source.surface.x) * time + localX
                        let targetX = target.surface.x + (destination.x - target.surface.x) * time
                        crossingLocal = sourceX - targetX
                    }
                    guard valid, crossingLocal >= 0, crossingLocal <= destination.width,
                          destination.isExposed(at: crossingLocal), time < firstTime else { continue }
                    firstTime = time
                    receiver = destination
                    receiverLocalX = crossingLocal
                }
                if let receiver, !hasEarlierCarriedContact(source: source, next: next, localX: localX,
                    receiverID: receiver.id, before: firstTime, motions: motions) {
                    let mass = source.heights[i] * source.spacing
                    supportTransfers.append(SupportTransfer(targetID: receiver.id,
                        x: receiver.x + receiverLocalX, baseY: receiver.baseY(at: receiverLocalX), mass: mass))
                    source.heights[i] = 0
                }
            }
        }
    }


    /// A diagonal drag can meet a wall before reaching a lower top. Do not hand the whole
    /// column past that earlier collision; the carried-material sweep handles it instead.
    private func hasEarlierCarriedContact(source: SnowDrift, next: Surface, localX: Float,
                                          receiverID: UInt64, before time: Float, motions: [BodyMotion]) -> Bool {
        let height = source.height(at: localX)
        guard height.isFinite, height > 0 else { return false }
        let layers = max(1, Int(ceil(min(28, height) / 3)))
        let thickness = height / Float(layers)
        let pitch = looseSnow.maximumActive > 0 ? looseSnow.cellSize : 3
        let radius = max(pitch * 0.75, min(thickness, source.spacing) * 0.5)
        for layer in 0..<layers {
            let offset = (Float(layer) + 0.5) * thickness
            let start = SIMD2(source.surface.x + localX, source.surface.baseY(at: localX) - offset)
            let end = SIMD2(next.x + localX, next.baseY(at: localX) - offset)
            let swept = CGRect(x: CGFloat(min(start.x, end.x) - radius),
                y: CGFloat(min(start.y, end.y) - radius), width: CGFloat(abs(end.x - start.x) + radius * 2),
                height: CGFloat(abs(end.y - start.y) + radius * 2))
            for motion in motions where motion.old.id != source.surface.id
                && motion.old.isElevated == source.surface.isElevated
                && motion.new.isElevated == next.isElevated {
                guard motion.old.bounds.union(motion.new.bounds).intersects(swept),
                      let hit = motion.contact(from: start, to: end, radius: radius), hit.time < time - 0.0001 else { continue }
                if motion.old.id != receiverID || hit.normal.y > -0.5 { return true }
            }
        }
        return false
    }


    /// Apply after moving-boundary pushes, so the moving window cannot immediately push its
    /// newly handed-off cap again. Saturation keeps an explicit bounded remainder for retry.
    func applySupportTransfers() {
        guard !supportTransfers.isEmpty else { return }
        var retained = 0
        for i in supportTransfers.indices {
            var transfer = supportTransfers[i]
            var top = transfer.baseY
            if let target = drifts.first(where: { $0.surface.id == transfer.targetID }) {
                let local = transfer.x - target.surface.x
                transfer.mass = target.depositMass(at: local, mass: transfer.mass)
                top = target.surface.baseY(at: max(0, min(target.surface.width, local))) - target.height(at: local)
            }
            if transfer.mass > 0.0001 {
                transfer.mass = looseSnow.add(mass: transfer.mass,
                    at: SIMD2(transfer.x, max(0, top - looseSnow.cellSize * 0.75)), direction: SIMD2(0, -1))
            }
            if transfer.mass > 0.0001 {
                supportTransfers[retained] = transfer
                retained += 1
            }
        }
        if retained < supportTransfers.count { supportTransfers.removeLast(supportTransfers.count - retained) }
        meshDirty = true
        interactionDirty = true
    }


    /// A temporary support's pile retains its location and area when the support vanishes.
    /// Keep unplaced area for retry when the granular pool or per-frame search is exhausted.
    func retainReleasedSnow(from drift: SnowDrift, coveredBy input: [SolidBody]) {
        guard drift.surface.releasesSnowWhenRemoved, budget.cells > 0 else { return }
        let covers = input.prefix(DesktopSceneBuilder.maximumBodies).filter { BodyChanges.valid($0) }
        for i in drift.heights.indices where drift.heights[i] > 0.0001 {
            let localX = Float(i) * drift.spacing
            let x = drift.surface.x + localX
            let bottom = drift.surface.baseY(at: localX)
            releaseIntervals.removeAll(keepingCapacity: true)
            releaseIntervals.append(Span(bottom - drift.heights[i], bottom))
            // Returning to the desktop plane exposes the cap to native window coverage
            // exactly once. Later movement pushes already pending material instead.
            for body in covers where x >= Float(body.bounds.minX) && x <= Float(body.bounds.maxX) {
                let edge = min(x - Float(body.bounds.minX), Float(body.bounds.maxX) - x)
                let r = body.cornerRadius
                let inset = edge < r ? r - sqrt(max(0, r * r - (r - edge) * (r - edge))) : 0
                let low = Float(body.bounds.minY) + inset
                let high = Float(body.bounds.maxY) - inset
                intervalScratch.removeAll(keepingCapacity: true)
                for span in releaseIntervals {
                    if low >= span.upper || high <= span.lower { intervalScratch.append(span) }
                    else {
                        if low > span.lower { intervalScratch.append(Span(span.lower, low)) }
                        if high < span.upper { intervalScratch.append(Span(high, span.upper)) }
                    }
                }
                swap(&releaseIntervals, &intervalScratch)
                if releaseIntervals.isEmpty { break }
            }
            for span in releaseIntervals {
                let height = span.upper - span.lower
                retainRelease(SnowRelease(position: SIMD2(x, (span.lower + span.upper) * 0.5),
                    height: height, mass: height * drift.spacing), in: &snowReleases)
            }
        }
        releaseIntervals.removeAll(keepingCapacity: true)
        intervalScratch.removeAll(keepingCapacity: true)
    }


    func retainRelease(_ release: SnowRelease, in queue: inout [SnowRelease]) {
        guard release.mass > 0.0001, budget.cells > 0 else { return }
        if queue.count < budget.cells {
            queue.append(release)
        } else {
            // Repeated dismissals cannot grow storage indefinitely. Coalesce overflow
            // into an existing reserve entry while retaining its total area and centroid.
            let slot = min(queue.count - 1,
                Int(max(0, min(1, release.position.x / size.x)) * Float(queue.count - 1)))
            let total = queue[slot].mass + release.mass
            let fraction = release.mass / total
            queue[slot].position += (release.position - queue[slot].position) * fraction
            queue[slot].height += (release.height - queue[slot].height) * fraction
            queue[slot].mass = total
        }
    }


    /// Dock magnification changes its horizontal footprint. Preserve the tail and tapered
    /// shoulder area that no longer fits on the smaller cap, using the existing material pool.
    func releaseTrimmedDockSnow(from previous: SnowDrift, to next: SnowDrift) {
        guard previous.surface.isDock, next.surface.isDock,
              next.surface.width < previous.surface.width else { return }
        let previousArea = previous.heights.reduce(0, +) * previous.spacing
        let retainedArea = next.heights.reduce(0, +) * next.spacing
        var remaining = max(0, previousArea - retainedArea)
        guard remaining > 0.0001 else { return }
        for i in previous.heights.indices where previous.heights[i] > 0.0001 {
            let x = Float(i) * previous.spacing
            let missingHeight = max(0, previous.heights[i] - next.height(at: x))
            let mass = min(remaining, missingHeight * previous.spacing)
            guard mass > 0.0001 else { continue }
            retainRelease(SnowRelease(position: SIMD2(previous.surface.x + x,
                previous.surface.baseY(at: x) - previous.heights[i] * 0.5),
                height: previous.heights[i], mass: mass), in: &snowReleases)
            remaining -= mass
            if remaining <= 0.0001 { break }
        }
        // Different sample spacing can leave a small interpolation remainder. Keep it at
        // the retreating edge; field exhaustion still leaves ownership in the retry reserve.
        if remaining > 0.0001 {
            let x = max(0, min(previous.surface.width, next.surface.width))
            let height = max(0.1, previous.height(at: x))
            retainRelease(SnowRelease(position: SIMD2(previous.surface.x + x,
                previous.surface.baseY(at: x) - height * 0.5), height: height, mass: remaining), in: &snowReleases)
        }
    }


    /// Pending material follows the same new-window erasure rule as visible caps. Retain
    /// the original column interval so a partial overlap removes only its covered area.
    func eraseReleasedSnow(inside appeared: [SolidBody]) {
        for body in appeared where !snowReleases.isEmpty {
            releaseScratch.removeAll(keepingCapacity: true)
            for release in snowReleases {
                let x = release.position.x
                guard x >= Float(body.bounds.minX), x <= Float(body.bounds.maxX) else {
                    retainRelease(release, in: &releaseScratch)
                    continue
                }
                let edge = min(x - Float(body.bounds.minX), Float(body.bounds.maxX) - x)
                let r = body.cornerRadius
                let inset = edge < r ? r - sqrt(max(0, r * r - (r - edge) * (r - edge))) : 0
                let low = Float(body.bounds.minY) + inset
                let high = Float(body.bounds.maxY) - inset
                let top = release.position.y - release.height * 0.5
                let bottom = release.position.y + release.height * 0.5
                guard low < bottom, high > top else {
                    retainRelease(release, in: &releaseScratch)
                    continue
                }
                let upper = max(0, min(bottom, low) - top)
                let lower = max(0, bottom - max(top, high))
                if upper > 0.0001 {
                    retainRelease(SnowRelease(position: SIMD2(x, top + upper * 0.5), height: upper,
                        mass: release.mass * upper / release.height), in: &releaseScratch)
                }
                if lower > 0.0001 {
                    retainRelease(SnowRelease(position: SIMD2(x, bottom - lower * 0.5), height: lower,
                        mass: release.mass * lower / release.height), in: &releaseScratch)
                }
            }
            swap(&snowReleases, &releaseScratch)
        }
        releaseScratch.removeAll(keepingCapacity: true)
    }


    func applySnowReleases() {
        guard !snowReleases.isEmpty else { return }
        var retained = 0
        var changed = false
        for i in snowReleases.indices {
            var release = snowReleases[i]
            let previousMass = release.mass
            release.mass = looseSnow.add(mass: release.mass, at: release.position, direction: SIMD2(0, 1))
            changed = changed || release.mass < previousMass
            if release.mass > 0.0001 {
                snowReleases[retained] = release
                retained += 1
            }
        }
        if retained < snowReleases.count { snowReleases.removeLast(snowReleases.count - retained) }
        if changed { meshDirty = true; interactionDirty = true }
    }
}
