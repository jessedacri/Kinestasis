import SwiftUI
import AppKit
import CoreVideo
import Metal
import QuartzCore
import AVFoundation
import PreemCore
import PreemMedia
import PreemRender

/// Realtime program-viewer host. ONE `CAMetalLayer`, driven at the
/// display's refresh rate by `CVDisplayLink`, that uses the same
/// `OfflineSequenceCompositor` the encoder uses for offline render.
///
/// That guarantees realtime ≡ render (by construction): one Sequence
/// → one compositor → identical pixels at the playhead.
///
/// **Frame-drop detection.** Each compose+present roundtrip is timed.
/// If it exceeds the display's frame budget for a sustained run, we
/// bump `workspace.recentFrameDrops` and the program viewer header
/// surfaces a subtle chip suggesting Render In to Out for the active
/// region.
///
/// **Cache substitution fast path.** When the playhead is inside a
/// cached pre-render range, the host bypasses the compositor and
/// reads the cache .mov via a dedicated `AVAssetFrameSource`,
/// blitting straight to the drawable. No compositing cost.
public struct RealtimeProgramHostView: NSViewRepresentable {
    @ObservedObject var workspace: WorkspaceModel

    public func makeCoordinator() -> Coordinator {
        Coordinator(workspace: workspace)
    }

    public func makeNSView(context: Context) -> RealtimeMetalView {
        let view = RealtimeMetalView()
        view.attach(coordinator: context.coordinator)
        context.coordinator.start()
        return view
    }

    public func updateNSView(_ nsView: RealtimeMetalView, context: Context) {
        context.coordinator.workspace = workspace
        // SwiftUI re-renders kick the coordinator so it notices new
        // sequence specs and rebuilds the compositor when needed.
        context.coordinator.scheduleSyncCheck()
    }

    public static func dismantleNSView(_ nsView: RealtimeMetalView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    public final class Coordinator {
        weak var workspace: WorkspaceModel?
        weak var metalView: RealtimeMetalView?

        private let device: MTLDevice
        private let commandQueue: MTLCommandQueue
        private var compositor: OfflineSequenceCompositor?
        private var compositorSpec: CompositorSpec?
        private var displayLink: CVDisplayLink?

        // Frame-drop tracking — published to workspace via a debounce
        // so the UI doesn't flicker on a single late frame.
        private var consecutiveDrops: Int = 0

        // Cache substitution: keep one reader open per cache .mov so
        // playing across the same cached range doesn't reopen.
        private var cacheReader: CacheFrameReader?
        private var lastCacheURL: URL?

        // True when a compose+present task is mid-flight. If the
        // display link fires another tick before the previous finishes,
        // we drop it. Prevents queueing tasks on main actor (which
        // would freeze UI) and bounds the number of in-flight drawables
        // to 1.
        nonisolated(unsafe) private var inFlight: Bool = false

        init(workspace: WorkspaceModel) {
            self.workspace = workspace
            guard let d = PreemRender.device else {
                fatalError("Metal device unavailable")
            }
            self.device = d
            guard let q = d.makeCommandQueue() else {
                fatalError("Could not make Metal command queue")
            }
            self.commandQueue = q
        }

        func start() {
            installDisplayLink()
        }

        func teardown() {
            if let link = displayLink {
                CVDisplayLinkStop(link)
                displayLink = nil
            }
            compositor?.teardown()
            compositor = nil
            cacheReader = nil
        }

        func scheduleSyncCheck() {
            ensureCompositorMatchesSequence()
        }

        // MARK: - Display link

        private func installDisplayLink() {
            var link: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&link)
            guard let link else {
                PreemDebugLog.log("[Realtime] CVDisplayLinkCreate failed")
                return
            }
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                guard let self else { return kCVReturnSuccess }
                Task { @MainActor in self.renderTick() }
                return kCVReturnSuccess
            }
            CVDisplayLinkStart(link)
            displayLink = link
        }

        // MARK: - Frame source for cache files

        private func cacheFrameReader(for url: URL) -> CacheFrameReader? {
            if url == lastCacheURL, let r = cacheReader { return r }
            cacheReader = try? CacheFrameReader(url: url, device: device)
            lastCacheURL = url
            return cacheReader
        }

        // MARK: - Tick

