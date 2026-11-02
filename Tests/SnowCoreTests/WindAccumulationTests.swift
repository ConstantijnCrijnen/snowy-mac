import Foundation
import XCTest
@testable import SnowCore

final class WindAccumulationTests: XCTestCase {
    private func world(wind: Float = 0, clear: Bool = true) -> SnowSimulation {
        let scene = DesktopSceneBuilder.build(displayBounds: CGRect(x: 0, y: 0, width: 1000, height: 800), menuInset: 24,
            windows: [
                DesktopWindowRecord(id: 1, bounds: CGRect(x: 400, y: 100, width: 200, height: 500), layer: 0, role: .application),
                DesktopWindowRecord(id: 2, bounds: CGRect(x: 100, y: 400, width: 800, height: 300), layer: 0, role: .application)
            ])
        let simulation = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 0), seed: 91)
        simulation.wind = WindSettings(vector: SIMD2(wind, 0))
        simulation.updateScene(surfaces: scene.surfaces, bodies: scene.bodies)
        if clear { simulation.clear() }
        return simulation
    }

    private func lower(_ world: SnowSimulation) -> SnowDrift { world.drifts.first { $0.surface.id == 2 }! }

    private func run(_ simulations: [SnowSimulation], steps: Int = 120) {
        for _ in 0..<steps { for simulation in simulations { simulation.step(dt: 1 / 30, cursor: nil) } }
    }

    private func area(_ simulation: SnowSimulation) -> Float {
        simulation.drifts.reduce(0) { $0 + $1.heights.reduce(0, +) * $1.spacing }
            + simulation.looseSnow.totalMass + simulation.pendingTransferMass
    }

    func testNewSurfaceDustingRespectsIncomingWindWithoutBlockingManualSnow() {
        let simulation = world(wind: 1, clear: false)
        let drift = lower(simulation)
        XCTAssertEqual(drift.height(at: 540), 0, accuracy: 0.001)
        XCTAssertGreaterThan(drift.height(at: 700), 0)
        XCTAssertEqual(drift.depositMass(at: 540, mass: 30), 0, accuracy: 0.001)
        XCTAssertGreaterThan(drift.height(at: 540), 0)
    }

    func testWindChangesActualCornerAccumulationWithoutRaisingTheHardLimit() {
        let calm = world(), right = world(wind: 1)
        run([calm, right])
        XCTAssertEqual(lower(right).height(at: 540), 0, accuracy: 0.001, "The right-side wake remains clear")
        XCTAssertGreaterThan(lower(right).height(at: 280), lower(calm).height(at: 280) * 1.3,
                             "The same upwind sample builds faster against the left wall")
        lower(right).accumulate(dt: 100_000, intensity: 1)
        XCTAssertLessThanOrEqual(lower(right).heights.max()!, 18)
        XCTAssertEqual(lower(right).height(at: 540), 0, accuracy: 0.001)
    }

    func testReversingWindSwapsWhichCornerAccumulates() {
        let right = world(wind: 1), left = world(wind: -1)
        run([right, left])
        XCTAssertGreaterThan(lower(right).height(at: 280), lower(left).height(at: 280) + 0.2)
        XCTAssertGreaterThan(lower(left).height(at: 540), lower(right).height(at: 540) + 0.2)
        XCTAssertEqual(lower(left).height(at: 280), 0, accuracy: 0.001)
    }

    func testSpeedChangesTheRadiusInTheRunningSimulation() {
        let slow = world(wind: 0.5), fast = world(wind: 1)
        run([slow, fast])
        XCTAssertGreaterThan(lower(slow).height(at: 580), 0.2)
        XCTAssertLessThan(lower(fast).height(at: 580), lower(slow).height(at: 580) * 0.25,
                          "Settled snow may diffuse into the shadow, but direct snowfall remains suppressed")
    }

    func testWindDirectionChangeDoesNotMoveOrClampSettledSnow() {
        let simulation = world()
        let drift = lower(simulation)
        for i in drift.heights.indices {
            let worldX = drift.surface.x + Float(i) * drift.spacing
            if worldX >= 620, worldX <= 660 { drift.heights[i] = 6 }
        }
        let before = area(simulation)
        let previous = drift.heights
        simulation.wind = WindSettings(vector: SIMD2(1, 0))
        // Rebuild the wind cache without advancing unrelated settling or gravity.
        simulation.updateScene(surfaces: simulation.drifts.map(\.surface), bodies: [
            SolidBody(id: 1, bounds: CGRect(x: 400, y: 100, width: 200, height: 500), cornerRadius: 12),
            SolidBody(id: 2, bounds: CGRect(x: 100, y: 400, width: 800, height: 300), cornerRadius: 12)
        ])
        XCTAssertEqual(drift.heights, previous)
        XCTAssertEqual(area(simulation), before, accuracy: 0.001)
        XCTAssertEqual(simulation.looseSnow.totalMass, 0)
        simulation.step(dt: 1 / 30, cursor: nil)
        XCTAssertEqual(drift.height(at: 540), 6, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(area(simulation), before - 0.01)
        XCTAssertLessThan(area(simulation), before + 30, "Only one frame of ambient deposition is added")
    }

    func testLandingFlakeCannotRefillAClearedWake() {
        let simulation = world(wind: 1)
        var flake = SnowParticle(position: SIMD2(640, 390), velocity: SIMD2(0, 600), radius: 2,
                                 opacity: 1, phase: 0, remainingLife: 100, mass: 8)
        XCTAssertTrue(simulation.advanceParticle(&flake, dt: 1 / 30, recycleOnContact: true))
        XCTAssertEqual(lower(simulation).height(at: 540), 0, accuracy: 0.001)
    }

    func testLooseSnowRemainsInTheSnowfallShadowAndCanSettleThere() {
        let simulation = world()
        XCTAssertEqual(simulation.looseSnow.add(mass: 90, at: SIMD2(640, 380)), 0, accuracy: 0.001)
        let before = area(simulation)
        simulation.wind = WindSettings(vector: SIMD2(1, 0))
        simulation.step(dt: 1 / 30, cursor: nil)
        XCTAssertGreaterThanOrEqual(area(simulation), before - 0.01)
        XCTAssertTrue(simulation.looseSnow.active.contains {
            let point = simulation.looseSnow.position(of: $0)
            return point.x >= 600 && point.x <= 696 && point.y >= 368 && point.y <= 403
        }, "Wind must not forcibly evacuate manually placed grains from its snowfall shadow")
        run([simulation], steps: 20)
        XCTAssertGreaterThan(lower(simulation).height(at: 540), 0.1)
    }

    func testManualDepositUsesTheSamePhysicalCapacityInCalmAndWind() {
        let calm = world(), right = world(wind: 1)
        let calmRemainder = lower(calm).depositMass(at: 540, mass: 30)
        let windRemainder = lower(right).depositMass(at: 540, mass: 30)
        XCTAssertEqual(windRemainder, calmRemainder, accuracy: 0.001)
        XCTAssertGreaterThan(lower(right).height(at: 540), 0)
        XCTAssertEqual(lower(right).height(at: 540), lower(calm).height(at: 540), accuracy: 0.001)
        XCTAssertEqual(lower(right).depositMass(at: 540, mass: 10, snowfall: true), 10)
    }

    func testShovelCanDeliberatelyFillASnowfallShadow() {
        let simulation = world(wind: 1)
        let drift = lower(simulation)
        for i in drift.heights.indices {
            let x = drift.surface.x + Float(i) * drift.spacing
            if x >= 710, x <= 750 { drift.heights[i] = 5 }
        }
        let before = area(simulation)
        simulation.tool = .shovel
        simulation.step(dt: 1 / 30, cursor: SIMD2(740, 395))
        simulation.step(dt: 1 / 30, cursor: SIMD2(650, 395))
        XCTAssertTrue(simulation.looseSnow.active.contains {
            let p = simulation.looseSnow.position(of: $0)
            return p.x >= 600 && p.x <= 696 && p.y <= 403
        })
        simulation.tool = .glove
        run([simulation], steps: 30)
        let shadowArea = drift.heights.indices.reduce(Float(0)) { sum, i in
            let x = drift.surface.x + Float(i) * drift.spacing
            return sum + ((x >= 600 && x <= 696) ? drift.heights[i] * drift.spacing : 0)
        }
        XCTAssertGreaterThan(shadowArea, 1)
        XCTAssertGreaterThanOrEqual(area(simulation), before - 0.01)
    }
}
