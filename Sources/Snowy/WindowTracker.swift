import AppKit
import CoreGraphics
import SnowCore

struct DisplayGeometry: Sendable {
    let id: UInt32
    let bounds: CGRect
    let menuInset: Float
    let dockBottomInset: Float

    init(id: UInt32, bounds: CGRect, menuInset: Float, dockBottomInset: Float = 0) {
        self.id = id
        self.bounds = bounds
        self.menuInset = menuInset
        self.dockBottomInset = dockBottomInset
    }
}

struct DisplaySnapshot: Sendable {
    let id: UInt32
    let surfaces: [Surface]
    let bodies: [SolidBody]
    let fullscreen: Bool
    let spotlightSupports: [SpotlightSnowSupport]
    let dockWindowID: UInt64?
    let desktop: SceneDesktop
}

private final class ProcessObserver {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, name: Notification.Name,
         action: @escaping @Sendable (Notification) -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: .main, using: action)
    }

    deinit { center.removeObserver(token) }
}

@MainActor
final class WindowTracker {
    private var inFlight = false
    private var generation = 0
    private var lastQuery: TimeInterval = -.infinity
    private var lastFullQuery: TimeInterval = -.infinity
    private var cachedRecords: [DesktopWindowRecord] = []
    private var trackedWindow: UInt32?
    private var roles: [Int32: DesktopWindowRole] = [:]
    private var bundleIdentifiers: [Int32: String] = [:]
    private var lastProcessLookup: TimeInterval = -.infinity
    private var wasDragging = false
    private var dockLayout: DockLayoutHint?
    private var lastDockPreferenceLookup: TimeInterval = -.infinity
    private var preferredDockIDs: [UInt32: UInt64] = [:]
    private var processObservers: [ProcessObserver] = []
    private var finderPID: pid_t?
    private var icons: [SceneAnchorTarget] = []
    private var iconQueryInFlight = false
    private var iconGeneration = 0
    private var lastIconQuery: TimeInterval = -.infinity
    var includesDesktopIcons = false {
        didSet {
            guard oldValue != includesDesktopIcons else { return }
            iconGeneration += 1
            icons.removeAll(keepingCapacity: true)
            lastIconQuery = -.infinity
            lastQuery = -.infinity
            lastFullQuery = -.infinity
        }
    }

