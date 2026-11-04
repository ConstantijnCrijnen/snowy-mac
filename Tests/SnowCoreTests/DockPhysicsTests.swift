import CoreGraphics
import XCTest
@testable import SnowCore

final class DockPhysicsTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let dockID = DesktopSceneBuilder.dockID

    private func scene(bounds: CGRect) -> DesktopScene {
        DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [DesktopWindowRecord(id: 7, bounds: bounds, layer: 20, role: .dock)],
            dockLayout: DockLayoutHint(orientation: .bottom, tileSize: 48, itemCount: 10))
    }

    private func area(_ simulation: SnowSimulation) -> Float {
        simulation.drifts.reduce(0) { $0 + $1.heights.reduce(0, +) * $1.spacing }
            + simulation.looseSnow.totalMass + simulation.pendingTransferMass
    }

    func testBottomDockReceivesFallingSnowAndBuildsAVisibleCap() throws {
        let geometry = scene(bounds: CGRect(x: 200, y: 720, width: 600, height: 70))
        let simulation = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 0))
        simulation.updateScene(surfaces: geometry.surfaces, bodies: geometry.bodies)
        simulation.clear()
        var flake = SnowParticle(position: SIMD2(500, 710), velocity: SIMD2(0, 600), radius: 2,
                                 opacity: 1, phase: 0, remainingLife: 100, mass: 8)
        XCTAssertTrue(simulation.advanceParticle(&flake, dt: 1 / 30, recycleOnContact: true))
        let drift = try XCTUnwrap(simulation.drifts.first { $0.surface.id == dockID })
        XCTAssertGreaterThan(drift.height(at: 300), 0)
        for _ in 0..<120 { simulation.step(dt: 1 / 30, cursor: nil) }
        XCTAssertGreaterThan(drift.height(at: 300), 0.5)
        simulation.rebuildMesh()
        XCTAssertTrue(simulation.mesh.contains {
            $0.position.x > 220 && $0.position.x < 780 && $0.position.y < 720 && $0.position.y > 700
        })
    }

    func testBottomDockHoverGeometryPreservesItsPileAndMovesItsSnowSurface() throws {
        let initial = scene(bounds: CGRect(x: 200, y: 720, width: 600, height: 70))
        let simulation = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 0))
        simulation.updateScene(surfaces: initial.surfaces, bodies: initial.bodies)
        simulation.clear()
        let original = try XCTUnwrap(simulation.drifts.first { $0.surface.id == dockID })
        original.accumulate(dt: 20, intensity: 1)
        let before = area(simulation)
        let magnifiedBounds = CGRect(x: 170, y: 690, width: 660, height: 100)
        let magnified = scene(bounds: magnifiedBounds)
        simulation.updateScene(surfaces: magnified.surfaces, bodies: magnified.bodies)
        let current = try XCTUnwrap(simulation.drifts.first { $0.surface.id == dockID })
        XCTAssertEqual(current.surface.x, 170)
        XCTAssertEqual(current.surface.y, 690)
        XCTAssertEqual(current.surface.width, 660)
        XCTAssertGreaterThan(current.height(at: 300), 1)
        XCTAssertEqual(area(simulation), before, accuracy: before * 0.02)
        XCTAssertEqual(simulation.looseSnow.totalMass, 0)
        XCTAssertEqual(magnified.bodies.first?.bounds, magnifiedBounds)
        XCTAssertTrue(simulation.mesh.contains {
            $0.position.x > 190 && $0.position.x < 810 && $0.position.y < 690 && $0.position.y > 670
        })
    }

    func testBottomDockShedsTrimmedSnowWhenHoverEndsWithoutLosingArea() throws {
        for granular in [true, false] {
            let simulation = SnowSimulation(size: SIMD2(1000, 800),
                budget: SimulationBudget(flakes: 0, debris: granular ? 96 : 0))
            let magnified = scene(bounds: CGRect(x: 170, y: 690, width: 660, height: 100))
            simulation.updateScene(surfaces: magnified.surfaces, bodies: magnified.bodies)
            simulation.clear()
            let expanded = try XCTUnwrap(simulation.drifts.first { $0.surface.id == dockID })
            // Snow builds on the extra width while magnified, including the new shoulder.
            expanded.accumulate(dt: 30, intensity: 1)
            let before = area(simulation)
            let normal = scene(bounds: CGRect(x: 200, y: 720, width: 600, height: 70))
            simulation.updateScene(surfaces: normal.surfaces, bodies: normal.bodies)
            XCTAssertEqual(area(simulation), before, accuracy: 0.1)
            XCTAssertGreaterThan(simulation.looseSnow.totalMass + simulation.pendingTransferMass, 0)
            let released = simulation.looseSnow.totalMass + simulation.pendingTransferMass
            simulation.updateScene(surfaces: normal.surfaces, bodies: normal.bodies)
            XCTAssertEqual(area(simulation), before, accuracy: 0.1)
            XCTAssertEqual(simulation.looseSnow.totalMass + simulation.pendingTransferMass, released, accuracy: 0.1)
        }
    }
}
