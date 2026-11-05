@preconcurrency import ApplicationServices
import CryptoKit
import Foundation

/// Finder's desktop scroll area can expose the frames of individual icons
/// through public Accessibility APIs. Only use this source after opt-in.
enum DesktopIconGeometry {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Call only from an explicit user action. The permission dialog is async.
    @MainActor static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Returns global top-down points, in the same coordinates as WindowServer.
    /// A transient messaging failure leaves the last good snapshot in use.
    static func read(finderPID: pid_t) -> [SceneAnchorTarget]? {
        guard isTrusted else { return [] }
        let finder = AXUIElementCreateApplication(finderPID)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.12
        guard let rootChildren = children(of: finder, maximum: 32) else { return nil }
        var desktop = scrollArea(in: rootChildren, deadline: deadline)
        if desktop == nil, ProcessInfo.processInfo.systemUptime < deadline,
           let windows = children(of: finder, attribute: kAXWindowsAttribute, maximum: 32) {
            desktop = scrollArea(in: windows, deadline: deadline)
        }
        guard let desktop else { return ProcessInfo.processInfo.systemUptime < deadline ? [] : nil }
        guard let desktopChildren = children(of: desktop, maximum: 96) else { return nil }
        var queue = desktopChildren.map { (element: $0, depth: 0) }
        var icons: [SceneAnchorTarget] = []
        var identifiers: Set<String> = []
        var index = 0
        while index < queue.count && icons.count < 64 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let node = queue[index]
            index += 1
            guard let values = iconValues(of: node.element) else { return nil }
            let role = values.first as? String
            let image = role == kAXImageRole || role == "AXIcon"
            let fileGroup = role == kAXGroupRole && values.count > 3 && (values[3] as? URL)?.isFileURL == true
            if image || fileGroup, let bounds = bounds(from: values), let id = identifier(from: values) {
                if identifiers.insert(id).inserted {
                    icons.append(SceneAnchorTarget(id: id, kind: .icon, bounds: bounds))
                }
            } else if node.depth < 3, queue.count < 96,
                      role == kAXGroupRole || role == kAXLayoutAreaRole || role == kAXScrollAreaRole {
                guard let descendants = children(of: node.element, maximum: 96 - queue.count) else { return nil }
                queue.append(contentsOf: descendants.map { ($0, node.depth + 1) })
            }
        }
        return icons
    }

    private static func scrollArea(in elements: [AXUIElement], deadline: TimeInterval) -> AXUIElement? {
        elements.first {
            ProcessInfo.processInfo.systemUptime < deadline && role(of: $0) == kAXScrollAreaRole
        }
    }

    private static func children(of element: AXUIElement, attribute: String = kAXChildrenAttribute,
                                 maximum: Int) -> [AXUIElement]? {
        _ = AXUIElementSetMessagingTimeout(element, 0.05)
        var result: CFArray?
        let error = AXUIElementCopyAttributeValues(element, attribute as CFString, 0, maximum, &result)
        if error == .attributeUnsupported || error == .noValue || error == .invalidUIElement { return [] }
        guard error == .success else { return nil }
        return result as? [AXUIElement] ?? []
    }

    private static func role(of element: AXUIElement) -> String? {
        _ = AXUIElementSetMessagingTimeout(element, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func iconValues(of element: AXUIElement) -> [Any]? {
        _ = AXUIElementSetMessagingTimeout(element, 0.05)
        let attributes = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute,
                          kAXURLAttribute, kAXIdentifierAttribute] as CFArray
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values)
        if error == .invalidUIElement { return [] }
        guard error == .success else { return nil }
        return values as? [Any] ?? []
    }

    private static func bounds(from values: [Any]) -> CGRect? {
        guard values.count == 5 else { return nil }
        let point = values[1] as CFTypeRef
        let size = values[2] as CFTypeRef
        guard CFGetTypeID(point) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        // The type checks above establish that these CF references are AXValues.
        guard AXValueGetValue(point as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              origin.x.isFinite, origin.y.isFinite,
              (6...256).contains(dimensions.width), (6...256).contains(dimensions.height) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    private static func identifier(from values: [Any]) -> String? {
        let identity = (values[3] as? URL)?.absoluteString ?? (values[4] as? String)
        guard let identity, !identity.isEmpty, identity.utf8.count <= 8_192 else { return nil }
        // Geometry snapshots and persisted light anchors never carry a filename or URL.
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "icon:" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
