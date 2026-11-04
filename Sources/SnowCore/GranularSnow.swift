import Foundation

/// A bounded cellular material field for displaced snow. Cells carry area, not projectile
/// sprites or rigid blobs. Gravity, compression and neighbour flow keep the material local.
public final class GranularSnow {
    public let cellSize: Float
    public let columns: Int
    public let rows: Int
    public let size: SIMD2<Float>
    public let maximumActive: Int
    public private(set) var mass: [Float]
    public private(set) var active: [Int] = []
    public private(set) var revision: UInt64 = 0

    public var totalMass: Float { active.reduce(0) { $0 + mass[$1] } }

    private var output: [Float]
    private var incoming: [Float]
    private var nextActive: [Int] = []
    private var listed: [Bool]
    private var solids: [Bool]
    private var difference: [Int16]
    private var bodies: [SolidBody] = []
    private var visited: [UInt32]
    private var visitGeneration: UInt32 = 0
    private var queue: [Int] = []
    private var affected: [Int] = []
    private var amounts: [Float] = []
    private var targets: [SIMD2<Float>] = []
    private var accumulator: Float = 0
    private var windDistance: Float = 0
    private var tick: UInt64 = 0
    private let epsilon: Float = 0.00001
    private let maximumSearch = 768
    private var placementVisits = 65_536
    private var searchOrigin: Int?
    private var searchDirection = SIMD2<Int>.zero
    private var searchCircle: SIMD2<Float>?
    private var searchRadius: Float = 0
    private var searchCursor = 0

    /// One bounded work allowance for a scene update or simulation frame. Exhaustion returns
    /// ownership to the source; it never drops material or starts an unbounded search.
    public func beginFrame() {
        placementVisits = 65_536
        searchOrigin = nil
    }

    public init(size input: SIMD2<Float>, maxCells: Int, maxActive: Int) {
        let width = input.x.isFinite ? max(1, min(65_536, input.x)) : 1
        let height = input.y.isFinite ? max(1, min(65_536, input.y)) : 1
        size = SIMD2(width, height)
        let budget = max(0, min(131_072, maxCells))
        if budget == 0 || maxActive <= 0 {
            cellSize = max(3, max(width, height))
            columns = 0
            rows = 0
            maximumActive = 0
            mass = []; output = []; incoming = []; listed = []; solids = []; difference = []; visited = []
            return
        }
        var pitch = max(3, sqrt(width * height / Float(budget)))
        var countX = max(1, Int(ceil(width / pitch)))
        var countY = max(1, Int(ceil(height / pitch)))
        while countX * countY > budget {
            pitch *= max(1.005, sqrt(Float(countX * countY) / Float(budget)))
            countX = max(1, Int(ceil(width / pitch)))
            countY = max(1, Int(ceil(height / pitch)))
        }
        cellSize = pitch
        columns = countX
        rows = countY
        let count = countX * countY
        maximumActive = max(0, min(count, min(32_768, maxActive)))
        mass = Array(repeating: 0, count: count)
        output = Array(repeating: 0, count: count)
        incoming = Array(repeating: 0, count: count)
        listed = Array(repeating: false, count: count)
        solids = Array(repeating: false, count: count)
        difference = Array(repeating: 0, count: countY * (countX + 1))
        visited = Array(repeating: 0, count: count)
        active.reserveCapacity(maximumActive)
        nextActive.reserveCapacity(maximumActive)
        affected.reserveCapacity(maximumActive)
        amounts.reserveCapacity(maximumActive)
        targets.reserveCapacity(maximumActive)
        queue.reserveCapacity(min(count, maximumSearch))
    }

    public func position(of index: Int) -> SIMD2<Float> {
        guard columns > 0, mass.indices.contains(index) else { return .zero }
        let x = Float(index % columns) * cellSize
        let y = Float(index / columns) * cellSize
        return SIMD2((x + min(size.x, x + cellSize)) * 0.5,
                     (y + min(size.y, y + cellSize)) * 0.5)
    }

    public func capacity(of index: Int) -> Float {
        guard columns > 0, mass.indices.contains(index) else { return 0 }
        let width = min(cellSize, size.x - Float(index % columns) * cellSize)
        let height = min(cellSize, size.y - Float(index / columns) * cellSize)
        return max(0, width * height)
    }

    public func isSolid(at index: Int) -> Bool { !solids.indices.contains(index) || solids[index] }

