import Foundation
import Observation

@MainActor
@Observable
final class DecorationSettings {
    static let scaleRange = 0.65...1.60

    private(set) var layout: DecorationLayout
    var scale: Double {
        didSet {
            guard scale != oldValue else { return }
            defaults.set(scale, forKey: "decorations.scale")
            apply()
        }
    }
    var pushes: Bool {
        didSet {
            guard pushes != oldValue else { return }
            defaults.set(pushes, forKey: "decorations.pushes")
            apply()
        }
    }
    private(set) var usesCustomScenes: Bool
    private(set) var scenes: [UInt32: DecorationScene]
    var includesDesktopIcons: Bool {
        didSet {
            guard includesDesktopIcons != oldValue else { return }
            defaults.set(includesDesktopIcons, forKey: "decorations.includesDesktopIcons")
            apply()
        }
    }
    var desktops: [SceneDesktop] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: ((DecorationConfiguration) -> Void)?
    @ObservationIgnored var onEditorVisibility: ((Bool) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = DecorationLayout(rawValue: defaults.string(forKey: "decorations.layout") ?? "") ?? .none
        let savedScale = defaults.object(forKey: "decorations.scale") as? Double ?? 1
        scale = savedScale.isFinite ? min(Self.scaleRange.upperBound, max(Self.scaleRange.lowerBound, savedScale)) : 1
        pushes = (defaults.object(forKey: "decorations.pushes") as? Bool) ?? defaults.bool(forKey: "decorations.canTopple")
        includesDesktopIcons = defaults.bool(forKey: "decorations.includesDesktopIcons")
        let savedScenes: [UInt32: DecorationScene]
        if let data = defaults.data(forKey: "decorations.scenes"), data.count <= 256_000,
           let restored = try? JSONDecoder().decode([UInt32: DecorationScene].self, from: data) {
            savedScenes = restored.mapValues { $0.bounded() }
        } else {
            savedScenes = [:]
        }
        scenes = savedScenes
        usesCustomScenes = !savedScenes.isEmpty && defaults.bool(forKey: "decorations.usesCustomScenes")
    }

    var configuration: DecorationConfiguration {
        DecorationConfiguration(layout: layout, scale: scale, pushes: pushes, usesCustomScenes: usesCustomScenes,
                                scenes: scenes, includesDesktopIcons: includesDesktopIcons)
    }

    func selectPreset(_ preset: DecorationLayout) {
        guard layout != preset || usesCustomScenes else { return }
        layout = preset
        usesCustomScenes = false
        defaults.set(preset.rawValue, forKey: "decorations.layout")
        defaults.set(false, forKey: "decorations.usesCustomScenes")
        apply()
    }

    func saveScenes(_ drafts: [UInt32: DecorationScene]) -> Bool {
        let updated = scenes.merging(drafts.mapValues { $0.bounded() }, uniquingKeysWith: { _, draft in draft })
        guard !updated.isEmpty, let data = try? JSONEncoder().encode(updated), data.count <= 256_000 else { return false }
        scenes = updated
        usesCustomScenes = true
        defaults.set(data, forKey: "decorations.scenes")
        defaults.set(true, forKey: "decorations.usesCustomScenes")
        apply()
        return true
    }

    func apply() { onChange?(configuration) }
}
