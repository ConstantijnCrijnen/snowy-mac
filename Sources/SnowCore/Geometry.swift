import Foundation

public struct Span: Equatable, Sendable {
    public var lower: Float
    public var upper: Float

    public init(_ lower: Float, _ upper: Float) {
        self.lower = lower
        self.upper = upper
    }

    public func contains(_ x: Float) -> Bool { x >= lower && x <= upper }
}

/// All simulation coordinates are display-local points, with Y increasing downward.
public struct Surface: Equatable, Sendable {
    public var id: UInt64
    public var x: Float
    public var y: Float
    public var width: Float
    public var visibleSpans: [Span]
    /// Vertical snowfall exposure is distinct from visible support: a floor beneath a floating
    /// window can receive swept snow, but it cannot receive snow falling through that window.
    public var snowfallSpans: [Span]
    public var isDock: Bool
    public var cornerRadius: Float
    public var releasesSnowWhenRemoved: Bool
    /// Spotlight renders above the desktop. Ordinary removable props stay on the desktop plane.
    public var isElevated: Bool
    public var minimumWidth: Float { releasesSnowWhenRemoved && !isElevated ? 5 : 16 }

    public init(id: UInt64, x: Float, y: Float, width: Float,
                visibleSpans: [Span]? = nil, isDock: Bool = false,
                cornerRadius: Float = 0, snowfallSpans: [Span]? = nil,
                releasesSnowWhenRemoved: Bool = false, isElevated: Bool? = nil) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.visibleSpans = visibleSpans ?? [Span(0, width)]
        self.snowfallSpans = snowfallSpans ?? self.visibleSpans
        self.isDock = isDock
        self.cornerRadius = cornerRadius.isFinite ? max(0, min(cornerRadius, width / 2)) : 0
        self.releasesSnowWhenRemoved = releasesSnowWhenRemoved
        self.isElevated = isElevated ?? releasesSnowWhenRemoved
    }

    public func isExposed(at localX: Float) -> Bool {
        visibleSpans.contains { $0.contains(localX) }
    }

    public func isSnowExposed(at localX: Float) -> Bool {
        snowfallSpans.contains { $0.contains(localX) }
    }

    /// The actual upper contour, including the two rounded shoulders, in display-local points.
    public func baseY(at localX: Float) -> Float {
        let radius = max(0, min(cornerRadius, width / 2))
        let edgeDistance = max(0, min(localX, width - localX))
        guard radius > 0, edgeDistance < radius else { return y }
        let horizontal = radius - edgeDistance
        return y + radius - sqrt(max(0, radius * radius - horizontal * horizontal))
    }
}

public enum Geometry {
    public static func subtract(_ obstruction: Span, from spans: [Span]) -> [Span] {
        var result: [Span] = []
        result.reserveCapacity(spans.count + 1)
        for span in spans {
            if obstruction.upper <= span.lower || obstruction.lower >= span.upper {
                result.append(span)
                continue
            }
            if obstruction.lower > span.lower {
                result.append(Span(span.lower, min(span.upper, obstruction.lower)))
            }
            if obstruction.upper < span.upper {
                result.append(Span(max(span.lower, obstruction.upper), span.upper))
            }
        }
        return result
    }

    public static func closestPoint(to point: SIMD2<Float>, on start: SIMD2<Float>,
                                    _ end: SIMD2<Float>) -> SIMD2<Float> {
        let delta = end - start
        let squared = delta.x * delta.x + delta.y * delta.y
        guard squared > 0.001 else { return start }
        let offset = point - start
        let t = max(0, min(1, (offset.x * delta.x + offset.y * delta.y) / squared))
        return start + delta * t
    }
}

struct RandomSource {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func unit() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 40) / Float(1 << 24)
    }
    mutating func value(_ lower: Float, _ upper: Float) -> Float {
        lower + (upper - lower) * unit()
    }
}
