import XCTest
import CoreGraphics
@testable import SnowCore

final class SystemSurfaceTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func metadata(id: UInt32, pid: Int32, bounds: CGRect, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
        [kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowNumber as String: NSNumber(value: id),
         kCGWindowLayer as String: NSNumber(value: layer),
         kCGWindowAlpha as String: NSNumber(value: alpha),
         kCGWindowBounds as String: ["X": bounds.minX, "Y": bounds.minY,
                                    "Width": bounds.width, "Height": bounds.height]]
    }

    func testSystemProcessRolesUseBundleIdentityWithoutWindowTitles() {
        XCTAssertTrue(DesktopWindowDecoder.processRole(bundleIdentifier: "com.apple.WindowManager") == .other)
        XCTAssertTrue(DesktopWindowDecoder.processRole(bundleIdentifier: "com.apple.WindowManager.controls") == .other)
        XCTAssertTrue(DesktopWindowDecoder.processRole(bundleIdentifier: "com.apple.Spotlight") == .spotlight)
        XCTAssertNil(DesktopWindowDecoder.processRole(bundleIdentifier: "com.example.SpotlightIndexExtension"))
        XCTAssertNil(DesktopWindowDecoder.processRole(bundleIdentifier: "com.example.WindowManager"))
    }

    func testCodexFloatingOverlayDoesNotClipSnowWhileItsNormalWindowRemainsPhysical() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let app = metadata(id: 1, pid: 123, bounds: CGRect(x: 100, y: 200, width: 1200, height: 700))
        // Observed alongside Codex's normal window on a 3024 × 1964 Retina display.
        // The transparent overlay reports opaque window alpha and extends beyond the screen.
        let overlay = metadata(id: 2, pid: 123, bounds: CGRect(x: 701, y: -39, width: 1138, height: 1867),
                               layer: Int(CGWindowLevelForKey(.floatingWindow)))
        let identities: [Int32: String] = [123: "com.openai.codex"]
        let baseline = DesktopSceneBuilder.build(displayBounds: screen, menuInset: 33, windows:
            DesktopWindowDecoder.decode(metadata: [app], processRoles: [:], excludingPID: 999,
                                        processBundleIdentifiers: identities))
        let records = DesktopWindowDecoder.decode(metadata: [overlay, app], processRoles: [:], excludingPID: 999,
                                                  processBundleIdentifiers: identities)
        let scene = DesktopSceneBuilder.build(displayBounds: screen, menuInset: 33, windows: records)
        XCTAssertEqual(scene.bodies, baseline.bodies)
        XCTAssertEqual(scene.surfaces, baseline.surfaces)
        XCTAssertEqual(scene.bodies.map(\.id), [1])
        XCTAssertEqual(scene.surfaces.first { $0.id == 1 }?.visibleSpans, [Span(0, 1200)])
        XCTAssertEqual(scene.surfaces[0].snowfallSpans, [Span(0, 100), Span(1300, 1512)])
    }

    func testFloatingWindowsOfOtherAppsAreNotExcludedByCodexNameOrGeometry() {
        for bundle in ["com.example.editor", "com.openai.codex.helper", "com.example.com.openai.codex"] {
            var floating = metadata(id: 1, pid: 123,
                                    bounds: CGRect(x: 701, y: -39, width: 1138, height: 1867),
                                    layer: Int(CGWindowLevelForKey(.floatingWindow)))
            floating[kCGWindowOwnerName as String] = "Codex"
            floating[kCGWindowName as String] = "Codex"
            let records = DesktopWindowDecoder.decode(metadata: [floating], processRoles: [:], excludingPID: 999,
                                                      processBundleIdentifiers: [123: bundle])
            XCTAssertTrue(records.first?.role == .application)
            let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records)
            XCTAssertEqual(scene.bodies.map(\.id), [1])
        }
    }

    func testCodexWindowsAtOtherApplicationLevelsRemainPhysical() {
        for level in [0, 1, 2, 4, 19] {
            let window = metadata(id: 1, pid: 123, bounds: CGRect(x: 100, y: 200, width: 400, height: 300),
                                  layer: level)
            let records = DesktopWindowDecoder.decode(metadata: [window], processRoles: [:], excludingPID: 999,
                                                      processBundleIdentifiers: [123: "com.openai.codex"])
            let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records)
            XCTAssertEqual(scene.bodies.map(\.id), [1])
            XCTAssertEqual(scene.surfaces.first { $0.id == 1 }?.visibleSpans, [Span(0, 400)])
        }
    }

    func testTilingPreviewsNeverBecomeBodiesOrSnowSupportsAtAnyAcceptedLayer() {
        let app = metadata(id: 1, pid: 1, bounds: CGRect(x: 100, y: 400, width: 800, height: 300))
        let baseRecords = DesktopWindowDecoder.decode(metadata: [app], processRoles: [:], excludingPID: 999)
        let baseline = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: baseRecords)
        for layer in [-2_147_483_603, 0, 3, 19, 20, 101] {
            for x in [CGFloat(0), 500] {
                let preview = metadata(id: 2, pid: 2, bounds: CGRect(x: x, y: 24, width: 500, height: 776),
                                       layer: layer, alpha: 0.7)
                let records = DesktopWindowDecoder.decode(metadata: [preview, app], processRoles: [2: .other], excludingPID: 999)
                XCTAssertTrue(records.first { $0.id == 2 }?.role == .other)
                let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records)
                XCTAssertEqual(scene.bodies, baseline.bodies)
                XCTAssertEqual(scene.surfaces, baseline.surfaces)
                XCTAssertFalse(DesktopSceneBuilder.isFullscreen(displayBounds: display, windows: records))
            }
        }
    }

    func testTilingPreviewAppearancePreservesExistingAccumulatedAndLooseSnow() {
        let app = metadata(id: 1, pid: 1, bounds: CGRect(x: 100, y: 400, width: 800, height: 300))
        let records = DesktopWindowDecoder.decode(metadata: [app], processRoles: [:], excludingPID: 999)
        let baseline = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records)
        let simulation = SnowSimulation(size: SIMD2(1000, 800), budget: SimulationBudget(flakes: 0))
        simulation.updateScene(surfaces: baseline.surfaces, bodies: baseline.bodies)
        simulation.clear()
        let cap = simulation.drifts.first { $0.surface.id == 1 }!
        _ = cap.depositMass(at: 150, mass: 400)
        _ = simulation.looseSnow.add(mass: 80, at: SIMD2(200, 350))
        let heights = cap.heights
        let loose = simulation.looseSnow.totalMass
        let preview = metadata(id: 2, pid: 2, bounds: CGRect(x: 0, y: 24, width: 500, height: 776), alpha: 0.7)
        let next = DesktopWindowDecoder.decode(metadata: [preview, app], processRoles: [2: .other], excludingPID: 999)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: next)
        simulation.updateScene(surfaces: scene.surfaces, bodies: scene.bodies)
        XCTAssertEqual(cap.heights, heights)
        XCTAssertEqual(simulation.looseSnow.totalMass, loose, accuracy: 0.001)
    }

    func testRealTiledApplicationStillCreatesItsPhysicalSurface() {
        let record = metadata(id: 1, pid: 1, bounds: CGRect(x: 0, y: 24, width: 500, height: 776), alpha: 0.7)
        let records = DesktopWindowDecoder.decode(metadata: [record], processRoles: [:], excludingPID: 999)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records)
        XCTAssertEqual(scene.bodies.map(\.id), [1])
        XCTAssertEqual(scene.surfaces.first { $0.id == 1 }?.y, 24)
    }

    func testSpotlightAtElevatedLevelsCreatesRoundedTemporarySupport() {
        let bounds = CGRect(x: 200, y: 180, width: 600, height: 70)
        for layer in [0, 20, 27, 101, 1000] {
            let records = DesktopWindowDecoder.decode(metadata: [metadata(id: 1, pid: 1, bounds: bounds, layer: layer)],
                                                       processRoles: [1: .spotlight], excludingPID: 999)
            let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records)
            XCTAssertEqual(scene.bodies, [SolidBody(id: 1, bounds: bounds, cornerRadius: 28, isElevated: true)])
            let support = scene.surfaces.first { $0.id == 1 }!
            XCTAssertEqual(support.y, 180)
            XCTAssertEqual(support.cornerRadius, 28)
            XCTAssertTrue(support.releasesSnowWhenRemoved)
            XCTAssertGreaterThan(support.baseY(at: 0), support.y)
            XCTAssertFalse(scene.surfaces[0].isSnowExposed(at: 500))
        }
    }

    func testSpotlightScreenHostAndAccessoryWindowsAreNotPhysical() {
        let records = [DesktopWindowRecord(id: 1, bounds: display, layer: 101, role: .spotlight),
                       DesktopWindowRecord(id: 2, bounds: CGRect(x: 100, y: 100, width: 80, height: 80), layer: 101, role: .spotlight)]
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records)
        XCTAssertTrue(scene.bodies.isEmpty)
        XCTAssertEqual(scene.surfaces.count, 1)
    }

    func testSpotlightReceivesASurfaceWithinTheGeometryBudget() {
        var records = (1...80).map { DesktopWindowRecord(id: UInt64($0), bounds: CGRect(x: 0, y: 500, width: 1000, height: 100),
                                                       layer: 0, role: .application) }
        records.append(DesktopWindowRecord(id: 90, bounds: CGRect(x: 200, y: 180, width: 600, height: 70),
                                          layer: 101, role: .spotlight))
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records)
        XCTAssertNotNil(scene.surfaces.first { $0.id == 90 })
        XCTAssertLessThanOrEqual(scene.bodies.count, DesktopSceneBuilder.maximumBodies)
        XCTAssertLessThanOrEqual(scene.surfaces.count, DesktopSceneBuilder.maximumSurfaces)
    }

    func testFinderWindowsRemainPhysicalWhileItsDesktopContainerIsIgnored() {
        let records = DesktopWindowDecoder.decode(metadata: [
            metadata(id: 1, pid: 1, bounds: CGRect(x: 100, y: 200, width: 400, height: 300)),
            metadata(id: 2, pid: 1, bounds: display, layer: -2_147_483_623)
        ], processRoles: [1: .desktop], excludingPID: 999)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records)
        XCTAssertEqual(scene.bodies.map(\.id), [1])
    }

    func testSpotlightOwnerFallbackWorksWithoutARunningApplicationEntry() {
        var panel = metadata(id: 1, pid: 1, bounds: CGRect(x: 200, y: 180, width: 600, height: 480), layer: 1000)
        panel[kCGWindowOwnerName as String] = "Spotlight"
        panel[kCGWindowName as String] = "This search content must not be used for classification"
        let records = DesktopWindowDecoder.decode(metadata: [panel], processRoles: [:], excludingPID: 999)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records)
        XCTAssertTrue(records.first?.role == .spotlight)
        XCTAssertTrue(scene.bodies.first?.isElevated == true)
        XCTAssertTrue(scene.surfaces.first { $0.id == 1 }?.releasesSnowWhenRemoved == true)
    }

    func testWindowManagerOwnerFallbackNeverBecomesAPhysicalBlock() {
        var preview = metadata(id: 1, pid: 1, bounds: CGRect(x: 0, y: 24, width: 500, height: 776))
        preview[kCGWindowOwnerName as String] = "WindowManager"
        let records = DesktopWindowDecoder.decode(metadata: [preview], processRoles: [:], excludingPID: 999)
        let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records)
        XCTAssertTrue(scene.bodies.isEmpty)
        XCTAssertFalse(DesktopSceneBuilder.isFullscreen(displayBounds: display, windows: records))
    }

    func testSpotlightClassificationDoesNotUseSubstringsOrWindowTitles() {
        for owner in ["Example Spotlight Tool", "WindowManager Helper", "Example App"] {
            var window = metadata(id: 1, pid: 1, bounds: CGRect(x: 200, y: 180, width: 600, height: 70), layer: 1000)
            window[kCGWindowOwnerName as String] = owner
            window[kCGWindowName as String] = "Spotlight"
            XCTAssertTrue(DesktopWindowDecoder.decode(metadata: [window], processRoles: [:], excludingPID: 999).isEmpty)
        }
        var panel = metadata(id: 1, pid: 1, bounds: CGRect(x: 200, y: 180, width: 600, height: 70), layer: 1000)
        panel[kCGWindowOwnerName as String] = "Spotlight"
        XCTAssertTrue(DesktopWindowDecoder.decode(metadata: [panel], processRoles: [1: .other], excludingPID: 999).isEmpty)
    }

    func testWideAndExpandedSpotlightPanelsAreRetainedWithoutAcceptingScreenHosts() {
        let wideDisplay = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        for bounds in [CGRect(x: 100, y: 180, width: 1800, height: 70),
                       CGRect(x: 40, y: 180, width: 2480, height: 700)] {
            let scene = DesktopSceneBuilder.build(displayBounds: wideDisplay, menuInset: 24, windows: [
                DesktopWindowRecord(id: 1, bounds: bounds, layer: 1000, role: .spotlight)])
            XCTAssertNotNil(scene.surfaces.first { $0.id == 1 })
        }
        let host = DesktopWindowRecord(id: 1, bounds: CGRect(x: 0, y: 24, width: 2560, height: 1416),
                                       layer: 1000, role: .spotlight)
        let scene = DesktopSceneBuilder.build(displayBounds: wideDisplay, menuInset: 24, windows: [host])
        XCTAssertTrue(scene.bodies.isEmpty)
    }

    func testUncachedNegativeLayerDockCannotBecomeAVerticalWidget() {
        for orientation in [DockLayoutHint.Orientation.left, .right] {
            let x: CGFloat = orientation == .left ? 8 : 922
            var dock = metadata(id: 1, pid: 1, bounds: CGRect(x: x, y: 100, width: 70, height: 600), layer: -2_147_483_602)
            dock[kCGWindowOwnerName as String] = "Dock"
            let records = DesktopWindowDecoder.decode(metadata: [dock], processRoles: [:], excludingPID: 999)
            XCTAssertTrue(records.first?.role == .dock)
            for hint in [DockLayoutHint(orientation: orientation, tileSize: 48, itemCount: 10), nil] {
                let scene = DesktopSceneBuilder.build(displayBounds: display, menuInset: 24, windows: records, dockLayout: hint)
                XCTAssertTrue(scene.bodies.isEmpty)
                XCTAssertEqual(scene.surfaces.count, 1)
                XCTAssertEqual(scene.surfaces[0].snowfallSpans, [Span(0, 1000)])
            }
        }
    }
}
