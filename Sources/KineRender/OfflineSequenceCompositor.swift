import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import Metal
import KineCore
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
    /// Persistent 1×1 black texture used as the letterbox backdrop when
    /// presenting a single source frame — avoids allocating + clearing a
    /// full-size scratch buffer every cached-playback frame.
    private let blackTexture: MTLTexture
    /// 2×2×2 identity 3D LUT, bound when a layer has no creative LUT.
    private let identityLUT3D: MTLTexture
    /// Parsed `.cube` LUTs keyed by file path. Loaded on first use, then
    /// cached for the compositor's lifetime.
    private var lutTextures: [String: MTLTexture] = [:]
    private var lutFailedPaths: Set<String> = []
    /// Scratch pool for intermediate layer accumulation. Sized small
    /// (~4 buffers) because at any one time we hold the running
    /// accumulator plus, for cross-dissolves, one combined-AB temp.
    /// The encoder's adaptor pool — bounded by `minimumBufferCount` —
    /// is used for the final composed output instead, so the encoder
    /// can back-pressure us through pool starvation when the hardware
    /// encoder gets behind.
    private let scratchPool: CVPixelBufferPool

    // MARK: - Frame source pool

    /// Decoder cache key. Same-source clips share ONE decoder by default
    /// (`.source`) so a bladed clip plays seamlessly across the cut. But
    /// clips that overlap a same-source sibling in timeline time (layering
    /// a clip over itself) each get their OWN decoder (`.clip`) — otherwise
    /// they'd yank one reader between two source positions every frame.
    /// See `refreshIsolationIfNeeded`.
    private enum DecoderKey: Hashable {
        case source(ClipID)
        case clip(PlacedClipID)
    }
    private var frameSources: [DecoderKey: VideoFrameSource] = [:]
    private var lastSourceTime: [DecoderKey: Double] = [:]

    // Video clips that overlap a same-source sibling in time → isolated to
    // their own decoder. Recomputed only when the clip layout changes.
    private var isolatedClips: Set<PlacedClipID> = []
    private var isolationSignature = 0

    /// O(n²) over video clips, but only when the layout signature changes
    /// (an edit); the per-compose cost is just the O(n) signature fold.
    private func refreshIsolationIfNeeded() {
        var sig = 17
        for track in sequence.videoTracks {
            for c in track.clips {
                sig = sig &* 31 &+ c.id.rawValue.hashValue
                sig = sig &* 31 &+ Int(c.timelineRange.start.seconds * 1000)
                sig = sig &* 31 &+ Int(c.timelineRange.duration.seconds * 1000)
                sig = sig &* 31 &+ c.sourceClipID.rawValue.hashValue
            }
        }
        guard sig != isolationSignature else { return }
        isolationSignature = sig
        var clips: [(id: PlacedClipID, src: ClipID, range: TimeRange)] = []
        for track in sequence.videoTracks {
            for c in track.clips { clips.append((c.id, c.sourceClipID, c.timelineRange)) }
        }
        var isolated = Set<PlacedClipID>()
        for i in clips.indices {
            for j in clips.indices where i != j {
                if clips[i].src == clips[j].src, clips[i].range.overlaps(clips[j].range) {
                    isolated.insert(clips[i].id)
                    break
                }
            }
        }
        isolatedClips = isolated
    }

    private func decoderKey(for clipID: PlacedClipID, sourceID: ClipID) -> DecoderKey {
        isolatedClips.contains(clipID) ? .clip(clipID) : .source(sourceID)
    }

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

        guard let device = KineRender.device else { throw CompositorError.noMetalDevice }
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

        // 1×1 opaque-black texture for letterbox bars in single-source
        // present. Built once; sampled (clamped) over the whole bottom.
        let blackTexDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        blackTexDesc.usage = [.shaderRead]
        guard let black = device.makeTexture(descriptor: blackTexDesc) else {
            throw CompositorError.textureBindingFailed
        }
        var px: [UInt8] = [0, 0, 0, 255]   // BGRA opaque black
        black.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                      withBytes: &px, bytesPerRow: 4)
        self.blackTexture = black

        // 2×2×2 identity 3D LUT — bound at the LUT texture slot whenever a
        // layer has no .cube LUT (trilinear sampling returns the input
        // unchanged), so the blend shader's texture3d arg is always valid.
        let lutDesc = MTLTextureDescriptor()
        lutDesc.textureType = .type3D
        lutDesc.pixelFormat = .rgba32Float
        lutDesc.width = 2; lutDesc.height = 2; lutDesc.depth = 2
        lutDesc.usage = .shaderRead
        lutDesc.storageMode = .shared
        guard let idLut = device.makeTexture(descriptor: lutDesc) else {
            throw CompositorError.textureBindingFailed
        }
        var lutData = [Float](repeating: 0, count: 2 * 2 * 2 * 4)
        var li = 0
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 {
            lutData[li] = Float(r); lutData[li+1] = Float(g); lutData[li+2] = Float(b); lutData[li+3] = 1
            li += 4
        } } }
        let lbpr = 2 * MemoryLayout<Float>.size * 4
        idLut.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                        size: MTLSize(width: 2, height: 2, depth: 2)),
                      mipmapLevel: 0, slice: 0, withBytes: &lutData,
                      bytesPerRow: lbpr, bytesPerImage: lbpr * 2)
        self.identityLUT3D = idLut
    }

    public func teardown() {
        for fs in frameSources.values { fs.tearDown() }
        frameSources.removeAll()
        lastSourceTime.removeAll()
        lastDeliveredFrame.removeAll()
    }

    /// Drop cached decoders/frames for sources no longer referenced by
    /// the current sequence, so a long editing session doesn't retain a
    /// decoder + held CVPixelBuffer per clip ever placed.
    public func pruneUnusedSources() {
        guard !frameSources.isEmpty else { return }
        refreshIsolationIfNeeded()
        // frameSources is populated only by video pulls, so the live key
        // set is the decoder key of every video clip.
        var live = Set<DecoderKey>()
        for track in sequence.videoTracks {
            for c in track.clips { live.insert(decoderKey(for: c.id, sourceID: c.sourceClipID)) }
        }
        for key in frameSources.keys where !live.contains(key) {
            frameSources[key]?.tearDown()
            frameSources.removeValue(forKey: key)
            lastSourceTime.removeValue(forKey: key)
            lastDeliveredFrame.removeValue(forKey: key)
        }
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
        // Blend the source over a persistent 1×1 black texture (the
        // letterbox backdrop). Single pass, no per-frame scratch buffer
        // allocation or black-fill pass — that churn was what made cached
        // playback stutter worse than live.
        encodeBlend(
            bottomTexture: blackTexture, top: source,
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
            case .single(let frame, let uniforms, let color, let curve, let lut):
                encodeBlend(bottom: acc, top: frame, uniforms: uniforms, color: color, curve: curve, lut: lut, into: dst, on: cmd)
            case .crossDissolve(let aF, let aU, let aC, let aCv, let bF, let bU, let bC, let bCv, let progress):
                encodeCrossDissolve(
                    acc: acc, a: aF, aUniforms: aU, aColor: aC, aCurve: aCv,
                    b: bF, bUniforms: bU, bColor: bC, bCurve: bCv,
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
            case .single(let frame, let uniforms, let color, let curve, let lut):
                encodeBlend(bottom: acc, top: frame, uniforms: uniforms, color: color, curve: curve, lut: lut, into: dst, on: cmd)
            case .crossDissolve(let aF, let aU, let aC, let aCv, let bF, let bU, let bC, let bCv, let progress):
                encodeCrossDissolve(
                    acc: acc, a: aF, aUniforms: aU, aColor: aC, aCurve: aCv,
                    b: bF, bUniforms: bU, bColor: bC, bCurve: bCv,
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
            case (.single(let frame, let uniforms, let color, let curve, let lut), true):
                encodeBlend(bottom: acc, top: frame, uniforms: uniforms, color: color, curve: curve, lut: lut, intoTexture: outputTexture, on: cmd)
            case (.single(let frame, let uniforms, let color, let curve, let lut), false):
                let next = try allocScratch()
                encodeBlend(bottom: acc, top: frame, uniforms: uniforms, color: color, curve: curve, lut: lut, into: next, on: cmd)
                acc = next
            case (.crossDissolve(let aF, let aU, let aC, let aCv, let bF, let bU, let bC, let bCv, let progress), true):
                encodeCrossDissolve(
                    acc: acc, a: aF, aUniforms: aU, aColor: aC, aCurve: aCv,
                    b: bF, bUniforms: bU, bColor: bC, bCurve: bCv,
                    progress: progress, intoTexture: outputTexture, on: cmd
                )
            case (.crossDissolve(let aF, let aU, let aC, let aCv, let bF, let bU, let bC, let bCv, let progress), false):
                let next = try allocScratch()
                encodeCrossDissolve(
                    acc: acc, a: aF, aUniforms: aU, aColor: aC, aCurve: aCv,
                    b: bF, bUniforms: bU, bColor: bC, bCurve: bCv,
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
        case single(CVPixelBuffer, LayerUniforms, ColorUniforms, [Float], MTLTexture?)
        /// Two paired-transition clips cross-dissolved. Each clip
        /// carries its own transform + color uniforms + curve LUT so the
        /// shader can aspect-fit and grade A and B independently — the
        /// dissolve math produces the correct `(1-p)*A + p*B` blend
        /// wherever both rects overlap, and lets the underlying layer
        /// show through in the regions only one clip covers (when their
        /// destRects differ, e.g. a 4:3 clip dissolving to a 16:9 clip).
        case crossDissolve(
            aFrame: CVPixelBuffer, aUniforms: LayerUniforms, aColor: ColorUniforms, aCurve: [Float],
            bFrame: CVPixelBuffer, bUniforms: LayerUniforms, bColor: ColorUniforms, bCurve: [Float],
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

    /// Per-layer color grade uniforms (the `kine.color` effect). The
    /// grade runs on the layer's source pixels before compositing:
    /// input-transform (log/gamma → linear working) → exposure + white
    /// balance in linear → back to display-referred Rec.709 → tone, sat,
    /// vibrance. `c2.w` is the enable flag (0 = pass through).
    public struct ColorUniforms {
        public var c0: SIMD4<Float>  // x=inputSpaceID, y=exposureGain(2^stops), z=contrast(-1..1), w=saturationMult
        public var c1: SIMD4<Float>  // x=temp(-1..1), y=tint(-1..1), z=highlights, w=shadows
        public var c2: SIMD4<Float>  // x=whites, y=blacks, z=vibrance, w=enabled
        // Camera-gamut → Rec.709 matrix rows (.xyz), applied in linear
        // after the transfer-function decode. Identity for Rec.709 inputs.
        public var g0: SIMD4<Float>
        public var g1: SIMD4<Float>
        public var g2: SIMD4<Float>

        public static let disabled = ColorUniforms(
            c0: SIMD4<Float>(0, 1, 0, 1), c1: .zero, c2: SIMD4<Float>(0, 0, 0, 0),
            g0: SIMD4<Float>(1, 0, 0, 0), g1: SIMD4<Float>(0, 1, 0, 0), g2: SIMD4<Float>(0, 0, 1, 0))
    }

    /// Build shader color uniforms from a sampled `ColorGrade`. Returns
    /// `.disabled` for an identity grade (neutral sliders AND Rec.709
    /// input) so untouched clips pay no grading cost.
    private func colorUniforms(_ g: ColorGrade) -> ColorUniforms {
        if g.isIdentity { return .disabled }
        let expGain = Float(pow(2.0, g.exposure))
        let satMult = Float(1.0 + g.saturation / 100.0)   // -100→0, 0→1, +100→2
        let gamut = ColorScience.gamutRows(g.inputSpace)
        let lutEnabled: Float = (g.lutPath != nil && g.lutIntensity > 0) ? 1 : 0
        // LUT enable + intensity ride the unused .w lanes of the gamut rows.
        var g0 = gamut.0, g1 = gamut.1
        g0.w = lutEnabled
        g1.w = Float(max(0, min(1, g.lutIntensity / 100.0)))
        return ColorUniforms(
            c0: SIMD4<Float>(Float(g.inputSpace.shaderID), expGain, Float(g.contrast / 100.0), satMult),
            c1: SIMD4<Float>(Float(g.temperature / 100.0), Float(g.tint / 100.0),
                             Float(g.highlights / 100.0), Float(g.shadows / 100.0)),
            c2: SIMD4<Float>(Float(g.whites / 100.0), Float(g.blacks / 100.0),
                             Float(g.vibrance / 100.0), 1),
            g0: g0, g1: g1, g2: gamut.2
        )
    }

    /// 128-float curve LUT: 4 channels (master, R, G, B) × 32 samples,
    /// fed to the shader as `constant float*`. Identity ramp where a
    /// channel has no curve. Returns the shared identity LUT when the
    /// grade has no curves at all (no per-frame allocation).
    static let identityCurveLUT: [Float] = {
        var a = [Float](repeating: 0, count: 128)
        for ch in 0..<4 { for i in 0..<32 { a[ch * 32 + i] = Float(i) / 31.0 } }
        return a
    }()

    private func curveLUT(_ g: ColorGrade) -> [Float] {
        if g.curveMaster.isEmpty && g.curveRed.isEmpty
            && g.curveGreen.isEmpty && g.curveBlue.isEmpty {
            return Self.identityCurveLUT
        }
        var a = [Float](repeating: 0, count: 128)
        func bake(_ pts: [CurvePoint], _ ch: Int) {
            if pts.count < 2 {
                for i in 0..<32 { a[ch * 32 + i] = Float(i) / 31.0 }
                return
            }
            let tc = ToneCurve(pts)
            for i in 0..<32 { a[ch * 32 + i] = Float(tc.evaluate(Double(i) / 31.0)) }
        }
        bake(g.curveMaster, 0); bake(g.curveRed, 1); bake(g.curveGreen, 2); bake(g.curveBlue, 3)
        return a
    }

    /// Load (and cache) a `.cube` LUT as a 3D texture. Returns nil if the
    /// file is missing/malformed (cached as failed so we don't retry every
    /// frame). Reuses the PPE `.cube` parser.
    private func lutTexture(forPath path: String) -> MTLTexture? {
        if let t = lutTextures[path] { return t }
        if lutFailedPaths.contains(path) { return nil }
        do {
            let loaded = try PPELUTLoader.load(url: URL(fileURLWithPath: path), device: device)
            lutTextures[path] = loaded.texture
            return loaded.texture
        } catch {
            lutFailedPaths.insert(path)
            return nil
        }
    }

    /// Seed frame sources for the layers active at `timelineSeconds`
    /// without rendering — warms decoders before the playhead crosses
    /// from a cached region into live compositing so the first live
    /// frame doesn't stall on a cold seek. Best-effort; errors are
    /// swallowed (a failed warm just means the seek happens later).
    public func prewarm(at timelineSeconds: Double) async {
        refreshIsolationIfNeeded()
        let probe = RationalTime(value: Int64(timelineSeconds * 1000), scale: 1000)
        for track in sequence.videoTracks {
            guard let clip = track.clips.first(where: { $0.timelineRange.contains(probe) }),
                  let source = mediaPool.clips[clip.sourceClipID] else { continue }
            let clipLocal = timelineSeconds - clip.timelineRange.start.seconds
            let shift = pairedFadeInSourceShift(for: clip, in: track)
            let sourceTime = clip.sourceRange.start.seconds + clipLocal + shift
            let key = decoderKey(for: clip.id, sourceID: clip.sourceClipID)
            _ = try? await pullFrame(key: key, source: source, atSourceTime: sourceTime)
        }
    }

    private func effectiveLayers(at t: Double) async throws -> [LayerContribution] {
        refreshIsolationIfNeeded()
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
                let key = decoderKey(for: clip.id, sourceID: clip.sourceClipID)
                let frame = try await pullFrame(key: key, source: source, atSourceTime: sourceTime)
                let uniforms = layerUniforms(for: clip, source: source, fadeAlpha: fade, clipLocalSeconds: clipLocal)
                let grade = clip.colorGrade(at: clipLocal)
                let lut = grade.lutPath.flatMap { lutTexture(forPath: $0) }
                layers.append(.single(frame, uniforms, colorUniforms(grade), curveLUT(grade), lut))
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

            let aKey = decoderKey(for: a.id, sourceID: a.sourceClipID)
            let bKey = decoderKey(for: b.id, sourceID: b.sourceClipID)
            let aFrame = try await pullFrame(key: aKey, source: sa, atSourceTime: aSourceTime)
            let bFrame = try await pullFrame(key: bKey, source: sb, atSourceTime: bSourceTime)
            // Each clip carries its own transform — the alpha-aware
            // cross-dissolve shader uses both A's and B's destRect /
            // cropRect to mix them at the correct aspect (no squishing
            // B into A's box). Solo fades on these clips are inside the
            // dissolve window already covered by the dissolve curve
            // itself, so we don't multiply in `layerAlpha` here.
            let aUniforms = layerUniforms(for: a, source: sa, fadeAlpha: 1.0, clipLocalSeconds: aClipLocal)
            let bUniforms = layerUniforms(for: b, source: sb, fadeAlpha: 1.0, clipLocalSeconds: bClipLocal)
            let aGrade = a.colorGrade(at: aClipLocal)
            let bGrade = b.colorGrade(at: bClipLocal)
            return .crossDissolve(
                aFrame: aFrame, aUniforms: aUniforms, aColor: colorUniforms(aGrade), aCurve: curveLUT(aGrade),
                bFrame: bFrame, bUniforms: bUniforms, bColor: colorUniforms(bGrade), bCurve: curveLUT(bGrade),
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
    private var lastDeliveredFrame: [DecoderKey: DeliveredFrame] = [:]

    private func pullFrame(key: DecoderKey, source: ClipSource, atSourceTime t: Double) async throws -> CVPixelBuffer {
        // Nudge the sample point a few ms INTO the frame interval. When a
        // clip's source-in equals its timeline-in (a contiguous blade),
        // the frame-quantized compose time lands exactly on source frame
        // boundaries, where the [pts, pts+dur) window test is fragile to
        // cross-timescale rounding and intermittently grabs the adjacent
        // frame — a steady stream of 1-frame skips that reads as chop.
        // A sub-frame epsilon keeps selection robustly inside one frame
        // without ever changing which frame it is.
        let target = CMTime(seconds: max(0, t) + 0.004, preferredTimescale: 600)

        // Cache hit: target lies inside the last delivered frame's
        // presentation window → re-use without touching the source.
        if let cached = lastDeliveredFrame[key],
           CMTimeCompare(target, cached.pts) >= 0,
           CMTimeCompare(target, cached.endPTS) < 0 {
            return cached.pixelBuffer
        }

        let fs = try await ensureFrameSource(key: key, source: source)
        let nominalDur = CMTime(
            seconds: 1.0 / max(1.0, fs.nominalFrameRate),
            preferredTimescale: 600
        )
        let prev = lastSourceTime[key]
        // Backward jump → reseek. Forward by < 0.5 s we can walk to
        // via nextFrame.
        let needsSeek: Bool = {
            guard let p = prev else { return true }
            if t < p { return true }
            return t - p > 0.5
        }()
        if needsSeek {
            // Seek one frame BEFORE target. AVAssetReader delivers frames
            // with pts >= the range start, so seeking exactly to `target`
            // skips the frame that *contains* target (its pts < target)
            // and the walk below returns a frame ~1 frame in the future —
            // a visible 1-frame glitch on every cold seek (clip first
            // appearing at a transition, cache→live crossover). Backing
            // up a frame puts the containing frame inside the reader's
            // range so the walk lands on it.
            let seekTarget = CMTimeMaximum(.zero, CMTimeSubtract(target, nominalDur))
            try await fs.seek(to: seekTarget)
            // Cached frame is no longer authoritative after a seek.
            lastDeliveredFrame.removeValue(forKey: key)
        }
        lastSourceTime[key] = t

        // Walk forward one frame at a time. The right frame is the one
        // whose [pts, pts+duration) window contains `target`. Cache
        // every frame we see, so the next tick almost certainly hits
        // the cache instead of advancing the source again — that's
        // what keeps a 24 fps source from playing at 60+ Hz when the
        // realtime host ticks at the display's refresh rate.
        var lastFrame: PPEDecodedFrame?
        for _ in 0..<16 {
            guard let f = try await fs.nextFrame() else { break }
            lastFrame = f
            let dur = (f.duration.isValid && f.duration.seconds > 0) ? f.duration : nominalDur
            let endPTS = CMTimeAdd(f.pts, dur)
            lastDeliveredFrame[key] = DeliveredFrame(
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
        if let cached = lastDeliveredFrame[key] { return cached.pixelBuffer }
        let buf = try allocScratch()
        if let cmd = commandQueue.makeCommandBuffer() {
            encodeBlackFill(into: buf, on: cmd)
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        return buf
    }

    private func ensureFrameSource(key: DecoderKey, source: ClipSource) async throws -> VideoFrameSource {
        if let cached = frameSources[key] { return cached }
        let fs: VideoFrameSource
        do {
            fs = try await AVAssetFrameSource.load(url: source.url)
        } catch {
            throw CompositorError.frameSourceLoadFailed(error.localizedDescription)
        }
        frameSources[key] = fs
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
        color: ColorUniforms = .disabled,
        curve: [Float] = OfflineSequenceCompositor.identityCurveLUT,
        lut: MTLTexture? = nil,
        into output: CVPixelBuffer,
        on cmd: MTLCommandBuffer
    ) {
        guard let dst = makeTexture(from: output, usage: [.renderTarget]) else { return }
        encodeBlend(bottom: bottom, top: top, uniforms: uniforms, color: color, curve: curve, lut: lut, intoTexture: dst, on: cmd)
    }

    private func encodeBlend(
        bottom: CVPixelBuffer,
        top: CVPixelBuffer,
        uniforms: LayerUniforms,
        color: ColorUniforms = .disabled,
        curve: [Float] = OfflineSequenceCompositor.identityCurveLUT,
        lut: MTLTexture? = nil,
        intoTexture dst: MTLTexture,
        on cmd: MTLCommandBuffer
    ) {
        guard let bottomTex = makeTexture(from: bottom, usage: [.shaderRead]) else { return }
        encodeBlend(bottomTexture: bottomTex, top: top, uniforms: uniforms, color: color, curve: curve, lut: lut, intoTexture: dst, on: cmd)
    }

    /// Blend variant whose bottom is an existing `MTLTexture` (e.g. the
    /// persistent black letterbox texture) — skips wrapping a CVPixelBuffer.
    private func encodeBlend(
        bottomTexture bottomTex: MTLTexture,
        top: CVPixelBuffer,
        uniforms: LayerUniforms,
        color: ColorUniforms = .disabled,
        curve: [Float] = OfflineSequenceCompositor.identityCurveLUT,
        lut: MTLTexture? = nil,
        intoTexture dst: MTLTexture,
        on cmd: MTLCommandBuffer
    ) {
        guard let topTex = makeTexture(from: top, usage: [.shaderRead]) else { return }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = dst
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        enc.setRenderPipelineState(blendPipeline)
        enc.setFragmentTexture(bottomTex, index: 0)
        enc.setFragmentTexture(topTex, index: 1)
        enc.setFragmentTexture(lut ?? identityLUT3D, index: 2)
        var u = uniforms
        enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.size, index: 0)
        var col = color
        enc.setFragmentBytes(&col, length: MemoryLayout<ColorUniforms>.size, index: 1)
        curve.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    /// Alpha-aware cross-dissolve into a CVPixelBuffer.
    private func encodeCrossDissolve(
        acc: CVPixelBuffer,
        a: CVPixelBuffer, aUniforms: LayerUniforms, aColor: ColorUniforms = .disabled, aCurve: [Float] = OfflineSequenceCompositor.identityCurveLUT,
        b: CVPixelBuffer, bUniforms: LayerUniforms, bColor: ColorUniforms = .disabled, bCurve: [Float] = OfflineSequenceCompositor.identityCurveLUT,
        progress: Double,
        into output: CVPixelBuffer,
        on cmd: MTLCommandBuffer
    ) {
        guard let dst = makeTexture(from: output, usage: [.renderTarget]) else { return }
        encodeCrossDissolve(
            acc: acc, a: a, aUniforms: aUniforms, aColor: aColor, aCurve: aCurve,
            b: b, bUniforms: bUniforms, bColor: bColor, bCurve: bCurve,
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
        a: CVPixelBuffer, aUniforms: LayerUniforms, aColor: ColorUniforms = .disabled, aCurve: [Float] = OfflineSequenceCompositor.identityCurveLUT,
        b: CVPixelBuffer, bUniforms: LayerUniforms, bColor: ColorUniforms = .disabled, bCurve: [Float] = OfflineSequenceCompositor.identityCurveLUT,
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
        var ca = aColor, cb = bColor
        enc.setFragmentBytes(&ca, length: MemoryLayout<ColorUniforms>.size, index: 1)
        enc.setFragmentBytes(&cb, length: MemoryLayout<ColorUniforms>.size, index: 2)
        aCurve.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 3) }
        bCurve.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 4) }
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

    // ===== Color management + grade (the `kine.color` effect) =====
    // Mirror of Swift's ColorUniforms.
    struct ColorUniforms {
        float4 c0;  // x=inputSpaceID, y=expGain(2^stops), z=contrast, w=satMult
        float4 c1;  // x=temp, y=tint, z=highlights, w=shadows
        float4 c2;  // x=whites, y=blacks, z=vibrance, w=enabled
        float4 g0;  // camera-gamut → Rec.709 matrix rows (.xyz)
        float4 g1;
        float4 g2;
    };

    static inline float3 srgbToLinear(float3 c) {
        float3 lo = c / 12.92;
        float3 hi = pow(max((c + 0.055) / 1.055, 0.0), float3(2.4));
        return select(lo, hi, c > 0.04045);
    }
    static inline float3 rec709ToLinear(float3 c) { return pow(max(c, 0.0), float3(2.4)); }
    static inline float3 linearToRec709(float3 c) { return pow(max(c, 0.0), float3(1.0 / 2.4)); }

    static inline float logC3ToLin(float x) {
        return (x > 0.149658) ? (pow(10.0, (x - 0.385537) / 0.2471896) - 0.052272) / 5.555556
                              : (x - 0.092809) / 5.367655;
    }
    static inline float sLog3ToLin(float x) {
        return (x >= 0.1673609) ? (pow(10.0, (x * 1023.0 - 420.0) / 261.5) * 0.19 - 0.01)
                                : (x * 1023.0 - 95.0) * 0.01125000 / (171.2102946 - 95.0);
    }
    // Canon C-Log3 decode (colour-science constants).
    static inline float cLog3ToLin(float x) {
        if (x < 0.04076162)  return -(pow(10.0, (0.07623209 - x) / 0.42889912) - 1.0) / 14.98325;
        if (x <= 0.105357102) return (x - 0.073059361) / 2.3069815;
        return (pow(10.0, (x - 0.069886632) / 0.42889912) - 1.0) / 14.98325;
    }
    // Canon C-Log2 decode (colour-science constants).
    static inline float cLog2ToLin(float x) {
        return (x < 0.035388128)
            ? -(pow(10.0, (0.035388128 - x) / 0.281863093) - 1.0) / 87.09937546
            :  (pow(10.0, (x - 0.035388128) / 0.281863093) - 1.0) / 87.09937546;
    }
    static inline float vLogToLin(float x) {
        return (x < 0.181) ? (x - 0.125) / 5.6 : pow(10.0, (x - 0.598206) / 0.241514) - 0.00873;
    }

    static inline float3 decodeToLinear(float3 enc, int space) {
        switch (space) {
            case 1: return srgbToLinear(enc);
            case 2: return max(enc, 0.0);
            case 3: return rec709ToLinear(enc);   // Rec.2020 transfer (2.4)
            case 4: return float3(logC3ToLin(enc.r), logC3ToLin(enc.g), logC3ToLin(enc.b));
            case 5: return float3(sLog3ToLin(enc.r), sLog3ToLin(enc.g), sLog3ToLin(enc.b));
            case 6: return float3(cLog3ToLin(enc.r), cLog3ToLin(enc.g), cLog3ToLin(enc.b));
            case 7: return float3(vLogToLin(enc.r), vLogToLin(enc.g), vLogToLin(enc.b));
            case 8: return float3(cLog2ToLin(enc.r), cLog2ToLin(enc.g), cLog2ToLin(enc.b));
            default: return rec709ToLinear(enc);
        }
    }

    static inline float lumaRec709(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

    /// Sample one channel of the 4×32 curve LUT (linear interp). ch:
    /// 0=master, 1=R, 2=G, 3=B.
    static inline float sampleCurve(constant float* curves, int ch, float x) {
        x = saturate(x);
        float fi = x * 31.0;
        int i0 = int(fi);
        int i1 = min(i0 + 1, 31);
        float f = fi - float(i0);
        int base = ch * 32;
        return mix(curves[base + i0], curves[base + i1], f);
    }

    /// enc = display/log-encoded source RGB → returns display-referred
    /// Rec.709 after a color-managed grade. Pass-through when disabled.
    static inline float3 applyColorGrade(float3 enc, constant ColorUniforms& u, constant float* curves) {
        if (u.c2.w < 0.5) return enc;
        int space = int(u.c0.x + 0.5);

        // 1. Input transform → scene-linear, then camera-gamut → Rec.709
        //    working primaries (identity for Rec.709 inputs).
        float3 cam = decodeToLinear(clamp(enc, 0.0, 1.0), space);
        float3 lin = float3(dot(u.g0.xyz, cam), dot(u.g1.xyz, cam), dot(u.g2.xyz, cam));

        // 2. Scene-linear: white balance + exposure.
        float temp = u.c1.x, tint = u.c1.y;
        lin *= float3(1.0 + 0.30 * temp + 0.10 * tint,
                      1.0 - 0.30 * tint,
                      1.0 - 0.30 * temp + 0.10 * tint);
        lin *= u.c0.y;

        // 3. Linear → display-referred Rec.709 for tonal/creative ops.
        float3 v = clamp(linearToRec709(max(lin, 0.0)), 0.0, 1.0);

        // 4. Tonal zones (smooth luminance masks).
        float L = lumaRec709(v);
        v += u.c1.w * 0.5 * pow(saturate(1.0 - L), 2.0);   // shadows
        v += u.c1.z * 0.5 * pow(saturate(L), 2.0);         // highlights
        v += u.c2.y * 0.3 * pow(saturate(1.0 - L), 4.0);   // blacks
        v += u.c2.x * 0.3 * pow(saturate(L), 4.0);         // whites
        v = saturate(v);

        // 5. Contrast about 0.5.
        v = saturate((v - 0.5) * (1.0 + u.c0.z) + 0.5);

        // 6. Saturation + vibrance.
        float L2 = lumaRec709(v);
        v = mix(float3(L2), v, u.c0.w);
        float mx = max(v.r, max(v.g, v.b));
        float mn = min(v.r, min(v.g, v.b));
        float vibAmt = u.c2.z * (1.0 - (mx - mn));
        v = mix(float3(L2), v, 1.0 + vibAmt);
        v = saturate(v);

        // 7. Curves: per-channel (R/G/B), then master applied to all.
        v.r = sampleCurve(curves, 1, v.r);
        v.g = sampleCurve(curves, 2, v.g);
        v.b = sampleCurve(curves, 3, v.b);
        v.r = sampleCurve(curves, 0, v.r);
        v.g = sampleCurve(curves, 0, v.g);
        v.b = sampleCurve(curves, 0, v.b);
        return saturate(v);
    }

    fragment float4 compositorBlendFragment(
        VertexOut in                              [[stage_in]],
        texture2d<float, access::sample> bottom   [[texture(0)]],
        texture2d<float, access::sample> top      [[texture(1)]],
        constant LayerUniforms& u                 [[buffer(0)]],
        constant ColorUniforms& col               [[buffer(1)]],
        constant float* curves                    [[buffer(2)]],
        texture3d<float, access::sample> lut      [[texture(2)]]
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
        t.rgb = applyColorGrade(t.rgb, col, curves);
        // Creative .cube LUT (applied in display Rec.709, blended by intensity).
        if (col.g0.w > 0.5) {
            constexpr sampler ls(filter::linear, address::clamp_to_edge);
            float3 looked = lut.sample(ls, saturate(t.rgb)).rgb;
            t.rgb = mix(t.rgb, looked, col.g1.w);
        }
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
        constant CrossDissolveUniforms& u         [[buffer(0)]],
        constant ColorUniforms& colA              [[buffer(1)]],
        constant ColorUniforms& colB              [[buffer(2)]],
        constant float* curvesA                   [[buffer(3)]],
        constant float* curvesB                   [[buffer(4)]]
    ) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = in.uv;
        float4 accColor = acc.sample(s, uv);

        float3 aSample = sampleLayerUV(uv, u.aDestRect, u.aCropRect, u.aRotation);
        float wA = aSample.z > 0.5 ? u.weights.x : 0.0;
        float3 aColor = wA > 0.0 ? applyColorGrade(texA.sample(s, aSample.xy).rgb, colA, curvesA) : float3(0.0);

        float3 bSample = sampleLayerUV(uv, u.bDestRect, u.bCropRect, u.bRotation);
        float wB = bSample.z > 0.5 ? u.weights.y : 0.0;
        float3 bColor = wB > 0.0 ? applyColorGrade(texB.sample(s, bSample.xy).rgb, colB, curvesB) : float3(0.0);

        float wAcc = max(0.0, 1.0 - wA - wB);
        float3 rgb = accColor.rgb * wAcc + aColor * wA + bColor * wB;
        return float4(rgb, 1.0);
    }
    """
}
