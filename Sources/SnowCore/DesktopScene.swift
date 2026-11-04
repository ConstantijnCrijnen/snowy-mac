import Foundation
import CoreGraphics

public enum DesktopSceneBuilder {
    public static let groundID = UInt64.max
    /// One logical support per display, independent of native host/tray window changes.
    public static let dockID = UInt64.max - 1
    public static let maximumBodies = 64
    public static let maximumSurfaces = 48

    public static func build(displayBounds display: CGRect, menuInset: Float,
                             windows: [DesktopWindowRecord], dockLayout: DockLayoutHint? = nil,
                             preferredDockID: UInt64? = nil, dockBottomInset: Float? = nil) -> DesktopScene {
        guard valid(display), display.width > 1, display.height > 1 else {
            return DesktopScene(surfaces: [], bodies: [])
        }
        let candidates = windows.prefix(512).filter { record in
            guard valid(record.bounds), record.bounds.intersects(display) else { return false }
            switch record.role {
            case .application:
                return record.layer >= 0 && record.layer < 20
                    && record.bounds.width >= 48 && record.bounds.height >= 32
            case .widget: return plausibleWidget(record.bounds, display: display)
            case .dock:
                // Vertical Docks are intentionally outside the snow scene, including
                // temporary horizontal animation windows owned by a side-oriented Dock.
                return (dockLayout?.orientation ?? .bottom) == .bottom
                    && record.opacity > 0.05 && plausibleBottomDock(record.bounds, display: display)
            case .spotlight:
                let usableHeight = display.height - CGFloat(max(0, menuInset))
                return record.layer >= 0
                    && record.bounds.width >= 200 && record.bounds.height >= 40
                    && record.bounds.width <= display.width
                    && record.bounds.height <= usableHeight
                    && record.bounds.minY >= display.minY + CGFloat(max(0, menuInset))
                    && !(record.bounds.width >= display.width * 0.95 && record.bounds.height >= usableHeight * 0.95)
            case .desktop, .other: return false
            }
        }.map { record -> DesktopWindowRecord in
            var result = record
            if record.role == .widget {
                // WidgetKit hosts include transparent chrome outside their visible tile. These
                // conservative content insets match the supplied screenshots; public metadata
                // doesn't expose a separate content frame or an arbitrary alpha silhouette.
                result.bounds = CGRect(x: record.bounds.minX + 8, y: record.bounds.minY + 16,
                                       width: record.bounds.width - 16, height: record.bounds.height - 24)
            }
            return result
        }
        // Preserve temporary Spotlight supports, Dock and widgets when many app windows
        // compete for the bounded geometry budget.
        var selected: [DesktopWindowRecord] = []
        var ids: Set<UInt64> = []
        for record in candidates where record.role == .spotlight {
            if selected.count < maximumBodies, ids.insert(record.id).inserted { selected.append(record) }
        }
        let dockCandidates = candidates.filter { $0.role == .dock }
        // Long bottom trays are real supports too. Only an essentially full-width
        // rectangle is a transparent host; retain a tray with visible end margins.
        let trays = dockCandidates.filter {
            !isBottomDockHost($0.bounds, display: display)
                // A compact visible tray must have a usable top, rather than the menu-bar
                // origin of an auxiliary Dock host that cannot supply a snow surface.
                && $0.bounds.minY >= display.minY + CGFloat(max(0, menuInset))
        }
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let canonical = trays.filter { $0.layer == dockLevel }
        let eligible = canonical.isEmpty ? trays : canonical
        var dock = eligible.first { $0.id == preferredDockID } ?? eligible.max {
            let leftScore = dockScore($0.bounds, display: display, hint: dockLayout)
            let rightScore = dockScore($1.bounds, display: display, hint: dockLayout)
            return leftScore == rightScore ? $0.id > $1.id : leftScore < rightScore
        }
        if dock == nil, let dockLayout, dockLayout.orientation == .bottom {
            let dockRecords = windows.prefix(512).filter {
                $0.role == .dock && valid($0.bounds) && $0.bounds.intersects(display)
            }
            let hosts = dockRecords.filter { isBottomDockHost($0.bounds, display: display) }
            let host = hosts.max {
                if ($0.layer == dockLevel) != ($1.layer == dockLevel) { return $0.layer != dockLevel }
                return $0.id > $1.id
            }
            if let bounds = reservedBottomTray(display: display, inset: dockBottomInset, hint: dockLayout) {
                // A screen's live reserved bottom strip proves where a visible Dock lives,
                // even when WindowServer exposes no compact or opaque Dock window.
                let footprints = dockRecords.filter {
                    plausibleBottomDock($0.bounds, display: display)
                        && !isBottomDockHost($0.bounds, display: display)
                        && abs($0.bounds.minY - bounds.minY) <= 32
                }
                let footprint = footprints.first { $0.id == preferredDockID } ?? footprints.max {
                    let left = dockScore($0.bounds, display: display, hint: dockLayout)
                    let right = dockScore($1.bounds, display: display, hint: dockLayout)
                    return left == right ? $0.id > $1.id : left < right
                }
                var resolved = bounds
                if let footprint {
                    let span = footprint.bounds.intersection(display)
                    resolved.origin.x = span.minX
                    resolved.size.width = span.width
                }
                dock = DesktopWindowRecord(id: preferredDockID ?? footprint?.id ?? host?.id ?? dockID,
                    bounds: resolved, layer: dockLevel, role: .dock)
            } else if dockBottomInset == nil, !dockLayout.autoHides,
                      let host = hosts.filter({
                          $0.bounds.minY >= display.maxY - min(640, display.height * 0.5)
                      }).max(by: { $0.id > $1.id }),
                      let bounds = estimatedBottomTray(host: host.bounds, display: display, hint: dockLayout) {
                // Compatibility for callers without a visible-frame observation. Native
                // tracking always supplies it, so another display cannot gain a phantom Dock.
                dock = DesktopWindowRecord(id: preferredDockID ?? host.id, bounds: bounds,
                                           layer: dockLevel, role: .dock)
            }
        }
        let dockWindowID = dock.flatMap { $0.id <= UInt64(UInt32.max) ? $0.id : nil }
        if var dock {
            dock.id = dockID
            selected.append(dock)
            ids.insert(dock.id)
        }
        for record in candidates where record.role == .widget {
            if selected.count < maximumBodies, ids.insert(record.id).inserted { selected.append(record) }
        }
        for record in candidates where record.role == .application {
            if selected.count < maximumBodies, ids.insert(record.id).inserted { selected.append(record) }
        }
        let bodies = selected.map { record in
            SolidBody(id: record.id, bounds: record.bounds.offsetBy(dx: -display.minX, dy: -display.minY)
                .intersection(CGRect(origin: .zero, size: display.size)), cornerRadius: radius(for: record),
                isElevated: record.role == .spotlight)
        }
        let width = Float(display.width), height = Float(display.height)
        var groundSpans = [Span(0, width)]
        var groundSnowfall = [Span(0, width)]
        for body in bodies {
            groundSnowfall = Geometry.subtract(Span(Float(body.bounds.minX), Float(body.bounds.maxX)), from: groundSnowfall)
        }
        for body in bodies where body.bounds.maxY >= display.height - 0.5 {
            groundSpans = Geometry.subtract(Span(Float(body.bounds.minX), Float(body.bounds.maxX)), from: groundSpans)
        }
        // Ground must survive a surface-budget truncation.
        var surfaces = [Surface(id: groundID, x: 0, y: height, width: width, visibleSpans: groundSpans,
                                snowfallSpans: groundSnowfall)]
        surfaces.reserveCapacity(maximumSurfaces)
        for record in selected.prefix(maximumSurfaces - 1) {
            let top = Float(record.bounds.minY - display.minY)
            guard top >= max(0, menuInset), top < height else { continue }
            let left = max(record.bounds.minX, display.minX), right = min(record.bounds.maxX, display.maxX)
            guard right - left >= 16 else { continue }
            var spans = [Span(0, Float(right - left))]
            var snowfall = spans
            for other in selected where other.id != record.id {
                // Spotlight's attached cap is presented immediately below its search panel,
                // above the ordinary desktop plane. Lower windows cannot hide its support.
                if record.role == .spotlight && other.role != .spotlight { continue }
                if other.bounds.minY < record.bounds.minY {
                    snowfall = Geometry.subtract(Span(Float(other.bounds.minX - left), Float(other.bounds.maxX - left)), from: snowfall)
                }
                // Snow is below every native window. Clip against every physical body, not only front windows.
                if other.bounds.minY < record.bounds.minY - 0.01, other.bounds.maxY > record.bounds.minY - 20 {
                    spans = Geometry.subtract(Span(Float(other.bounds.minX - left), Float(other.bounds.maxX - left)), from: spans)
                    if spans.isEmpty { break }
                }
            }
            surfaces.append(Surface(id: record.id, x: Float(left - display.minX), y: top,
                                    width: Float(right - left), visibleSpans: spans, isDock: record.role == .dock,
                                    cornerRadius: radius(for: record), snowfallSpans: snowfall,
                                    releasesSnowWhenRemoved: record.role == .spotlight))
        }
        return DesktopScene(surfaces: surfaces, bodies: bodies, dockWindowID: dockWindowID)
    }

