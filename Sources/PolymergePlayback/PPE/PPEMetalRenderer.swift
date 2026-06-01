import AppKit
import CoreMedia
import CoreVideo
import Metal
import MetalKit
import QuartzCore

/// Metal-based video renderer for PPE. Decoded frames from a
/// `PPEFrameQueue` are uploaded into an `MTLTexture` via
/// `CVMetalTextureCache` (zero-copy when the pixel buffer is
/// Metal-compatible, which AVAssetFrameSource guarantees by
/// setting `kCVPixelBufferMetalCompatibilityKey`) and drawn onto
/// a `CAMetalLayer` sized to the hosting view.
///
/// **Why Metal instead of `AVSampleBufferDisplayLayer`.** The
/// sample-buffer display layer schedules frames on its own via
/// its `CMTimebase`, which is wall-clock-locked and drifts from
/// the audio engine. Metal gives us direct control: on each
/// `CADisplayLink` tick (screen refresh), the renderer queries
/// the master clock via a caller-supplied closure, looks up
/// the best frame in the queue, and draws it. No decoder
/// scheduling, no timebase, no flush-on-seek stutter. Frame
/// drops are explicit ("nothing new, hold last frame") instead
/// of happening inside AVFoundation where we can't see them.
///
/// **Shader**: minimal pass-through. Vertex shader emits two
/// triangles covering NDC with UVs; fragment samples the
/// frame texture. No color transform yet — that's M7's
/// exposure + LUT chain, which will plug in by chaining
/// additional fragment stages. 32BGRA input → display output;
/// sRGB gamma is handled by CAMetalLayer's default
/// `colorspace` / `pixelFormat` settings (BGRA8Unorm_sRGB).
public final class PPEMetalRenderer {

    // MARK: - Metal objects

    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    /// Color-prep pipeline (exposure + 3D LUT). Selected instead
    /// of `pipelineState` when the active video has a non-zero
    /// exposure or a LUT attached.
    private let colorPipelineState: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    /// Sampler for the 3D LUT texture — trilinear interpolation,
    /// clamp-to-edge on all three axes so out-of-gamut source
    /// colors don't wrap.
    private let lutSampler: MTLSamplerState
    private let textureCache: CVMetalTextureCache

    /// Most-recent LUT upload. Keyed by URL so re-selecting the
    /// same LUT reuses the cached texture instead of re-parsing.
    /// Non-owning — cleared on `resetLastFrame` when the video
    /// changes since the LUT may not apply to the new video.
    private var cachedLUT: PPELUTLoader.LoadedLUT?

    // MARK: - State

    /// The layer that frames are drawn into. Install as the
    /// backing layer of a layer-backed NSView via `MetalRenderView`.
    public let layer: CAMetalLayer

    /// The `CustomVideoPlayer` this renderer pulls decode state
    /// from. Weak so the controller can be released without
    /// keeping the renderer alive. The renderer reads `frameQueue`
    /// and `currentVideoLocalSeconds()` off the controller on
    /// each display-link tick. The controller bumps its
    /// `generation` on video change; the renderer notices and
    /// resets `lastDrawnFrame` so stale frames don't carry over.
    public weak var controller: CustomVideoPlayer? {
        didSet {
            // Generation tracking persists across controller
            // assignment — it's a sentinel, reset to 0 is fine.
            lastSeenGeneration = 0
            lastDrawnFrame = nil
        }
    }
    private var lastSeenGeneration: UInt64 = 0

    /// The latest frame we actually uploaded + drew. Held to
    /// draw again on subsequent refresh ticks when the queue
    /// has nothing newer ("hold last frame" behavior). Also
    /// retains the pixel buffer so the texture cache entry
    /// stays valid.
    private var lastDrawnFrame: PPEDecodedFrame?

    /// Fired (on the main queue) the first time a fresh frame is drawn
    /// after a generation reset (video change / seek). Lets a caller hold
    /// a placeholder until real video is on screen, avoiding a cold-start
    /// black flash. One-shot per reset.
    public var onFirstFrameAfterReset: (() -> Void)?
    private var firstFramePending = false

    private var displayLink: CVDisplayLink?
    private var displayLinkCallbackBox: Unmanaged<DisplayLinkWrapper>?

