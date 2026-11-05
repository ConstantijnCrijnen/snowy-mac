import Foundation
import XCTest
@testable import SnowCore

final class RemovedSupportTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let spotlight = DesktopWindowRecord(id: 10,
        bounds: CGRect(x: 200, y: 180, width: 600, height: 70), layer: 101, role: .spotlight)

    private func apply(_ records: [DesktopWindowRecord], to simulation: SnowSimulation) {
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records)
        simulation.updateScene(surfaces: scene.surfaces, bodies: scene.bodies)
    }

    private func total(_ simulation: SnowSimulation) -> Float {
        simulation.drifts.reduce(0) { $0 + $1.heights.reduce(0, +) * $1.spacing }
            + simulation.looseSnow.totalMass + simulation.pendingTransferMass
    }

    private func seed(_ simulation: SnowSimulation) {
        let cap = simulation.drifts.first { $0.surface.id == spotlight.id }!
        for i in cap.heights.indices {
            let x = Float(i) * cap.spacing
            cap.heights[i] = x > 40 && x < cap.surface.width - 40 ? 6 : 0
        }
    }

    func testSpotlightCollectsSnowAndReleasesItWhenDismissed() {
        let simulation = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 0))
        let control = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 0))
        let lower = DesktopWindowRecord(id: 20, bounds: CGRect(x: 100, y: 400, width: 800, height: 300),
                                       layer: 0, role: .application)
        for world in [simulation, control] {
            apply([spotlight, lower], to: world)
            world.clear()
        }
        let cap = simulation.drifts.first { $0.surface.id == spotlight.id }!
        cap.accumulate(dt: 10, intensity: 1)
        XCTAssertGreaterThan(cap.height(at: 300), 0)
        simulation.clear()
        seed(simulation)
        let before = total(simulation)

        for world in [simulation, control] { apply([lower], to: world) }

        XCTAssertNil(simulation.drifts.first { $0.surface.id == spotlight.id })
        XCTAssertGreaterThan(simulation.looseSnow.totalMass, before * 0.9)
        XCTAssertEqual(total(simulation), before, accuracy: 0.1)
        let initialY = simulation.looseSnow.active.reduce(Float(0)) {
            $0 + simulation.looseSnow.position(of: $1).y * simulation.looseSnow.mass[$1]
        } / simulation.looseSnow.totalMass
        simulation.step(dt: 1 / 30, cursor: nil)
        let fallingY = simulation.looseSnow.active.reduce(Float(0)) {
            $0 + simulation.looseSnow.position(of: $1).y * simulation.looseSnow.mass[$1]
        } / simulation.looseSnow.totalMass
        XCTAssertGreaterThan(fallingY, initialY)
        control.step(dt: 1 / 30, cursor: nil)
        for _ in 0..<100 {
            simulation.step(dt: 1 / 30, cursor: nil)
            control.step(dt: 1 / 30, cursor: nil)
        }
        let received = simulation.drifts.first { $0.surface.id == lower.id }!
        let ambient = control.drifts.first { $0.surface.id == lower.id }!
        let deposited = zip(received.heights, ambient.heights).reduce(Float(0)) { $0 + $1.0 - $1.1 } * received.spacing
        XCTAssertGreaterThan(deposited, before * 0.75)
        XCTAssertEqual(total(simulation) - total(control), before, accuracy: before * 0.01)
    }

    func testRepeatedDismissalSnapshotsDoNotDuplicateReleasedSnow() {
        let simulation = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 0))
        apply([spotlight], to: simulation)
        simulation.clear()
        seed(simulation)
        let before = total(simulation)
        for _ in 0..<5 { apply([], to: simulation) }
        XCTAssertEqual(total(simulation), before, accuracy: 0.1)
        simulation.clear()
        XCTAssertEqual(total(simulation), 0)
    }

    func testNarrowDesktopPropCollectsAndReleasesSnowOnTheDesktopPlane() throws {
        let simulation = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 0))
        let floor = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: []).surfaces
        let prop = Surface(id: 42, x: 40, y: 770, width: 8,
                           releasesSnowWhenRemoved: true, isElevated: false)
        let body = SolidBody(id: 42, bounds: CGRect(x: 40, y: 770, width: 8, height: 30))
        simulation.updateScene(surfaces: floor + [prop], bodies: [body])
        let cap = try XCTUnwrap(simulation.drifts.first { $0.surface.id == prop.id })
        simulation.clear()
        cap.accumulate(dt: 30, intensity: 1)
        simulation.rebuildMesh()
        XCTAssertGreaterThan(cap.height(at: 4), 1)
        XCTAssertLessThanOrEqual(cap.height(at: 4), 4)
        XCTAssertFalse(simulation.mesh.isEmpty)
        XCTAssertTrue(simulation.elevatedMeshRanges.isEmpty)
        let before = total(simulation)
        simulation.updateScene(surfaces: floor, bodies: [])
        XCTAssertEqual(total(simulation), before, accuracy: 0.1)
        XCTAssertGreaterThan(simulation.looseSnow.totalMass, 0)
    }

    func testDismissalPreservesAreaWhenGranularStorageIsUnavailable() {
        let simulation = SnowSimulation(size: SIMD2(1000, 800),
            budget: SimulationBudget(flakes: 0, debris: 0, cells: 24, surfaces: 3))
        var expected: Float = 0
        // Repeated openings can exhaust the fixed reserve entry count. Overflow coalesces
        // rather than allocating more entries or losing the previous pile's area.
        for _ in 0..<12 {
            apply([spotlight], to: simulation)
            for drift in simulation.drifts { drift.clear() }
            seed(simulation)
            expected = total(simulation)
            apply([], to: simulation)
            XCTAssertEqual(total(simulation), expected, accuracy: 0.1)
            XCTAssertEqual(simulation.looseSnow.totalMass, 0)
            XCTAssertGreaterThan(simulation.pendingTransferMass, 0)
        }
        simulation.clear()
        XCTAssertEqual(simulation.pendingTransferMass, 0)
    }

    func testReleaseRetriesAfterGranularStorageBecomesAvailable() {
        let simulation = SnowSimulation(size: SIMD2(1000, 800),
            budget: SimulationBudget(flakes: 0, debris: 1, cells: 256, surfaces: 3))
        apply([spotlight], to: simulation)
        simulation.clear()
        seed(simulation)
        _ = simulation.looseSnow.add(mass: 1_000_000, at: SIMD2(30, 30))
        apply([], to: simulation)
        XCTAssertGreaterThan(simulation.pendingTransferMass, 0)
        simulation.looseSnow.clear()
        let pending = simulation.pendingTransferMass
        simulation.step(dt: 1 / 30, cursor: nil)
        XCTAssertGreaterThan(simulation.looseSnow.totalMass, 0)
        XCTAssertLessThan(simulation.pendingTransferMass, pending)
        XCTAssertGreaterThanOrEqual(total(simulation), pending - 0.01)
    }

    func testNewWindowErasesOnlyItsCoveredPortionDuringSpotlightDismissal() {
        let simulation = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 0, debris: 0))
        apply([spotlight], to: simulation)
        simulation.clear()
        seed(simulation)
        let before = total(simulation)
        let window = DesktopWindowRecord(id: 20, bounds: CGRect(x: 100, y: 177, width: 800, height: 400),
                                         layer: 0, role: .application)
        apply([window], to: simulation)
        for drift in simulation.drifts { drift.clear() }
        XCTAssertEqual(total(simulation), before * 0.5, accuracy: 0.1)
        XCTAssertEqual(simulation.pendingTransferMass, before * 0.5, accuracy: 0.1)
    }

    func testNewWindowAlsoErasesPreviouslyQueuedReleasedSnow() {
        let simulation = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 0, debris: 0))
        apply([spotlight], to: simulation)
        simulation.clear()
        seed(simulation)
        apply([], to: simulation)
        XCTAssertGreaterThan(simulation.pendingTransferMass, 0)
        let window = DesktopWindowRecord(id: 20, bounds: CGRect(x: 100, y: 100, width: 800, height: 200),
                                         layer: 0, role: .application)
        apply([window], to: simulation)
        XCTAssertEqual(simulation.pendingTransferMass, 0)
    }

    func testSpotlightCapRemainsVisibleAndCanBePushedAboveAnApplication() {
        let simulation = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 0))
        apply([spotlight], to: simulation)
        simulation.clear()
        seed(simulation)
        let before = total(simulation)
        let app = DesktopWindowRecord(id: 20, bounds: CGRect(x: 100, y: 80, width: 800, height: 600),
                                      layer: 0, role: .application)
        apply([spotlight, app], to: simulation)
        let cap = simulation.drifts.first { $0.surface.id == spotlight.id }!
        XCTAssertEqual(cap.height(at: 300), 6, accuracy: 0.01)
        XCTAssertTrue(cap.surface.isExposed(at: 300))
        XCTAssertTrue(cap.surface.isSnowExposed(at: 300))
        XCTAssertFalse(simulation.elevatedMeshRanges.isEmpty)
        XCTAssertTrue(simulation.elevatedMeshRanges.allSatisfy { $0.lowerBound >= 0 && $0.upperBound <= simulation.mesh.count })
        simulation.tool = .shovel
        simulation.step(dt: 1 / 30, cursor: SIMD2(500, 177))
        XCTAssertLessThan(cap.height(at: 300), 0.05)
        XCTAssertGreaterThan(cap.height(at: 340), 6)
        XCTAssertGreaterThanOrEqual(total(simulation), before - 0.01)
        // On dismissal that material returns behind native app windows. Covered material
        // must not remain queued inside a solid and later pop out when the app moves.
        apply([app], to: simulation)
        XCTAssertTrue(simulation.elevatedMeshRanges.isEmpty)
        XCTAssertEqual(simulation.pendingTransferMass, 0)
        XCTAssertEqual(simulation.looseSnow.totalMass, 0)
    }

    func testMovingWindowPushesQueuedSnowInsteadOfErasingIt() {
        let simulation = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 0, debris: 0))
        let app = DesktopWindowRecord(id: 20, bounds: CGRect(x: 850, y: 100, width: 100, height: 200),
                                     layer: 0, role: .application)
        apply([spotlight, app], to: simulation)
        simulation.clear()
        seed(simulation)
        apply([app], to: simulation)
        let before = simulation.pendingTransferMass
        XCTAssertGreaterThan(before, 0)
        var moved = app
        moved.bounds.origin.x = 300
        apply([moved], to: simulation)
        apply([moved], to: simulation)
        XCTAssertEqual(simulation.pendingTransferMass, before, accuracy: 0.1)
        XCTAssertEqual(total(simulation), before, accuracy: 0.1)
    }

    func testSpotlightCapDoesNotTransferToALowerPlaneWhenMovedDown() {
        let simulation = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 0))
        let app = DesktopWindowRecord(id: 20, bounds: CGRect(x: 100, y: 400, width: 800, height: 300),
                                     layer: 0, role: .application)
        apply([spotlight, app], to: simulation)
        simulation.clear()
        seed(simulation)
        let before = total(simulation)
        var moved = spotlight
        moved.bounds.origin.y = 450
        apply([moved, app], to: simulation)
        XCTAssertEqual(simulation.drifts.first { $0.surface.id == spotlight.id }!.height(at: 300), 6, accuracy: 0.01)
        XCTAssertEqual(simulation.drifts.first { $0.surface.id == app.id }!.height(at: 400), 0)
        XCTAssertEqual(total(simulation), before, accuracy: 0.1)
        XCTAssertEqual(simulation.pendingTransferMass, 0)
    }

    func testScreenEdgePushDoesNotStrandPendingSnowOutsideTheDisplay() {
        let simulation = SnowSimulation(size: SIMD2(1000, 800),
            budget: SimulationBudget(flakes: 0, debris: 1, cells: 256, surfaces: 3))
        let app = DesktopWindowRecord(id: 20, bounds: CGRect(x: 0, y: 100, width: 100, height: 200),
                                     layer: 0, role: .application)
        apply([spotlight, app], to: simulation)
        simulation.clear()
        seed(simulation)
        _ = simulation.looseSnow.add(mass: 1_000_000, at: SIMD2(30, 450))
        apply([app], to: simulation)
        let pending = simulation.pendingTransferMass
        XCTAssertGreaterThan(pending, 0)
        var moved = app
        moved.bounds.origin.x = 980
        apply([moved], to: simulation)
        XCTAssertEqual(simulation.pendingTransferMass, pending, accuracy: 0.1)
        simulation.looseSnow.clear()
        apply([], to: simulation)
        XCTAssertGreaterThan(simulation.looseSnow.totalMass, pending * 0.9)
        XCTAssertLessThan(simulation.pendingTransferMass, pending * 0.1)
    }
}
