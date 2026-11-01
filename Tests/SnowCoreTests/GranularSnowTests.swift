import Foundation
import XCTest
@testable import SnowCore

final class GranularSnowTests: XCTestCase {
    private func field(size: SIMD2<Float> = SIMD2(120, 120), active: Int = 1600) -> GranularSnow {
        GranularSnow(size: size, maxCells: 1600, maxActive: active)
    }

    private func freeLanding(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ mass: Float) -> (remaining: Float, blocked: Bool) {
        (mass, false)
    }

    func testAdaptiveGridAndActivePoolRespectExplicitBudgets() {
        let snow = GranularSnow(size: SIMD2(65_536, 65_536), maxCells: 1024, maxActive: 12)
        XCTAssertLessThanOrEqual(snow.columns * snow.rows, 1024)
        XCTAssertGreaterThanOrEqual(snow.cellSize, 3)
        let unplaced = snow.add(mass: 100_000_000, at: SIMD2(32_000, 32_000))
        XCTAssertLessThanOrEqual(snow.active.count, 12)
        XCTAssertEqual(snow.totalMass + unplaced, 100_000_000, accuracy: 10)
        XCTAssertTrue(snow.active.allSatisfy { snow.mass[$0] <= snow.capacity(of: $0) + 0.001 })
    }

    func testAddedAreaIsStoredOrExplicitlyReturned() {
        let snow = field(active: 1)
        let unplaced = snow.add(mass: 20, at: SIMD2(60, 60))
        XCTAssertEqual(snow.totalMass + unplaced, 20, accuracy: 0.001)
        XCTAssertEqual(snow.active.count, 1)
        XCTAssertGreaterThan(unplaced, 0)
    }

    func testLocalPlacementCannotFloodThroughAWindowWall() {
        let snow = field()
        snow.setBodies([SolidBody(id: 1, bounds: CGRect(x: 60, y: 0, width: 6, height: 120))])
        let unplaced = snow.add(mass: 10_000, at: SIMD2(30, 60), direction: SIMD2(1, 0))
        XCTAssertGreaterThan(unplaced, 0)
        XCTAssertTrue(snow.active.allSatisfy { snow.position(of: $0).x < 60 })
        XCTAssertEqual(snow.totalMass + unplaced, 10_000, accuracy: 0.01)
    }

    func testGravityMovesGrainsDownWithoutLaunchingThem() {
        let snow = field()
        XCTAssertEqual(snow.add(mass: 9, at: SIMD2(60, 30)), 0)
        let oldY = snow.position(of: snow.active[0]).y
        snow.step(dt: 1 / 60, wind: .zero, landing: freeLanding)
        XCTAssertEqual(snow.active.count, 1)
        XCTAssertEqual(snow.position(of: snow.active[0]).y - oldY, snow.cellSize, accuracy: 0.001)
        XCTAssertEqual(snow.totalMass, 9, accuracy: 0.001)
    }

    func testRoundedPlatformStopsAndPilesLooseSnow() {
        let snow = field()
        snow.setBodies([SolidBody(id: 1, bounds: CGRect(x: 0, y: 75, width: 120, height: 12), cornerRadius: 6)])
        XCTAssertEqual(snow.add(mass: 90, at: SIMD2(60, 30)), 0)
        for _ in 0..<45 { snow.step(dt: 1 / 60, wind: .zero, landing: freeLanding) }
        XCTAssertEqual(snow.totalMass, 90, accuracy: 0.01)
        XCTAssertTrue(snow.active.allSatisfy { snow.position(of: $0).y < 75 })
        XCTAssertTrue(snow.active.allSatisfy { !snow.isSolid(at: $0) })
    }

    func testStaticProfileLandingReceivesCarriedAreaExactlyOnce() {
        let snow = field()
        XCTAssertEqual(snow.add(mass: 45, at: SIMD2(60, 15)), 0)
        var accepted: Float = 0
        for _ in 0..<35 {
            snow.step(dt: 1 / 60, wind: .zero) { from, to, mass in
                if from.y <= 60, to.y >= 60 { accepted += mass; return (0, true) }
                return (mass, false)
            }
        }
        XCTAssertEqual(accepted, 45, accuracy: 0.001)
        XCTAssertEqual(snow.totalMass, 0, accuracy: 0.001)
    }

    func testHardShovelClearsItsWholeRadiusAndPreservesArea() {
        let snow = field()
        XCTAssertEqual(snow.add(mass: 180, at: SIMD2(60, 60)), 0)
        snow.brush(from: SIMD2(60, 60), to: SIMD2(60, 60), radius: 14, hard: true)
        XCTAssertEqual(snow.totalMass, 180, accuracy: 0.01)
        XCTAssertTrue(snow.active.allSatisfy {
            let delta = snow.position(of: $0) - SIMD2<Float>(60, 60)
            return delta.x * delta.x + delta.y * delta.y >= 14 * 14
        })
    }

    func testShovelCannotTeleportGrainsAcrossAnAdjacentWindow() {
        let snow = field()
        snow.setBodies([SolidBody(id: 1, bounds: CGRect(x: 60, y: 0, width: 6, height: 120))])
        XCTAssertEqual(snow.add(mass: 90, at: SIMD2(42, 60)), 0)
        snow.brush(from: SIMD2(40, 60), to: SIMD2(54, 60), radius: 14, hard: true)
        XCTAssertEqual(snow.totalMass, 90, accuracy: 0.01)
        XCTAssertTrue(snow.active.allSatisfy { snow.position(of: $0).x < 60 })
    }

