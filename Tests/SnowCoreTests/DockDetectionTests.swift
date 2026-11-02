import CoreGraphics
import XCTest
@testable import SnowCore

final class DockDetectionTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func hint(_ orientation: DockLayoutHint.Orientation = .bottom,
                      autoHides: Bool = false) -> DockLayoutHint {
        DockLayoutHint(orientation: orientation, tileSize: 48, itemCount: 10, autoHides: autoHides)
    }

    private func metadata(owner: String = "Dock", alpha: Double = 0, layer: Int = 1500,
                          bounds: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 800)) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: 42),
         kCGWindowOwnerPID as String: NSNumber(value: 123),
         kCGWindowOwnerName as String: owner,
         kCGWindowLayer as String: NSNumber(value: layer),
         kCGWindowAlpha as String: NSNumber(value: alpha),
         kCGWindowBounds as String: bounds.dictionaryRepresentation]
    }

    func testVisibleBottomReservationCreatesDockWithoutAnyQuartzWindow() throws {
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: [],
            dockLayout: hint(), dockBottomInset: 80)
        let cap = try XCTUnwrap(scene.surfaces.first { $0.isDock })
        let body = try XCTUnwrap(scene.bodies.first)
        XCTAssertEqual(cap.id, DesktopSceneBuilder.dockID)
        XCTAssertNil(scene.dockWindowID)
        XCTAssertEqual(cap.y, 720)
        XCTAssertEqual(body.bounds, CGRect(x: 218, y: 720, width: 564, height: 80))
        XCTAssertTrue(body.contains(SIMD2(500, 750)))
        XCTAssertEqual(scene.surfaces.first?.snowfallSpans, [Span(0, 218), Span(782, 1000)])
    }

    func testTransparentHighLevelDockHostIsRetainedOnlyAsBoundedFallbackMetadata() throws {
        let records = DesktopWindowDecoder.decode(metadata: [metadata()], processRoles: [:], excludingPID: 999)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.opacity, 0)
        XCTAssertTrue(records.first?.role == .dock)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records,
            dockLayout: hint(), dockBottomInset: 80)
        let body = try XCTUnwrap(scene.bodies.first)
        XCTAssertEqual(body.id, DesktopSceneBuilder.dockID)
        XCTAssertEqual(scene.dockWindowID, 42)
        XCTAssertEqual(body.bounds, CGRect(x: 218, y: 720, width: 564, height: 80))
        XCTAssertFalse(body.contains(SIMD2(500, 100)), "A screen-sized Dock host must never become the collider")
    }

    func testTransparentCompactDockUsesItsHorizontalFootprintWithReservedRoof() throws {
        let raw = metadata(bounds: CGRect(x: 160, y: 720, width: 680, height: 70))
        let records = DesktopWindowDecoder.decode(metadata: [raw], processRoles: [:], excludingPID: 999)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records,
            dockLayout: hint(), dockBottomInset: 80)
        XCTAssertEqual(scene.bodies.first?.bounds, CGRect(x: 160, y: 720, width: 680, height: 80))
        XCTAssertEqual(try XCTUnwrap(scene.surfaces.first { $0.isDock }).id, DesktopSceneBuilder.dockID)
        XCTAssertEqual(scene.dockWindowID, 42)
    }

    func testOversizedOpaqueDockHostCannotBypassObservedMissingReservation() {
        let records = DesktopWindowDecoder.decode(metadata: [metadata(alpha: 1)], processRoles: [:], excludingPID: 999)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records,
            dockLayout: hint(), dockBottomInset: 0)
        XCTAssertTrue(scene.bodies.isEmpty)
        XCTAssertNil(scene.surfaces.first { $0.isDock })
    }

    func testObservedScreenWithoutDockCannotGainAHostOnlyPhantomDock() {
        let host = DesktopWindowRecord(id: 42, bounds: CGRect(x: 0, y: 720, width: 1000, height: 80),
                                       layer: 20, role: .dock)
        for autoHides in [false, true] {
            let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: [host],
                dockLayout: hint(autoHides: autoHides), dockBottomInset: 0)
            XCTAssertTrue(scene.bodies.isEmpty)
            XCTAssertEqual(scene.surfaces.first?.snowfallSpans, [Span(0, 1000)])
        }
    }

    func testAutoHideRevealStripAndMalformedInsetsDoNotInventADock() {
        let insets: [Float] = [0, 2, 19, -1, .nan, .infinity, 321, 800]
        for inset in insets {
            let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: [],
                dockLayout: hint(autoHides: true), dockBottomInset: inset)
            XCTAssertTrue(scene.bodies.isEmpty)
            XCTAssertNil(scene.surfaces.first { $0.isDock })
        }
    }

    func testAutoHideMayUseAnActualVisibleTrayButNotAnUnobservedHost() {
        let tray = DesktopWindowRecord(id: 42, bounds: CGRect(x: 200, y: 720, width: 600, height: 70),
                                       layer: 20, role: .dock)
        let visible = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: [tray],
            dockLayout: hint(autoHides: true), dockBottomInset: 2)
        XCTAssertEqual(visible.bodies.first?.bounds, tray.bounds)
        let host = DesktopWindowRecord(id: 43, bounds: CGRect(x: 0, y: 720, width: 1000, height: 80),
                                       layer: 20, role: .dock)
        let hidden = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: [host],
            dockLayout: hint(autoHides: true))
        XCTAssertTrue(hidden.bodies.isEmpty)
    }

    func testRealReservationCanProveVisibleDockEvenWhenAutoHideIsEnabled() {
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: [],
            dockLayout: hint(autoHides: true), dockBottomInset: 80)
        XCTAssertNotNil(scene.surfaces.first { $0.isDock })
        XCTAssertEqual(scene.bodies.first?.bounds.minY, 720)
    }

    func testVerticalDockPreferencesRejectReservationAndEveryDockHost() {
        let records = DesktopWindowDecoder.decode(metadata: [metadata()], processRoles: [:], excludingPID: 999)
        for orientation in [DockLayoutHint.Orientation.left, .right] {
            let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records,
                dockLayout: hint(orientation), dockBottomInset: 80)
            XCTAssertTrue(scene.bodies.isEmpty)
            XCTAssertEqual(scene.surfaces.first?.snowfallSpans, [Span(0, 1000)])
        }
    }

    func testDockFallbackIsLocalToTheObservedDisplay() {
        let secondary = CGRect(x: 1000, y: -400, width: 1000, height: 800)
        let primary = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: [],
            dockLayout: hint(), dockBottomInset: 0)
        let dockScreen = DesktopSceneBuilder.build(displayBounds: secondary, menuInset: 24, windows: [],
            dockLayout: hint(), dockBottomInset: 64)
        XCTAssertTrue(primary.bodies.isEmpty)
        XCTAssertEqual(dockScreen.bodies.first?.bounds, CGRect(x: 218, y: 736, width: 564, height: 64))
    }

    func testFallbackKeepsPreviousDockIdentityWhenMetadataTemporarilyDisappears() {
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: [],
            dockLayout: hint(), preferredDockID: 42, dockBottomInset: 80)
        XCTAssertEqual(scene.bodies.first?.id, DesktopSceneBuilder.dockID)
        XCTAssertEqual(scene.surfaces.first { $0.isDock }?.id, DesktopSceneBuilder.dockID)
        XCTAssertEqual(scene.dockWindowID, 42)
    }

    func testFallbackAndNativeTrayTransitionsPreserveTheSameAccumulatedCap() throws {
        let simulation = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 0))
        let initial = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: [],
            dockLayout: hint(), dockBottomInset: 80)
        simulation.updateScene(surfaces: initial.surfaces, bodies: initial.bodies)
        simulation.clear()
        let original = try XCTUnwrap(simulation.drifts.first { $0.surface.isDock })
        original.accumulate(dt: 20, intensity: 1)
        let heights = original.heights
        let bounds = try XCTUnwrap(initial.bodies.first).bounds
        let transparent = DesktopWindowDecoder.decode(metadata: [metadata(bounds: bounds)],
            processRoles: [:], excludingPID: 999)
        let opaque = DesktopWindowDecoder.decode(metadata: [metadata(alpha: 1, layer: 20, bounds: bounds)],
            processRoles: [:], excludingPID: 999)
        for records in [transparent, opaque, []] {
            let next = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records,
                dockLayout: hint(), dockBottomInset: 80)
            simulation.updateScene(surfaces: next.surfaces, bodies: next.bodies)
            let current = try XCTUnwrap(simulation.drifts.first { $0.surface.isDock })
            XCTAssertTrue(current === original, "Native tray discovery must not replace the logical Dock support")
            XCTAssertEqual(current.heights, heights)
            XCTAssertEqual(next.bodies.first?.id, DesktopSceneBuilder.dockID)
        }
    }

    func testNoQuartzDockFallbackStopsIncomingFlakesAndReceivesLooseSnow() throws {
        let geometry = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: [],
            dockLayout: hint(), dockBottomInset: 80)
        let simulation = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 0))
        let control = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 0))
        for world in [simulation, control] {
            world.updateScene(surfaces: geometry.surfaces, bodies: geometry.bodies)
            world.clear()
        }
        var flake = SnowParticle(position: SIMD2(500, 710), velocity: SIMD2(0, 600), radius: 2,
                                 opacity: 1, phase: 0, remainingLife: 100, mass: 8)
        XCTAssertTrue(simulation.advanceParticle(&flake, dt: 1 / 30, recycleOnContact: true))
        XCTAssertLessThan(flake.position.y, 720)
        let cap = try XCTUnwrap(simulation.drifts.first { $0.surface.isDock })
        XCTAssertGreaterThan(cap.height(at: 500 - cap.surface.x), 0)
        simulation.clear()
        XCTAssertEqual(simulation.looseSnow.add(mass: 30, at: SIMD2(500, 680)), 0, accuracy: 0.001)
        for _ in 0..<30 {
            simulation.step(dt: 1 / 30, cursor: nil)
            control.step(dt: 1 / 30, cursor: nil)
        }
        let ambient = try XCTUnwrap(control.drifts.first { $0.surface.isDock })
        let area = cap.heights.reduce(0, +) * cap.spacing
        let ambientArea = ambient.heights.reduce(0, +) * ambient.spacing
        XCTAssertGreaterThan(area - ambientArea, 25, "Carried snow must land on the metadata-independent Dock roof")
        XCTAssertLessThan(simulation.looseSnow.totalMass, 1)
        let body = try XCTUnwrap(geometry.bodies.first)
        XCTAssertFalse(simulation.looseSnow.active.contains { body.contains(simulation.looseSnow.position(of: $0)) })
    }

    func testTransparentAppOrWindowManagerOverlayIsNeverRescuedAsADockHost() {
        for owner in ["Example App", "WindowManager"] {
            for alpha in [0.0, 0.03] {
                let records = DesktopWindowDecoder.decode(metadata: [metadata(owner: owner, alpha: alpha)],
                    processRoles: [:], excludingPID: 999)
                XCTAssertTrue(records.isEmpty)
            }
        }
    }
}