    public func clear() {
        searchOrigin = nil
        for index in active { mass[index] = 0; listed[index] = false }
        active.removeAll(keepingCapacity: true)
        accumulator = 0
        windDistance = 0
        revision &+= 1
    }

    /// Rasterize the rounded union with two updates per body/row and a single row-prefix pass.
    /// Cost is bounded by grid size plus summed body heights, not bodyCount * screenArea.
    public func setBodies(_ input: [SolidBody]) {
        guard columns > 0 else { return }
        let valid = Array(input.prefix(64).filter {
            let r = $0.bounds
            return r.minX.isFinite && r.minY.isFinite && r.width.isFinite && r.height.isFinite
                && abs(r.minX) < 100_000 && abs(r.minY) < 100_000
                && r.width > 0 && r.height > 0 && r.width <= 100_000 && r.height <= 100_000
        })
        guard valid != bodies else { return }
        bodies = valid
        searchOrigin = nil
        for index in difference.indices { difference[index] = 0 }
        for body in bodies {
            let rect = body.bounds
            let firstRow = max(0, Int(ceil(Float(rect.minY) / cellSize - 0.5)))
            let lastRow = min(rows - 1, Int(floor(Float(rect.maxY) / cellSize - 0.5)))
            guard firstRow <= lastRow else { continue }
            let radius = min(body.cornerRadius, Float(min(rect.width, rect.height) / 2))
            for row in firstRow...lastRow {
                let y = position(of: row * columns).y
                let edge = min(y - Float(rect.minY), Float(rect.maxY) - y)
                let inset = edge < radius ? radius - sqrt(max(0, radius * radius - (radius - edge) * (radius - edge))) : 0
                let left = max(0, Int(ceil((Float(rect.minX) + inset) / cellSize - 0.5)))
                let right = min(columns - 1, Int(floor((Float(rect.maxX) - inset) / cellSize - 0.5)))
                guard left <= right else { continue }
                let base = row * (columns + 1)
                difference[base + left] += 1
                difference[base + right + 1] -= 1
            }
        }
        for row in 0..<rows {
            var coverage: Int16 = 0
            for column in 0..<columns {
                coverage += difference[row * (columns + 1) + column]
                solids[row * columns + column] = coverage > 0
            }
        }
        revision &+= 1
    }

    /// A new window removes covered material. Moving windows use push(by:to:) instead.
    public func erase(inside body: SolidBody) {
        var changed = false
        for index in active where body.contains(position(of: index)) {
            mass[index] = 0
            changed = true
        }
        if changed { compact(); searchOrigin = nil; revision &+= 1 }
    }

    /// Add material by a bounded flood through free space. Return area that could not fit, so
    /// the caller can retain it in its original height profile instead of silently losing it.
    @discardableResult
    public func add(mass amount: Float, at point: SIMD2<Float>, direction: SIMD2<Float> = .zero,
                    excludingCircle circle: (center: SIMD2<Float>, radius: Float)? = nil) -> Float {
        place(amount, at: point, direction: direction, excludingCircle: circle, restorationSlots: 0)
    }

