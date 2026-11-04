import XCTest
@testable import SnowCore

final class SnowSimulationTests: XCTestCase {
    private func simulation(budget: SimulationBudget = SimulationBudget(flakes: 0)) -> SnowSimulation {
        SnowSimulation(size: SIMD2(1000, 800), budget: budget, seed: 42)
    }

    private func snow(on simulation: SnowSimulation, surface: Surface = Surface(id: 1, x: 100, y: 200, width: 400)) {
        simulation.updateSurfaces([surface])
        for i in simulation.drifts[0].heights.indices { simulation.drifts[0].heights[i] = 8 }
    }

    func testForegroundWindowSplitsBackgroundSnowEdge() {
        let spans = Geometry.subtract(Span(120, 260), from: [Span(0, 400)])
        XCTAssertEqual(spans, [Span(0, 120), Span(260, 400)])
        XCTAssertEqual(Geometry.subtract(Span(-10, 500), from: spans), [])
    }

    func testFastCursorSweepsEntirePathIntoBoundedGranularSnow() {
        let simulation = simulation(budget: SimulationBudget(flakes: 0, debris: 8))
        snow(on: simulation)
        simulation.step(dt: 1 / 30, cursor: SIMD2(90, 195))
        simulation.step(dt: 1 / 30, cursor: SIMD2(510, 195))
        XCTAssertLessThan(simulation.drifts[0].height(at: 200), 6)
        XCTAssertGreaterThan(simulation.drifts[0].height(at: 200), 0)
        XCTAssertGreaterThan(simulation.looseSnow.totalMass, 0)
        XCTAssertLessThanOrEqual(simulation.looseSnow.active.count, simulation.budget.maximumGranules)
    }

    func testStationaryPointerDoesNotVacuumSnow() {
        let simulation = simulation()
        snow(on: simulation)
        simulation.step(dt: 1 / 30, cursor: SIMD2(300, 195))
        simulation.step(dt: 1 / 30, cursor: SIMD2(300, 195))
        XCTAssertGreaterThanOrEqual(simulation.drifts[0].height(at: 200), 8)
        XCTAssertEqual(simulation.looseSnow.totalMass, 0)
    }

    func testSweepDoesNotRemoveOccludedSnow() {
        let simulation = simulation()
        snow(on: simulation, surface: Surface(id: 1, x: 100, y: 200, width: 400,
                                              visibleSpans: [Span(0, 100), Span(300, 400)]))
        simulation.step(dt: 1 / 30, cursor: SIMD2(90, 195))
        simulation.step(dt: 1 / 30, cursor: SIMD2(510, 195))
        XCTAssertEqual(simulation.drifts[0].height(at: 200), 8)
        XCTAssertLessThan(simulation.drifts[0].height(at: 50), 6)
    }

    func testResumeDoesNotClearAnArtificialCursorPath() {
        let simulation = simulation()
        snow(on: simulation)
        simulation.step(dt: 1 / 30, cursor: SIMD2(90, 195))
        simulation.resetPointer()
        simulation.step(dt: 1 / 30, cursor: SIMD2(510, 195))
        XCTAssertGreaterThanOrEqual(simulation.drifts[0].height(at: 200), 8)
    }

    func testLongFrameDoesNotSweepOrCatchUpSnowfall() {
        let simulation = simulation()
        snow(on: simulation)
        simulation.step(dt: 1 / 30, cursor: SIMD2(90, 195))
        simulation.step(dt: 3600, cursor: SIMD2(510, 195))
        XCTAssertLessThan(simulation.drifts[0].height(at: 200), 8.1)
        XCTAssertGreaterThanOrEqual(simulation.drifts[0].height(at: 200), 8)
    }

