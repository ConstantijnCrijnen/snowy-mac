import Foundation
import XCTest
@testable import SnowCore

final class FirstLaunchPolicyTests: XCTestCase {
    func testFreshInstallPresentsButUnknownOrVersionKeysDoNotChangeTheDecision() {
        XCTAssertTrue(FirstLaunchPolicy.shouldPresent(persistedKeys: []))
        XCTAssertTrue(FirstLaunchPolicy.shouldPresent(persistedKeys: ["version", "unrelated"]))
    }

    func testPreviouslyConsideredLaunchNeverPresentsAgain() {
        XCTAssertFalse(FirstLaunchPolicy.shouldPresent(persistedKeys: [FirstLaunchPolicy.consideredKey]))
        XCTAssertFalse(FirstLaunchPolicy.shouldPresent(persistedKeys: [FirstLaunchPolicy.consideredKey, "version"]))
    }

    func testEveryLegacyWeatherPreferenceSuppressesTheWalkthrough() {
        for key in FirstLaunchPolicy.legacyPreferenceKeys {
            XCTAssertFalse(FirstLaunchPolicy.shouldPresent(persistedKeys: [key]), key)
        }
    }

    func testSkipCloseAndFinishAllUseTheSamePermanentPresentationMarker() throws {
        let suite = "app.snowy.tests.welcome.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.register(defaults: ["snowfall": "Steady"])
        XCTAssertTrue(FirstLaunchPolicy.shouldPresent(in: defaults, domainName: suite),
                      "Registration is not evidence of a previous installation")
        FirstLaunchPolicy.markConsidered(in: defaults)
        XCTAssertFalse(FirstLaunchPolicy.shouldPresent(in: defaults, domainName: suite))
        let relaunched = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertFalse(FirstLaunchPolicy.shouldPresent(in: relaunched, domainName: suite))
        XCTAssertNil(relaunched.persistentDomain(forName: suite)?["snowfall"],
                       "The welcome marker does not persist or change weather settings")
    }

    func testAnExistingFalseOrZeroPreferenceStillMeansAnExistingInstall() throws {
        let suite = "app.snowy.tests.welcome.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "paused")
        defaults.set(0, forKey: "windX")
        XCTAssertFalse(FirstLaunchPolicy.shouldPresent(in: defaults, domainName: suite))
        FirstLaunchPolicy.markConsidered(in: defaults)
        XCTAssertEqual(defaults.object(forKey: "paused") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "windX") as? Int, 0)
    }
}