    private func place(_ amount: Float, at point: SIMD2<Float>, direction: SIMD2<Float>,
                       excludingCircle circle: (center: SIMD2<Float>, radius: Float)?,
                       restorationSlots: Int) -> Float {
        guard amount.isFinite, amount > epsilon else { return 0 }
        guard point.x.isFinite, point.y.isFinite, let origin = index(at: point), !solids[origin] else { return amount }
        let horizontal = abs(direction.x) >= abs(direction.y)
        let primary = horizontal ? SIMD2(direction.x >= 0 ? 1 : -1, 0) : SIMD2(0, direction.y >= 0 ? 1 : -1)
        let alternate = horizontal ? SIMD2(0, -1) : SIMD2(1, 0)
        if searchOrigin != origin || searchDirection != primary || searchCircle != circle?.center
            || searchRadius != (circle?.radius ?? 0) {
            visitGeneration &+= 1
            if visitGeneration == 0 {
                for i in visited.indices { visited[i] = 0 }
                visitGeneration = 1
            }
            queue.removeAll(keepingCapacity: true)
            queue.append(origin)
            visited[origin] = visitGeneration
            searchOrigin = origin
            searchDirection = primary
            searchCircle = circle?.center
            searchRadius = circle?.radius ?? 0
            searchCursor = 0
        }
        var remaining = amount
        while searchCursor < queue.count, searchCursor < maximumSearch, placementVisits > 0 {
            let current = queue[searchCursor]
            placementVisits -= 1
            let p = position(of: current)
            let outside: Bool
            if let circle {
                let delta = p - circle.center
                let margin = max(0, circle.radius) + cellSize * 0.55
                outside = delta.x * delta.x + delta.y * delta.y >= margin * margin
            } else { outside = true }
            if outside {
                let available = max(0, capacity(of: current) - mass[current])
                let accepted = min(remaining, available)
                let fullTransfer = accepted >= remaining - epsilon
                let reserve = max(0, restorationSlots - (fullTransfer ? 1 : 0))
                if accepted > epsilon {
                    guard listed[current] || active.count < maximumActive - reserve else {
                        if remaining < amount { revision &+= 1 }
                        return remaining
                    }
                    if !listed[current] { listed[current] = true; active.append(current) }
                    mass[current] += accepted
                    remaining -= accepted
                    if remaining <= epsilon, mass[current] < capacity(of: current) - epsilon {
                        revision &+= 1
                        return 0 // Reuse this partially occupied cell on the next batch addition.
                    }
                }
            }
            for side in 0..<4 {
                let step: SIMD2<Int>
                switch side {
                case 0: step = primary
                case 1: step = alternate
                case 2: step = SIMD2(-alternate.x, -alternate.y)
                default: step = SIMD2(-primary.x, -primary.y)
                }
                let x = current % columns + step.x, y = current / columns + step.y
                guard x >= 0, x < columns, y >= 0, y < rows else { continue }
                let neighbour = y * columns + x
                guard !solids[neighbour], visited[neighbour] != visitGeneration,
                      queue.count < maximumSearch else { continue }
                visited[neighbour] = visitGeneration
                queue.append(neighbour)
            }
            searchCursor += 1
            if remaining <= epsilon { revision &+= 1; return 0 }
        }
        if remaining < amount { revision &+= 1 }
        return remaining
    }

    /// Treat a held cursor as a circular physical tool. Hard mode excludes every touched grain;
    /// soft mode moves only a travel-proportional fraction, without a launch impulse.
    public func brush(from start: SIMD2<Float>, to end: SIMD2<Float>, radius inputRadius: Float, hard: Bool) {
        guard columns > 0, start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite,
              inputRadius.isFinite else { return }
        let radius = max(0, min(128, inputRadius))
        guard radius > 0 else { return }
        let delta = end - start
        let travel = sqrt(delta.x * delta.x + delta.y * delta.y)
        guard hard || travel > 0.01 else { return }
        affected.removeAll(keepingCapacity: true)
        amounts.removeAll(keepingCapacity: true)
        targets.removeAll(keepingCapacity: true)
        for index in active {
            let point = position(of: index)
            let closest = Geometry.closestPoint(to: point, on: start, end)
            let offset = point - closest
            let distance = sqrt(offset.x * offset.x + offset.y * offset.y)
            guard distance < radius + cellSize * (hard ? 0.35 : 0) else { continue }
            let fraction = hard ? Float(1) : min(0.65, travel / max(1, radius)) * max(0, 1 - distance / radius)
            let amount = mass[index] * fraction
            guard amount > epsilon else { continue }
            let radial = point - end
            let radialLength = sqrt(radial.x * radial.x + radial.y * radial.y)
            var direction = travel > 0.01 ? delta / travel : (radialLength > 0.01 ? radial / radialLength : SIMD2(0, -1))
            if travel > 0.01, radialLength > 0.01 { direction += radial / radialLength * 0.25 }
            let directionLength = max(0.001, sqrt(direction.x * direction.x + direction.y * direction.y))
            direction /= directionLength
            let desired = end + direction * (radius + cellSize)
            affected.append(index)
            amounts.append(amount)
            targets.append(lastFreePoint(from: point, to: desired))
        }
        displacePrepared(excludingCircle: (end, radius), direction: travel > 0.01 ? delta / travel : SIMD2(0, -1))
    }

