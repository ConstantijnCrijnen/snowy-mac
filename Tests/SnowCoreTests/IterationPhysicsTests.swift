import Foundation
import XCTest
@testable import SnowCore

final class IterationPhysicsTests: XCTestCase {
    private func world() -> SnowSimulation {
        SnowSimulation(size: SIMD2(1000, 800),
                       budget: SimulationBudget(flakes: 0, debris: 32), seed: 57)
    }

    private func seedMiddle(_ drift: SnowDrift, height: Float = 8) {
        for i in drift.heights.indices {
            let x = Float(i) * drift.spacing
            drift.heights[i] = x >= 40 && x <= drift.surface.width - 40 ? height : 0
        }
    }

    private func totalArea(_ simulation: SnowSimulation) -> Float {
        simulation.drifts.reduce(Float(0)) { $0 + $1.heights.reduce(0, +) * $1.spacing }
            + simulation.looseSnow.totalMass
    }

    func testSmallGloveMotionPushesWithoutErasingTheWholeTouchedPile() {
        let simulation = world()
        simulation.updateSurfaces([Surface(id: 1, x: 100, y: 200, width: 400)])
        simulation.clear()
        seedMiddle(simulation.drifts[0])
        simulation.step(dt: 1 / 30, cursor: SIMD2(300, 195))
        let areaBefore = totalArea(simulation)

        simulation.step(dt: 1 / 30, cursor: SIMD2(301, 195))

        XCTAssertGreaterThan(simulation.drifts[0].height(at: 200), 6,
                             "A one-point glove movement must not atomize an entire eight-point pile")
        XCTAssertEqual(totalArea(simulation), areaBefore, accuracy: areaBefore * 0.01,
                       "Pushed area stays on surfaces or in granular snow, allowing only ambient snowfall")
    }

    func testStationaryGloveDoesNotExcavateOrEmitSnow() {
        let simulation = world()
        simulation.updateSurfaces([Surface(id: 1, x: 100, y: 200, width: 400)])
        simulation.clear()
        seedMiddle(simulation.drifts[0])
        simulation.step(dt: 1 / 30, cursor: SIMD2(300, 195))
        simulation.step(dt: 1 / 30, cursor: SIMD2(300, 195))

        XCTAssertGreaterThanOrEqual(simulation.drifts[0].height(at: 200), 8)
        XCTAssertEqual(simulation.looseSnow.totalMass, 0)
    }

    func testMovingSupportKeepsItsCapAttachedWithoutAnAutomaticAvalanche() {
        let simulation = world()
        simulation.updateScene(surfaces: [Surface(id: 1, x: 100, y: 200, width: 400)],
                               bodies: [SolidBody(id: 1, bounds: CGRect(x: 100, y: 200, width: 400, height: 300))])
        simulation.clear()
        seedMiddle(simulation.drifts[0])
        simulation.rebuildMesh()
        let oldRevision = simulation.meshRevision

        simulation.updateScene(surfaces: [Surface(id: 1, x: 140, y: 220, width: 400)],
                               bodies: [SolidBody(id: 1, bounds: CGRect(x: 140, y: 220, width: 400, height: 300))])

        XCTAssertEqual(simulation.looseSnow.totalMass, 0, "A support update must not generate a row of old-position spray")
        XCTAssertEqual(simulation.drifts[0].height(at: 200), 8, accuracy: 0.01)
        XCTAssertGreaterThan(simulation.meshRevision, oldRevision,
                             "Attached geometry must refresh in the same update, not wait for the settling tick")
        XCTAssertFalse(simulation.mesh.isEmpty)
        XCTAssertTrue(simulation.mesh.allSatisfy { $0.position.x >= 140 && $0.position.x <= 540 })
        XCTAssertTrue(simulation.mesh.allSatisfy { $0.position.y > 200 && $0.position.y < 221 })
    }

