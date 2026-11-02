import XCTest
@testable import SnowCore

final class WindSettingsTests: XCTestCase {
    func testArrowLengthControlsStrengthAndClampsOutsidePad() {
        let setting = WindSettings(vector: SIMD2(3, 4))
        XCTAssertEqual(setting.vector.x, 0.6, accuracy: 0.0001)
        XCTAssertEqual(setting.vector.y, 0.8, accuracy: 0.0001)
        XCTAssertEqual(setting.speedFraction, 1, accuracy: 0.0001)
        XCTAssertEqual(hypot(setting.velocity.x, setting.velocity.y), 80, accuracy: 0.001)
    }

    func testArrowRotationUsesScreenCoordinates() {
        let north = WindSettings(vector: SIMD2(0, -0.5))
        let east = WindSettings(vector: SIMD2(0.5, 0))
        let southwest = WindSettings(headingDegrees: 225, speedFraction: 0.75)
        XCTAssertEqual(north.headingDegrees, 0, accuracy: 0.001)
        XCTAssertEqual(east.headingDegrees, 90, accuracy: 0.001)
        XCTAssertEqual(southwest.headingDegrees, 225, accuracy: 0.001)
        XCTAssertEqual(southwest.directionName, "SW")
        XCTAssertEqual(southwest.speedFraction, 0.75, accuracy: 0.001)
    }

    func testBadPersistedValuesBecomeCalm() {
        XCTAssertEqual(WindSettings(vector: SIMD2(.nan, 1)), WindSettings())
        XCTAssertEqual(WindSettings(vector: SIMD2(1, .infinity)), WindSettings())
        XCTAssertEqual(WindSettings(headingDegrees: .infinity, speedFraction: 1), WindSettings())
        let huge = WindSettings(vector: SIMD2(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude))
        XCTAssertTrue(huge.vector.x.isFinite)
        XCTAssertEqual(huge.speedFraction, 1, accuracy: 0.0001)
    }

    func testZeroArrowMeansCalmAndAngleWraps() {
        XCTAssertEqual(WindSettings().summary, "Calm")
        XCTAssertEqual(WindSettings().velocity, .zero)
        XCTAssertEqual(WindSettings(headingDegrees: 450, speedFraction: 0.4),
                       WindSettings(headingDegrees: 90, speedFraction: 0.4))
    }
}
