import Foundation

/// Presentation-only elasticity. The wind vector remains clamped by WindSettings;
/// this model never changes the actual direction or strength of the weather.
public struct StretchyWind: Sendable {
    public private(set) var length: Float
    public private(set) var velocity: Float = 0
    public private(set) var isSettling = false
    public private(set) var isDragging = false
    public private(set) var thicknessScale: Float = 1
    private var target: Float
    private var reference: Float
    private var elapsed: Float = 0
    private var thicknessVelocity: Float = 0

    public init(length: Float = 0) {
        let value = length.isFinite ? max(0, min(1, length)) : 0
        self.length = value
        target = value
        reference = max(0.3, value)
    }

    /// An asymptote keeps the arrow inside the pad even during a long outward pull.
    public static func rubberBand(_ rawLength: Float) -> Float {
        guard rawLength.isFinite else { return 0 }
        let value = max(0, rawLength)
        guard value > 1 else { return value }
        return min(1.18, 1 + 0.18 * (1 - 1 / (1 + (value - 1) * 3)))
    }

    public mutating func beginDrag(length current: Float) {
        snap(to: current)
        reference = max(0.3, length)
        isDragging = true
    }

    public mutating func drag(to rawLength: Float, reducedMotion: Bool = false) {
        guard rawLength.isFinite else { return }
        isDragging = true
        isSettling = false
        velocity = 0
        length = reducedMotion ? max(0, min(1, rawLength)) : Self.rubberBand(rawLength)
        thicknessScale = reducedMotion ? 1 : max(0.80, min(1.16, sqrt(reference / max(0.12, length))))
        thicknessVelocity = 0
    }

    public mutating func release(to value: Float, reducedMotion: Bool = false) {
        target = value.isFinite ? max(0, min(1, value)) : 0
        isDragging = false
        elapsed = 0
        velocity = 0
        if reducedMotion || (abs(length - target) < 0.0005 && abs(thicknessScale - 1) < 0.0005) {
            snap(to: target)
        } else {
            isSettling = true
        }
    }

    /// Returns true while another presentation frame is needed. Bounded substeps
    /// and a final deadline make this safe for interrupted/irregular UI frames.
    @discardableResult
    public mutating func step(dt: Float) -> Bool {
        guard isSettling else { return false }
        guard dt.isFinite, dt > 0 else { snap(to: target); return false }
        let interval = min(dt, 1 / 30)
        elapsed += interval
        let count = max(1, min(4, Int(ceil(interval / (1 / 120)))))
        let h = interval / Float(count)
        for _ in 0..<count {
            let acceleration = (target - length) * 360 - velocity * 27
            velocity += acceleration * h
            length = max(0, min(1.18, length + velocity * h))
            thicknessVelocity += ((1 - thicknessScale) * 360 - thicknessVelocity * 27) * h
            thicknessScale = max(0.75, min(1.2, thicknessScale + thicknessVelocity * h))
        }
        if elapsed >= 0.7 || (abs(length - target) < 0.0005 && abs(velocity) < 0.005
            && abs(thicknessScale - 1) < 0.0005 && abs(thicknessVelocity) < 0.005) {
            snap(to: target)
        }
        return isSettling
    }

    public mutating func snap(to value: Float) {
        target = value.isFinite ? max(0, min(1, value)) : 0
        length = target
        reference = max(0.3, target)
        velocity = 0
        thicknessScale = 1
        thicknessVelocity = 0
        elapsed = 0
        isDragging = false
        isSettling = false
    }
}