    func testNewWindowDeletesOnlyItsCoveredPartOfAnExistingPile() {
        let simulation = world()
        let floor = Surface(id: DesktopSceneBuilder.groundID, x: 0, y: 800, width: 1000)
        simulation.updateSurfaces([floor])
        simulation.clear()
        for i in simulation.drifts[0].heights.indices { simulation.drifts[0].heights[i] = 10 }

        simulation.updateBodies([SolidBody(id: 2, bounds: CGRect(x: 250, y: 780, width: 100, height: 60))])

        XCTAssertEqual(simulation.drifts[0].height(at: 300), 0)
        XCTAssertEqual(simulation.drifts[0].height(at: 200), 10)
        XCTAssertEqual(simulation.drifts[0].height(at: 400), 10)
        simulation.updateBodies([])
        simulation.updateSurfaces([floor])
        XCTAssertEqual(simulation.drifts[0].height(at: 300), 0,
                       "Removing a covering window must not restore snow that was only hidden")
    }

    func testBodiesAboveAPileDoNotDeleteTheUncoveredGapBelowThem() {
        let simulation = world()
        simulation.updateSurfaces([Surface(id: DesktopSceneBuilder.groundID, x: 0, y: 800, width: 1000)])
        simulation.clear()
        for i in simulation.drifts[0].heights.indices { simulation.drifts[0].heights[i] = 10 }

        simulation.updateBodies([SolidBody(id: 2, bounds: CGRect(x: 250, y: 100, width: 100, height: 300))])

        XCTAssertEqual(simulation.drifts[0].height(at: 300), 10,
                       "Coverage deletion uses actual vertical overlap, not the window's entire horizontal shadow")
    }

    func testFullPileConsumesAmbientContactSoSnowfallCanRecycle() {
        let simulation = world()
        simulation.updateSurfaces([Surface(id: DesktopSceneBuilder.groundID, x: 0, y: 800, width: 1000)])
        let floor = simulation.drifts[0]
        floor.accumulate(dt: 100_000, intensity: 1)
        let top = floor.surface.y - floor.height(at: 500)
        var flake = SnowParticle(position: SIMD2(500, top - 12), velocity: SIMD2(0, 800),
                                 radius: 2, opacity: 1, phase: 0, remainingLife: 100, mass: 2)

        XCTAssertTrue(simulation.advanceParticle(&flake, dt: 1 / 30, recycleOnContact: true),
                      "A full pile must recycle ambient flakes instead of pinning them in place")
    }

    func testReleasedSnowOccupiesManyBoundedGranularCells() {
        let simulation = world()
        XCTAssertEqual(simulation.looseSnow.add(mass: 800, at: SIMD2(200, 150)), 0, accuracy: 0.001)
        XCTAssertEqual(simulation.looseSnow.totalMass, 800, accuracy: 0.01)
        XCTAssertGreaterThan(simulation.looseSnow.active.count, 10,
                             "Bulk snow must be distributed over interacting cells, not one enlarged ellipse")
        for index in simulation.looseSnow.active {
            XCTAssertLessThanOrEqual(simulation.looseSnow.mass[index], simulation.looseSnow.capacity(of: index) + 0.001)
        }
    }