    func testFallingFlakeLandsOnFirstCrossedSurface() {
        let simulation = simulation()
        simulation.updateSurfaces([Surface(id: 1, x: 100, y: 200, width: 400),
                                   Surface(id: 2, x: 100, y: 300, width: 400)])
        simulation.clear()
        let particle = SnowParticle(position: SIMD2(300, 350), velocity: SIMD2(0, 50),
                                    radius: 2, opacity: 1, phase: 0, remainingLife: 1)
        XCTAssertTrue(simulation.land(from: SIMD2(300, 190), particle: particle))
        XCTAssertGreaterThan(simulation.drifts[0].height(at: 200), 0)
        XCTAssertEqual(simulation.drifts[1].height(at: 200), 0)
    }

    func testFlakePassesThroughCoveredEdge() {
        let simulation = simulation()
        simulation.updateSurfaces([Surface(id: 1, x: 100, y: 200, width: 400,
                                          visibleSpans: [Span(0, 80), Span(320, 400)])])
        let particle = SnowParticle(position: SIMD2(300, 210), velocity: SIMD2(0, 50),
                                    radius: 2, opacity: 1, phase: 0, remainingLife: 1)
        XCTAssertFalse(simulation.land(from: SIMD2(300, 190), particle: particle))
    }

    func testMovingAndRepositioningWindowsKeepSnowAttached() {
        let simulation = simulation()
        snow(on: simulation)
        simulation.updateSurfaces([Surface(id: 1, x: 140, y: 200, width: 400)])
        XCTAssertEqual(simulation.drifts[0].height(at: 200), 8)
        XCTAssertEqual(simulation.looseSnow.totalMass, 0)
        simulation.updateSurfaces([Surface(id: 1, x: 400, y: 200, width: 400)])
        XCTAssertEqual(simulation.drifts[0].height(at: 200), 8)
    }

    func testRepeatedSnapshotPreservesSnowAndMeshIdentity() {
        let simulation = simulation()
        snow(on: simulation)
        let previous = simulation.drifts[0]
        simulation.updateSurfaces([previous.surface])
        XCTAssertTrue(simulation.drifts[0] === previous)
        XCTAssertEqual(simulation.drifts[0].height(at: 200), 8)
    }

    func testSnowRemainsShallowAndCornersTaper() {
        let simulation = simulation()
        simulation.updateSurfaces([Surface(id: 1, x: 100, y: 200, width: 400)])
        simulation.drifts[0].accumulate(dt: 100_000, intensity: 1)
        XCTAssertEqual(simulation.drifts[0].heights.first, 0)
        XCTAssertEqual(simulation.drifts[0].heights.last, 0)
        XCTAssertLessThanOrEqual(simulation.drifts[0].heights.max()!, 18)
        XCTAssertGreaterThan(simulation.drifts[0].height(at: 200), 3)
    }

    func testDockGetsALowerRidgeThanWindows() {
        let simulation = simulation()
        simulation.updateSurfaces([Surface(id: 1, x: 100, y: 700, width: 400, isDock: true)])
        simulation.drifts[0].accumulate(dt: 100_000, intensity: 1)
        XCTAssertLessThanOrEqual(simulation.drifts[0].heights.max()!, 13)
        XCTAssertGreaterThan(simulation.drifts[0].height(at: 200), 3)
    }

    func testCPUVertexAndInstanceLayoutsMatchMetal() {
        XCTAssertEqual(MemoryLayout<SnowVertex>.stride, 16)
        XCTAssertEqual(MemoryLayout<SnowVertex>.offset(of: \.material), 8)
        XCTAssertEqual(MemoryLayout<ParticleInstance>.stride, 16)
        XCTAssertEqual(MemoryLayout<ParticleInstance>.offset(of: \.radius), 8)
        XCTAssertEqual(MemoryLayout<ParticleInstance>.offset(of: \.opacity), 12)
    }

