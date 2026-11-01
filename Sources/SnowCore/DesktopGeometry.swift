import Foundation
import CoreGraphics

public struct SolidBody: Equatable, Sendable {
    public var id: UInt64
    public var bounds: CGRect
    public var cornerRadius: Float
    public var isElevated: Bool
    public init(id: UInt64, bounds: CGRect, cornerRadius: Float = 0, isElevated: Bool = false) {
        self.id = id
        self.bounds = bounds
        self.cornerRadius = cornerRadius.isFinite
            ? max(0, min(cornerRadius, Float(min(bounds.width, bounds.height) / 2))) : 0
        self.isElevated = isElevated
    }

    public func contains(_ point: SIMD2<Float>, padding: Float = 0) -> Bool {
        let radius = max(0, cornerRadius + padding)
        let rect = bounds.insetBy(dx: -CGFloat(padding), dy: -CGFloat(padding))
        guard rect.contains(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))) else { return false }
        guard radius > 0 else { return true }
        let centerX = max(Float(rect.minX) + radius, min(point.x, Float(rect.maxX) - radius))
        let centerY = max(Float(rect.minY) + radius, min(point.y, Float(rect.maxY) - radius))
        let offset = point - SIMD2(centerX, centerY)
        return offset.x * offset.x + offset.y * offset.y <= radius * radius
    }
}

public enum DesktopWindowRole: Sendable { case application, widget, dock, spotlight, desktop, other }

/// Sanitized metadata in global Quartz coordinates; the builder returns display-local geometry.
public struct DesktopWindowRecord: Sendable {
    public var id: UInt64
    public var bounds: CGRect
    public var layer: Int
    public var role: DesktopWindowRole
    public var opacity: Float
    public init(id: UInt64, bounds: CGRect, layer: Int, role: DesktopWindowRole, opacity: Float = 1) {
        self.id = id; self.bounds = bounds; self.layer = layer; self.role = role
        self.opacity = opacity.isFinite ? max(0, min(1, opacity)) : 0
    }
}

public struct DesktopScene: Sendable {
    public var surfaces: [Surface]
    public var bodies: [SolidBody]
    public var dockWindowID: UInt64?
    public init(surfaces: [Surface], bodies: [SolidBody], dockWindowID: UInt64? = nil) {
        self.surfaces = surfaces; self.bodies = bodies; self.dockWindowID = dockWindowID
    }
}

/// Count-only Dock preferences for a bottom-edge transparent host fallback. This is a
/// bounded content-size estimate, not a replacement for a compact WindowServer tray frame.
public struct DockLayoutHint: Sendable {
    public enum Orientation: String, Sendable { case bottom, left, right }
    public let orientation: Orientation
    public let tileSize: Float
    public let itemCount: Int
    public let autoHides: Bool

    public init(orientation: Orientation, tileSize: Float, itemCount: Int, autoHides: Bool = false) {
        self.orientation = orientation
        self.tileSize = tileSize.isFinite ? max(16, min(128, tileSize)) : 48
        self.itemCount = max(1, min(80, itemCount))
        self.autoHides = autoHides
    }
}
