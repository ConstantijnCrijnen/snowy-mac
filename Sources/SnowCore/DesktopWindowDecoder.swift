import Foundation
import CoreGraphics

/// Separates CFDictionary decoding from live WindowServer access for deterministic regression tests.
public enum DesktopWindowDecoder {
    /// Process identity is enough to distinguish system presentation overlays from real
    /// application windows; window titles and search contents are never needed.
    public static func processRole(bundleIdentifier: String) -> DesktopWindowRole? {
        let bundle = bundleIdentifier.lowercased()
        if bundle == "com.apple.windowmanager" || bundle.hasPrefix("com.apple.windowmanager.") {
            return .other
        }
        if bundle == "com.apple.spotlight" { return .spotlight }
        if bundle == "com.apple.dock" { return .dock }
        if bundle == "com.apple.notificationcenterui" || bundle.contains("widgetkit")
            || bundle == "com.apple.widgetextensionhost" { return .widget }
        if bundle == "com.apple.finder" || bundle.contains("wallpaper") { return .desktop }
        return nil
    }

    /// Public WindowServer owner identity is a fallback for UI services absent from the
    /// running-application cache. These are exact executable names, never window titles.
    private static func systemRole(ownerName: String?) -> DesktopWindowRole? {
        switch ownerName {
        case "Spotlight": return .spotlight
        case "WindowManager": return .other
        case "Dock": return .dock
        default: return nil
        }
    }

    public static func decode(metadata: [[String: Any]], processRoles: [Int32: DesktopWindowRole],
                              excludingPID: Int32, dockLevel: Int = 20,
                              processBundleIdentifiers: [Int32: String] = [:]) -> [DesktopWindowRecord] {
        var records: [DesktopWindowRecord] = []
        records.reserveCapacity(min(512, metadata.count))
        for dictionary in metadata.prefix(512) {
            // CFNumber backing types vary; accept integer and floating-point opacity encodings.
            guard let pid = dictionary[kCGWindowOwnerPID as String] as? NSNumber,
                  pid.doubleValue.isFinite, pid.int64Value > 0, pid.int64Value <= Int64(Int32.max),
                  pid.int32Value != excludingPID,
                  let number = dictionary[kCGWindowNumber as String] as? NSNumber,
                  number.doubleValue.isFinite, number.int64Value > 0, number.uint64Value <= UInt64(UInt32.max),
                  let level = dictionary[kCGWindowLayer as String] as? NSNumber,
                  level.doubleValue.isFinite, level.int64Value >= Int64(Int32.min), level.int64Value <= Int64(Int32.max),
                  let alpha = dictionary[kCGWindowAlpha as String] as? NSNumber,
                  alpha.doubleValue.isFinite, alpha.doubleValue >= 0,
                  let rawBounds = dictionary[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary) else { continue }
            let layer = level.intValue
            let processRole = processRoles[pid.int32Value]
                ?? systemRole(ownerName: dictionary[kCGWindowOwnerName as String] as? String)
            // A transparent Dock host can still identify the native content container.
            // Preserve it as fallback metadata; it is never accepted as an opaque tray.
            guard alpha.doubleValue > 0.05 || processRole == .dock else { continue }
            // Spotlight's panel level varies across system versions; explicit process
            // identity and bounded panel geometry make a global elevated-level guess unnecessary.
            guard layer <= 101 || processRole == .spotlight || processRole == .dock else { continue }
            let role: DesktopWindowRole
            if processBundleIdentifiers[pid.int32Value]?.lowercased() == "com.openai.codex",
               layer == Int(CGWindowLevelForKey(.floatingWindow)) {
                // Codex's transparent floating presentation window can report alpha 1.
                // Its bounds are not a physical obstacle; retain the normal app window below.
                role = .other
            } else if processRole == .other {
                // WindowManager's tiling suggestions are translucent presentation, not new
                // physical windows. Keep them out of the scene at every window level.
                role = .other
            } else if processRole == .spotlight {
                role = .spotlight
            } else if processRole == .dock {
                // Dock presentation levels vary with orientation and OS versions. Its edge
                // geometry, not one exact WindowServer level, decides which window is the Dock.
                role = .dock
            } else if processRole == .widget {
                role = .widget
            } else if layer < 0 {
                // Other compact desktop-level windows can be third-party widgets. The scene
                // builder rejects screen-sized hosts. Finder/wallpaper desktop containers are explicit.
                role = processRole == .desktop ? .desktop : .widget
            } else {
                role = layer < dockLevel ? .application : .other
            }
            records.append(DesktopWindowRecord(id: number.uint64Value, bounds: bounds, layer: layer, role: role,
                                               opacity: alpha.floatValue))
        }
        return records
    }
}
