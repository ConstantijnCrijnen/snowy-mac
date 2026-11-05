import Foundation

/// A version-independent first-launch decision, using only Snowy's persisted
/// preference keys. Registered defaults do not make a new install look used.
public enum FirstLaunchPolicy {
    public static let consideredKey = "welcome.hasBeenConsidered"
    public static let legacyPreferenceKeys: Set<String> = [
        "paused", "snowfall", "windX", "windY", "cursorTool"
    ]

    public static func shouldPresent(persistedKeys: Set<String>) -> Bool {
        !persistedKeys.contains(consideredKey)
            && persistedKeys.isDisjoint(with: legacyPreferenceKeys)
    }

    /// Capture before starting the coordinator, which may save preferences.
    public static func shouldPresent(in defaults: UserDefaults, domainName: String) -> Bool {
        let domain = defaults.persistentDomain(forName: domainName) ?? [:]
        return shouldPresent(persistedKeys: Set(domain.keys))
    }

    /// Record before presenting, so closing, skipping, or quitting never repeats
    /// the walkthrough. Existing installations receive the same permanent marker.
    public static func markConsidered(in defaults: UserDefaults) {
        if !defaults.bool(forKey: consideredKey) {
            defaults.set(true, forKey: consideredKey)
        }
    }
}
