import AppKit
import MetalKit
import SnowCore

@MainActor
final class MetalContext {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let driftPipeline: MTLRenderPipelineState
    let flakePipeline: MTLRenderPipelineState

    init() throws {
        // Avoid waking a discrete GPU just to draw desktop decoration.
        guard let device = MTLCopyAllDevices().first(where: { $0.isLowPower && !$0.isRemovable })
                ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { throw RendererError.unavailable }
        self.device = device
        self.queue = queue
        queue.label = "Snowy shared render queue"
        let library: MTLLibrary
        if let url = Bundle.main.url(forResource: "Snow", withExtension: "metallib") {
            library = try device.makeLibrary(URL: url)
        } else {
            // `swift run` development fallback; packaged apps ship a precompiled library.
            guard let url = Bundle.module.url(forResource: "Snow", withExtension: "metal") else {
                throw RendererError.missingShaders
            }
            library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        }
        func pipeline(vertex: String, fragment: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = vertex
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        driftPipeline = try pipeline(vertex: "driftVertex", fragment: "driftFragment")
        flakePipeline = try pipeline(vertex: "flakeVertex", fragment: "flakeFragment")
    }
}

enum RendererError: Error {
    case unavailable, missingShaders, allocationFailed
}

@MainActor
final class MetalRenderer: NSObject, MTKViewDelegate {
    let simulation: SnowSimulation
    let view: MTKView
    let spotlightOverlay: SpotlightOverlay
    var beforeFrame: ((TimeInterval, SIMD2<Float>?) -> Void)?
    var cursorPosition: (() -> SIMD2<Float>)?
    var onFailure: (() -> Void)?
    private let context: MetalContext
    private let menuInset: Float
    private let inFlight = DispatchSemaphore(value: 2)
    private var lastFrame: TimeInterval?
    private var slotIndex = 0
    private var slots: [Slot] = []

    private struct FrameUniforms {
        var viewport: SIMD2<Float>
        var time: Float
        var padding: Float = 0
    }

    private struct Slot {
        let particles: MTLBuffer
        let mesh: MTLBuffer
        var meshRevision: UInt64 = .max
    }

    init(context: MetalContext, size: CGSize, menuInset: Float, budget: SimulationBudget,
         seed: UInt64) throws {
        self.context = context
        self.menuInset = menuInset
        simulation = SnowSimulation(size: SIMD2(Float(size.width), Float(size.height)), budget: budget, seed: seed)
        view = MTKView(frame: CGRect(origin: .zero, size: size), device: context.device)
        spotlightOverlay = SpotlightOverlay(device: context.device)
        super.init()
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.framebufferOnly = true
        view.depthStencilPixelFormat = .invalid
        view.sampleCount = 1
        view.layer?.isOpaque = false
        if let layer = view.layer as? CAMetalLayer {
            layer.isOpaque = false
            layer.maximumDrawableCount = 2
            layer.presentsWithTransaction = false
        }
        view.delegate = self
        for _ in 0..<2 {
            guard let particles = context.device.makeBuffer(
                length: max(16, budget.flakes * MemoryLayout<ParticleInstance>.stride),
                options: .cpuCacheModeWriteCombined),
                  let mesh = context.device.makeBuffer(
                    length: max(16, budget.maximumSnowVertices * MemoryLayout<SnowVertex>.stride),
                    options: .cpuCacheModeWriteCombined) else { throw RendererError.allocationFailed }
            slots.append(Slot(particles: particles, mesh: mesh))
        }
    }

