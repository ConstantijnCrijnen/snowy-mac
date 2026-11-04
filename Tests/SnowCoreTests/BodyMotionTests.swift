import Foundation
import XCTest
@testable import SnowCore

final class BodyMotionTests: XCTestCase {
    private func body(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 200, _ height: CGFloat = 200,
                      id: UInt64 = 1, radius: Float = 0) -> SolidBody {
        SolidBody(id: id, bounds: CGRect(x: x, y: y, width: width, height: height), cornerRadius: radius)
    }

    func testNewWindowAppearsButPersistentWindowMoves() {
        let original = body(100, 100)
        let changed = body(140, 100)
        let opened = body(500, 100, id: 2)
        let changes = BodyChanges.classify(old: [original], new: [changed, opened])
        XCTAssertEqual(changes.appeared, [opened])
        XCTAssertEqual(changes.moved.count, 1)
        XCTAssertEqual(changes.moved[0].old, original)
        XCTAssertEqual(changes.moved[0].new, changed)
        XCTAssertTrue(changes.removed.isEmpty)
    }

    func testReorderingIsNeitherAppearanceNorMovement() {
        let first = body(100, 100)
        let second = body(500, 100, id: 2)
        let changes = BodyChanges.classify(old: [first, second], new: [second, first])
        XCTAssertTrue(changes.appeared.isEmpty)
        XCTAssertTrue(changes.moved.isEmpty)
        XCTAssertTrue(changes.removed.isEmpty)
    }

    func testWindowFromBelowPushesSnowAboveItsNewTop() {
        let movement = BodyMotion(old: body(100, 400), new: body(100, 250))
        let snow = SIMD2<Float>(200, 300)
        let pushed = movement.displacedPosition(of: snow, padding: 2)
        XCTAssertNotNil(pushed)
        XCTAssertLessThan(pushed!.y, 248)
        XCTAssertEqual(pushed!.x, 200, accuracy: 0.001)
        XCTAssertEqual(movement.direction(at: snow), SIMD2(0, -1))
    }

    func testWindowFromLeftPushesSnowBeyondItsNewRightBoundary() {
        let movement = BodyMotion(old: body(100, 100), new: body(250, 100))
        let pushed = movement.displacedPosition(of: SIMD2(350, 200), padding: 2)
        XCTAssertNotNil(pushed)
        XCTAssertGreaterThan(pushed!.x, 452)
        XCTAssertEqual(pushed!.y, 200, accuracy: 0.001)
    }

    func testWindowFromRightPushesSnowBeyondItsNewLeftBoundary() {
        let movement = BodyMotion(old: body(500, 100), new: body(250, 100))
        let pushed = movement.displacedPosition(of: SIMD2(400, 200), padding: 2)
        XCTAssertNotNil(pushed)
        XCTAssertLessThan(pushed!.x, 248)
        XCTAssertEqual(pushed!.y, 200, accuracy: 0.001)
    }

    func testFastWindowStillPushesSnowThatItCompletelyPassed() {
        let movement = BodyMotion(old: body(100, 100, 100), new: body(600, 100, 100))
        let snow = SIMD2<Float>(400, 200)
        XCTAssertFalse(movement.new.contains(snow))
        let pushed = movement.displacedPosition(of: snow)
        XCTAssertNotNil(pushed)
        XCTAssertGreaterThan(pushed!.x, 700)
    }

    func testExpandingLeftAndTopFacesPushInTheirOwnDirections() {
        let movement = BodyMotion(old: body(200, 200), new: body(100, 100, 300, 300))
        XCTAssertLessThan(movement.displacedPosition(of: SIMD2(150, 300))!.x, 100)
        XCTAssertLessThan(movement.displacedPosition(of: SIMD2(300, 150))!.y, 100)
        XCTAssertEqual(movement.direction(at: SIMD2(150, 300)), SIMD2(-1, 0))
        XCTAssertEqual(movement.direction(at: SIMD2(300, 150)), SIMD2(0, -1))
    }

    func testShrinkingBoundaryReleasesSnowRatherThanPullingIt() {
        let movement = BodyMotion(old: body(100, 100, 300, 300), new: body(200, 200, 100, 100))
        XCTAssertNil(movement.displacedPosition(of: SIMD2(150, 200)))
    }

    func testRoundedEmptyCornerDoesNotPushUntouchedSnow() {
        let movement = BodyMotion(old: body(100, 100, radius: 30), new: body(110, 100, radius: 30))
        XCTAssertNil(movement.displacedPosition(of: SIMD2(307, 101)))
        let pushed = movement.displacedPosition(of: SIMD2(307, 150), padding: 2)
        XCTAssertNotNil(pushed)
        XCTAssertGreaterThan(pushed!.x, 312)
    }

    func testInvalidAndDuplicateGeometryCannotExpandClassification() {
        var values = (0..<1000).map { body(CGFloat($0), 100, id: UInt64($0)) }
        values.insert(body(.nan, 100, id: 2000), at: 0)
        values.insert(values[1], at: 0)
        let changes = BodyChanges.classify(old: [], new: values)
        XCTAssertLessThanOrEqual(changes.appeared.count, DesktopSceneBuilder.maximumBodies)
        XCTAssertEqual(Set(changes.appeared.map(\.id)).count, changes.appeared.count)
        XCTAssertFalse(changes.appeared.contains { $0.id == 2000 })
        let removed = BodyChanges.classify(old: [body(100, 100)], new: [])
        XCTAssertEqual(removed.removed.count, 1)
    }
}