    init() {
        // Spotlight can start after our periodic process-role cache was populated. Refresh
        // identities on lifecycle events instead of repeatedly enumerating every process.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            processObservers.append(ProcessObserver(center: NSWorkspace.shared.notificationCenter, name: name) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.lastProcessLookup = -.infinity
                    self?.lastFullQuery = -.infinity
                }
            })
        }
    }

    func invalidate() {
        generation += 1
        lastQuery = -.infinity
        lastFullQuery = -.infinity
        cachedRecords.removeAll(keepingCapacity: true)
        trackedWindow = nil
        dockLayout = nil
        preferredDockIDs.removeAll(keepingCapacity: true)
        lastDockPreferenceLookup = -.infinity
        lastProcessLookup = -.infinity
        iconGeneration += 1
        icons.removeAll(keepingCapacity: true)
        lastIconQuery = -.infinity
    }

    func refreshIfNeeded(displays: [DisplayGeometry], now: TimeInterval, dragging: Bool,
                         idleInterval: TimeInterval = 0.5,
                         completion: @escaping @MainActor ([DisplaySnapshot]?) -> Void) {
        guard !inFlight else { return }
        if wasDragging && !dragging {
            lastFullQuery = -.infinity
            lastQuery = -.infinity
            trackedWindow = nil
        }
        wasDragging = dragging
        let fullRefresh = now - lastFullQuery >= (dragging ? 0.10 : idleInterval)
        if dragging, trackedWindow == nil { trackedWindow = windowUnderDragPointer() }
        let target = dragging && !fullRefresh ? trackedWindow : nil
        let minimumInterval = dragging ? 1.0 / 30.0 : idleInterval
        guard fullRefresh || target != nil,
              now - lastQuery >= minimumInterval - 0.0005 else { return }
        // Carry the deadline forward rather than dropping every second 30 Hz display callback
        // because its timestamp arrived a fraction of a millisecond before an exact 1/30 s.
        lastQuery = max(now, lastQuery + minimumInterval)
        if fullRefresh { lastFullQuery = now }
        inFlight = true
        if now - lastProcessLookup > 5 {
            roles.removeAll(keepingCapacity: true)
            bundleIdentifiers.removeAll(keepingCapacity: true)
            finderPID = nil
            for app in NSWorkspace.shared.runningApplications {
                guard let bundle = app.bundleIdentifier else { continue }
                bundleIdentifiers[app.processIdentifier] = bundle
                if let role = DesktopWindowDecoder.processRole(bundleIdentifier: bundle) {
                    roles[app.processIdentifier] = role
                }
                if bundle == "com.apple.finder" { finderPID = app.processIdentifier }
            }
            lastProcessLookup = now
        }
        if now - lastDockPreferenceLookup >= 0.5 {
            lastDockPreferenceLookup = now
            let preferences = UserDefaults(suiteName: "com.apple.dock")
            // The default orientation need not have a stored preference key.
            let rawOrientation = preferences?.string(forKey: "orientation") ?? "bottom"
            if let orientation = DockLayoutHint.Orientation(rawValue: rawOrientation) {
                // Only counts are retained; titles, paths and individual Dock item contents are never inspected.
                let count = min(80, preferences?.array(forKey: "persistent-apps")?.count ?? 0)
                    + min(80, preferences?.array(forKey: "persistent-others")?.count ?? 0)
                    + (((preferences?.object(forKey: "show-recents") as? NSNumber)?.boolValue ?? true) ? 3 : 0)
                    + 2 // Finder and Trash are implicit Dock tiles.
                let tile = (preferences?.object(forKey: "tilesize") as? NSNumber)?.floatValue ?? 48
                let autoHides = (preferences?.object(forKey: "autohide") as? NSNumber)?.boolValue ?? false
                dockLayout = DockLayoutHint(orientation: orientation, tileSize: tile, itemCount: count,
                                            autoHides: autoHides)
            } else { dockLayout = nil }
        }
        let processRoles = roles
        let processBundleIdentifiers = bundleIdentifiers
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let requestGeneration = generation
        Task { [weak self] in
            let records = await Task.detached(priority: .utility) {
                Self.read(processRoles: processRoles, processBundleIdentifiers: processBundleIdentifiers,
                          ownPID: ownPID, target: target)
            }.value
            guard let self else { return }
            self.inFlight = false
            guard self.generation == requestGeneration else {
                completion(nil)
                return
            }
            if let target {
                if let replacement = records.first(where: { $0.id == UInt64(target) }),
                   let index = self.cachedRecords.firstIndex(where: { $0.id == UInt64(target) }) {
                    self.cachedRecords[index] = replacement
                } else {
                    self.cachedRecords.removeAll { $0.id == UInt64(target) }
                    self.trackedWindow = nil
                }
            } else {
                let previous = Dictionary(self.cachedRecords.map { ($0.id, $0.bounds) }, uniquingKeysWith: { first, _ in first })
                let changed = records.first {
                    ($0.role == .application || $0.role == .widget) && previous[$0.id] != nil && previous[$0.id] != $0.bounds
                }
                self.cachedRecords = records
                self.trackedWindow = dragging ? (self.windowUnderDragPointer() ?? changed.map { UInt32($0.id) }) : nil
            }
            self.deliverSnapshots(displays: displays, completion: completion)
            self.refreshIcons(displays: displays, now: now, dragging: dragging, completion: completion)
        }
    }

    private func deliverSnapshots(displays: [DisplayGeometry], completion: ([DisplaySnapshot]?) -> Void) {
        let snapshots = Self.snapshots(displays: displays, records: cachedRecords, icons: icons,
                                       dockLayout: dockLayout, preferredDockIDs: preferredDockIDs)
        for snapshot in snapshots {
            preferredDockIDs[snapshot.id] = snapshot.dockWindowID
        }
        completion(snapshots)
    }

    private func refreshIcons(displays: [DisplayGeometry], now: TimeInterval, dragging: Bool,
                              completion: @escaping @MainActor ([DisplaySnapshot]?) -> Void) {
        guard includesDesktopIcons, !iconQueryInFlight,
              now - lastIconQuery >= (dragging ? 0.20 : 1.0) else { return }
        lastIconQuery = now
        let requestGeneration = iconGeneration
        let pid = finderPID
        iconQueryInFlight = true
        // Finder IPC runs separately so slow icon metadata never delays snow geometry.
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                if let pid { return DesktopIconGeometry.read(finderPID: pid) }
                return []
            }.value
            guard let self else { return }
            self.iconQueryInFlight = false
            guard self.iconGeneration == requestGeneration, self.includesDesktopIcons,
                  let result, result != self.icons else { return }
            self.icons = result
            if !self.inFlight {
                self.deliverSnapshots(displays: displays, completion: completion)
            }
        }
    }

    private func windowUnderDragPointer() -> UInt32? {
        let pointer = NSEvent.mouseLocation
        let point = CGPoint(x: pointer.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - pointer.y)
        return cachedRecords.first { record in
            guard record.role == .application || record.role == .widget,
                  record.bounds.insetBy(dx: -12, dy: -12).contains(point) else { return false }
            if record.role == .widget { return true }
            let frame = record.bounds
            return point.y < frame.minY + 40 || point.y > frame.maxY - 12
                || point.x < frame.minX + 12 || point.x > frame.maxX - 12
        }.map { UInt32($0.id) }
    }

    nonisolated private static func read(processRoles: [Int32: DesktopWindowRole],
                                         processBundleIdentifiers: [Int32: String], ownPID: Int32,
                                         target: UInt32?) -> [DesktopWindowRecord] {
        // During a drag, only the selected moving window is queried at display cadence. A full
        // on-screen discovery remains bounded to 10 Hz (2 Hz idle), and requests never overlap.
        let dictionaries: [[String: Any]]
        if let target {
            // Quartz window-ID arrays contain raw integer values, not CFNumber objects.
            // Using IncludingWindow alone is unsupported; description-by-ID avoids generating
            // dictionaries for every window just to follow one moving support.
            let identifiers = CFArrayCreateMutable(kCFAllocatorDefault, 1, nil)!
            CFArrayAppendValue(identifiers, UnsafeRawPointer(bitPattern: UInt(target)))
            dictionaries = CGWindowListCreateDescriptionFromArray(identifiers) as? [[String: Any]] ?? []
        } else {
            dictionaries = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        }
        let onScreen = target == nil ? dictionaries : dictionaries.filter {
            ($0[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue != false
        }
        return DesktopWindowDecoder.decode(metadata: onScreen, processRoles: processRoles,
                                            excludingPID: ownPID,
                                            dockLevel: Int(CGWindowLevelForKey(.dockWindow)),
                                            processBundleIdentifiers: processBundleIdentifiers)
    }

    nonisolated private static func snapshots(displays: [DisplayGeometry],
                                              records: [DesktopWindowRecord], icons: [SceneAnchorTarget],
                                              dockLayout: DockLayoutHint?,
                                              preferredDockIDs: [UInt32: UInt64]) -> [DisplaySnapshot] {
        let spotlightLevels = Dictionary(records.filter { $0.role == .spotlight }.map { ($0.id, $0.layer) },
                                          uniquingKeysWith: { first, _ in first })
        let widgetIDs = Set(records.lazy.filter { $0.role == .widget }.map(\.id))
        return displays.map { display in
            let scene = DesktopSceneBuilder.build(displayBounds: display.bounds, menuInset: display.menuInset,
                                                  windows: records, dockLayout: dockLayout,
                                                  preferredDockID: preferredDockIDs[display.id],
                                                  dockBottomInset: display.dockBottomInset)
            let spotlight = scene.surfaces.compactMap { surface -> SpotlightSnowSupport? in
                guard surface.isElevated, let level = spotlightLevels[surface.id],
                      surface.id <= UInt64(UInt32.max) else { return nil }
                // Window caps have an 18-point physical limit plus an antialiased upper rim.
                let rect = CGRect(x: CGFloat(surface.x) - 1, y: CGFloat(surface.y) - 20,
                                  width: CGFloat(surface.width) + 2,
                                  height: CGFloat(surface.cornerRadius) + 22)
                return SpotlightSnowSupport(windowID: UInt32(surface.id), level: level, capBounds: rect)
            }
            var anchors = scene.bodies.compactMap { body -> SceneAnchorTarget? in
                guard widgetIDs.contains(body.id), body.bounds.width >= 4, body.bounds.height >= 4 else { return nil }
                return SceneAnchorTarget(id: "widget:\(body.id)", kind: .widget, bounds: body.bounds)
            }
            for icon in icons {
                // Prefer the display containing an icon's center to avoid duplicate snap targets.
                guard display.bounds.contains(CGPoint(x: icon.bounds.midX, y: icon.bounds.midY)) else { continue }
                let bounds = icon.bounds.intersection(display.bounds)
                    .offsetBy(dx: -display.bounds.minX, dy: -display.bounds.minY)
                guard bounds.width >= 4, bounds.height >= 4 else { continue }
                anchors.append(SceneAnchorTarget(id: icon.id, kind: .icon, bounds: bounds))
            }
            let desktop = SceneDesktop(id: display.id, size: display.bounds.size,
                                       dock: scene.bodies.first { $0.id == DesktopSceneBuilder.dockID }?.bounds,
                                       anchors: anchors)
            return DisplaySnapshot(id: display.id, surfaces: scene.surfaces, bodies: scene.bodies,
                                   fullscreen: DesktopSceneBuilder.isFullscreen(displayBounds: display.bounds, windows: records),
                                   spotlightSupports: spotlight, dockWindowID: scene.dockWindowID, desktop: desktop)
        }
    }
}