    /// Existing boundaries plough material in their direction of travel. The swept leading
    /// face also catches a grain when the window moved more than a cell between snapshots.
    public func push(by old: SolidBody, to new: SolidBody) {
        guard columns > 0 else { return }
        let delta = SIMD2(Float(new.bounds.midX - old.bounds.midX), Float(new.bounds.midY - old.bounds.midY))
        affected.removeAll(keepingCapacity: true)
        amounts.removeAll(keepingCapacity: true)
        targets.removeAll(keepingCapacity: true)
        for index in active {
            let point = position(of: index)
            let swept = ParticleCollision.hit(from: point, to: point - delta, radius: 0,
                                              rectangle: old.bounds, cornerRadius: old.cornerRadius)
            guard new.contains(point) || (swept != nil && !old.contains(point)) else { continue }
            var normal = swept?.normal ?? motionNormal(old: old, new: new, point: point)
            if abs(normal.x) + abs(normal.y) < 0.01 { normal = SIMD2(0, -1) }
            var target = point
            if abs(normal.x) >= abs(normal.y) {
                target.x = normal.x > 0 ? Float(new.bounds.maxX) + cellSize : Float(new.bounds.minX) - cellSize
            } else {
                target.y = normal.y > 0 ? Float(new.bounds.maxY) + cellSize : Float(new.bounds.minY) - cellSize
            }
            target = clampedPoint(target)
            affected.append(index)
            amounts.append(mass[index])
            targets.append(target)
        }
        let length = sqrt(delta.x * delta.x + delta.y * delta.y)
        displacePrepared(excludingCircle: nil, direction: length > 0.01 ? delta / length : SIMD2(0, -1))
    }

    private func displacePrepared(excludingCircle circle: (center: SIMD2<Float>, radius: Float)?,
                                  direction: SIMD2<Float>) {
        guard !affected.isEmpty else { return }
        searchOrigin = nil
        var restorationSlots = 0
        for offset in affected.indices {
            let index = affected[offset]
            mass[index] = max(0, mass[index] - amounts[offset])
            if mass[index] <= epsilon { mass[index] = 0; restorationSlots += 1 }
        }
        compact()
        for offset in affected.indices {
            let index = affected[offset]
            let vacated = !listed[index]
            let remaining = place(amounts[offset], at: targets[offset], direction: direction,
                                  excludingCircle: circle, restorationSlots: restorationSlots)
            if remaining > epsilon {
                // A completely boxed-in or resource-saturated tool cannot destroy area.
                if !listed[index] { listed[index] = true; active.append(index) }
                mass[index] += remaining
            }
            if vacated { restorationSlots = max(0, restorationSlots - 1) }
        }
        revision &+= 1
    }

    /// Fixed cellular gravity, with no projectile velocity or unbounded catch-up loop.
    public func step(dt: Float, wind: SIMD2<Float>,
                     landing: (SIMD2<Float>, SIMD2<Float>, Float) -> (remaining: Float, blocked: Bool)) {
        guard columns > 0, dt.isFinite, dt > 0 else { return }
        searchOrigin = nil
        let verticalWind = wind.y.isFinite ? max(-80, min(80, wind.y)) : 0
        accumulator += min(dt, 0.05) * (1 + verticalWind / 160)
        let fixed: Float = 1 / 60
        let steps = min(3, Int((accumulator + 0.000001) / fixed))
        guard steps > 0 else { return }
        accumulator = max(0, min(fixed, accumulator - Float(steps) * fixed))
        for _ in 0..<steps {
            guard !active.isEmpty else { break }
            let horizontalWind = wind.x.isFinite ? max(-100, min(100, wind.x)) : 0
            windDistance += horizontalWind * fixed / cellSize
            let blown = abs(windDistance) >= 1
            let windSide = windDistance >= 0 ? 1 : -1
            if blown { windDistance -= Float(windSide) }
            cellularStep(windSide: blown ? windSide : 0, landing: landing)
        }
    }