    func testWindowMovingFromBelowPushesSnowUpWithoutDeletingIt() {
        let snow = field()
        let old = SolidBody(id: 1, bounds: CGRect(x: 20, y: 75, width: 80, height: 20))
        snow.setBodies([old])
        XCTAssertEqual(snow.add(mass: 54, at: SIMD2(60, 60)), 0)
        let new = SolidBody(id: 1, bounds: CGRect(x: 20, y: 45, width: 80, height: 20))
        snow.setBodies([new])
        snow.push(by: old, to: new)
        XCTAssertEqual(snow.totalMass, 54, accuracy: 0.01)
        XCTAssertTrue(snow.active.allSatisfy { snow.position(of: $0).y < 45 })
    }

    func testFastSidewaysWindowSweepsGrainsAheadOfItsFinalFace() {
        let snow = field()
        let old = SolidBody(id: 1, bounds: CGRect(x: 5, y: 20, width: 15, height: 80))
        snow.setBodies([old])
        XCTAssertEqual(snow.add(mass: 27, at: SIMD2(45, 60)), 0)
        let new = SolidBody(id: 1, bounds: CGRect(x: 65, y: 20, width: 15, height: 80))
        snow.setBodies([new])
        snow.push(by: old, to: new)
        XCTAssertEqual(snow.totalMass, 27, accuracy: 0.01)
        XCTAssertTrue(snow.active.allSatisfy { snow.position(of: $0).x > 80 })
    }

    func testNewWindowErasesOnlyCoveredCells() {
        let snow = field()
        for x in [Float(30), 51, 72] { XCTAssertEqual(snow.add(mass: 9, at: SIMD2(x, 51)), 0) }
        let new = SolidBody(id: 1, bounds: CGRect(x: 40, y: 40, width: 20, height: 20))
        snow.setBodies([new])
        snow.erase(inside: new)
        XCTAssertEqual(snow.totalMass, 18, accuracy: 0.001)
        XCTAssertFalse(snow.active.contains { new.contains(snow.position(of: $0)) })
    }

    func testStationarySoftGloveDoesNotExcavate() {
        let snow = field()
        XCTAssertEqual(snow.add(mass: 9, at: SIMD2(60, 60)), 0)
        let index = snow.active[0]
        snow.brush(from: SIMD2(60, 60), to: SIMD2(60, 60), radius: 14, hard: false)
        XCTAssertEqual(snow.active, [index])
        XCTAssertEqual(snow.totalMass, 9, accuracy: 0.001)
    }

    func testZeroBudgetDoesNotAllocateOrLoseCallerOwnedMass() {
        let snow = GranularSnow(size: SIMD2(120, 120), maxCells: 0, maxActive: 0)
        XCTAssertEqual(snow.add(mass: 12, at: SIMD2(60, 60)), 12)
        snow.setBodies([SolidBody(id: 1, bounds: CGRect(x: 20, y: 20, width: 30, height: 30))])
        snow.brush(from: .zero, to: SIMD2(20, 20), radius: 14, hard: true)
        snow.step(dt: 1, wind: .zero, landing: freeLanding)
        XCTAssertTrue(snow.active.isEmpty)
        XCTAssertTrue(snow.mass.isEmpty)
    }

    func testTwoDiagonalFlowsCannotOverfillAPartiallyOccupiedCell() {
        let snow = field()
        snow.setBodies([
            SolidBody(id: 1, bounds: CGRect(x: 0, y: 60, width: 60, height: 3)),
            SolidBody(id: 2, bounds: CGRect(x: 63, y: 60, width: 57, height: 3)),
            SolidBody(id: 3, bounds: CGRect(x: 0, y: 63, width: 120, height: 12))
        ])
        for point in [SIMD2<Float>(58.5, 58.5), SIMD2(64.5, 58.5), SIMD2(61.5, 61.5)] {
            XCTAssertEqual(snow.add(mass: 4.5, at: point), 0)
        }
        snow.step(dt: 1 / 60, wind: .zero, landing: freeLanding)
        XCTAssertEqual(snow.totalMass, 13.5, accuracy: 0.001)
        XCTAssertTrue(snow.active.allSatisfy { snow.mass[$0] <= snow.capacity(of: $0) + 0.001 })
    }

    func testContourUsesLocalCellGeometryWithinTheVertexBudget() {
        let snow = field()
        XCTAssertEqual(snow.add(mass: 180, at: SIMD2(60, 60)), 0)
        let contour = GranularContour(field: snow)
        var mesh: [SnowVertex] = []
        contour.append(field: snow, to: &mesh, limit: snow.maximumActive * 12)
        XCTAssertFalse(mesh.isEmpty)
        XCTAssertLessThanOrEqual(mesh.count, snow.active.count * 12)
        XCTAssertTrue(mesh.allSatisfy { vertex in
            snow.active.contains { index in
                let offset = vertex.position - snow.position(of: index)
                return offset.x * offset.x + offset.y * offset.y <= snow.cellSize * snow.cellSize * 2
            }
        }, "Released material is meshed from neighbouring cells, never drawn as a large particle sprite")
    }
}
