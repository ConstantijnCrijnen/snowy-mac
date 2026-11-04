import XCTest
@testable import SnowCore

final class StretchyWindTests: XCTestCase {
    func testOutwardPullIsElasticButBounded() {
        XCTAssertEqual(StretchyWind.rubberBand(0.6), 0.6)
        XCTAssertGreaterThan(StretchyWind.rubberBand(1.5), 1)
        XCTAssertLessThan(StretchyWind.rubberBand(1.5), 1.18)
        XCTAssertLessThanOrEqual(StretchyWind.rubberBand(.greatestFiniteMagnitude), 1.18)
        XCTAssertEqual(StretchyWind.rubberBand(.nan), 0)
    }

    func testDragFollowsPointerThenSettlesToClampedStrength() {
        var spring = StretchyWind(length: 0.5)
        spring.beginDrag(length: 0.5)
        spring.drag(to: 1.5)
        XCTAssertGreaterThan(spring.length, 1)
        XCTAssertLessThan(spring.thicknessScale, 1)
        spring.release(to: 1)
        XCTAssertTrue(spring.isSettling)
        for _ in 0..<60 { spring.step(dt: 1 / 60) }
        XCTAssertFalse(spring.isSettling)
        XCTAssertEqual(spring.length, 1)
        XCTAssertEqual(spring.velocity, 0)
    }

    func testShorteningHasCompressionFeedbackWithoutLengthLag() {
        var spring = StretchyWind(length: 0.8)
        spring.beginDrag(length: 0.8)
        spring.drag(to: 0.3)
        XCTAssertEqual(spring.length, 0.3)
        XCTAssertGreaterThan(spring.thicknessScale, 1)
        spring.release(to: 0.3)
        XCTAssertTrue(spring.isSettling)
        for _ in 0..<60 { spring.step(dt: 1 / 60) }
        XCTAssertFalse(spring.isSettling)
        XCTAssertEqual(spring.length, 0.3)
        XCTAssertEqual(spring.thicknessScale, 1)
    }

    func testReducedMotionAndInterruptedAnimationSnapSafely() {
        var spring = StretchyWind(length: 0.5)
        spring.beginDrag(length: 0.5)
        spring.drag(to: 2, reducedMotion: true)
        XCTAssertEqual(spring.length, 1)
        spring.release(to: 1, reducedMotion: true)
        XCTAssertFalse(spring.isSettling)
        spring.beginDrag(length: 0.8)
        spring.drag(to: 2)
        spring.release(to: 1)
        spring.beginDrag(length: 0.4)
        XCTAssertFalse(spring.isSettling)
        XCTAssertEqual(spring.length, 0.4)
    }

    func testBadFrameTimeCannotLeaveAnAnimationRunningForever() {
        var spring = StretchyWind(length: 0.5)
        spring.beginDrag(length: 0.5)
        spring.drag(to: 2)
        spring.release(to: 1)
        XCTAssertFalse(spring.step(dt: .nan))
        XCTAssertEqual(spring.length, 1)
    }
}