    private func cellularStep(windSide: Int,
                              landing: (SIMD2<Float>, SIMD2<Float>, Float) -> (remaining: Float, blocked: Bool)) {
        nextActive.removeAll(keepingCapacity: true)
        var changed = false
        for offset in active.indices {
            let index = active[offset]
            var remaining = mass[index]
            guard remaining > epsilon else { continue }
            let start = position(of: index)
            let column = index % columns
            let row = index / columns
            let side = windSide != 0 ? windSide : ((tick + UInt64(column)).isMultiple(of: 2) ? -1 : 1)
            for attempt in 0..<3 {
                guard remaining > epsilon else { break }
                let dx = attempt == 0 ? (windSide == 0 ? 0 : side) : (attempt == 1 ? (windSide == 0 ? side : 0) : -side)
                let targetColumn = column + dx
                let targetRow = row + 1
                guard targetColumn >= 0, targetColumn < columns else { continue }
                if dx != 0 {
                    let adjacent = row * columns + targetColumn
                    if solids[adjacent] || mass[adjacent] >= capacity(of: adjacent) * 0.9 { continue }
                }
                let target = targetRow < rows ? targetRow * columns + targetColumn : nil
                if let target, !solids[target], mass[target] >= capacity(of: target) * 0.98 { continue }
                let end = target.map { position(of: $0) } ?? SIMD2(start.x + Float(dx) * cellSize, size.y + cellSize)
                let contact = landing(start, end, remaining)
                let before = remaining
                remaining = max(0, min(remaining, contact.remaining.isFinite ? contact.remaining : remaining))
                if before - remaining > epsilon { changed = true }
                guard remaining > epsilon, !contact.blocked, let target, !solids[target] else { continue }
                // Reserve the old occupant until the next tick. Several diagonal parents
                // must not each count the same remaining vacancy and overcompress a cell.
                let occupied = mass[target] + incoming[target]
                let room = max(0, capacity(of: target) - occupied)
                let moved = min(remaining, room)
                guard moved > epsilon else { continue }
                let unprocessed = active.count - offset - 1
                let requiresSource = moved < remaining - epsilon ? 1 : 0
                guard output[target] > epsilon || nextActive.count + unprocessed + requiresSource < maximumActive else { continue }
                writeOutput(moved, at: target)
                incoming[target] += moved
                remaining -= moved
                changed = true
            }
            if remaining > epsilon { writeOutput(remaining, at: index) }
        }
        for index in active { mass[index] = 0; listed[index] = false }
        for index in nextActive { incoming[index] = 0 }
        swap(&mass, &output)
        swap(&active, &nextActive)
        for index in active { listed[index] = true }
        tick &+= 1
        if changed { revision &+= 1 }
    }

    private func writeOutput(_ amount: Float, at index: Int) {
        if output[index] <= epsilon { nextActive.append(index) }
        output[index] += amount
    }

    private func compact() {
        var count = 0
        for index in active {
            if mass[index] > epsilon { active[count] = index; count += 1 }
            else { mass[index] = 0; listed[index] = false }
        }
        if count < active.count { active.removeLast(active.count - count) }
    }

    private func index(at point: SIMD2<Float>) -> Int? {
        guard columns > 0, point.x >= 0, point.y >= 0, point.x < size.x, point.y < size.y else { return nil }
        return min(rows - 1, Int(point.y / cellSize)) * columns + min(columns - 1, Int(point.x / cellSize))
    }

    private func clampedPoint(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let marginX = min(cellSize, size.x) * 0.5, marginY = min(cellSize, size.y) * 0.5
        return SIMD2(max(marginX, min(size.x - marginX, p.x)),
                     max(marginY, min(size.y - marginY, p.y)))
    }

    private func lastFreePoint(from start: SIMD2<Float>, to desired: SIMD2<Float>) -> SIMD2<Float> {
        let end = clampedPoint(desired)
        let delta = end - start
        let length = sqrt(delta.x * delta.x + delta.y * delta.y)
        let required = max(1, Int(ceil(length / (cellSize * 0.45))))
        let samples = min(512, required)
        var previous = start
        for sample in 1...samples {
            guard placementVisits > 0 else { return previous }
            placementVisits -= 1
            let candidate = start + delta * (Float(sample) / Float(required))
            guard let index = index(at: candidate), !solids[index] else { return previous }
            previous = candidate
        }
        return previous
    }

    private func motionNormal(old: SolidBody, new: SolidBody, point: SIMD2<Float>) -> SIMD2<Float> {
        if point.x <= Float(old.bounds.minX), new.bounds.minX < old.bounds.minX { return SIMD2(-1, 0) }
        if point.x >= Float(old.bounds.maxX), new.bounds.maxX > old.bounds.maxX { return SIMD2(1, 0) }
        if point.y <= Float(old.bounds.minY), new.bounds.minY < old.bounds.minY { return SIMD2(0, -1) }
        if point.y >= Float(old.bounds.maxY), new.bounds.maxY > old.bounds.maxY { return SIMD2(0, 1) }
        let delta = SIMD2(Float(new.bounds.midX - old.bounds.midX), Float(new.bounds.midY - old.bounds.midY))
        if abs(delta.x) > abs(delta.y) { return SIMD2(delta.x >= 0 ? 1 : -1, 0) }
        return SIMD2(0, delta.y > 0 ? 1 : -1)
    }
}
