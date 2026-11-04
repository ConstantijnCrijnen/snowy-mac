import AppKit
import MetalKit

struct SpotlightSnowSupport: Sendable {
    let windowID: UInt32
    let level: Int
    /// Display-local Quartz points enclosing only the attached snow cap.
    let capBounds: CGRect
}

private final class SpotlightSnowPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A cropped presentation of the existing simulation mesh. Drawing is explicitly driven
/// by the main renderer, with no render clock, physics state, particle buffers or queue.
@MainActor
final class SpotlightOverlay: NSObject, MTKViewDelegate {
    let view: MTKView
    private let panel: NSPanel
    private var anchor: SpotlightSnowSupport?
    private var encodeFrame: ((MTLRenderPassDescriptor, CAMetalDrawable) -> Void)?
    private(set) var crop = CGRect.zero
    private(set) var isActive = false
    var logicalArea: CGFloat { crop.width * crop.height }

    init(device: MTLDevice) {
        view = MTKView(frame: .zero, device: device)
        panel = SpotlightSnowPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        super.init()
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.framebufferOnly = true
        view.depthStencilPixelFormat = .invalid
        view.sampleCount = 1
        view.delegate = self
        view.layer?.isOpaque = false
        if let layer = view.layer as? CAMetalLayer {
            layer.isOpaque = false
            layer.maximumDrawableCount = 2
            layer.presentsWithTransaction = false
        }
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true
        panel.contentView = view
    }

    func update(supports: [SpotlightSnowSupport], displayBounds: CGRect, primaryTop: CGFloat) {
        let localDisplay = CGRect(origin: .zero, size: displayBounds.size)
        var union = CGRect.null
        var chosen: SpotlightSnowSupport?
        // Normally Spotlight has one visible panel. Never turn auxiliary/transient panels
        // at distant positions into a second full-display drawable.
        for support in supports.prefix(48) {
            let rect = support.capBounds.intersection(localDisplay).integral
            guard !rect.isNull, !rect.isEmpty,
                  rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else { continue }
            if let chosen, support.level != chosen.level { continue }
            let proposed = union.isNull ? rect : union.union(rect)
            guard proposed.width <= displayBounds.width,
                  proposed.height <= min(128, displayBounds.height) else { continue }
            union = proposed
            if chosen == nil { chosen = support }
        }
        anchor = chosen
        crop = union.isNull ? .zero : union
        guard let chosen, !crop.isEmpty else {
            isActive = false
            panel.orderOut(nil)
            view.releaseDrawables()
            return
        }
        panel.level = NSWindow.Level(rawValue: chosen.level)
        let frame = CGRect(x: displayBounds.minX + crop.minX,
                           y: primaryTop - displayBounds.minY - crop.maxY,
                           width: crop.width, height: crop.height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }

    func apply(show: Bool, scale: CGFloat) {
        isActive = show && anchor != nil && !crop.isEmpty
        if isActive, let anchor {
            let drawableSize = CGSize(width: max(1, (crop.width * scale).rounded(.down)),
                                      height: max(1, (crop.height * scale).rounded(.down)))
            if view.drawableSize != drawableSize { view.drawableSize = drawableSize }
            // Match Spotlight's native level, then place its snow immediately beneath its
            // actual window. Ordinary app windows stay below this small cap strip.
            panel.order(.below, relativeTo: Int(anchor.windowID))
        } else {
            if panel.isVisible { panel.orderOut(nil) }
            view.releaseDrawables()
        }
    }

    func close() {
        isActive = false
        panel.orderOut(nil)
        view.releaseDrawables()
        panel.close()
    }

    /// MTKView advances/releases its current drawable at the end of draw(). Reading
    /// currentDrawable directly from a permanently paused view reuses a presented drawable.
    /// One manual draw per main frame supplies a fresh drawable without another display link.
    func renderFrame(_ encode: @escaping (MTLRenderPassDescriptor, CAMetalDrawable) -> Void) {
        guard isActive else { return }
        encodeFrame = encode
        defer { encodeFrame = nil }
        view.draw()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let encodeFrame,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
        encodeFrame(pass, drawable)
    }
}
