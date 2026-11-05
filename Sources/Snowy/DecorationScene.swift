import Foundation

enum DecorationSupport: String, Codable, CaseIterable, Identifiable, Sendable {
    case floor, dock

    var id: Self { self }
    var title: String { self == .floor ? "Desktop edge" : "Dock top" }
}

struct PlacedDecoration: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var assetID: String
    var x: Double
    var scale: Double = 1
    var pushes: Bool = true
    var support: DecorationSupport = .floor
}

enum SceneAnchorKind: String, Equatable, Sendable {
    case widget, icon

    var title: String { self == .widget ? "Widget" : "Icon" }
}

struct SceneAnchorTarget: Equatable, Identifiable, Sendable {
    let id: String
    let kind: SceneAnchorKind
    let bounds: CGRect
}

struct SceneDesktop: Equatable, Identifiable, Sendable {
    let id: UInt32
    let size: CGSize
    let dock: CGRect?
    let anchors: [SceneAnchorTarget]
}

struct DecorationScene: Codable, Equatable, Sendable {
    static let maxProps = 16
    static let maxLights = LightString.maximumStrings
    static let maxJoints = LightString.maximumAnchors

    var props: [PlacedDecoration] = []
    var lights: [LightString] = []

    var isEmpty: Bool { props.isEmpty && lights.isEmpty }

    static func preset(_ layout: DecorationLayout, scale: Double, pushes: Bool,
                       in desktop: SceneDesktop) -> DecorationScene {
        let pieces = layout.pieces
        let gap = 11.0
        let margin = 18.0
        let width = max(1, desktop.size.width)
        let nativeWidth = Double(pieces.reduce(0) { $0 + $1.width }) * scale * 3
        let groupWidth = nativeWidth + Double(max(0, pieces.count - 1)) * gap
        let layoutIndex = UInt8(DecorationLayout.allCases.firstIndex(of: layout) ?? 0)
        var left = margin
        if let dock = desktop.dock, left + groupWidth > dock.minX - gap,
           dock.maxX + gap + groupWidth <= width - margin {
            left = width - margin - groupWidth
        }
        let props = pieces.enumerated().map { index, piece in
            let size = Double(piece.width) * scale * 3
            let center = min(1, max(0, (left + size / 2) / width))
            left += size + gap
            let id = UUID(uuid: (0xA1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, layoutIndex, UInt8(index)))
            return PlacedDecoration(id: id, assetID: piece.id, x: center,
                                    scale: scale, pushes: pushes && piece.movesByDefault)
        }
        return DecorationScene(props: props)
    }

    func bounded() -> Self {
        var propIDs = Set<UUID>()
        var lightIDs = Set<UUID>()
        let props = props.prefix(Self.maxProps).compactMap { prop -> PlacedDecoration? in
            guard propIDs.insert(prop.id).inserted, DecorationCatalog.piece(prop.assetID) != nil,
                  prop.x.isFinite, prop.scale.isFinite else { return nil }
            var safe = prop
            safe.x = min(1, max(0, safe.x))
            safe.scale = min(1.6, max(0.65, safe.scale))
            return safe
        }
        let lights = lights.prefix(Self.maxLights).compactMap { light -> LightString? in
            guard lightIDs.insert(light.id).inserted, light.anchors.count >= 2,
                  light.slack.isFinite else { return nil }
            var safe = light
            safe.anchors = Array(light.anchors.prefix(Self.maxJoints))
            safe.slack = light.usableSlack
            return safe
        }
        return Self(props: props, lights: lights)
    }
}

struct DecorationConfiguration: Equatable {
    var layout: DecorationLayout = .none
    var scale = 1.0
    var pushes = false
    var usesCustomScenes = false
    var scenes: [UInt32: DecorationScene] = [:]
    var includesDesktopIcons = false

    var hasContent: Bool {
        layout != .none || (usesCustomScenes && scenes.values.contains { !$0.isEmpty })
    }

    func scene(for desktop: SceneDesktop) -> DecorationScene {
        if usesCustomScenes, let custom = scenes[desktop.id] { return custom }
        return .preset(layout, scale: scale, pushes: pushes, in: desktop)
    }
}