    // Diagnostic counters printed once per second while the
    // display link is running. Turned off by default; flip
    // `PPEMetalRenderer.debugLog` at compile time if the
    // user reports "black screen" or "choppy PPE" again.
    public static let debugLog: Bool = false
    private var diagFramesThisSec: Int = 0
    private var diagNilThisSec: Int = 0
    private var diagLastLog: CFTimeInterval = 0

    // MARK: - Init

    /// Create a renderer with a default Metal device. Throws if
    /// Metal isn't available (this is macOS 14+ so that's very
    /// unlikely — every shipping Mac since 2012 has a Metal
    /// GPU).
    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RendererError.metalUnavailable
        }
        guard let cq = device.makeCommandQueue() else {
            throw RendererError.commandQueueCreation
        }
        self.device = device
        self.commandQueue = cq

        // Build the render pipeline from an inline shader. The
        // shader is tiny (two-triangle fullscreen pass) so
        // embedding it here rather than in a .metal file keeps
        // the PPE self-contained.
        let library = try device.makeLibrary(
            source: Self.shaderSource,
            options: nil
        )
        guard let vertexFn = library.makeFunction(name: "ppeVertexMain"),
              let fragmentFn = library.makeFunction(name: "ppeFragmentMain"),
              let fragmentColorFn = library.makeFunction(name: "ppeFragmentColor") else {
            throw RendererError.shaderCompilation
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.pipelineState = try device.makeRenderPipelineState(descriptor: desc)

        let colorDesc = MTLRenderPipelineDescriptor()
        colorDesc.vertexFunction = vertexFn
        colorDesc.fragmentFunction = fragmentColorFn
        colorDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.colorPipelineState = try device.makeRenderPipelineState(descriptor: colorDesc)

        // Default sampler: linear filtering so the 4K → preview
        // downscale path gets clean minification. Edge-clamping
        // avoids artifacts at view edges.
        let sdesc = MTLSamplerDescriptor()
        sdesc.minFilter = .linear
        sdesc.magFilter = .linear
        sdesc.sAddressMode = .clampToEdge
        sdesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sdesc) else {
            throw RendererError.samplerCreation
        }
        self.sampler = sampler

        // Separate sampler for the 3D LUT: trilinear + clamp on
        // all three axes so out-of-gamut colors snap to the
        // edge cell instead of wrapping.
        let lsdesc = MTLSamplerDescriptor()
        lsdesc.minFilter = .linear
        lsdesc.magFilter = .linear
        lsdesc.sAddressMode = .clampToEdge
        lsdesc.tAddressMode = .clampToEdge
        lsdesc.rAddressMode = .clampToEdge
        guard let lutSampler = device.makeSamplerState(descriptor: lsdesc) else {
            throw RendererError.samplerCreation
        }
        self.lutSampler = lutSampler

        // Texture cache for zero-copy pixel-buffer → MTLTexture
        // uploads. Apple's recommended path; avoids a `memcpy`
        // per frame.
        var cacheOut: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cacheOut
        )
        guard status == kCVReturnSuccess, let cache = cacheOut else {
            throw RendererError.textureCacheCreation(Int(status))
        }
        self.textureCache = cache

        // The CAMetalLayer that shows frames. Caller installs
        // it as the backing layer of an NSView.
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        // Present through Core Animation's transaction system so the
        // layer participates in compositing — its `opacity` honors
        // SwiftUI's `.opacity()` modifier, two PPE layers stacked in a
        // ZStack actually alpha-blend, and the render path lines up
        // with CA's vsync. Costs ~1 frame of latency (the wait-until-
        // scheduled pattern in `draw`), which is invisible at NLE
        // playback rates and well within typical video-engine slop.
        layer.presentsWithTransaction = true
        layer.isOpaque = false
        layer.needsDisplayOnBoundsChange = true
        // Aspect-preserving contentsGravity so video centers in
        // the layer bounds; Metal handles the actual scaling.
        layer.contentsGravity = .resizeAspect
        self.layer = layer
    }

    deinit {
        stop()
    }

    // MARK: - Display link lifecycle

    /// Start driving frame presentation from screen refresh.
    /// Safe to call multiple times (no-op if already running).
    public func start() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else {
            print("[PPE renderer] failed to create CVDisplayLink")
            return
        }
        let wrapper = DisplayLinkWrapper { [weak self] in
            self?.drawCurrentFrame()
        }
        let ptr = Unmanaged.passRetained(wrapper)
        self.displayLinkCallbackBox = ptr
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userInfo -> CVReturn in
            guard let userInfo else { return kCVReturnError }
            let w = Unmanaged<DisplayLinkWrapper>.fromOpaque(userInfo).takeUnretainedValue()
            w.callback()
            return kCVReturnSuccess
        }, ptr.toOpaque())
        CVDisplayLinkStart(link)
        self.displayLink = link
    }

    /// Stop driving frame presentation. The last-drawn frame
    /// stays on screen.
    public func stop() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
        displayLink = nil
        displayLinkCallbackBox?.release()
        displayLinkCallbackBox = nil
    }

    /// Clear the "last drawn" latch. Call this on seek so the
    /// renderer doesn't keep showing the pre-seek frame while
    /// the decoder is flushing + refilling.
    public func resetLastFrame() {
        lastDrawnFrame = nil
    }

    // MARK: - Frame drawing

    /// Called on the CVDisplayLink thread (NOT main). Queries
    /// the frame queue, uploads if a new frame is available,
    /// draws whatever we have into the layer.
    private func drawCurrentFrame() {
        let ctrl = controller
        // Controller bumps `generation` when the active video
        // changes or a seek fires. Drop the last-drawn frame so
        // we don't keep showing the pre-switch image, and flush
        // the Metal texture cache so CVPixelBuffers from the
        // prior video release their backing IOSurfaces promptly.
        // Without this flush, a user scrubbing across many
        // cameras can accumulate 1-2 GB of IOSurface memory
        // (4K BGRA = 33 MB/buffer × many cached entries).
        if let g = ctrl?.generation, g != lastSeenGeneration {
            lastSeenGeneration = g
            lastDrawnFrame = nil
            firstFramePending = true
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        let queueRef = ctrl?.frameQueue
        let target = ctrl?.currentVideoLocalSeconds()
        let fromQueue = queueRef?.frame(forPlaybackSeconds: target ?? -1)
        let frameToShow = fromQueue ?? lastDrawnFrame
        if let frame = frameToShow {
            lastDrawnFrame = frame
            draw(frame: frame)
            if firstFramePending {
                // Only signal "ready" once we're actually showing the
                // playback target region. After a seek (especially the
                // reverse-lookahead seek, which lands ~1.25s early) the
                // first post-reset frames are far from the target; firing
                // here would flash that wrong area before catch-up. Holding
                // until pts ≈ target keeps the placeholder over the gap.
                let reachedTarget = target.map { CMTimeGetSeconds(frame.pts) >= $0 - 0.1 } ?? true
                if reachedTarget {
                    firstFramePending = false
                    let cb = onFirstFrameAfterReset
                    DispatchQueue.main.async { cb?() }
                }
            }
            if Self.debugLog { diagFramesThisSec &+= 1 }
        } else if Self.debugLog {
            diagNilThisSec &+= 1
        }
        if Self.debugLog {
            let now = CACurrentMediaTime()
            if diagLastLog == 0 { diagLastLog = now }
            if now - diagLastLog >= 1.0 {
                let stats = queueRef?.stats()
                print(String(format: "[PPE renderer] %ds: drew=%d nil=%d  target=%@ qdepth=%d/%d eof=%@",
                             Int(now),
                             diagFramesThisSec,
                             diagNilThisSec,
                             target.map { String(format: "%.3f", $0) } ?? "nil",
                             stats?.depth ?? -1,
                             stats?.capacity ?? -1,
                             (stats?.reachedEOF ?? false) ? "yes" : "no"))
                diagFramesThisSec = 0
                diagNilThisSec = 0
                diagLastLog = now
            }
        }
    }

    private func draw(frame: PPEDecodedFrame) {
        let pixelBuffer = frame.pixelBuffer
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return }

        // Build a Metal texture from the pixel buffer via the
        // cache. Zero-copy on Apple Silicon + Intel Metal-
        // compatible pixel buffers.
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width, height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTex = cvTexture,
              let mtlTex = CVMetalTextureGetTexture(cvTex) else {
            return
        }

        // Grab the next drawable. Under heavy load
        // `nextDrawable` can return nil — skip this tick
        // rather than block; the next display-link callback
        // will try again.
        guard let drawable = layer.nextDrawable() else { return }

        // Match layer drawable size to the layer's current
        // bounds in pixels. The layer's `contentsGravity =
        // resizeAspect` handles aspect correction at
        // composition time.
        let contentsScale = layer.contentsScale > 0 ? layer.contentsScale : 2
        let layerSize = layer.bounds.size
        let pixelW = Int(layerSize.width * contentsScale)
        let pixelH = Int(layerSize.height * contentsScale)
        if pixelW > 0, pixelH > 0,
           layer.drawableSize.width != CGFloat(pixelW) ||
           layer.drawableSize.height != CGFloat(pixelH) {
            layer.drawableSize = CGSize(width: pixelW, height: pixelH)
        }

        // Compute the aspect-fit vertex coords. NDC is [-1, 1]
        // on both axes. We preserve the source's aspect and
        // letterbox / pillarbox as needed.
        let drawW = Double(layer.drawableSize.width)
        let drawH = Double(layer.drawableSize.height)
        let srcAspect = Double(width) / Double(height)
        let dstAspect = (drawW > 0 && drawH > 0) ? drawW / drawH : 1
        var sx: Float = 1, sy: Float = 1
        if srcAspect > dstAspect {
            // Source wider than target: letterbox top/bottom
            sy = Float(dstAspect / srcAspect)
        } else if srcAspect < dstAspect {
            // Source narrower than target: pillarbox sides
            sx = Float(srcAspect / dstAspect)
        }

        // 6 vertices = 2 triangles forming the fit rect.
        // Each vertex: (x, y, u, v).
        let verts: [Float] = [
            -sx,  sy, 0, 0,
            -sx, -sy, 0, 1,
             sx,  sy, 1, 0,
             sx,  sy, 1, 0,
            -sx, -sy, 0, 1,
             sx, -sy, 1, 1,
        ]

        // Decide which pipeline to use based on the active
        // video's color-prep state. The pass-through pipeline
        // is the cheapest path — take it when exposure is 0
        // AND no LUT is attached. Otherwise switch to the
        // color-prep pipeline with uniforms + optional 3D LUT.
        let exposureStops = controller?.currentVideo?.exposureStops ?? 0
        let lutURL = controller?.currentVideo?.lutURL
        let activeLUT = resolveLUT(for: lutURL)
        let wantsColorPrep = (exposureStops != 0) || (activeLUT != nil)

        guard let cmd = commandQueue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        if wantsColorPrep {
            enc.setRenderPipelineState(colorPipelineState)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.setFragmentSamplerState(lutSampler, index: 1)
            enc.setFragmentTexture(mtlTex, index: 0)
            if let activeLUT {
                enc.setFragmentTexture(activeLUT.texture, index: 1)
            }
            // Uniforms: gain = 2^stops (exposure multiply in
            // linear light); lutEnabled = 0/1. Keeping these
            // two fields minimal so the shader's constant-buffer
            // fetch is a single cache line.
            var uniforms = ColorUniforms(
                exposureGain: Float(pow(2.0, exposureStops)),
                lutEnabled: activeLUT != nil ? 1 : 0
            )
            enc.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<ColorUniforms>.size,
                index: 0
            )
        } else {
            enc.setRenderPipelineState(pipelineState)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.setFragmentTexture(mtlTex, index: 0)
        }
        verts.withUnsafeBytes { raw in
            enc.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()
        // CATransaction-integrated present (pairs with
        // `layer.presentsWithTransaction = true`). The display link
        // fires off the main thread; we wait for the GPU to schedule
        // the work, then dispatch the present to main so it joins
        // CoreAnimation's main-thread implicit transaction. Calling
        // `drawable.present()` directly off-thread (or wrapping in an
        // explicit CATransaction commit from this thread) deadlocked
        // CA when multiple PPE instances were composited together —
        // main was getting flooded with cross-thread transaction
        // commits. `drawable.present()` itself is thread-safe and
        // queues for the next main-runloop transaction; dispatching
        // here just makes that runloop boundary explicit.
        cmd.commit()
        cmd.waitUntilScheduled()
        DispatchQueue.main.async {
            drawable.present()
        }
    }

    /// Swift-side mirror of the shader's `PPEColorUniforms`
    /// struct. Must match layout + size exactly — the renderer
    /// passes this through `setFragmentBytes`.
    private struct ColorUniforms {
        var exposureGain: Float
        var lutEnabled: UInt32
    }

    /// Resolve the active LUT for a URL, using the cached
    /// upload when possible. Switching from "LUT A" back to
    /// "LUT A" doesn't re-parse the file. Switching away from a
    /// LUT drops the cache so GPU memory releases.
    private func resolveLUT(for url: URL?) -> PPELUTLoader.LoadedLUT? {
        guard let url else {
            cachedLUT = nil
            return nil
        }
        if let cached = cachedLUT, cached.sourceURL == url {
            return cached
        }
        do {
            let loaded = try PPELUTLoader.load(url: url, device: device)
            cachedLUT = loaded
            return loaded
        } catch {
            print("[PPE renderer] LUT load failed for \(url.lastPathComponent): \(error.localizedDescription)")
            cachedLUT = nil
            return nil
        }
    }

    // MARK: - Shader

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    // Inline vertex layout (x,y,u,v float4 packed) — use
    // buffer(0) with 16-byte stride. Same as setVertexBytes.
    vertex VOut ppeVertexMain(
        uint vid [[vertex_id]],
        constant float *verts [[buffer(0)]]
    ) {
        VOut out;
        const uint base = vid * 4u;
        out.position = float4(verts[base + 0], verts[base + 1], 0.0, 1.0);
        out.uv       = float2(verts[base + 2], verts[base + 3]);
        return out;
    }

    // Pass-through fragment — no exposure, no LUT. Used when
    // both adjustments are inactive (fast path, zero GPU cost
    // for color math).
    fragment float4 ppeFragmentMain(
        VOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]]
    ) {
        return tex.sample(samp, in.uv);
    }

    // Color-prep fragment: exposure multiply + optional 3D LUT.
    // Workflow:
    //   1. Sample BGRA source (sRGB-encoded).
    //   2. sRGB → linear (approximate via pow 2.2; good enough
    //      for preview, not math-exact sRGB EOTF).
    //   3. Multiply by 2^exposureStops (exposure comp, linear
    //      light).
    //   4. Linear → display-normalized (back to 0..1 sRGB-ish).
    //   5. If LUT provided: 3D texture sample with trilinear
    //      filtering, bypassing the linear stage since most
    //      production LUTs are designed against Rec.709 /
    //      log-display input.
    //   6. Output.
    //
    // The `gain` uniform is pre-computed on the CPU as
    // `pow(2, stops)` so the shader is branchless on the hot
    // path. `lutEnabled` is a 0/1 int so the compiler can
    // peephole-optimize the skip path.
    struct PPEColorUniforms {
        float exposureGain;  // 2^stops
        uint  lutEnabled;    // 0 or 1
    };

    fragment float4 ppeFragmentColor(
        VOut in [[stage_in]],
        texture2d<float> tex      [[texture(0)]],
        texture3d<float> lutTex   [[texture(1)]],
        sampler samp              [[sampler(0)]],
        sampler lutSamp           [[sampler(1)]],
        constant PPEColorUniforms &u [[buffer(0)]]
    ) {
        float4 c = tex.sample(samp, in.uv);

        // Exposure: sRGB → linear → multiply → sRGB. Using
        // gamma 2.2 rather than full sRGB EOTF — a close-enough
        // approximation for on-set monitoring and saves a pair
        // of piecewise branches per pixel.
        float3 lin = pow(c.rgb, float3(2.2));
        lin *= u.exposureGain;
        lin = max(lin, 0.0);
        float3 srgb = pow(lin, float3(1.0 / 2.2));
        srgb = clamp(srgb, 0.0, 1.0);

        if (u.lutEnabled != 0) {
            // Sample the 3D LUT. Texture UV is already [0, 1]
            // and the loader normalized the LUT's declared
            // domain into that range.
            float3 lutResult = lutTex.sample(lutSamp, srgb).rgb;
            return float4(lutResult, c.a);
        }

        return float4(srgb, c.a);
    }
    """

    public enum RendererError: LocalizedError {
        case metalUnavailable
        case commandQueueCreation
        case shaderCompilation
        case samplerCreation
        case textureCacheCreation(Int)

        public var errorDescription: String? {
            switch self {
            case .metalUnavailable: return "Metal unavailable on this system"
            case .commandQueueCreation: return "Could not create Metal command queue"
            case .shaderCompilation: return "PPE shader compilation failed"
            case .samplerCreation: return "Could not create Metal sampler state"
            case .textureCacheCreation(let c): return "CVMetalTextureCacheCreate failed (\(c))"
            }
        }
    }
}

/// Box so we can pass an @escaping closure through
/// CVDisplayLink's opaque-pointer callback API.
private final class DisplayLinkWrapper {
    let callback: () -> Void
    init(_ callback: @escaping () -> Void) {
        self.callback = callback
    }
}
