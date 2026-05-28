import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import Metal
import PreemCore
import PolymergePlayback

/// Offline (pull-mode) compositor for a `Sequence`. Single source of
/// truth for "what pixel buffer does the program viewer show at time T",
/// independent of the realtime PPE display-link path.
///
/// **Composition rules** (matching the realtime path's user-visible behavior,
/// minus the pre-warm + handover-tail tricks PPE needs to hide its decoder
/// latency — offline doesn't need those because we wait for every frame):
///
/// - For each video track bottom-up, find the contribution at time T.
/// - Single clip with no fade        → frame at full opacity.
/// - Single clip with solo fade      → frame at fade-ramp opacity; underlying
///                                     layers show through.
/// - Two abutting clips A and B with paired cross-dissolve transitions →
///   the dissolve window paints `mix(A, B, progress)` as a single opaque
///   layer; underlying layers are hidden through the dissolve.
/// - Over-blending top onto bottom: `top * alpha + bottom * (1 - alpha)`.
///
/// **Pull mode** uses one `AVAssetFrameSource` per `ClipID`, cached for the
/// compositor's lifetime; encoders typically run sequentially within a few
/// clips so the seek-cache stays warm.
public final class OfflineSequenceCompositor {

    public enum CompositorError: Error, LocalizedError {
        case noMetalDevice
        case textureCacheCreate(Int32)
        case pixelBufferPoolCreate(Int32)
        case pixelBufferAllocFailed(Int32)
        case textureBindingFailed
        case shaderCompile(String)
        case pipelineCreate(String)
        case noSourceForClip(ClipID)
        case frameSourceLoadFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noMetalDevice:                 return "No Metal device available."
            case .textureCacheCreate(let s):     return "CVMetalTextureCacheCreate failed (\(s))."
            case .pixelBufferPoolCreate(let s):  return "CVPixelBufferPoolCreate failed (\(s))."
            case .pixelBufferAllocFailed(let s): return "CVPixelBufferPoolCreatePixelBuffer failed (\(s))."
            case .textureBindingFailed:          return "CVMetalTextureCacheCreateTextureFromImage failed."
            case .shaderCompile(let s):          return "Compositor shader did not compile: \(s)"
            case .pipelineCreate(let s):         return "Compositor pipeline did not link: \(s)"
            case .noSourceForClip(let id):       return "No source in media pool for clip \(id.rawValue.uuidString)."
            case .frameSourceLoadFailed(let s):  return "Frame source failed to load: \(s)"
            }
        }
    }

    // MARK: - Config

    /// Sequence + media pool are mutable so the realtime host can
    /// refresh them on each tick — transform/effect/clip mutations
    /// must flow into the compositor without a full teardown/rebuild
    /// (which would trash the Metal pipeline + scratch pool). Output
    /// resolution + Metal state are immutable; spec-changing rebuilds
    /// happen at the host level.
    public var sequence: Sequence
    public var mediaPool: MediaPool
    public let outputWidth: Int
    public let outputHeight: Int

    // MARK: - Metal

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let blendPipeline: MTLRenderPipelineState
    private let blackPipeline: MTLRenderPipelineState
    private let crossDissolvePipeline: MTLRenderPipelineState
    /// Scratch pool for intermediate layer accumulation. Sized small
    /// (~4 buffers) because at any one time we hold the running
    /// accumulator plus, for cross-dissolves, one combined-AB temp.
    /// The encoder's adaptor pool — bounded by `minimumBufferCount` —
    /// is used for the final composed output instead, so the encoder
    /// can back-pressure us through pool starvation when the hardware
    /// encoder gets behind.
    private let scratchPool: CVPixelBufferPool

    // MARK: - Frame source pool

    private var frameSources: [ClipID: AVAssetFrameSource] = [:]
    private var lastSourceTime: [ClipID: Double] = [:]

    public init(
        sequence: Sequence,
        mediaPool: MediaPool,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil
    ) throws {
        self.sequence = sequence
        self.mediaPool = mediaPool
        self.outputWidth  = outputWidth  ?? sequence.settings.resolution.width
        self.outputHeight = outputHeight ?? sequence.settings.resolution.height

        guard let device = PreemRender.device else { throw CompositorError.noMetalDevice }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw CompositorError.noMetalDevice }
        self.commandQueue = queue

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let cache else {
            throw CompositorError.textureCacheCreate(cacheStatus)
        }
        self.textureCache = cache

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw CompositorError.shaderCompile(error.localizedDescription)
        }
        guard
            let vertexFn   = library.makeFunction(name: "compositorQuadVertex"),
            let blendFn    = library.makeFunction(name: "compositorBlendFragment"),
            let blackFn    = library.makeFunction(name: "compositorBlackFragment"),
            let xfadeFn    = library.makeFunction(name: "compositorCrossDissolveFragment")
        else {
            throw CompositorError.pipelineCreate("missing shader functions")
        }

        let blendDesc = MTLRenderPipelineDescriptor()
        blendDesc.vertexFunction = vertexFn
        blendDesc.fragmentFunction = blendFn
        blendDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            self.blendPipeline = try device.makeRenderPipelineState(descriptor: blendDesc)
        } catch {
            throw CompositorError.pipelineCreate(error.localizedDescription)
        }

        let blackDesc = MTLRenderPipelineDescriptor()
        blackDesc.vertexFunction = vertexFn
        blackDesc.fragmentFunction = blackFn
        blackDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            self.blackPipeline = try device.makeRenderPipelineState(descriptor: blackDesc)
        } catch {
            throw CompositorError.pipelineCreate(error.localizedDescription)
        }

        let xfadeDesc = MTLRenderPipelineDescriptor()
        xfadeDesc.vertexFunction = vertexFn
        xfadeDesc.fragmentFunction = xfadeFn
        xfadeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            self.crossDissolvePipeline = try device.makeRenderPipelineState(descriptor: xfadeDesc)
        } catch {
            throw CompositorError.pipelineCreate(error.localizedDescription)
        }

        let poolAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: self.outputWidth,
            kCVPixelBufferHeightKey as String: self.outputHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        // Cap scratch at 6 buffers — 2 ping-pong accumulators + 1
        // cross-dissolve temp + headroom. If we ever exceed this, the
        // pool fails fast instead of growing unbounded.
        let poolOpts: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 6,
        ]
        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(nil, poolOpts as CFDictionary, poolAttrs as CFDictionary, &pool)
        guard poolStatus == kCVReturnSuccess, let pool else {
            throw CompositorError.pixelBufferPoolCreate(poolStatus)
        }
        self.scratchPool = pool
    }

    public func teardown() {
        for fs in frameSources.values { fs.tearDown() }
        frameSources.removeAll()
        lastSourceTime.removeAll()
        lastDeliveredFrame.removeAll()
    }

    deinit {
        for fs in frameSources.values { fs.tearDown() }
    }

    /// Drop the per-frame CVMetalTexture entries so any backing pixel
    /// buffers can return to their pool. The encoder calls this when
    /// the adaptor's pool reports a transient allocation cap so the
    /// next pool fetch succeeds.
    public func flushTextureCache() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    /// Aspect-fit a single source pixel buffer (e.g. a pre-render cache
    /// frame) into an output `MTLTexture`. Used by the realtime host's
    /// cache fast-path so cache playback letterboxes correctly into a
    /// drawable of any size. Reuses the blend pipeline with a black
    /// "bottom" and the source frame as "top".
    public func presentSingleSourceFrame(
        _ source: CVPixelBuffer,
        into output: MTLTexture
    ) {
        let srcW = CVPixelBufferGetWidth(source)
        let srcH = CVPixelBufferGetHeight(source)
        let dstW = output.width
        let dstH = output.height
        guard srcW > 0, srcH > 0, dstW > 0, dstH > 0 else { return }

        // Aspect-preserving fit of source into dest.
        let srcAspect = Double(srcW) / Double(srcH)
        let dstAspect = Double(dstW) / Double(dstH)
        var fitW = Double(dstW)
        var fitH = Double(dstH)
        if srcAspect > dstAspect {
            fitH = Double(dstW) / srcAspect
        } else {
            fitW = Double(dstH) * srcAspect
        }
        let minU = (Double(dstW) - fitW) / 2.0 / Double(dstW)
        let minV = (Double(dstH) - fitH) / 2.0 / Double(dstH)
        let maxU = 1.0 - minU
        let maxV = 1.0 - minV
        let uniforms = LayerUniforms(
            destRect: SIMD4<Float>(Float(minU), Float(minV), Float(maxU), Float(maxV)),
            cropRect: SIMD4<Float>(0, 0, 1, 1),
            opacity: SIMD4<Float>(1, 0, 0, 0),
            rotation: SIMD4<Float>(1, 0, 0, 0)
        )

        guard let cmd = commandQueue.makeCommandBuffer() else { return }
        // Pool buffer for the black "bottom" — the blend shader does
        // (bottom * (1-α)) + (top * α) at α=1, so the bottom would be
        // irrelevant for the destRect, but it IS what we want in the
        // letterbox region. Black bars there.
        guard let bottom = try? allocScratch() else { return }
        encodeBlackFill(into: bottom, on: cmd)
        encodeBlend(
            bottom: bottom, top: source,
            uniforms: uniforms,
            intoTexture: output, on: cmd
        )
        cmd.commit()
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    /// Compose the frame visible at `timelineSeconds` directly into the
    /// caller-supplied `output` buffer. The caller owns the buffer
    /// (typically vended from `AVAssetWriterInputPixelBufferAdaptor`'s
    /// bounded pool), so the compositor doesn't manage output lifetime.
    /// Intermediates for multi-layer / cross-dissolve composition come
    /// from the compositor's internal scratch pool.
    ///
    /// All blend passes share a single `MTLCommandBuffer` and the
    /// final commit deliberately does NOT `waitUntilCompleted`:
    /// AVAssetWriter / VideoToolbox honor IOSurface use-counts so the
    /// encoder waits for the GPU write to land before reading. Saves
    /// 8–15 ms per 4K frame.
    ///
    /// Safe to call from a serial dispatch queue (the encoder's video
    /// pump). Internal state is confined to the compositor instance;
    /// the only cross-thread surface is the texture cache, which Apple
    /// documents as thread-safe.
    public func compose(at timelineSeconds: Double, into output: CVPixelBuffer) throws {
        let layers = try syncEffectiveLayers(at: timelineSeconds)

        guard let cmd = commandQueue.makeCommandBuffer() else {
            throw CompositorError.textureBindingFailed
        }

        if layers.isEmpty {
            encodeBlackFill(into: output, on: cmd)
            cmd.commit()
            return
        }

        // First scratch buffer holds the running accumulator. We
        // black-fill it, then blend each layer onto it. The LAST layer's
        // blend writes directly into `output` to avoid a final copy.
        var acc = try allocScratch()
        encodeBlackFill(into: acc, on: cmd)

        for (idx, layer) in layers.enumerated() {
            let isLast = idx == layers.count - 1
            let dst: CVPixelBuffer = isLast ? output : try allocScratch()
            switch layer {
            case .single(let frame, let uniforms):
                encodeBlend(bottom: acc, top: frame, uniforms: uniforms, into: dst, on: cmd)
            case .crossDissolve(let aF, let aU, let bF, let bU, let progress):
                encodeCrossDissolve(
                    acc: acc, a: aF, aUniforms: aU, b: bF, bUniforms: bU,
                    progress: progress, into: dst, on: cmd
                )
            }
            acc = dst
        }

        cmd.commit()
        // No waitUntilCompleted — IOSurface fences carry the sync to AVF.
    }

    /// Uniforms for a layer that fills the whole output with the whole
    /// source (no aspect-fit, no crop). Used inside cross-dissolve's
    /// pure-mix sub-pass — both A and B already arrive as source-sized
    /// pixel buffers, and the dissolved result is then placed via the
    /// layer's real transform in the second blend pass.
    static func identityUniforms(opacity: Float) -> LayerUniforms {
        LayerUniforms(
            destRect: SIMD4<Float>(0, 0, 1, 1),
            cropRect: SIMD4<Float>(0, 0, 1, 1),
            opacity: SIMD4<Float>(opacity, 0, 0, 0),
            rotation: SIMD4<Float>(1, 0, 0, 0)
        )
    }

    /// Async variant of `compose(at:into outputTexture:)`. Used by the
    /// realtime host so the per-frame work never blocks the main actor.
    /// The sync version (which goes through `syncEffectiveLayers`) is
    /// kept for the encoder, whose pump already runs on its own
    /// dispatch queue and can block freely.
    ///
    /// **Two-pass**: composes into a sequence-resolution scratch
    /// buffer, then aspect-fits that buffer into the drawable. Without
    /// this, a non-matching view aspect (any time the user resizes the
    /// program viewer) would stretch the picture — the layer destRects
    /// are in sequence UV space, not drawable UV space.
    public func composeAsync(at timelineSeconds: Double, into outputTexture: MTLTexture) async throws {
        let layers = try await effectiveLayers(at: timelineSeconds)

        if layers.isEmpty {
            guard let cmd = commandQueue.makeCommandBuffer() else {
                throw CompositorError.textureBindingFailed
            }
            encodeBlackFill(intoTexture: outputTexture, on: cmd)
            cmd.commit()
            return
        }

        // Pass 1: compose at sequence resolution.
        let composed = try allocScratch()
        try renderLayersIntoBuffer(layers, into: composed)

        // Pass 2: aspect-fit the composed frame into the drawable.
        // Letterboxes / pillarboxes the entire sequence picture when
        // the drawable aspect doesn't match.
        presentSingleSourceFrame(composed, into: outputTexture)
    }

    /// Layer-encoding pass that targets a CVPixelBuffer. Used by
    /// composeAsync and the encoder; mirrors the MTLTexture variant
    /// (renderLayers) byte for byte.
    private func renderLayersIntoBuffer(
        _ layers: [LayerContribution],
        into output: CVPixelBuffer
    ) throws {
        guard let cmd = commandQueue.makeCommandBuffer() else {
            throw CompositorError.textureBindingFailed
        }

        if layers.isEmpty {
            encodeBlackFill(into: output, on: cmd)
            cmd.commit()
            return
        }

        var acc = try allocScratch()
        encodeBlackFill(into: acc, on: cmd)

        for (idx, layer) in layers.enumerated() {
            let isLast = idx == layers.count - 1
            let dst: CVPixelBuffer = isLast ? output : try allocScratch()
            switch layer {
            case .single(let frame, let uniforms):
                encodeBlend(bottom: acc, top: frame, uniforms: uniforms, into: dst, on: cmd)
            case .crossDissolve(let aF, let aU, let bF, let bU, let progress):
                encodeCrossDissolve(
                    acc: acc, a: aF, aUniforms: aU, b: bF, bUniforms: bU,
                    progress: progress, into: dst, on: cmd
                )
            }
            acc = dst
        }
        cmd.commit()
    }

    /// Compose into an MTLTexture (typically a `CAMetalLayer.nextDrawable()`
    /// texture). Used by the realtime program viewer. The texture's
    /// dimensions don't need to match the compositor's output size —
    /// the shader maps source UVs through `destRect`, so a 1920×1080
    /// compositor can paint into a different-sized drawable cleanly.
    public func compose(at timelineSeconds: Double, into outputTexture: MTLTexture) throws {
        let layers = try syncEffectiveLayers(at: timelineSeconds)
        try renderLayers(layers, into: outputTexture)
    }

    private func renderLayers(_ layers: [LayerContribution], into outputTexture: MTLTexture) throws {
        guard let cmd = commandQueue.makeCommandBuffer() else {
            throw CompositorError.textureBindingFailed
        }

        if layers.isEmpty {
            encodeBlackFill(intoTexture: outputTexture, on: cmd)
            cmd.commit()
            return
        }

        // Build the accumulator in a pool buffer, then write the last
        // layer's blend directly into the drawable's texture.
        var acc = try allocScratch()
        encodeBlackFill(into: acc, on: cmd)

        for (idx, layer) in layers.enumerated() {
            let isLast = idx == layers.count - 1
            switch (layer, isLast) {
            case (.single(let frame, let uniforms), true):
                encodeBlend(bottom: acc, top: frame, uniforms: uniforms, intoTexture: outputTexture, on: cmd)
            case (.single(let frame, let uniforms), false):
                let next = try allocScratch()
                encodeBlend(bottom: acc, top: frame, uniforms: uniforms, into: next, on: cmd)
                acc = next
            case (.crossDissolve(let aF, let aU, let bF, let bU, let progress), true):
                encodeCrossDissolve(
                    acc: acc, a: aF, aUniforms: aU, b: bF, bUniforms: bU,
                    progress: progress, intoTexture: outputTexture, on: cmd
                )
            case (.crossDissolve(let aF, let aU, let bF, let bU, let progress), false):
                let next = try allocScratch()
                encodeCrossDissolve(
                    acc: acc, a: aF, aUniforms: aU, b: bF, bUniforms: bU,
                    progress: progress, into: next, on: cmd
                )
                acc = next
            }
        }

        cmd.commit()
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    /// Convenience overload kept for callers (tests, playback
    /// substitution preview) that want to own the output buffer too.
    /// Allocates from the internal scratch pool, used as the "default
    /// output" pool when the caller doesn't have one.
    public func compose(at timelineSeconds: Double) async throws -> CVPixelBuffer {
        let buf = try allocScratch()
        try compose(at: timelineSeconds, into: buf)
        // Block on completion of the most recent command buffer for
        // callers that read CPU-side immediately (no encoder fence to
        // ride on).
        if let cmd = commandQueue.makeCommandBuffer() {
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        return buf
    }

    /// Synchronous variant of `effectiveLayers` — same pull-mode source
    /// access but wrapped in a `DispatchSemaphore` so it can run inside
    /// the encoder's serial dispatch queue without bouncing through
    /// `await`. The frame source's internal queue is async-safe; we
    /// just need a synchronous shell.
    private func syncEffectiveLayers(at t: Double) throws -> [LayerContribution] {
        var result: Result<[LayerContribution], Error> = .success([])
        let sem = DispatchSemaphore(value: 0)
        Task.detached { [weak self] in
            guard let self else { sem.signal(); return }
            do {
                let r = try await self.effectiveLayers(at: t)
                result = .success(r)
            } catch {
                result = .failure(error)
            }
            sem.signal()
        }
        sem.wait()
        switch result {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }

    // MARK: - Layer enumeration

    /// GPU-side uniforms passed to the blend shader for each layer.
    /// All fields are float4 to keep alignment unambiguous between MSL
    /// and Swift's SIMD types. Total 64 bytes.
    ///
    /// - `destRect`: (minU, minV, maxU, maxV) in output UV. Carries the
    ///   layer's placement (letterbox / pillarbox / Transform effect).
    /// - `cropRect`: (minU, minV, maxU, maxV) in source UV. Carries the
    ///   crop window applied before fit.
    /// - `opacity`: `.x` is the layer's effective alpha (fade + clip
    ///   opacity multiplied).
    /// - `rotation`: `.x` is `cosθ`, `.y` is `sinθ` — pre-computed CPU-
    ///   side so the shader doesn't have to call sin/cos per fragment.
    ///   `.z` is the destRect's PIXEL aspect (fitW / fitH); the shader
    ///   uses it to keep rotation pixel-correct so a square stays
    ///   square. Rotation is applied around the destRect's center.
    public struct LayerUniforms {
        public var destRect: SIMD4<Float>
        public var cropRect: SIMD4<Float>
        public var opacity:  SIMD4<Float>
        public var rotation: SIMD4<Float>

        public init(
            destRect: SIMD4<Float>,
            cropRect: SIMD4<Float>,
            opacity: SIMD4<Float>,
            rotation: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 0)
        ) {
            self.destRect = destRect
            self.cropRect = cropRect
            self.opacity = opacity
            self.rotation = rotation
        }
    }

    /// What the compositor renders on one video track at one time.
    private enum LayerContribution {
        case single(CVPixelBuffer, LayerUniforms)
        /// Two paired-transition clips cross-dissolved. Each clip
        /// carries its own transform uniforms so the shader can
        /// aspect-fit A and B independently — the dissolve math
        /// produces the correct `(1-p)*A + p*B` blend wherever both
        /// rects overlap, and lets the underlying layer show through
        /// in the regions only one clip covers (when their destRects
        /// differ, e.g. a 4:3 clip dissolving to a 16:9 clip).
        case crossDissolve(
            aFrame: CVPixelBuffer, aUniforms: LayerUniforms,
            bFrame: CVPixelBuffer, bUniforms: LayerUniforms,
            progress: Double
        )
    }

    /// GPU-side uniforms for the alpha-aware cross-dissolve shader.
    /// 112 bytes: A and B each get a full set of transform fields
    /// (destRect / cropRect / rotation), plus a `weights` float4
    /// carrying the pre-computed dissolve weights (`x = A_opacity *
    /// (1-progress)`, `y = B_opacity * progress`).
    public struct CrossDissolveUniforms {
        public var aDestRect: SIMD4<Float>
        public var aCropRect: SIMD4<Float>
        public var aRotation: SIMD4<Float>
        public var bDestRect: SIMD4<Float>
        public var bCropRect: SIMD4<Float>
        public var bRotation: SIMD4<Float>
        public var weights:  SIMD4<Float>   // .x = wA, .y = wB; rest reserved
    }

    private func effectiveLayers(at t: Double) async throws -> [LayerContribution] {
        var layers: [LayerContribution] = []
        let probe = RationalTime(value: Int64(t * 1000), scale: 1000)

        // Bottom-up: V1 first, V2 on top, etc.
        for track in sequence.videoTracks {
            if let xfade = try await crossDissolveContribution(track: track, t: t) {
                layers.append(xfade)
                continue
            }
            if let clip = track.clips.first(where: { $0.timelineRange.contains(probe) }),
               let source = mediaPool.clips[clip.sourceClipID] {
                let fade = layerAlpha(for: clip, at: t, in: track)
                let shift = pairedFadeInSourceShift(for: clip, in: track)
                let clipLocal = t - clip.timelineRange.start.seconds
                let sourceTime = clip.sourceRange.start.seconds + clipLocal + shift
                let frame = try await pullFrame(source: source, atSourceTime: sourceTime)
                let uniforms = layerUniforms(for: clip, source: source, fadeAlpha: fade, clipLocalSeconds: clipLocal)
                layers.append(.single(frame, uniforms))
            }
        }
        return layers
    }

    /// Compute the shader uniforms for a single layer: aspect-fit
    /// (letterbox/pillarbox) by default, with the clip's Transform +
    /// Crop effects applied. Returns `LayerUniforms` ready for the
    /// blend shader.
    private func layerUniforms(
        for clip: PlacedClip, source: ClipSource, fadeAlpha: Double, clipLocalSeconds: Double
    ) -> LayerUniforms {
        let xform = clip.transform(at: clipLocalSeconds)

        // Source pixel dimensions (fall back to output if missing).
        let srcW: Double
        let srcH: Double
        if let v = source.videoTracks.first {
            srcW = Double(v.resolution.width)
            srcH = Double(v.resolution.height)
        } else {
            srcW = Double(outputWidth)
            srcH = Double(outputHeight)
        }

        // Crop in source UV. `cropLeft` etc. are 0…1 fractions to cut
        // from each side. The visible source rect is the inner box.
        // Crop does NOT change destRect — the picture stays where it
        // would be without the crop, and the cropped edges become
        // transparent (showing the layer below). That's Premiere's
        // model and matches user intuition: cropping the top doesn't
        // also pillarbox the picture.
        let cropL = max(0.0, min(1.0, xform.cropLeft))
        let cropT = max(0.0, min(1.0, xform.cropTop))
        let cropR = max(0.0, min(1.0 - cropL, xform.cropRight))
        let cropB = max(0.0, min(1.0 - cropT, xform.cropBottom))

        // Aspect-fit the FULL source into the output (ignoring crop),
        // then apply user scale on top.
        let outW = Double(outputWidth)
        let outH = Double(outputHeight)
        var fitW: Double
        var fitH: Double
        if xform.stretchToFill || srcW <= 0 || srcH <= 0 {
            fitW = outW
            fitH = outH
        } else {
            let fit = min(outW / srcW, outH / srcH)
            fitW = srcW * fit
            fitH = srcH * fit
        }
        fitW *= xform.scaleX
        fitH *= xform.scaleY

        // Position: 0 = centered, ±1 = full sequence width/height shift.
        let centerX = outW * 0.5 + xform.positionX * outW
        let centerY = outH * 0.5 + xform.positionY * outH

        let minPxX = centerX - fitW * 0.5
        let minPxY = centerY - fitH * 0.5
        let maxPxX = centerX + fitW * 0.5
        let maxPxY = centerY + fitH * 0.5

        let destRect = SIMD4<Float>(
            Float(minPxX / outW), Float(minPxY / outH),
            Float(maxPxX / outW), Float(maxPxY / outH)
        )
        let cropRect = SIMD4<Float>(
            Float(cropL), Float(cropT),
            Float(1.0 - cropR), Float(1.0 - cropB)
        )
        let opacity = max(0, min(1, xform.opacity * fadeAlpha))
        let radians = xform.rotationDegrees * .pi / 180.0
        // Pixel aspect of destRect — the shader uses this to make
        // rotation behave as a pure pixel-space rotation. Without
        // this correction the rotation appears to squish because the
        // destRect's UV ratio (often 1:1 inside a non-square output)
        // doesn't match its true pixel aspect.
        let destPxW = fitW
        let destPxH = max(1.0, fitH)
        let destPixelAspect = destPxW / destPxH
        let rotation = SIMD4<Float>(
            Float(cos(radians)), Float(sin(radians)),
            Float(destPixelAspect), 0
        )
        // Crop feather as a fraction of the source UV space — we
        // express it relative to source UV (0..1) so the shader's
        // distance test against cropRect is in the same units.
        let feather = max(0, min(0.5, xform.cropFeather))
        return LayerUniforms(
            destRect: destRect, cropRect: cropRect,
            opacity: SIMD4<Float>(Float(opacity), Float(feather), 0, 0),
            rotation: rotation
        )
    }

    /// If a paired cross-dissolve straddles `t` on this track, return
    /// the contribution; otherwise nil. Source-time shift for B matches
    /// the realtime path's `playbackShiftForPairedFadeIn`.
    private func crossDissolveContribution(track: VideoTrack, t: Double) async throws -> LayerContribution? {
        let sorted = track.clips.sorted { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        guard sorted.count >= 2 else { return nil }

        for i in 0..<(sorted.count - 1) {
            let a = sorted[i]
            let b = sorted[i + 1]
            guard abs(a.timelineRange.end.seconds - b.timelineRange.start.seconds) < 0.001 else { continue }
            guard let tOut = a.transitionOut,
                  let tIn  = b.transitionIn,
                  tOut.kind == tIn.kind
            else { continue }
            let leftHalf  = tOut.duration.seconds
            let rightHalf = tIn.duration.seconds
            let total = leftHalf + rightHalf
            guard total > 0 else { continue }
            let cutT = a.timelineRange.end.seconds
            let start = cutT - leftHalf
            let end   = cutT + rightHalf
            guard t >= start, t <= end else { continue }

            guard let sa = mediaPool.clips[a.sourceClipID],
                  let sb = mediaPool.clips[b.sourceClipID]
            else { continue }

            let aClipLocal = t - a.timelineRange.start.seconds
            let bClipLocal = t - b.timelineRange.start.seconds
            let aSourceTime = a.sourceRange.start.seconds + aClipLocal
            let bSourceTime = b.sourceRange.start.seconds + (t - start)   // shift = leftHalf
            let progress = (t - start) / total

            let aFrame = try await pullFrame(source: sa, atSourceTime: aSourceTime)
            let bFrame = try await pullFrame(source: sb, atSourceTime: bSourceTime)
            // Each clip carries its own transform — the alpha-aware
            // cross-dissolve shader uses both A's and B's destRect /
            // cropRect to mix them at the correct aspect (no squishing
            // B into A's box). Solo fades on these clips are inside the
            // dissolve window already covered by the dissolve curve
            // itself, so we don't multiply in `layerAlpha` here.
            let aUniforms = layerUniforms(for: a, source: sa, fadeAlpha: 1.0, clipLocalSeconds: aClipLocal)
            let bUniforms = layerUniforms(for: b, source: sb, fadeAlpha: 1.0, clipLocalSeconds: bClipLocal)
            return .crossDissolve(
                aFrame: aFrame, aUniforms: aUniforms,
                bFrame: bFrame, bUniforms: bUniforms,
                progress: progress
            )
        }
        return nil
    }

    /// Layer alpha at time `t` for a single clip — accounts for solo
    /// fade-in / fade-out. Paired transitions are routed through the
    /// cross-dissolve branch above so we never double-apply.
    private func layerAlpha(for clip: PlacedClip, at t: Double, in track: VideoTrack) -> Double {
        var alpha: Double = 1.0
        let clipStart = clip.timelineRange.start.seconds
        let clipEnd   = clip.timelineRange.end.seconds

        if let tIn = clip.transitionIn, !isPairedTransition(.in, on: clip, in: track) {
            let dur = tIn.duration.seconds
            if dur > 0, t < clipStart + dur {
                alpha *= max(0, min(1, (t - clipStart) / dur))
            }
        }
        if let tOut = clip.transitionOut, !isPairedTransition(.out, on: clip, in: track) {
            let dur = tOut.duration.seconds
            if dur > 0, t > clipEnd - dur {
                alpha *= max(0, min(1, (clipEnd - t) / dur))
            }
        }
        return alpha
    }

    private enum TransitionSide { case `in`, out }

    /// Same logic as the realtime path: a transition is "paired" when it
    /// abuts a neighbor that also carries a transition on the matching
    /// side and the kinds line up.
    private func isPairedTransition(_ side: TransitionSide, on clip: PlacedClip, in track: VideoTrack) -> Bool {
        let sorted = track.clips.sorted { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        guard let i = sorted.firstIndex(where: { $0.id == clip.id }) else { return false }
        switch side {
        case .in:
            guard i > 0 else { return false }
            let prev = sorted[i - 1]
            guard abs(prev.timelineRange.end.seconds - clip.timelineRange.start.seconds) < 0.001 else { return false }
            guard let pOut = prev.transitionOut, let cIn = clip.transitionIn else { return false }
            return pOut.kind == cIn.kind
        case .out:
            guard i + 1 < sorted.count else { return false }
            let next = sorted[i + 1]
            guard abs(clip.timelineRange.end.seconds - next.timelineRange.start.seconds) < 0.001 else { return false }
            guard let cOut = clip.transitionOut, let nIn = next.transitionIn else { return false }
            return cOut.kind == nIn.kind
        }
    }

    /// Paired-fade-in source shift: when this clip is the incoming side of
    /// a cross-dissolve, source playback is shifted forward by the partner's
    /// leftHalf so the incoming clip has real motion during the dissolve.
    /// Outside the dissolve range we still apply the shift so playback
    /// stays continuous past the cut.
    private func pairedFadeInSourceShift(for clip: PlacedClip, in track: VideoTrack) -> Double {
        guard clip.transitionIn != nil else { return 0 }
        let sorted = track.clips.sorted { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        guard let i = sorted.firstIndex(where: { $0.id == clip.id }), i > 0 else { return 0 }
        let prev = sorted[i - 1]
        guard abs(prev.timelineRange.end.seconds - clip.timelineRange.start.seconds) < 0.001 else { return 0 }
        return prev.transitionOut?.duration.seconds ?? 0
    }

    // MARK: - Frame source pull

    /// Last delivered frame per source. Persisting it lets pullFrame
    /// re-show the same frame on subsequent ticks when the requested
    /// target time still falls inside that frame's duration window.
    ///
    /// **This is the realtime correctness fix.** The realtime host
    /// calls `compose(at:)` at the display refresh rate (60–120 Hz),
    /// but a 24/30 fps source only produces a new frame every 33–42 ms.
    /// Without this cache, every tick called `nextFrame()` and advanced
    /// the source — sources played 2.5× wall-clock even when "paused".
    private struct DeliveredFrame {
        let pts: CMTime
        let endPTS: CMTime
        let pixelBuffer: CVPixelBuffer
    }
    private var lastDeliveredFrame: [ClipID: DeliveredFrame] = [:]

    private func pullFrame(source: ClipSource, atSourceTime t: Double) async throws -> CVPixelBuffer {
        let target = CMTime(seconds: t, preferredTimescale: 600)

        // Cache hit: target lies inside the last delivered frame's
        // presentation window → re-use without touching the source.
        if let cached = lastDeliveredFrame[source.id],
           CMTimeCompare(target, cached.pts) >= 0,
           CMTimeCompare(target, cached.endPTS) < 0 {
            return cached.pixelBuffer
        }

        let fs = try await ensureFrameSource(for: source)
        let prev = lastSourceTime[source.id]
        // Backward jump → reseek. Forward by < 0.5 s we can walk to
        // via nextFrame.
        let needsSeek: Bool = {
            guard let p = prev else { return true }
            if t < p { return true }
            return t - p > 0.5
        }()
        if needsSeek {
            try await fs.seek(to: target)
            // Cached frame is no longer authoritative after a seek.
            lastDeliveredFrame.removeValue(forKey: source.id)
        }
        lastSourceTime[source.id] = t

        // Walk forward one frame at a time. The right frame is the one
        // whose [pts, pts+duration) window contains `target`. Cache
        // every frame we see, so the next tick almost certainly hits
        // the cache instead of advancing the source again — that's
        // what keeps a 24 fps source from playing at 60+ Hz when the
        // realtime host ticks at the display's refresh rate.
        let nominalDur = CMTime(
            seconds: 1.0 / max(1.0, fs.nominalFrameRate),
            preferredTimescale: 600
        )
        var lastFrame: PPEDecodedFrame?
        for _ in 0..<16 {
            guard let f = try await fs.nextFrame() else { break }
            lastFrame = f
            let dur = (f.duration.isValid && f.duration.seconds > 0) ? f.duration : nominalDur
            let endPTS = CMTimeAdd(f.pts, dur)
            lastDeliveredFrame[source.id] = DeliveredFrame(
                pts: f.pts, endPTS: endPTS, pixelBuffer: f.pixelBuffer
            )
            // Target is inside this frame's window → that's the one.
            if CMTimeCompare(target, f.pts) >= 0 && CMTimeCompare(target, endPTS) < 0 {
                return f.pixelBuffer
            }
            // Target is BEFORE this frame's window → we overshot (rare;
            // happens when seek lands ahead of target). Best-effort.
            if CMTimeCompare(target, f.pts) < 0 {
                return f.pixelBuffer
            }
            // Target is past this frame → keep pulling.
        }
        // 16 iterations or EOF without hitting the window. Return the
        // last frame we saw (best approximation), or the previously
        // cached frame, or black.
        if let f = lastFrame { return f.pixelBuffer }
        if let cached = lastDeliveredFrame[source.id] { return cached.pixelBuffer }
        let buf = try allocScratch()
        if let cmd = commandQueue.makeCommandBuffer() {
            encodeBlackFill(into: buf, on: cmd)
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        return buf
    }

    private func ensureFrameSource(for source: ClipSource) async throws -> AVAssetFrameSource {
        if let cached = frameSources[source.id] { return cached }
        let fs: AVAssetFrameSource
        do {
            fs = try await AVAssetFrameSource.load(url: source.url)
        } catch {
            throw CompositorError.frameSourceLoadFailed(error.localizedDescription)
        }
        frameSources[source.id] = fs
        return fs
    }

    // MARK: - Metal helpers

    private func allocScratch() throws -> CVPixelBuffer {
        var buf: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, scratchPool, &buf)
        guard status == kCVReturnSuccess, let buf else {
            throw CompositorError.pixelBufferAllocFailed(status)
        }
        return buf
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer, usage: MTLTextureUsage) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTex
        )
        guard status == kCVReturnSuccess, let cvTex else { return nil }
        return CVMetalTextureGetTexture(cvTex)
    }

    /// Encode a black clear into `output` as a single render pass on
    /// the given command buffer.
    private func encodeBlackFill(into output: CVPixelBuffer, on cmd: MTLCommandBuffer) {
        guard let dst = makeTexture(from: output, usage: [.renderTarget]) else { return }
        encodeBlackFill(intoTexture: dst, on: cmd)
    }

    /// Same as above but draws directly into an `MTLTexture` — used by
    /// the realtime host writing into a `CAMetalLayer` drawable.
    private func encodeBlackFill(intoTexture dst: MTLTexture, on cmd: MTLCommandBuffer) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = dst
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        enc.setRenderPipelineState(blackPipeline)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    /// Encode a blend pass on the given command buffer. GPU command
    /// ordering inside the queue makes sure passes that read `output`
    /// after this one runs see the result.
    private func encodeBlend(
        bottom: CVPixelBuffer,
        top: CVPixelBuffer,
        uniforms: LayerUniforms,
        into output: CVPixelBuffer,
        on cmd: MTLCommandBuffer
    ) {
        guard let dst = makeTexture(from: output, usage: [.renderTarget]) else { return }
        encodeBlend(bottom: bottom, top: top, uniforms: uniforms, intoTexture: dst, on: cmd)
    }

    private func encodeBlend(
        bottom: CVPixelBuffer,
        top: CVPixelBuffer,
        uniforms: LayerUniforms,
        intoTexture dst: MTLTexture,
        on cmd: MTLCommandBuffer
    ) {
        guard let bottomTex = makeTexture(from: bottom, usage: [.shaderRead]),
              let topTex = makeTexture(from: top, usage: [.shaderRead])
        else { return }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = dst
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        enc.setRenderPipelineState(blendPipeline)
        enc.setFragmentTexture(bottomTex, index: 0)
        enc.setFragmentTexture(topTex, index: 1)
        var u = uniforms
        enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.size, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    /// Alpha-aware cross-dissolve into a CVPixelBuffer.
    private func encodeCrossDissolve(
        acc: CVPixelBuffer,
        a: CVPixelBuffer, aUniforms: LayerUniforms,
        b: CVPixelBuffer, bUniforms: LayerUniforms,
        progress: Double,
        into output: CVPixelBuffer,
        on cmd: MTLCommandBuffer
    ) {
        guard let dst = makeTexture(from: output, usage: [.renderTarget]) else { return }
        encodeCrossDissolve(
            acc: acc, a: a, aUniforms: aUniforms, b: b, bUniforms: bUniforms,
            progress: progress, intoTexture: dst, on: cmd
        )
    }

    /// Alpha-aware cross-dissolve into an MTLTexture (realtime path).
    /// Produces correct `(1-p)*A + p*B` inside the overlapping
    /// destRects, plus the right fall-off where only one clip covers
    /// (V_below shows through with weight `1 - wA - wB`). Single render
    /// pass — the shader does the masking + sampling per-fragment.
    private func encodeCrossDissolve(
        acc: CVPixelBuffer,
        a: CVPixelBuffer, aUniforms: LayerUniforms,
        b: CVPixelBuffer, bUniforms: LayerUniforms,
        progress: Double,
        intoTexture dst: MTLTexture,
        on cmd: MTLCommandBuffer
    ) {
        guard let accTex = makeTexture(from: acc, usage: [.shaderRead]),
              let aTex   = makeTexture(from: a,   usage: [.shaderRead]),
              let bTex   = makeTexture(from: b,   usage: [.shaderRead])
        else { return }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = dst
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        enc.setRenderPipelineState(crossDissolvePipeline)
        enc.setFragmentTexture(accTex, index: 0)
        enc.setFragmentTexture(aTex,   index: 1)
        enc.setFragmentTexture(bTex,   index: 2)

        let p = Float(max(0, min(1, progress)))
        let wA = Float(max(0, min(1, aUniforms.opacity.x))) * (1 - p)
        let wB = Float(max(0, min(1, bUniforms.opacity.x))) * p
        var u = CrossDissolveUniforms(
            aDestRect: aUniforms.destRect,
            aCropRect: aUniforms.cropRect,
            aRotation: aUniforms.rotation,
            bDestRect: bUniforms.destRect,
            bCropRect: bUniforms.cropRect,
            bRotation: bUniforms.rotation,
            weights:   SIMD4<Float>(wA, wB, 0, 0)
        )
        enc.setFragmentBytes(&u, length: MemoryLayout<CrossDissolveUniforms>.size, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    // MARK: - Shader source

    private static let shaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    constant float2 kQuad[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    constant float2 kQuadUV[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    vertex VertexOut compositorQuadVertex(uint vid [[vertex_id]]) {
        VertexOut out;
        out.position = float4(kQuad[vid], 0.0, 1.0);
        out.uv       = kQuadUV[vid];
        return out;
    }

    /// Mirror of Swift's LayerUniforms — 64 bytes total. All fields are
    /// float4 to keep alignment unambiguous between MSL and Swift's
    /// SIMD types. `rotation.xy` is (cosθ, sinθ) pre-computed CPU-side.
    struct LayerUniforms {
        float4 destRect;   // (minU, minV, maxU, maxV) in output UV
        float4 cropRect;   // (minU, minV, maxU, maxV) in source UV
        float4 opacity;    // .x = opacity; rest reserved
        float4 rotation;   // .x = cosθ, .y = sinθ; rest reserved
    };

    fragment float4 compositorBlendFragment(
        VertexOut in                              [[stage_in]],
        texture2d<float, access::sample> bottom   [[texture(0)]],
        texture2d<float, access::sample> top      [[texture(1)]],
        constant LayerUniforms& u                 [[buffer(0)]]
    ) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = in.uv;
        float4 b = bottom.sample(s, uv);

        // Outside the layer's destination rect → letterbox; the layer
        // contributes nothing here, so the underlying accumulator
        // (already in `bottom`) is what shows.
        bool inDest = uv.x >= u.destRect.x && uv.x < u.destRect.z
                   && uv.y >= u.destRect.y && uv.y < u.destRect.w;
        if (!inDest) {
            return float4(b.rgb, 1.0);
        }

        // Normalise this fragment's position within destRect to [0,1].
        float2 norm = (uv - u.destRect.xy) / (u.destRect.zw - u.destRect.xy);

        // Rotate around the destRect's center, in pixel-aspect-corrected
        // space so a square logo in the source stays square in output.
        // rotation.z carries the destRect's PIXEL aspect (computed
        // CPU-side from fitW / fitH, not UV ratios).
        float c = u.rotation.x;
        float sn = u.rotation.y;
        float aspect = max(0.0001, u.rotation.z);
        float2 centered = norm - float2(0.5, 0.5);
        centered.x *= aspect;
        float2 rotated;
        rotated.x = centered.x * c - centered.y * sn;
        rotated.y = centered.x * sn + centered.y * c;
        rotated.x /= aspect;
        float2 rotatedNorm = rotated + float2(0.5, 0.5);

        // If rotation pulled us outside [0,1] (corners after a 45°
        // rotation), drop to the underlying layer.
        if (rotatedNorm.x < 0.0 || rotatedNorm.x >= 1.0
         || rotatedNorm.y < 0.0 || rotatedNorm.y >= 1.0) {
            return float4(b.rgb, 1.0);
        }

        // Crop semantics: the rotated UV is in the FULL source's UV
        // space (0..1 across the whole picture). Compute the signed
        // "inside" distance to each edge in source-UV units, take the
        // min, and apply a smoothstep falloff using `feather` as the
        // half-width (0 = hard cut). At the edge the layer reveals
        // whatever's below; deeper inside, the layer's full opacity.
        if (rotatedNorm.x < u.cropRect.x || rotatedNorm.x > u.cropRect.z
         || rotatedNorm.y < u.cropRect.y || rotatedNorm.y > u.cropRect.w) {
            return float4(b.rgb, 1.0);
        }
        float feather = u.opacity.y;
        float4 t = top.sample(s, rotatedNorm);
        float coverage = 1.0;
        if (feather > 0.0001) {
            // Auto edge selection: feather only edges that are actually
            // cropped. Uncropped edges keep a sentinel large distance
            // so they never trip the falloff. Premiere convention.
            float large = 100.0;
            float dL = (u.cropRect.x > 0.0001) ? (rotatedNorm.x - u.cropRect.x) : large;
            float dR = (u.cropRect.z < 0.9999) ? (u.cropRect.z - rotatedNorm.x) : large;
            float dT = (u.cropRect.y > 0.0001) ? (rotatedNorm.y - u.cropRect.y) : large;
            float dB = (u.cropRect.w < 0.9999) ? (u.cropRect.w - rotatedNorm.y) : large;
            float d  = min(min(dL, dR), min(dT, dB));
            coverage = smoothstep(0.0, feather, d);
        }
        float alpha = u.opacity.x * coverage;
        return float4(mix(b.rgb, t.rgb, alpha), 1.0);
    }

    fragment float4 compositorBlackFragment(VertexOut in [[stage_in]]) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    /// Alpha-aware cross-dissolve. Each clip carries its own destRect /
    /// cropRect / rotation; the shader samples whichever clips cover
    /// the current fragment and mixes them with the underlying
    /// accumulator using:
    ///
    ///   result = acc*(1 - wA - wB) + A*wA + B*wB
    ///
    /// where wA = A_opacity*(1-progress) inside A's destRect (else 0),
    /// and wB = B_opacity*progress inside B's destRect (else 0). This
    /// produces:
    ///   - inside both rects:  (1-p)*A + p*B   (true cross-dissolve)
    ///   - inside A only:      p*acc + (1-p)*A (acc visible where B doesn't reach)
    ///   - inside B only:      (1-p)*acc + p*B
    ///   - outside both:       acc            (unchanged underlying)
    struct CrossDissolveUniforms {
        float4 aDestRect;
        float4 aCropRect;
        float4 aRotation;
        float4 bDestRect;
        float4 bCropRect;
        float4 bRotation;
        float4 weights;   // .x = wA, .y = wB
    };

    /// Returns the source UV inside a layer (with rotation around the
    /// destRect center, aspect-corrected) if the fragment is inside
    /// the destRect; .w = 0 if outside.
    static inline float3 sampleLayerUV(
        float2 uv,
        float4 destRect,
        float4 cropRect,
        float4 rotation
    ) {
        if (uv.x < destRect.x || uv.x >= destRect.z
         || uv.y < destRect.y || uv.y >= destRect.w) {
            return float3(0.0, 0.0, 0.0);
        }
        float2 norm = (uv - destRect.xy) / (destRect.zw - destRect.xy);
        float c = rotation.x;
        float sn = rotation.y;
        float aspect = max(0.0001, rotation.z);
        float2 centered = norm - float2(0.5, 0.5);
        centered.x *= aspect;
        float2 rotated = float2(
            centered.x * c - centered.y * sn,
            centered.x * sn + centered.y * c
        );
        rotated.x /= aspect;
        float2 rotatedNorm = rotated + float2(0.5, 0.5);
        if (rotatedNorm.x < 0.0 || rotatedNorm.x >= 1.0
         || rotatedNorm.y < 0.0 || rotatedNorm.y >= 1.0) {
            return float3(0.0, 0.0, 0.0);
        }
        if (rotatedNorm.x < cropRect.x || rotatedNorm.x > cropRect.z
         || rotatedNorm.y < cropRect.y || rotatedNorm.y > cropRect.w) {
            return float3(0.0, 0.0, 0.0);
        }
        return float3(rotatedNorm, 1.0);
    }

    fragment float4 compositorCrossDissolveFragment(
        VertexOut in                              [[stage_in]],
        texture2d<float, access::sample> acc      [[texture(0)]],
        texture2d<float, access::sample> texA     [[texture(1)]],
        texture2d<float, access::sample> texB     [[texture(2)]],
        constant CrossDissolveUniforms& u         [[buffer(0)]]
    ) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = in.uv;
        float4 accColor = acc.sample(s, uv);

        float3 aSample = sampleLayerUV(uv, u.aDestRect, u.aCropRect, u.aRotation);
        float wA = aSample.z > 0.5 ? u.weights.x : 0.0;
        float3 aColor = wA > 0.0 ? texA.sample(s, aSample.xy).rgb : float3(0.0);

        float3 bSample = sampleLayerUV(uv, u.bDestRect, u.bCropRect, u.bRotation);
        float wB = bSample.z > 0.5 ? u.weights.y : 0.0;
        float3 bColor = wB > 0.0 ? texB.sample(s, bSample.xy).rgb : float3(0.0);

        float wAcc = max(0.0, 1.0 - wA - wB);
        float3 rgb = accColor.rgb * wAcc + aColor * wA + bColor * wB;
        return float4(rgb, 1.0);
    }
    """
}