    public static func isFullscreen(displayBounds display: CGRect, windows: [DesktopWindowRecord]) -> Bool {
        guard let front = windows.prefix(512).first(where: {
            $0.role == .application && $0.layer == 0 && valid($0.bounds)
                && $0.bounds.intersects(display) && $0.bounds.width >= 120 && $0.bounds.height >= 80
        }) else { return false }
        return abs(front.bounds.minX - display.minX) < 3 && abs(front.bounds.minY - display.minY) < 3
            && front.bounds.width >= display.width - 3 && front.bounds.height >= display.height - 3
    }

    private static func plausibleWidget(_ rect: CGRect, display: CGRect) -> Bool {
        rect.width >= 48 && rect.height >= 48 && rect.width <= min(1100, display.width * 0.9)
            && rect.height <= min(1100, display.height * 0.9)
    }

    private static func plausibleBottomDock(_ rect: CGRect, display: CGRect) -> Bool {
        let visible = rect.intersection(display)
        return rect.width >= max(96, rect.height * 1.8) && rect.height >= 20 && rect.height <= 240
            && rect.minY >= display.maxY - 260 && rect.maxY >= display.maxY - 48 && visible.height >= 16
    }

    private static func radius(for record: DesktopWindowRecord) -> Float {
        min(record.role == .spotlight ? 28 : (record.role == .widget ? 22 : 12),
            Float(min(record.bounds.width, record.bounds.height) / 2))
    }

