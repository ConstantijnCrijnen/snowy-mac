import Foundation

/// A direction and strength in screen coordinates (positive Y points downward).
public struct WindSettings: Equatable, Sendable {
    public let vector: SIMD2<Float>

    public init(vector: SIMD2<Float> = .zero) {
        guard vector.x.isFinite, vector.y.isFinite else { self.vector = .zero; return }
        let length = hypot(Double(vector.x), Double(vector.y))
        self.vector = length > 1 ? vector * Float(1 / length) : vector
    }

    public init(headingDegrees: Float, speedFraction: Float) {
        guard headingDegrees.isFinite, speedFraction.isFinite else { self = WindSettings(); return }
        let angle = headingDegrees.truncatingRemainder(dividingBy: 360) * .pi / 180
        self = WindSettings(vector: SIMD2(sin(angle), -cos(angle)) * max(0, min(1, speedFraction)))
    }

    public var speedFraction: Float { min(1, sqrt(vector.x * vector.x + vector.y * vector.y)) }
    public var velocity: SIMD2<Float> { vector * 80 }
    public var headingDegrees: Float {
        guard speedFraction > 0.0001 else { return 0 }
        let angle = atan2(vector.x, -vector.y) * 180 / .pi
        return angle < 0 ? angle + 360 : angle
    }

    public var directionName: String {
        guard speedFraction >= 0.01 else { return "Calm" }
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return names[Int((headingDegrees + 22.5) / 45) % names.count]
    }

    public var summary: String {
        speedFraction < 0.01 ? "Calm" : "\(Int((speedFraction * 100).rounded()))% · \(directionName)"
    }
}
