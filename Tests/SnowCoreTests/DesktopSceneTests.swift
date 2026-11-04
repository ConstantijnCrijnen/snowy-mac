import XCTest
import CoreGraphics
@testable import SnowCore

final class DesktopSceneTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let dockID = DesktopSceneBuilder.dockID

    private func window(_ id: UInt64, _ rect: CGRect, role: DesktopWindowRole = .application,
                        layer: Int = 0) -> DesktopWindowRecord {
        DesktopWindowRecord(id: id, bounds: rect, layer: layer, role: role)
    }

    func testWindowCreatesTopSurfaceAndCollisionBody() {
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [window(1, CGRect(x: 100, y: 200, width: 400, height: 300))])
        XCTAssertEqual(scene.surfaces.first?.id, UInt64.max)
        let cap = scene.surfaces.first { $0.id == 1 }
        XCTAssertEqual(cap?.x, 100)
        XCTAssertEqual(cap?.y, 200)
        XCTAssertEqual(cap?.visibleSpans, [Span(0, 400)])
        XCTAssertEqual(scene.bodies, [SolidBody(id: 1, bounds: CGRect(x: 100, y: 200, width: 400, height: 300), cornerRadius: 12)])
    }

    func testCFNumberMetadataDecodesIntoAnAccumulatingWindowSurface() {
        // Core Graphics can encode opaque alpha as an integer CFNumber. No live desktop query is needed.
        let dictionary: [String: Any] = [
            kCGWindowOwnerPID as String: NSNumber(value: Int64(123)),
            kCGWindowNumber as String: NSNumber(value: UInt64(42)),
            kCGWindowLayer as String: NSNumber(value: Int32(0)),
            kCGWindowAlpha as String: NSNumber(value: 1),
            kCGWindowBounds as String: ["X": 100, "Y": 200, "Width": 400, "Height": 300]
        ]
        let records = DesktopWindowDecoder.decode(metadata: [dictionary], processRoles: [:], excludingPID: 999)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, 42)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records)
        XCTAssertEqual(scene.surfaces.first { $0.id == 42 }?.y, 200)
        XCTAssertEqual(scene.bodies.count, 1)
        let simulation = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 0))
        simulation.updateBodies(scene.bodies)
        simulation.updateSurfaces(scene.surfaces)
        simulation.drifts.first { $0.surface.id == 42 }!.accumulate(dt: 10, intensity: 1)
        simulation.rebuildMesh()
        XCTAssertTrue(simulation.mesh.contains {
            $0.position.x >= 100 && $0.position.x <= 500 && $0.position.y > 180 && $0.position.y < 200
        }, "Decoded window geometry must produce visible snow vertices above its title bar")
        XCTAssertTrue(DesktopWindowDecoder.decode(metadata: [dictionary], processRoles: [:], excludingPID: 123).isEmpty)
    }

    func testAnyCoveringWindowClipsSnowEvenIfNativeZOrderIsBehind() {
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: [
            window(1, CGRect(x: 100, y: 200, width: 400, height: 300)),
            window(2, CGRect(x: 250, y: 100, width: 100, height: 400))
        ])
        XCTAssertEqual(scene.surfaces.first { $0.id == 1 }?.visibleSpans, [Span(0, 150), Span(250, 400)])
    }

    func testNegativeLevelWidgetAccumulatesButWallpaperDoesNot() {
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: [
            window(1, CGRect(x: 50, y: 100, width: 300, height: 160), role: .widget, layer: -2_147_483_603),
            window(2, display, role: .desktop, layer: -2_147_483_623),
            window(3, display, role: .widget, layer: -2_147_483_602)
        ])
        XCTAssertEqual(scene.bodies.map(\.id), [1])
        XCTAssertNotNil(scene.surfaces.first { $0.id == 1 })
    }

    func testBottomDockCreatesUpperSurfaceAndBody() {
        let bounds = CGRect(x: 200, y: 720, width: 600, height: 70)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [window(1, bounds, role: .dock, layer: 20)])
        XCTAssertEqual(scene.bodies.count, 1)
        XCTAssertEqual(scene.bodies.first?.bounds, bounds)
        XCTAssertEqual(scene.surfaces.first { $0.id == dockID }?.isDock, true)
        XCTAssertEqual(scene.surfaces.first { $0.id == dockID }?.y, 720)
        XCTAssertEqual(scene.dockWindowID, 1)
    }

    func testHiddenDockDoesNotCreatePhantomSurface() {
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [window(1, CGRect(x: 200, y: 798, width: 600, height: 70), role: .dock, layer: 20)])
        XCTAssertEqual(scene.surfaces.count, 1)
        XCTAssertTrue(scene.bodies.isEmpty)
    }

    func testGroundExistsAndWindowsReachingBottomBlockItsSpan() {
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [window(1, CGRect(x: 100, y: 400, width: 400, height: 400))])
        XCTAssertEqual(scene.surfaces[0].id, UInt64.max)
        XCTAssertEqual(scene.surfaces[0].y, 800)
        XCTAssertEqual(scene.surfaces[0].visibleSpans, [Span(0, 100), Span(500, 1000)])
    }

    func testFloatingWindowShadowsAmbientFloorSnowButLeavesSupportForSweptSnow() {
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [window(1, CGRect(x: 100, y: 200, width: 400, height: 300))])
        let floor = scene.surfaces[0]
        XCTAssertEqual(floor.visibleSpans, [Span(0, 1000)])
        XCTAssertEqual(floor.snowfallSpans, [Span(0, 100), Span(500, 1000)])
        XCTAssertTrue(floor.isExposed(at: 300), "Snow pushed around the window may still settle on the floor")
        XCTAssertFalse(floor.isSnowExposed(at: 300), "Ambient snowfall must not appear through a window roof")
    }

    func testOverheadWindowShadowsLowerCapWithoutHidingItsSupport() {
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: [
            window(1, CGRect(x: 100, y: 500, width: 400, height: 200)),
            window(2, CGRect(x: 200, y: 100, width: 200, height: 200))
        ])
        let cap = scene.surfaces.first { $0.id == 1 }!
        XCTAssertEqual(cap.visibleSpans, [Span(0, 400)])
        XCTAssertEqual(cap.snowfallSpans, [Span(0, 100), Span(300, 400)])
    }

    func testWidgetSupportMatchesInsetVisibleTileAndRoundedShoulders() {
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [window(1, CGRect(x: 50, y: 100, width: 300, height: 160), role: .widget, layer: -2_147_483_603)])
        let cap = scene.surfaces.first { $0.id == 1 }!
        XCTAssertEqual(scene.bodies[0].bounds, CGRect(x: 58, y: 116, width: 284, height: 136))
        XCTAssertEqual(cap.x, 58)
        XCTAssertEqual(cap.y, 116)
        XCTAssertEqual(cap.cornerRadius, 22)
        XCTAssertEqual(cap.baseY(at: 0), 138, accuracy: 0.001)
        XCTAssertEqual(cap.baseY(at: 22), 116, accuracy: 0.001)
        XCTAssertEqual(cap.baseY(at: 284), 138, accuracy: 0.001)
        XCTAssertFalse(scene.bodies[0].contains(SIMD2(58, 116)), "The empty bounding-box corner is not widget material")
        XCTAssertTrue(scene.bodies[0].contains(SIMD2(80, 116.1)))
    }

    func testNormalWindowShoulderFollowsRadiusRatherThanFloatingOverCorner() {
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [window(1, CGRect(x: 100, y: 200, width: 400, height: 300))])
        let cap = scene.surfaces.first { $0.id == 1 }!
        XCTAssertEqual(cap.cornerRadius, 12)
        XCTAssertEqual(cap.baseY(at: 0), 212, accuracy: 0.001)
        XCTAssertGreaterThan(cap.baseY(at: 4), 200)
        XCTAssertEqual(cap.baseY(at: 12), 200, accuracy: 0.001)
        XCTAssertEqual(cap.baseY(at: 200), 200, accuracy: 0.001)
    }

    func testBottomDockAtNonstandardLevelStillCreatesSurfaceAndRejectsWallpaper() {
        let fixture: (UInt64, CGRect, Int) -> [String: Any] = { number, bounds, layer in
            [kCGWindowOwnerPID as String: NSNumber(value: 123),
             kCGWindowNumber as String: NSNumber(value: number),
             kCGWindowLayer as String: NSNumber(value: layer),
             kCGWindowAlpha as String: NSNumber(value: 1),
             kCGWindowBounds as String: bounds.dictionaryRepresentation]
        }
        for rect in [CGRect(x: 200, y: 720, width: 600, height: 70),
                     CGRect(x: 100, y: 690, width: 800, height: 100)] {
            let records = DesktopWindowDecoder.decode(metadata: [fixture(1, rect, -2_147_483_602), fixture(2, display, -2_147_483_623)],
                                                       processRoles: [123: .dock], excludingPID: 999)
            let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records)
            XCTAssertEqual(scene.bodies.count, 1)
            XCTAssertEqual(scene.surfaces.first { $0.id == dockID }?.isDock, true)
            XCTAssertEqual(scene.surfaces.first { $0.id == dockID }?.width, Float(rect.width))
            XCTAssertEqual(scene.dockWindowID, 1)
            XCTAssertNil(scene.surfaces.first { $0.id == 2 })
        }
    }

    func testCompactDockTrayWinsOverAnEdgeSpanningHost() {
        let host = window(1, CGRect(x: 0, y: 720, width: 1000, height: 80), role: .dock, layer: 20)
        let compact = window(2, CGRect(x: 200, y: 720, width: 600, height: 70), role: .dock, layer: 20)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: [host, compact])
        XCTAssertEqual(scene.bodies.map(\.id), [dockID])
        XCTAssertEqual(scene.dockWindowID, 2)
        XCTAssertEqual(scene.surfaces.first { $0.isDock }?.id, dockID)
        XCTAssertEqual(scene.surfaces.first { $0.isDock }?.y, 720)
    }

    func testEdgeSpanningBottomDockHostWithoutHintNeverCreatesAFullWidthWall() {
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [window(1, CGRect(x: 0, y: 720, width: 1000, height: 80), role: .dock, layer: 20)])
        XCTAssertTrue(scene.bodies.isEmpty)
        XCTAssertNil(scene.surfaces.first { $0.isDock })
        XCTAssertEqual(scene.surfaces.first?.snowfallSpans, [Span(0, 1000)])
    }

    func testVerticalDockPreferencesAlsoExcludeBottomLookingAnimationsAndHosts() {
        for orientation in [DockLayoutHint.Orientation.left, .right] {
            let host = CGRect(x: orientation == .left ? 8 : 922, y: 0, width: 70, height: 800)
            let hint = DockLayoutHint(orientation: orientation, tileSize: 48, itemCount: 6)
            let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
                windows: [window(1, host, role: .dock, layer: 20),
                          window(2, CGRect(x: 200, y: 720, width: 600, height: 70), role: .dock, layer: 20),
                          window(3, CGRect(x: 0, y: 720, width: 1000, height: 80), role: .dock, layer: 20)],
                dockLayout: hint, preferredDockID: 2)
            XCTAssertTrue(scene.bodies.isEmpty)
            XCTAssertNil(scene.surfaces.first { $0.isDock })
            XCTAssertEqual(scene.surfaces.first?.visibleSpans, [Span(0, 1000)])
            XCTAssertEqual(scene.surfaces.first?.snowfallSpans, [Span(0, 1000)])
        }
    }

    func testEdgeSpanningBottomDockHostGetsCenteredCompactFallback() {
        let hint = DockLayoutHint(orientation: .bottom, tileSize: 48, itemCount: 6)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [window(1, CGRect(x: 0, y: 720, width: 1000, height: 80), role: .dock, layer: 20)], dockLayout: hint)
        XCTAssertEqual(scene.bodies.first?.bounds, CGRect(x: 326, y: 736, width: 348, height: 64))
        XCTAssertEqual(scene.surfaces.first { $0.isDock }?.y, 736)
    }

    func testMalformedDockLayoutValuesStayBounded() {
        let tiny = DockLayoutHint(orientation: .left, tileSize: -100, itemCount: Int.min)
        XCTAssertEqual(tiny.tileSize, 16)
        XCTAssertEqual(tiny.itemCount, 1)
        let huge = DockLayoutHint(orientation: .bottom, tileSize: 1_000_000, itemCount: Int.max)
        XCTAssertEqual(huge.tileSize, 128)
        XCTAssertEqual(huge.itemCount, 80)
        XCTAssertEqual(DockLayoutHint(orientation: .bottom, tileSize: .nan, itemCount: 3).tileSize, 48)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [window(1, CGRect(x: 0, y: 720, width: 1000, height: 80), role: .dock, layer: 20)], dockLayout: huge)
        XCTAssertLessThanOrEqual(scene.bodies.first!.bounds.width, 984)
        XCTAssertGreaterThanOrEqual(scene.bodies.first!.bounds.minX, 8)
        XCTAssertGreaterThanOrEqual(scene.bodies.first!.bounds.height, 16)
    }

    func testVerticalDockCreatesNoBodySurfaceOrSnowfallShadow() {
        for height in [CGFloat(800), 1600, 4000] {
            for orientation in [DockLayoutHint.Orientation.left, .right] {
                let screen = CGRect(x: 0, y: 0, width: 1000, height: height)
                let bounds = CGRect(x: orientation == .left ? 8 : 922, y: 32, width: 70, height: height - 40)
                let hints: [DockLayoutHint?] = [nil,
                    DockLayoutHint(orientation: orientation, tileSize: 48, itemCount: 6)]
                for hint in hints {
                    let scene = DesktopSceneBuilder.build(displayBounds: screen, menuInset: 24,
                        windows: [window(1, bounds, role: .dock, layer: 20)], dockLayout: hint)
                    XCTAssertTrue(scene.bodies.isEmpty)
                    XCTAssertNil(scene.surfaces.first { $0.isDock })
                    XCTAssertEqual(scene.surfaces.first?.visibleSpans, [Span(0, 1000)])
                    XCTAssertEqual(scene.surfaces.first?.snowfallSpans, [Span(0, 1000)])
                }
            }
        }
    }

    func testVerticalDockAtAnyPresentationLevelIsExcludedWithoutPreferences() {
        for level in [-2_147_483_602, 20, 101] {
            for bounds in [CGRect(x: 8, y: 24, width: 70, height: 768),
                           CGRect(x: 922, y: 160, width: 70, height: 480)] {
                let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
                    windows: [window(1, bounds, role: .dock, layer: level)])
                XCTAssertTrue(scene.bodies.isEmpty)
                XCTAssertNil(scene.surfaces.first { $0.isDock })
                XCTAssertEqual(scene.surfaces.first?.snowfallSpans, [Span(0, 1000)])
            }
        }
    }

    func testVerticalDockDoesNotClipOrShadowAnApplicationSurface() {
        let application = window(1, CGRect(x: 40, y: 500, width: 400, height: 200))
        let verticalDock = window(2, CGRect(x: 8, y: 24, width: 70, height: 768), role: .dock, layer: 20)
        let baseline = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: [application])
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [verticalDock, application])
        XCTAssertEqual(scene.bodies, baseline.bodies)
        XCTAssertEqual(scene.surfaces, baseline.surfaces)
    }

    func testNearlyFullWidthBottomDockKeepsItsActualTrayBounds() {
        let bounds = CGRect(x: 8, y: 720, width: 984, height: 72)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [window(1, bounds, role: .dock, layer: 20)],
            dockLayout: DockLayoutHint(orientation: .bottom, tileSize: 48, itemCount: 6))
        XCTAssertEqual(scene.bodies.first?.bounds, bounds)
    }

    func testBottomDockPreferenceRejectsVerticalDockOwnedWindows() {
        let left = window(1, CGRect(x: 8, y: 36, width: 70, height: 740), role: .dock, layer: 20)
        let bottom = window(2, CGRect(x: 200, y: 720, width: 600, height: 70), role: .dock, layer: 20)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [left, bottom],
            dockLayout: DockLayoutHint(orientation: .bottom, tileSize: 48, itemCount: 13), preferredDockID: 1)
        XCTAssertEqual(scene.bodies.map(\.id), [dockID])
        XCTAssertEqual(scene.dockWindowID, 2)
        XCTAssertEqual(scene.surfaces.first { $0.isDock }?.y, 720)
    }

    func testDockLevelTrayBeatsAThinnerMoreElongatedIndicator() {
        let tray = window(1, CGRect(x: 200, y: 720, width: 600, height: 70), role: .dock, layer: 20)
        let indicator = window(2, CGRect(x: 140, y: 770, width: 720, height: 20), role: .dock, layer: 101)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [indicator, tray])
        XCTAssertEqual(scene.bodies.map(\.id), [dockID])
        XCTAssertEqual(scene.dockWindowID, 1)
    }

    func testPreferredTrayRemainsStableWhenACompetingAnimationAppears() {
        let tray = window(1, CGRect(x: 200, y: 720, width: 600, height: 70), role: .dock, layer: 20)
        let animation = window(2, CGRect(x: 190, y: 700, width: 620, height: 90), role: .dock, layer: 20)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [animation, tray], preferredDockID: 1)
        XCTAssertEqual(scene.bodies.map(\.id), [dockID])
        XCTAssertEqual(scene.dockWindowID, 1)
        let reordered = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [tray, animation], preferredDockID: 1)
        XCTAssertEqual(reordered.bodies, scene.bodies)
        XCTAssertEqual(reordered.dockWindowID, 1)
    }

    func testPreferredNonstandardWindowCannotOverrideAnActualDockLevelTray() {
        let previous = window(1, CGRect(x: 200, y: 720, width: 600, height: 70), role: .dock, layer: -2_147_483_602)
        let actual = window(2, CGRect(x: 190, y: 700, width: 620, height: 90), role: .dock, layer: 20)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [previous, actual], preferredDockID: 1)
        XCTAssertEqual(scene.bodies.map(\.id), [dockID])
        XCTAssertEqual(scene.dockWindowID, 2)
    }

    func testDenseDockHostFallbackScalesThicknessWithItsCompressedLength() {
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [window(1, CGRect(x: 0, y: 720, width: 1000, height: 80), role: .dock, layer: 20)],
            dockLayout: DockLayoutHint(orientation: .bottom, tileSize: 48, itemCount: 30))
        let body = scene.bodies.first!
        XCTAssertEqual(body.bounds.width, 984, accuracy: 0.001)
        XCTAssertLessThan(body.bounds.height, 40,
                          "A compressed icon pitch also reduces the estimated cross-axis thickness")
        XCTAssertGreaterThanOrEqual(body.bounds.height, 16)
    }

    func testSquareDockOwnedIconIsNotMistakenForTheTray() {
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24,
            windows: [window(1, CGRect(x: 8, y: 200, width: 96, height: 96), role: .dock, layer: 20)])
        XCTAssertTrue(scene.bodies.isEmpty)
        XCTAssertNil(scene.surfaces.first { $0.isDock })
    }

    func testSecondaryDisplayConvertsGlobalBoundsToLocalPoints() {
        let bounds = CGRect(x: -1000, y: -300, width: 1000, height: 800)
        let scene = DesktopSceneBuilder.build(displayBounds: bounds, menuInset: 24,
            windows: [window(1, CGRect(x: -900, y: -100, width: 400, height: 300))])
        XCTAssertEqual(scene.surfaces.first { $0.id == 1 }?.x, 100)
        XCTAssertEqual(scene.surfaces.first { $0.id == 1 }?.y, 200)
        XCTAssertEqual(scene.bodies.first?.bounds.origin, CGPoint(x: 100, y: 200))
    }

    func testMalformedAndDuplicateMetadataRemainBounded() {
        var windows = (0..<1000).map { window(UInt64($0), CGRect(x: 10, y: 100, width: 300, height: 300)) }
        windows.insert(window(2000, CGRect(x: CGFloat.nan, y: 100, width: 300, height: 300)), at: 0)
        windows.insert(windows[1], at: 0)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: windows)
        XCTAssertLessThanOrEqual(scene.bodies.count, 64)
        XCTAssertLessThanOrEqual(scene.surfaces.count, 48)
        XCTAssertEqual(Set(scene.bodies.map(\.id)).count, scene.bodies.count)
        XCTAssertEqual(scene.surfaces.first?.id, UInt64.max)
    }
}