    func testResourceBudgetsHoldWithManyWideWindows() {
        let budget = SimulationBudget(flakes: 12, debris: 4, cells: 160, surfaces: 12)
        let simulation = simulation(budget: budget)
        simulation.updateSurfaces((0..<200).map { Surface(id: UInt64($0), x: 0, y: 100, width: 1000) })
        for drift in simulation.drifts { drift.accumulate(dt: 100, intensity: 1) }
        simulation.snowfall = .flurry
        simulation.step(dt: 1 / 30, cursor: nil)
        simulation.rebuildMesh()
        XCTAssertEqual(simulation.drifts.count, 12)
        XCTAssertLessThanOrEqual(simulation.drifts.reduce(0) { $0 + $1.heights.count }, 160)
        XCTAssertTrue(simulation.drifts.allSatisfy { $0.heights.count >= 5 && $0.height(at: 500) > 0 })
        XCTAssertLessThanOrEqual(simulation.mesh.count, budget.maximumSnowVertices)
        XCTAssertLessThanOrEqual(simulation.flakes.count, 12)
        XCTAssertLessThanOrEqual(simulation.looseSnow.active.count, budget.maximumGranules)
    }

    func testMalformedAndDuplicateGeometryCannotAllocateUnboundedStorage() {
        let simulation = simulation()
        simulation.updateSurfaces([
            Surface(id: 1, x: 0, y: 200, width: .infinity),
            Surface(id: 2, x: .nan, y: 200, width: 100),
            Surface(id: 3, x: 0, y: 200, width: 100, visibleSpans: [Span(0, .nan)]),
            Surface(id: 4, x: 0, y: 200, width: 100),
            Surface(id: 4, x: 0, y: 300, width: 100)
        ])
        XCTAssertEqual(simulation.drifts.count, 1)
        XCTAssertEqual(simulation.drifts[0].surface.id, 4)
    }

    func testZeroBudgetCreatesNoParticlesOrDrifts() {
        let simulation = simulation(budget: SimulationBudget(flakes: 0, debris: 0, cells: 0, surfaces: 0))
        simulation.updateSurfaces([Surface(id: 1, x: 100, y: 200, width: 400)])
        simulation.step(dt: 1 / 30, cursor: nil)
        XCTAssertTrue(simulation.drifts.isEmpty)
        XCTAssertTrue(simulation.flakes.isEmpty)
        XCTAssertTrue(simulation.mesh.isEmpty)
        XCTAssertEqual(simulation.looseSnow.totalMass, 0)
    }

    func testReducedMotionHasNoAmbientFlakesAndPreservesBrushPhysics() {
        let simulation = simulation(budget: SimulationBudget(flakes: 20))
        snow(on: simulation)
        simulation.reducedMotion = true
        simulation.step(dt: 1 / 30, cursor: SIMD2(260, 195))
        simulation.step(dt: 1 / 30, cursor: SIMD2(300, 195))
        XCTAssertTrue(simulation.flakes.isEmpty)
        XCTAssertLessThanOrEqual(simulation.looseSnow.active.count, simulation.budget.maximumGranules)
        XCTAssertLessThan(simulation.drifts[0].height(at: 180), 8)
    }

    func testPowerPolicyRespondsToLowPowerHeatAndReducedMotion() {
        let normal = RenderPolicy(lowPower: false, thermalLevel: 0, reducedMotion: false)
        let low = RenderPolicy(lowPower: true, thermalLevel: 0, reducedMotion: false)
        let hot = RenderPolicy(lowPower: false, thermalLevel: 2, reducedMotion: false)
        let critical = RenderPolicy(lowPower: false, thermalLevel: 3, reducedMotion: false)
        let reduced = RenderPolicy(lowPower: false, thermalLevel: 0, reducedMotion: true)
        XCTAssertEqual(normal.framesPerSecond, 30)
        XCTAssertLessThan(low.framesPerSecond, normal.framesPerSecond)
        XCTAssertLessThan(hot.particleScale, low.particleScale)
        XCTAssertTrue(critical.suspended)
        XCTAssertEqual(reduced.particleScale, 0)
    }
}