    func apply(policy: RenderPolicy, scale: CGFloat, paused: Bool) {
        simulation.reducedMotion = policy.reducedMotion
        simulation.particleScale = policy.particleScale
        view.preferredFramesPerSecond = policy.framesPerSecond
        let drawableSize = CGSize(width: max(1, (view.bounds.width * scale).rounded(.down)),
                                  height: max(1, (view.bounds.height * scale).rounded(.down)))
        if view.drawableSize != drawableSize { view.drawableSize = drawableSize }
        if view.isPaused != paused {
            lastFrame = nil
            simulation.resetPointer()
            view.isPaused = paused
        }
        if paused { view.releaseDrawables() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // A busy GPU drops a decorative frame; it never stalls the main thread on our buffers.
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var submitted = false
        defer { if !submitted { inFlight.signal() } }
        let now = CACurrentMediaTime()
        let cursor = cursorPosition?()
        beforeFrame?(now, cursor)
        let dt = Float(lastFrame.map { now - $0 } ?? (1 / Double(view.preferredFramesPerSecond)))
        lastFrame = now
        simulation.step(dt: dt, cursor: cursor)

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = context.queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let slot = slots[slotIndex]
        let count = simulation.flakes.count
        let particles = slot.particles.contents().bindMemory(to: ParticleInstance.self,
                                                            capacity: max(1, count))
        var offset = 0
        for particle in simulation.flakes { particles[offset] = ParticleInstance(particle); offset += 1 }
        if count > 0, slot.particles.storageMode == .managed {
            slot.particles.didModifyRange(0..<(count * MemoryLayout<ParticleInstance>.stride))
        }
        if slot.meshRevision != simulation.meshRevision {
            simulation.mesh.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress, bytes.count > 0 {
                    slot.mesh.contents().copyMemory(from: base, byteCount: bytes.count)
                }
            }
            if !simulation.mesh.isEmpty, slot.mesh.storageMode == .managed {
                slot.mesh.didModifyRange(0..<(simulation.mesh.count * MemoryLayout<SnowVertex>.stride))
            }
            slots[slotIndex].meshRevision = simulation.meshRevision
        }
        var uniforms = FrameUniforms(viewport: simulation.size, time: Float(now.truncatingRemainder(dividingBy: 3600)))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        let top = min(Int(view.drawableSize.height) - 1,
                      max(0, Int(CGFloat(menuInset) * view.drawableSize.height / max(1, view.bounds.height))))
        encoder.setScissorRect(MTLScissorRect(x: 0, y: top, width: Int(view.drawableSize.width),
                                             height: Int(view.drawableSize.height) - top))
        if !simulation.mesh.isEmpty {
            encoder.setRenderPipelineState(context.driftPipeline)
            encoder.setVertexBuffer(slot.mesh, offset: 0, index: 0)
            // Elevated Spotlight caps are presented once in their cropped foreground pass.
            // Every other cap and all transported material stay on the desktop plane.
            var start = 0
            for range in simulation.elevatedMeshRanges {
                let lower = max(start, min(simulation.mesh.count, range.lowerBound))
                if lower > start {
                    encoder.drawPrimitives(type: .triangle, vertexStart: start, vertexCount: lower - start)
                }
                start = max(start, min(simulation.mesh.count, range.upperBound))
            }
            if start < simulation.mesh.count {
                encoder.drawPrimitives(type: .triangle, vertexStart: start, vertexCount: simulation.mesh.count - start)
            }
        }
        if count > 0 {
            encoder.setRenderPipelineState(context.flakePipeline)
            encoder.setVertexBuffer(slot.particles, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
        }
        encoder.endEncoding()
        command.present(drawable)
        encodeSpotlight(command: command, mesh: slot.mesh, uniforms: uniforms)
        let semaphore = inFlight
        command.addCompletedHandler { [weak self] completed in
            semaphore.signal()
            if completed.status == .error {
                Task { @MainActor in self?.onFailure?() }
            }
        }
        submitted = true
        slotIndex = (slotIndex + 1) % slots.count
        command.commit()
    }

    private func encodeSpotlight(command: MTLCommandBuffer, mesh: MTLBuffer, uniforms: FrameUniforms) {
        guard spotlightOverlay.isActive else { return }
        let foreground = spotlightOverlay.view
        let crop = spotlightOverlay.crop
        guard crop.width > 0, crop.height > 0 else { return }
        spotlightOverlay.renderFrame { [self] pass, drawable in
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            // Keep the existing global-coordinate mesh and shader projection. A shifted
            // viewport maps only the cap strip, without a second CPU/GPU mesh.
            let scaleX = foreground.drawableSize.width / crop.width
            let scaleY = foreground.drawableSize.height / crop.height
            encoder.setViewport(MTLViewport(originX: Double(-crop.minX * scaleX),
                                            originY: Double(-crop.minY * scaleY),
                                            width: Double(CGFloat(simulation.size.x) * scaleX),
                                            height: Double(CGFloat(simulation.size.y) * scaleY),
                                            znear: 0, zfar: 1))
            encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: Int(foreground.drawableSize.width),
                                                 height: Int(foreground.drawableSize.height)))
            var frame = uniforms
            encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.setRenderPipelineState(context.driftPipeline)
            encoder.setVertexBuffer(mesh, offset: 0, index: 0)
            for range in simulation.elevatedMeshRanges {
                let lower = max(0, min(simulation.mesh.count, range.lowerBound))
                let upper = max(lower, min(simulation.mesh.count, range.upperBound))
                if upper > lower {
                    encoder.drawPrimitives(type: .triangle, vertexStart: lower, vertexCount: upper - lower)
                }
            }
            encoder.endEncoding()
            command.present(drawable)
        }
    }
}