        /// Called on the main actor from the display link. Does only
        /// the quick work that needs main-actor isolation (read
        /// workspace state, refresh compositor spec, set drawable
        /// size, acquire `nextDrawable`), then HANDS OFF compose +
        /// present to a detached Task. Main actor stays free for UI
        /// events — that's what fixes the editor-wide lag.
        private func renderTick() {
            guard let workspace, let view = metalView, let layer = view.metalLayer else { return }
            // Drop this tick if a previous compose+present is still in
            // flight. Bounds the GPU queue to 1 frame and keeps the
            // main actor from queueing pending render tasks.
            if inFlight { return }

            ensureCompositorMatchesSequence()
            let viewScale = view.window?.backingScaleFactor ?? 2.0
            let neededSize = CGSize(
                width: max(1, view.bounds.width * viewScale),
                height: max(1, view.bounds.height * viewScale)
            )
            if layer.drawableSize != neededSize {
                layer.drawableSize = neededSize
            }

            // No drawable typically means the window is hidden,
            // occluded, or off-screen — not a render budget miss.
            // Skipping without bumping `consecutiveDrops` prevents the
            // chip from sticking ON after the user hides/restores
            // the window.
            guard let drawable = layer.nextDrawable() else {
                return
            }

            // Snapshot everything compose needs while we're still on
            // main. After this point we never touch workspace from
            // the background.
            let playhead = workspace.playheadTime.seconds
            let cacheSeg = workspace.cacheSegmentAtPlayhead()
            let reader: CacheFrameReader? = cacheSeg.flatMap { cacheFrameReader(for: $0.url) }
            let segStart = cacheSeg?.startSeconds ?? 0
            let device = self.device
            let queue = self.commandQueue
            let cmp = self.compositor

            inFlight = true
            let started = Date()

            Task.detached(priority: .userInitiated) { [weak self] in
                // Compose into the drawable's texture. Either via cache
                // fast-path (blit) or via the compositor. Both run off
                // the main actor.
                if let reader {
                    let offset = playhead - segStart
                    reader.render(
                        at: offset,
                        into: drawable.texture,
                        device: device,
                        queue: queue,
                        compositor: cmp
                    )
                } else if let cmp {
                    do {
                        try await cmp.composeAsync(at: playhead, into: drawable.texture)
                    } catch {
                        PreemDebugLog.log("[Realtime] composeAsync failed: \(error.localizedDescription)")
                    }
                }
                drawable.present()

                // Bookkeeping — bump back to main actor only for the
                // small state writes.
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.noteDuration(started: started)
                    self.inFlight = false
                }
            }
        }

        private func noteDuration(started: Date) {
            // 16.6 ms = 60fps budget. We don't know the display's
            // actual refresh exactly here (could be 120Hz on a Pro),
            // so use a generous 20ms threshold for "drop suspected".
            let ms = Date().timeIntervalSince(started) * 1000.0
            if ms > 20 {
                // Cap so a long bad stretch doesn't take 10s of
                // recovery ticks to flush.
                consecutiveDrops = min(12, consecutiveDrops + 1)
            } else {
                // Decay quickly on good ticks — halving snaps back to
                // 0 in a few frames after a transient blip.
                consecutiveDrops = max(0, consecutiveDrops - 2)
            }
            publishDrop()
        }

        private func publishDrop() {
            guard let workspace else { return }
            // Hysteresis — turn the chip ON only after a sustained
            // run, OFF as soon as we're clean again. Avoids flicker.
            // Coalesce: only write when the bool actually changes, so
            // we don't fire the workspace's objectWillChange every
            // tick (which was burning a SwiftUI re-render per frame).
            let dropping = workspace.realtimeIsDropping
                ? consecutiveDrops > 2
                : consecutiveDrops >= 6
            if dropping != workspace.realtimeIsDropping {
                workspace.realtimeIsDropping = dropping
            }
        }

        // MARK: - Compositor (re)build

        private struct CompositorSpec: Equatable {
            let sequenceID: SequenceID
            let width: Int
            let height: Int
        }

        private func ensureCompositorMatchesSequence() {
            guard let workspace, let sequence = workspace.activeSequence else {
                compositor?.teardown()
                compositor = nil
                compositorSpec = nil
                return
            }
            let spec = CompositorSpec(
                sequenceID: sequence.id,
                width: sequence.settings.resolution.width,
                height: sequence.settings.resolution.height
            )
            if spec != compositorSpec {
                compositor?.teardown()
                compositor = try? OfflineSequenceCompositor(
                    sequence: sequence,
                    mediaPool: workspace.project.mediaPool,
                    outputWidth: spec.width,
                    outputHeight: spec.height
                )
                compositorSpec = spec
            } else {
                // Same sequence spec, but the sequence/mediaPool structs
                // may have mutated (transform edits, clip moves, etc.).
                // Push fresh snapshots into the compositor so the next
                // compose sees the latest state. Safe on main: the
                // `inFlight` guard ensures no detached compose is
                // currently reading these fields.
                compositor?.sequence = sequence
                compositor?.mediaPool = workspace.project.mediaPool
            }
        }
    }
}

/// NSView with `CAMetalLayer` as its backing layer. The coordinator
/// installs itself via `attach` so the display-link callback can find
/// the layer + workspace.
public final class RealtimeMetalView: NSView {
    public private(set) var metalLayer: CAMetalLayer?
    fileprivate weak var coordinator: RealtimeProgramHostView.Coordinator?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let l = CAMetalLayer()
        l.device = PreemRender.device
        l.pixelFormat = .bgra8Unorm
        l.framebufferOnly = false   // compositor writes via render passes
        l.isOpaque = true
        l.contentsGravity = .resize
        layer = l
        metalLayer = l
    }

    public required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    fileprivate func attach(coordinator: RealtimeProgramHostView.Coordinator) {
        self.coordinator = coordinator
        coordinator.metalView = self
    }

    public override func layout() {
        super.layout()
        // Trigger a coordinator sync so drawableSize updates pick up.
        coordinator?.scheduleSyncCheck()
    }
}

