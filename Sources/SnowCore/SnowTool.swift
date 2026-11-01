public enum SnowTool: String, CaseIterable, Sendable {
    case glove = "Glove"
    case shovel = "Shovel"

    public var radius: Float { self == .shovel ? 36 : 24 }
}