    func testRoundedColliderLeavesTheEmptyCornerFree() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 200)
        XCTAssertNil(ParticleCollision.hit(from: SIMD2(97, 100), to: SIMD2(105, 100),
                                          radius: 1, rectangle: rect, cornerRadius: 20))
        let contact = ParticleCollision.hit(from: SIMD2(100, 80), to: SIMD2(110, 120),
                                            radius: 1, rectangle: rect, cornerRadius: 20)
        XCTAssertNotNil(contact)
        XCTAssertLessThan(contact!.normal.x, 0)
        XCTAssertLessThan(contact!.normal.y, 0)
    }

    func testWindVectorActuallyDeflectsFallingSnow() {
        let calm = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 8), seed: 57)
        let windy = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 8), seed: 57)
        windy.wind = WindSettings(vector: SIMD2(1, 0))
        calm.step(dt: 1 / 30, cursor: nil)
        windy.step(dt: 1 / 30, cursor: nil)
        XCTAssertFalse(calm.flakes.isEmpty)
        XCTAssertEqual(windy.flakes[0].position.x - calm.flakes[0].position.x, 80 / 30, accuracy: 0.01)
    }

    func testResizingSupportDoesNotLeaveSnowAtTheOldFrame() {
        let simulation = world()
        simulation.updateSurfaces([Surface(id: 1, x: 100, y: 200, width: 400)])
        seedMiddle(simulation.drifts[0])
        simulation.updateSurfaces([Surface(id: 1, x: 80, y: 260, width: 520)])
        XCTAssertEqual(simulation.looseSnow.totalMass, 0)
        XCTAssertGreaterThan(simulation.drifts[0].height(at: 200), 7)
        XCTAssertFalse(simulation.mesh.isEmpty)
        XCTAssertTrue(simulation.mesh.allSatisfy { $0.position.x >= 80 && $0.position.x <= 600 && $0.position.y > 240 })
    }

    func testGranularSnowIsPlacedOutsideWindowCells() {
        let simulation = world()
        let obstacle = SolidBody(id: 1, bounds: CGRect(x: 300, y: 100, width: 200, height: 400))
        simulation.updateBodies([obstacle])
        XCTAssertEqual(simulation.looseSnow.add(mass: 300, at: SIMD2(285, 300), direction: SIMD2(1, 0)), 0, accuracy: 0.001)
        XCTAssertTrue(simulation.looseSnow.active.allSatisfy {
            !obstacle.contains(simulation.looseSnow.position(of: $0))
        })
    }

    func testWindowCoveringPileBaseCannotLeaveHiddenSnowToReappear() {
        let simulation = world()
        simulation.updateSurfaces([Surface(id: DesktopSceneBuilder.groundID, x: 0, y: 800, width: 1000)])
        for i in simulation.drifts[0].heights.indices { simulation.drifts[0].heights[i] = 10 }
        simulation.updateBodies([SolidBody(id: 2, bounds: CGRect(x: 250, y: 795, width: 100, height: 50))])
        XCTAssertEqual(simulation.drifts[0].height(at: 300), 0)
        simulation.updateBodies([])
        XCTAssertEqual(simulation.drifts[0].height(at: 300), 0)
        XCTAssertEqual(simulation.drifts[0].height(at: 200), 10)
    }

    func testShovelClearsStaticAndLooseSnowWithinItsRadius() {
        let simulation = world()
        simulation.updateSurfaces([Surface(id: 1, x: 100, y: 200, width: 400)])
        simulation.clear()
        seedMiddle(simulation.drifts[0], height: 4)
        XCTAssertEqual(simulation.looseSnow.add(mass: 120, at: SIMD2(300, 180)), 0, accuracy: 0.001)
        let before = totalArea(simulation)
        simulation.tool = .shovel
        let cursor = SIMD2<Float>(300, 195)

        simulation.step(dt: 1 / 30, cursor: cursor)

        XCTAssertLessThan(simulation.drifts[0].height(at: 200), 0.02,
                          "The shovel evacuates contacted columns, not just a fraction of their height")
        XCTAssertTrue(simulation.looseSnow.active.allSatisfy {
            let relative = simulation.looseSnow.position(of: $0) - cursor
            return hypot(relative.x, relative.y) >= 36
        }, "The shovel has a rigid empty region even for already detached snow")
        XCTAssertEqual(totalArea(simulation), before, accuracy: before * 0.01)
    }

    func testShovelPushesMoreSnowThanTheGloveForTheSameShortStroke() {
        let glove = world()
        let shovel = world()
        for simulation in [glove, shovel] {
            simulation.updateSurfaces([Surface(id: 1, x: 100, y: 200, width: 400)])
            simulation.clear()
            seedMiddle(simulation.drifts[0], height: 4)
            simulation.step(dt: 1 / 30, cursor: SIMD2(300, 195))
        }
        shovel.tool = .shovel
        glove.step(dt: 1 / 30, cursor: SIMD2(301, 195))
        shovel.step(dt: 1 / 30, cursor: SIMD2(301, 195))
        XCTAssertGreaterThan(glove.drifts[0].height(at: 200), 3)
        XCTAssertLessThan(shovel.drifts[0].height(at: 200), 0.02)
        XCTAssertGreaterThan(shovel.looseSnow.totalMass, glove.looseSnow.totalMass)
    }

    func testExistingWindowMovingFromLeftPushesFloorSnowRatherThanErasingIt() {
        assertMovingWindowPreservesSnow(
            old: CGRect(x: 100, y: 700, width: 100, height: 100),
            new: CGRect(x: 260, y: 700, width: 100, height: 100),
            seed: Span(290, 340), outside: { $0.x > 360 })
    }

    func testExistingWindowMovingFromRightPushesFloorSnowRatherThanErasingIt() {
        assertMovingWindowPreservesSnow(
            old: CGRect(x: 600, y: 700, width: 100, height: 100),
            new: CGRect(x: 300, y: 700, width: 100, height: 100),
            seed: Span(350, 390), outside: { $0.x < 300 })
    }

    func testExistingWindowMovingFromBelowLiftsFloorSnowRatherThanErasingIt() {
        assertMovingWindowPreservesSnow(
            old: CGRect(x: 200, y: 850, width: 200, height: 100),
            new: CGRect(x: 200, y: 760, width: 200, height: 100),
            seed: Span(240, 360), outside: { $0.y < 760 })
    }

    private func assertMovingWindowPreservesSnow(old: CGRect, new: CGRect, seed: Span,
                                                outside: (SIMD2<Float>) -> Bool,
                                                file: StaticString = #filePath, line: UInt = #line) {
        let simulation = world()
        let floor = Surface(id: DesktopSceneBuilder.groundID, x: 0, y: 800, width: 1000)
        simulation.updateScene(surfaces: [floor], bodies: [SolidBody(id: 2, bounds: old)])
        simulation.clear()
        let drift = simulation.drifts[0]
        for i in drift.heights.indices where seed.contains(Float(i) * drift.spacing) { drift.heights[i] = 10 }
        let before = totalArea(simulation)

        simulation.updateScene(surfaces: [floor], bodies: [SolidBody(id: 2, bounds: new)])

        XCTAssertGreaterThan(simulation.looseSnow.totalMass, before * 0.8, file: file, line: line)
        XCTAssertEqual(totalArea(simulation), before, accuracy: 0.05, file: file, line: line)
        XCTAssertTrue(simulation.looseSnow.active.allSatisfy {
            outside(simulation.looseSnow.position(of: $0))
        }, file: file, line: line)
    }

    func testNewWindowAtTheSameLocationErasesInsteadOfPushing() {
        let simulation = world()
        let floor = Surface(id: DesktopSceneBuilder.groundID, x: 0, y: 800, width: 1000)
        simulation.updateScene(surfaces: [floor], bodies: [SolidBody(id: 1, bounds: CGRect(x: 100, y: 700, width: 100, height: 100))])
        simulation.clear()
        for i in simulation.drifts[0].heights.indices where Span(290, 340).contains(Float(i) * simulation.drifts[0].spacing) {
            simulation.drifts[0].heights[i] = 10
        }
        XCTAssertEqual(simulation.looseSnow.add(mass: 30, at: SIMD2(310, 780)), 0, accuracy: 0.001)

        simulation.updateScene(surfaces: [floor], bodies: [SolidBody(id: 2, bounds: CGRect(x: 260, y: 700, width: 100, height: 100))])

        XCTAssertEqual(simulation.drifts[0].height(at: 310), 0)
        XCTAssertEqual(simulation.looseSnow.totalMass, 0, accuracy: 0.001)
    }
}
