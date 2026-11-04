import Foundation
import XCTest
@testable import SnowCore

final class CarriedSnowCollisionTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func window(_ id: UInt64, x: CGFloat, y: CGFloat = 300,
                        width: CGFloat = 200, height: CGFloat = 200,
                        role: DesktopWindowRole = .application) -> DesktopWindowRecord {
        DesktopWindowRecord(id: id, bounds: CGRect(x: x, y: y, width: width, height: height),
                            layer: role == .widget ? -2_147_483_602 : (role == .spotlight ? 101 : 0), role: role)
    }

    private func world(granular: Bool = true) -> SnowSimulation {
        SnowSimulation(size: SIMD2(1000, 800),
                       budget: SimulationBudget(flakes: 0, debris: granular ? 96 : 0), seed: 119)
    }

    private func apply(_ records: [DesktopWindowRecord], to simulation: SnowSimulation) {
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records)
        simulation.updateScene(surfaces: scene.surfaces, bodies: scene.bodies)
    }

    private func drift(_ simulation: SnowSimulation, id: UInt64 = 1) -> SnowDrift {
        simulation.drifts.first { $0.surface.id == id }!
    }

    private func seed(_ simulation: SnowSimulation) {
        simulation.clear()
        let source = drift(simulation)
        for i in source.heights.indices {
            let x = Float(i) * source.spacing
            source.heights[i] = x >= 20 && x <= source.surface.width - 20 ? 6 : 0
        }
    }

    private func area(_ simulation: SnowSimulation) -> Float {
        simulation.drifts.reduce(0) { $0 + $1.heights.reduce(0, +) * $1.spacing }
            + simulation.looseSnow.totalMass + simulation.pendingTransferMass
    }

    func testCarriedSnowStopsAtTheLeftWallWhileUncontactedSnowStaysAttached() {
        let simulation = world()
        let wall = window(2, x: 500, y: 200, width: 100, height: 400)
        apply([window(1, x: 100), wall], to: simulation)
        seed(simulation)
        let before = area(simulation)

        apply([window(1, x: 450), wall], to: simulation)

        XCTAssertEqual(drift(simulation).height(at: 24), 6, accuracy: 0.01)
        XCTAssertLessThan(drift(simulation).height(at: 100), 0.01,
                          "A carried cap must detach before entering an existing window's side")
        XCTAssertGreaterThan(simulation.looseSnow.totalMass, 0)
        XCTAssertTrue(simulation.looseSnow.active.allSatisfy {
            simulation.looseSnow.position(of: $0).x < 500
        }, "Detached material belongs on the approach side, not beyond the wall")
        XCTAssertEqual(area(simulation), before, accuracy: before * 0.01)
    }

    func testCarriedSnowStopsAtTheRightWallDuringLeftwardMotion() {
        let simulation = world()
        let wall = window(2, x: 500, y: 200, width: 100, height: 400)
        apply([window(1, x: 700), wall], to: simulation)
        seed(simulation)
        let before = area(simulation)

        apply([window(1, x: 350), wall], to: simulation)

        XCTAssertLessThan(drift(simulation).heights.max()!, 0.01)
        XCTAssertGreaterThan(simulation.looseSnow.totalMass, 0)
        XCTAssertTrue(simulation.looseSnow.active.allSatisfy {
            simulation.looseSnow.position(of: $0).x > 600
        })
        XCTAssertEqual(area(simulation), before, accuracy: before * 0.01)
    }

    func testFastWholeWallCrossingDoesNotTunnelOrPushDetachedSnowTwice() {
        let simulation = world()
        let wall = window(2, x: 500, y: 200, width: 100, height: 400)
        apply([window(1, x: 100), wall], to: simulation)
        seed(simulation)
        let before = area(simulation)

        apply([window(1, x: 750), wall], to: simulation)

        XCTAssertLessThan(drift(simulation).heights.max()!, 0.01,
                          "Crossing the entire obstacle between snapshots must still register contact")
        XCTAssertGreaterThan(simulation.looseSnow.totalMass, before * 0.9)
        XCTAssertTrue(simulation.looseSnow.active.allSatisfy {
            simulation.looseSnow.position(of: $0).x < 500
        }, "The moving carrier must not plough its just-detached contact material a second time")
        XCTAssertEqual(area(simulation), before, accuracy: before * 0.01)
    }

    func testWidgetSidesStopCarriedSnowUsingTheirInsetPhysicalBounds() {
        let simulation = world()
        // Widget hosts trim 8pt horizontally and 16pt at their top, so the physical
        // left wall lies at x=500 and begins at y=200.
        let widget = window(2, x: 492, y: 184, width: 116, height: 432, role: .widget)
        apply([window(1, x: 100), widget], to: simulation)
        seed(simulation)
        let before = area(simulation)

        apply([window(1, x: 450), widget], to: simulation)

        XCTAssertLessThan(drift(simulation).height(at: 100), 0.01)
        XCTAssertGreaterThan(simulation.looseSnow.totalMass, 0)
        XCTAssertTrue(simulation.looseSnow.active.allSatisfy {
            simulation.looseSnow.position(of: $0).x < 500
        })
        XCTAssertEqual(area(simulation), before, accuracy: before * 0.01)
    }

    func testRoundedShoulderContactDetachesSnowOutsideTheRoundedBody() {
        let simulation = world()
        let wall = window(2, x: 500, y: 220, width: 100, height: 300)
        apply([window(1, x: 100, y: 230), wall], to: simulation)
        seed(simulation)
        let before = area(simulation)

        apply([window(1, x: 450, y: 230), wall], to: simulation)

        let body = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [wall]).bodies.first!
        XCTAssertLessThan(drift(simulation).height(at: 100), 0.01)
        XCTAssertGreaterThan(simulation.looseSnow.totalMass + simulation.pendingTransferMass, 0)
        XCTAssertTrue(simulation.looseSnow.active.allSatisfy {
            !body.contains(simulation.looseSnow.position(of: $0))
        })
        XCTAssertEqual(area(simulation), before, accuracy: before * 0.01)
    }

    func testUpwardCarriedCapContactsAWindowUnderside() {
        let simulation = world()
        let ceiling = window(2, x: 200, y: 100, width: 500, height: 200)
        apply([window(1, x: 300, y: 400, width: 300), ceiling], to: simulation)
        seed(simulation)
        let before = area(simulation)

        apply([window(1, x: 300, y: 303, width: 300), ceiling], to: simulation)

        XCTAssertLessThan(drift(simulation).height(at: 150), 6)
        XCTAssertGreaterThan(simulation.looseSnow.totalMass + simulation.pendingTransferMass, 0)
        XCTAssertEqual(area(simulation), before, accuracy: before * 0.01)
    }

    func testSnowStaysAttachedWhenItsPathDoesNotTouchAnotherBody() {
        let simulation = world()
        let wall = window(2, x: 500, y: 200, width: 100, height: 400)
        apply([window(1, x: 100), wall], to: simulation)
        seed(simulation)
        let heights = drift(simulation).heights

        apply([window(1, x: 250), wall], to: simulation)

        XCTAssertEqual(drift(simulation).heights, heights)
        XCTAssertEqual(simulation.looseSnow.totalMass, 0)
        XCTAssertEqual(simulation.pendingTransferMass, 0)
    }

    func testDetachedAreaSurvivesAFullPoolAndNeverResurfacesOnTheCarrier() {
        let simulation = world(granular: false)
        let wall = window(2, x: 500, y: 200, width: 100, height: 400)
        apply([window(1, x: 100), wall], to: simulation)
        seed(simulation)
        let before = area(simulation)

        for x in [CGFloat(750), 750, 100] {
            apply([window(1, x: x), wall], to: simulation)
            XCTAssertLessThan(drift(simulation).heights.max()!, 0.01)
            XCTAssertEqual(simulation.looseSnow.totalMass, 0)
            XCTAssertEqual(simulation.pendingTransferMass, before, accuracy: before * 0.01)
            XCTAssertEqual(area(simulation), before, accuracy: before * 0.01)
        }
    }

    func testSpotlightCapCrossesAnApplicationOnItsSeparatePresentationPlane() {
        let simulation = world()
        let app = window(2, x: 600, y: 200, width: 100, height: 400)
        apply([window(1, x: 100, width: 300, height: 70, role: .spotlight), app], to: simulation)
        seed(simulation)
        let heights = drift(simulation).heights
        let before = area(simulation)

        apply([window(1, x: 550, width: 300, height: 70, role: .spotlight), app], to: simulation)

        XCTAssertEqual(drift(simulation).heights, heights)
        XCTAssertEqual(simulation.looseSnow.totalMass, 0)
        XCTAssertEqual(simulation.pendingTransferMass, 0)
        XCTAssertEqual(area(simulation), before, accuracy: before * 0.01)
    }

    func testDiagonalMovementStopsAtAnEarlierSideWallBeforeALaterLowerSupport() {
        let simulation = world()
        let wall = window(2, x: 500, y: 200, width: 100, height: 400)
        let lower = window(3, x: 0, y: 450, width: 1000, height: 300)
        apply([window(1, x: 100, y: 100, height: 150), wall, lower], to: simulation)
        seed(simulation)
        let before = area(simulation)

        // Every populated column crosses x=500 while still above y=450, then
        // ends beyond the wall. Its first physical contact is the wall's left side.
        apply([window(1, x: 750, y: 550, height: 150), wall, lower], to: simulation)

        XCTAssertLessThan(drift(simulation).heights.max()!, 0.01)
        XCTAssertEqual(drift(simulation, id: 3).heights.reduce(0, +), 0, accuracy: 0.01,
                       "A later support handoff cannot bypass an earlier side-wall collision")
        XCTAssertGreaterThan(simulation.looseSnow.totalMass, before * 0.9)
        XCTAssertTrue(simulation.looseSnow.active.allSatisfy {
            simulation.looseSnow.position(of: $0).x < 500
        })
        XCTAssertEqual(area(simulation), before, accuracy: before * 0.01)
    }
}
