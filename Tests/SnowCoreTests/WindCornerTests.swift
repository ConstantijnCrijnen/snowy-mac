import Foundation
import XCTest
@testable import SnowCore

final class WindCornerTests: XCTestCase {
    private let wall = SolidBody(id: 1, bounds: CGRect(x: 100, y: 50, width: 100, height: 250), cornerRadius: 12)

    private func effect(_ x: Float, y: Float = 200, wind: SIMD2<Float> = SIMD2(80, 0),
                        supportID: UInt64 = 2, walls: [SolidBody]? = nil) -> CornerWindEffect {
        WindCorners.effect(at: SIMD2(x, y), supportID: supportID, bodies: walls ?? [wall], wind: wind)
    }

    func testRightwardWindClearsTheRightWakeAndBuildsTheLeftCorner() {
        let right = effect(220)
        XCTAssertTrue(right.clear)
        XCTAssertEqual(right.depositionScale, 0)
        XCTAssertEqual(right.capacityScale, 0)
        XCTAssertTrue(effect(200).clear, "The sample exactly at the lee wall must not retain a thin seam of snow")
        let left = effect(80)
        XCTAssertFalse(left.clear)
        XCTAssertGreaterThan(left.depositionScale, 1)
        XCTAssertGreaterThan(left.capacityScale, 1)
    }

    func testReversingWindMirrorsTheTwoCorners() {
        XCTAssertEqual(effect(80), effect(220, wind: SIMD2(-80, 0)))
        XCTAssertEqual(effect(220), effect(80, wind: SIMD2(-80, 0)))
    }

    func testFasterWindExtendsTheClearRadius() {
        XCTAssertEqual(WindCorners.clearRadius(for: SIMD2(40, 0)), 48, accuracy: 0.001)
        XCTAssertEqual(WindCorners.clearRadius(for: SIMD2(80, 0)), 96, accuracy: 0.001)
        XCTAssertFalse(effect(260, wind: SIMD2(40, 0)).clear)
        XCTAssertTrue(effect(260, wind: SIMD2(80, 0)).clear)
        XCTAssertEqual(effect(310), .neutral)
    }

    func testWakeReturnsSmoothlyToNormalAfterTheClearRadius() {
        let transition = effect(298)
        XCTAssertFalse(transition.clear)
        XCTAssertGreaterThan(transition.depositionScale, 0)
        XCTAssertLessThan(transition.depositionScale, 1)
        XCTAssertEqual(effect(304), .neutral)
    }

    func testCalmVerticalAndMalformedWindDoNotInventCornerEffects() {
        XCTAssertEqual(effect(220, wind: .zero), .neutral)
        XCTAssertEqual(effect(220, wind: SIMD2(0, -80)), .neutral)
        XCTAssertEqual(effect(220, wind: SIMD2(.nan, 0)), .neutral)
        XCTAssertEqual(effect(220, wind: SIMD2(80, .infinity)), .neutral)
        XCTAssertEqual(effect(.nan), .neutral)
    }

    func testOwnSupportAndDistantVerticalBodiesAreIgnored() {
        XCTAssertEqual(effect(220, supportID: 1), .neutral)
        XCTAssertEqual(effect(220, y: 400), .neutral)
        XCTAssertEqual(effect(220, y: 20), .neutral)
        XCTAssertEqual(effect(150), .neutral)
        XCTAssertEqual(effect(220, y: 50), .neutral,
                       "Coplanar tops do not form a protruding wall above the receiving support")
    }

    func testSmallBodyEndingInThePileBandHasALocalWeakerWake() {
        let overhead = SolidBody(id: 3, bounds: CGRect(x: 100, y: 50, width: 100, height: 136))
        XCTAssertTrue(effect(220, walls: [overhead]).clear)
        XCTAssertFalse(effect(270, walls: [overhead]).clear)
        XCTAssertEqual(effect(220, y: 220, walls: [overhead]), .neutral)
    }

    func testCachedProfileSamplesAreBoundedAndMatchPointEvaluation() {
        let surface = Surface(id: 2, x: 0, y: 200, width: 400)
        let samples = WindCorners.effects(for: surface, cellCount: 101, bodies: [wall], wind: SIMD2(80, 0))
        XCTAssertEqual(samples.count, 101)
        XCTAssertEqual(samples[20], effect(80))
        XCTAssertEqual(samples[55], effect(220))
        XCTAssertTrue(WindCorners.effects(for: surface, cellCount: -1, bodies: [wall], wind: SIMD2(80, 0)).isEmpty)
        XCTAssertEqual(WindCorners.effects(for: surface, cellCount: Int.max, bodies: [wall], wind: SIMD2(80, 0)).count, 512)
    }

    func testMultipleWallsAndExtremeInputsCannotExceedTheMultiplierBudget() {
        let walls = (0..<1000).map { SolidBody(id: UInt64($0 + 10), bounds: wall.bounds) }
        let result = effect(80, wind: SIMD2(Float.greatestFiniteMagnitude, 0), walls: walls)
        XCTAssertTrue(result.depositionScale.isFinite)
        XCTAssertLessThanOrEqual(result.depositionScale, 2.25)
        XCTAssertLessThanOrEqual(result.capacityScale, 1.6)
        XCTAssertGreaterThanOrEqual(result.depositionScale, 1)
        var invalid = wall
        invalid.cornerRadius = .nan
        XCTAssertEqual(effect(220, walls: [invalid]), .neutral)
    }
}