    private static func dockScore(_ rect: CGRect, display: CGRect, hint: DockLayoutHint?) -> CGFloat {
        let elongation = rect.width / rect.height
        let edgeGap = abs(rect.maxY - display.maxY)
        let expectedThickness = CGFloat(hint?.tileSize ?? 48) + 16
        // Cap the aspect contribution so a narrow animation/indicator window cannot win
        // merely by being much thinner than the actual rounded tray.
        let thicknessPenalty = abs(log(max(0.1, rect.height / expectedThickness))) * 40
        return min(14, elongation) * 2 - min(48, edgeGap) - thicknessPenalty
    }

    private static func isBottomDockHost(_ rect: CGRect, display: CGRect) -> Bool {
        rect.height >= 20 && rect.minX <= display.minX + 2
            && rect.maxX >= display.maxX - 2
            && rect.maxY >= display.maxY - 48
    }

    private static func reservedBottomTray(display: CGRect, inset: Float?, hint: DockLayoutHint) -> CGRect? {
        guard hint.orientation == .bottom, let inset, inset.isFinite,
              inset >= 20, CGFloat(inset) <= min(320, display.height * 0.5) else { return nil }
        let available = display.width - 16
        let wantedLength = CGFloat(hint.itemCount) * (CGFloat(hint.tileSize) + 6) + 24
        let length = min(available, wantedLength)
        guard length >= 32 else { return nil }
        return CGRect(x: display.minX + (display.width - length) / 2,
                      y: display.maxY - CGFloat(inset), width: length, height: CGFloat(inset))
    }

    private static func estimatedBottomTray(host: CGRect, display: CGRect, hint: DockLayoutHint) -> CGRect? {
        guard hint.orientation == .bottom else { return nil }
        let wantedLength = CGFloat(hint.itemCount) * (CGFloat(hint.tileSize) + 6) + 24
        let available = display.width - 16
        let length = min(available, wantedLength)
        let fit = min(1, available / wantedLength)
        let thickness = min(host.height, max(16, (CGFloat(hint.tileSize) + 16) * fit))
        guard length >= 32, thickness >= 16 else { return nil }
        return CGRect(x: display.minX + 8 + (available - length) / 2,
                      y: host.maxY - thickness, width: length, height: thickness)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
            && abs(rect.minX) < 100_000 && abs(rect.minY) < 100_000
            && rect.width > 1 && rect.width <= 100_000 && rect.height > 1 && rect.height <= 100_000
    }
}