/// Reads frames from a pre-render cache `.mov` via `AVAssetReader`,
/// stepping forward on each call. Used by the realtime host's cache
/// fast-path. Reopens on a backward seek.
///
/// **Threading.** Designed for single-threaded use: the realtime host
/// guards against re-entrancy via its `inFlight` flag. Marked
/// `@unchecked Sendable` so we can pass it across the actor boundary
/// from main to the render Task; internal state isn't actually shared
/// across threads at any instant.
public final class CacheFrameReader: @unchecked Sendable {
    private let url: URL
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let nominalFrameRate: Double
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var lastDelivered: CMTime = .invalid
    private var lastDuration: CMTime = .invalid
    private var lastBuffer: CVPixelBuffer?

    public init(url: URL, device: MTLDevice) throws {
        self.url = url
        self.asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        guard let t = asset.tracks(withMediaType: .video).first else {
            throw NSError(domain: "preem.cache", code: 1)
        }
        self.track = t
        let rate = Double(t.nominalFrameRate)
        self.nominalFrameRate = rate > 0 ? rate : 24.0
        // Don't start the AVAssetReader here — the first `render(at:)`
        // call will start it at the right target time. Pre-starting at
        // 0 caused the realtime host to walk frames 0..N to catch up
        // to the actual playhead position after a render, producing a
        // visible fast-motion sweep.
    }

    private func restart(at start: CMTime) throws {
        let r = try AVAssetReader(asset: asset)
        let outSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: outSettings)
        out.alwaysCopiesSampleData = false
        r.add(out)
        r.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        r.startReading()
        self.reader = r
        self.output = out
        self.lastDelivered = .invalid
        self.lastDuration = .invalid
        self.lastBuffer = nil
    }

    public func render(
        at offsetSeconds: Double,
        into texture: MTLTexture,
        device: MTLDevice,
        queue: MTLCommandQueue,
        compositor: OfflineSequenceCompositor?
    ) {
        let target = CMTime(seconds: max(0, offsetSeconds), preferredTimescale: 600)

        // Decide whether to seek the AVAssetReader or walk forward.
        // - Reader not started yet (first render): seek straight to target.
        // - Backward jump: seek.
        // - Large forward gap (> 0.5 s): seek, otherwise walking N
        //   frames blocks the realtime host AND flashes each
        //   intermediate frame on screen.
        // - Otherwise: walk via `copyNextSampleBuffer`, cheap.
        let needsSeek: Bool = {
            if reader == nil { return true }
            guard lastDelivered.isValid else { return true }
            if CMTimeCompare(target, lastDelivered) < 0 { return true }
            if target.seconds - lastDelivered.seconds > 0.5 { return true }
            return false
        }()
        if needsSeek {
            try? restart(at: target)
        }

        // Fast path: target lies inside the last frame's [pts, pts+dur)
        // window — keep showing the same frame. This is what stops a
        // 24 fps cache file from advancing 60 times per second.
        if let buffer = lastBuffer,
           lastDelivered.isValid,
           lastDuration.isValid,
           CMTimeCompare(target, lastDelivered) >= 0,
           CMTimeCompare(target, CMTimeAdd(lastDelivered, lastDuration)) < 0 {
            present(buffer: buffer, into: texture, queue: queue, compositor: compositor)
            return
        }

        // Otherwise pull frames until target is inside the current
        // frame's window (or we've exhausted the source).
        let nominalDur = CMTime(
            seconds: 1.0 / max(1.0, nominalFrameRate),
            preferredTimescale: 600
        )
        var pulledLast = false
        var iterations = 0
        while let out = output, iterations < 32 {
            iterations += 1
            guard let sb = out.copyNextSampleBuffer(),
                  let buf = CMSampleBufferGetImageBuffer(sb) else { break }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            var dur = CMSampleBufferGetDuration(sb)
            if !dur.isValid || dur.seconds <= 0 { dur = nominalDur }
            lastDelivered = pts
            lastDuration = dur
            lastBuffer = buf
            pulledLast = true
            let endPTS = CMTimeAdd(pts, dur)
            // target inside [pts, endPTS) → done.
            if CMTimeCompare(target, pts) >= 0, CMTimeCompare(target, endPTS) < 0 {
                break
            }
            // target before this frame → we overshot via seek. Best-effort.
            if CMTimeCompare(target, pts) < 0 {
                break
            }
            // target past endPTS → keep pulling.
        }
        _ = pulledLast

        guard let buffer = lastBuffer else { return }
        present(buffer: buffer, into: texture, queue: queue, compositor: compositor)
    }

    private func present(
        buffer: CVPixelBuffer,
        into texture: MTLTexture,
        queue: MTLCommandQueue,
        compositor: OfflineSequenceCompositor?
    ) {
        if let compositor {
            // Aspect-fit the cache frame into the drawable via the
            // compositor's blend pipeline. Handles both downscale
            // (larger cache than drawable) and letterbox (different
            // aspects). Uses linear filtering, so the picture stays
            // crisp at any drawable size.
            compositor.presentSingleSourceFrame(buffer, into: texture)
        }
    }
}
