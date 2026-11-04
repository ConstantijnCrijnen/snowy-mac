import Foundation
import XCTest
@testable import SnowCore

final class PhysicsWorldTests: XCTestCase {
    private func world(granularAllocation: Int = 96) -> SnowSimulation {
        SnowSimulation(size: SIMD2(1000, 800),
                       budget: SimulationBudget(flakes: 0, debris: granularAllocation), seed: 47)
    }

    private func flake(at position: SIMD2<Float>, velocity: SIMD2<Float>, mass: Float = 8) -> SnowParticle {
        SnowParticle(position: position, velocity: velocity, radius: 2, opacity: 1,
                     phase: 0, remainingLife: 100, mass: mass)
    }

    private func area(_ drift: SnowDrift) -> Float { drift.heights.reduce(0, +) * drift.spacing }
    private func totalArea(_ world: SnowSimulation) -> Float {
        world.drifts.reduce(0) { $0 + area($1) } + world.looseSnow.totalMass
    }
    private func drift(_ id: UInt64, in world: SnowSimulation) -> SnowDrift {
        world.drifts.first { $0.surface.id == id }!
    }

    func testAmbientFlakeCannotTunnelThroughLeftWindowWall() {
        let simulation = world()
        simulation.updateBodies([SolidBody(id: 1, bounds: CGRect(x: 300, y: 200, width: 200, height: 200))])
        var snow = flake(at: SIMD2(100, 300), velocity: SIMD2(8000, 0))
        XCTAssertFalse(simulation.advanceParticle(&snow, dt: 0.05))
        XCTAssertLessThanOrEqual(snow.position.x, 298.01)
        XCTAssertLessThanOrEqual(snow.velocity.x, 0)
    }

    func testAmbientFlakeCannotTunnelThroughRightWindowWall() {
        let simulation = world()
        simulation.updateBodies([SolidBody(id: 1, bounds: CGRect(x: 300, y: 200, width: 200, height: 200))])
        var snow = flake(at: SIMD2(700, 300), velocity: SIMD2(-8000, 0))
        XCTAssertFalse(simulation.advanceParticle(&snow, dt: 0.05))
        XCTAssertGreaterThanOrEqual(snow.position.x, 501.99)
        XCTAssertGreaterThanOrEqual(snow.velocity.x, 0)
    }

    func testAmbientFlakeCollidesWithWindowUnderside() {
        let simulation = world()
        simulation.updateBodies([SolidBody(id: 1, bounds: CGRect(x: 300, y: 200, width: 200, height: 200))])
        var snow = flake(at: SIMD2(400, 500), velocity: SIMD2(0, -6000))
        XCTAssertFalse(simulation.advanceParticle(&snow, dt: 0.05))
        XCTAssertGreaterThanOrEqual(snow.position.y, 401.99)
        XCTAssertGreaterThanOrEqual(snow.velocity.y, 0)
    }

    func testDiagonalFlakeLandsAtCrossingRatherThanFinalX() {
        let simulation = world()
        simulation.updateScene(surfaces: [Surface(id: 1, x: 100, y: 200, width: 400)],
                               bodies: [SolidBody(id: 1, bounds: CGRect(x: 100, y: 200, width: 400, height: 200))])
        simulation.clear()
        var snow = flake(at: SIMD2(20, 100), velocity: SIMD2(6000, 3000))
        XCTAssertTrue(simulation.advanceParticle(&snow, dt: 0.05))
        XCTAssertGreaterThan(drift(1, in: simulation).height(at: 116), 0)
        XCTAssertEqual(drift(1, in: simulation).height(at: 220), 0)
    }

    func testGranularMassSettlesOnADifferentLowerWindow() {
        let simulation = world()
        let control = world()
        let surfaces = [Surface(id: 1, x: 100, y: 200, width: 200),
                        Surface(id: 2, x: 450, y: 500, width: 300)]
        let bodies = [SolidBody(id: 1, bounds: CGRect(x: 100, y: 200, width: 200, height: 200)),
                      SolidBody(id: 2, bounds: CGRect(x: 450, y: 500, width: 300, height: 200))]
        for world in [simulation, control] {
            world.updateScene(surfaces: surfaces, bodies: bodies)
            world.clear()
        }
        XCTAssertEqual(simulation.looseSnow.add(mass: 20, at: SIMD2(500, 470)), 0, accuracy: 0.001)
        for _ in 0..<20 {
            simulation.step(dt: 1 / 30, cursor: nil)
            control.step(dt: 1 / 30, cursor: nil)
        }
        XCTAssertEqual(area(drift(1, in: simulation)) - area(drift(1, in: control)), 0, accuracy: 0.01)
        XCTAssertGreaterThan(area(drift(2, in: simulation)) - area(drift(2, in: control)), 15)
        XCTAssertEqual(totalArea(simulation) - totalArea(control), 20, accuracy: 0.1)
    }

    func testScreenFloorCatchesGranularMass() {
        let simulation = world()
        let control = world()
        for world in [simulation, control] {
            world.updateScene(surfaces: [Surface(id: DesktopSceneBuilder.groundID, x: 0, y: 800, width: 1000)], bodies: [])
            world.clear()
        }
        XCTAssertEqual(simulation.looseSnow.add(mass: 24, at: SIMD2(500, 760)), 0, accuracy: 0.001)
        for _ in 0..<20 {
            simulation.step(dt: 1 / 30, cursor: nil)
            control.step(dt: 1 / 30, cursor: nil)
        }
        XCTAssertGreaterThan(area(drift(DesktopSceneBuilder.groundID, in: simulation))
                             - area(drift(DesktopSceneBuilder.groundID, in: control)), 20)
        XCTAssertEqual(totalArea(simulation) - totalArea(control), 24, accuracy: 0.1)
    }

    func testDepositingMassConservesAreaWhenCapacityIsAvailable() {
        let simulation = world()
        simulation.updateSurfaces([Surface(id: 1, x: 100, y: 200, width: 400)])
        simulation.clear()
        let destination = drift(1, in: simulation)
        XCTAssertEqual(destination.depositMass(at: 200, mass: 20), 0, accuracy: 0.001)
        XCTAssertEqual(area(destination), 20, accuracy: 0.01)
    }

    func testSweptGranularSnowUltimatelyReachesTheFloorWithoutAProjectileExpiry() {
        let simulation = world()
        let control = world()
        let surfaces = [Surface(id: DesktopSceneBuilder.groundID, x: 0, y: 800, width: 1000),
                        Surface(id: 1, x: 100, y: 120, width: 200)]
        let bodies = [SolidBody(id: 1, bounds: CGRect(x: 100, y: 120, width: 200, height: 300))]
        for world in [simulation, control] {
            world.updateScene(surfaces: surfaces, bodies: bodies)
            world.clear()
        }
        let source = drift(1, in: simulation)
        for i in source.heights.indices.dropFirst().dropLast() { source.heights[i] = 4 }
        simulation.step(dt: 1 / 30, cursor: SIMD2(90, 117))
        simulation.step(dt: 1 / 30, cursor: SIMD2(310, 117))
        XCTAssertGreaterThan(simulation.looseSnow.totalMass, 0)
        for _ in 0..<150 {
            simulation.step(dt: 1 / 30, cursor: nil)
            control.step(dt: 1 / 30, cursor: nil)
        }
        let transported = area(drift(DesktopSceneBuilder.groundID, in: simulation))
            - area(drift(DesktopSceneBuilder.groundID, in: control))
        XCTAssertGreaterThan(transported, 100, "Existing snow should reach the floor through granular flow, beyond its ambient dusting")
    }

    func testRepeatedSweepsKeepGranularStorageBounded() {
        let simulation = world(granularAllocation: 4)
        simulation.updateSurfaces([Surface(id: DesktopSceneBuilder.groundID, x: 0, y: 800, width: 1000),
                                   Surface(id: 1, x: 100, y: 200, width: 400)])
        let source = drift(1, in: simulation)
        for i in source.heights.indices.dropFirst().dropLast() { source.heights[i] = 4 }
        for i in 0..<12 {
            simulation.step(dt: 1 / 30, cursor: SIMD2(i.isMultiple(of: 2) ? 90 : 510, 198))
            XCTAssertLessThanOrEqual(simulation.looseSnow.active.count, simulation.budget.maximumGranules)
        }
    }

    func testGranuleOvertakenByGrowingCapSettlesWithoutBeingStranded() {
        let simulation = world(), control = world()
        for world in [simulation, control] {
            world.updateScene(surfaces: [Surface(id: 7, x: 200, y: 720, width: 600, isDock: true)],
                bodies: [SolidBody(id: 7, bounds: CGRect(x: 200, y: 720, width: 600, height: 70))])
            world.clear()
            let cap = drift(7, in: world)
            for i in cap.heights.indices where Float(i) * cap.spacing > 200 && Float(i) * cap.spacing < 400 {
                cap.heights[i] = 3
            }
        }
        // A preceding landing grew the roof above the adjacent grain's center. The grain
        // is outside the native body, but already intersects its smooth snow profile.
        XCTAssertEqual(simulation.looseSnow.add(mass: 9, at: SIMD2(499.5, 718.5)), 0, accuracy: 0.001)
        simulation.step(dt: 1 / 30, cursor: nil)
        control.step(dt: 1 / 30, cursor: nil)
        XCTAssertEqual(simulation.looseSnow.totalMass, 0, accuracy: 0.001)
        XCTAssertEqual(area(drift(7, in: simulation)) - area(drift(7, in: control)), 9, accuracy: 0.01)
        XCTAssertEqual(totalArea(simulation) - totalArea(control), 9, accuracy: 0.01)
    }
}
