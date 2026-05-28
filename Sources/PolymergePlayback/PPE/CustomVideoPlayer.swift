import AVFoundation
import Combine
import CoreMedia
import Foundation
import PolymergeMediaModel

/// PolyMerge Playback Engine controller — the M4 integration
/// layer that ties everything together:
///
/// ```
/// AudioPlaybackEngine (master clock via currentAudibleSeconds)
///      │
///      ▼
/// CustomVideoPlayer
///   ├── VideoFrameSource  (M1: decodes)
///   ├── PPEFrameQueue      (M2: ring buffer of frames)
///   ├── PPEBackgroundDecoder (M2: keeps queue full)
///   └── PPEMetalRenderer   (M3: CADisplayLink-driven present)
/// ```
///
/// Parallel to `VideoPlayerController` during the migration
/// window. Views check `AppSettings.shared.useCustomVideoPlayer`
/// to decide which controller's output to show. When the flag
/// is off, nothing here runs; the legacy AVPlayer path handles
/// playback as before.
///
/// **A/V sync story**. Every tick, the Metal renderer's display
/// link callback calls `currentTimeProvider()`, which returns
/// `AudioPlaybackEngine.currentAudibleSeconds() -
/// video.timecode.totalSeconds`. The frame queue returns the
/// latest frame whose PTS is ≤ that time. That frame is drawn.
/// The audio and video share ONE source of truth for time —
/// the audio device's hardware clock, minus its output
/// latency. They cannot drift relative to each other because
/// they're reading the same number.
///
/// **Playback semantics**.
/// - play: start decoder + renderer display link. Audio engine
///   is assumed to already be playing (transport owns audio).
/// - pause: stop decoder + renderer. Last drawn frame stays
///   visible.
/// - seek: decoder seeks, queue flushes, renderer resets its
///   last-drawn latch so stale frame doesn't show.
/// - rate: not supported for custom path yet (forward 1× only).
///   Shuttle > 1× or reverse falls back to a static frame.
@Observable
public final class CustomVideoPlayer {

    // MARK: - Inputs + dependencies

    // Master-clock state. `syncVideoPlayer` passes the
    // session's `playheadAbsoluteSeconds` on every tick; we
    // stash it along with the host-time it was captured at so
    // the renderer (running on the display link thread at up
    // to 120 Hz) can interpolate between the tick-rate updates
    // without needing to reach into the session's observable
    // state on a background thread.
    private var lastAbsoluteSeconds: Double = 0
    private var lastAbsoluteHostTime: CFTimeInterval = 0
    /// Rate the master clock is advancing at — 0 when paused,
    /// the transport's rate when playing. Used by the
    /// renderer-side extrapolation so during steady-state play
    /// the frame we draw tracks wall-clock even though update()
    /// only fires at the transport tick rate.
    private var clockRate: Double = 0
    /// Lock protecting the three fields above. NSLock because
    /// this is a hot path on the render thread — actor hops
    /// would eat per-frame budget.
    private let clockLock = NSLock()

    // MARK: - Observable state

    /// File ID of the video currently loaded. Observable so
    /// views can rebuild only when the video actually changes.
    /// Follows the same semantics as `VideoPlayerController.
    /// currentVideoID` so the existing observation pattern keeps
    /// working.
    public private(set) var currentVideoID: UUID?
    public private(set) var currentVideo: VideoFile?
    public private(set) var isAtValidPosition: Bool = false

    // Renderers are owned by the VIEWS now (one per view
    // instance), not by this controller. Reason: a CAMetalLayer
    // can only have ONE parent; the previous design where one
    // shared renderer owned one layer put viewer window + embedded
    // preview in a tug-of-war over parenting, producing "black
    // preview when viewer is open" and "PPE stops working after
    // toggling LEGACY/PPE". Each view now creates its own renderer
    // and reads the decode pipeline (queue + time) from here.

    /// Frame queue populated by the background decoder. Published
    /// so view-owned renderers can pull frames. nil when no video
    /// is loaded.
    public private(set) var frameQueue: PPEFrameQueue?

    /// Generation counter — bumps each time a new video is
    /// attached. View-owned renderers observe this to reset
    /// their "last-drawn" latch so they don't keep showing the
    /// previous video's final frame across a camera switch.
    public private(set) var generation: UInt64 = 0

    // MARK: - Internal state

    private var decoder: PPEBackgroundDecoder?
    /// Video-local time offset — the timeline TC of the loaded
    /// video's first frame, in seconds. Subtracted from the
    /// master clock to get video-local playback time.
    private var videoStartTCSeconds: Double = 0
    private var videoDurationSeconds: Double = 0
    /// True when the transport is asking us to play. Drives
    /// whether the display link runs and the decoder pulls
    /// frames. Written on the main thread from `update(...)`.
    private var isActivelyPlaying: Bool = false
    /// Last `secondsInVideo` we were told. Used to detect scrub
    /// jumps (> 500 ms delta → issue a seek on the decoder).
    private var lastObservedVideoSeconds: Double = -1

    // Debounced / serialized scrub seek. The playhead fires at
    // up to 30 Hz during a drag; the decoder's seek is async +
    // ~50 ms per fire. If we kicked a new detached seek task
    // on every tick they'd stack up and thrash the queue. We
    // instead store the latest scrub target + a seeking flag;
    // the in-flight seek loops to pick up a newer target when
    // it completes.
    private var pendingScrubTargetSeconds: Double?
    private var isSeekingDecoder: Bool = false

    // MARK: - Init / teardown

    /// Build a player. The master clock is fed via `update(...)`
    /// — the player itself owns no audio engine reference (it
    /// receives absolute time on every transport tick). This
    /// keeps the playback library decoupled from the audio
    /// engine.
    public init() {}

    deinit {
        let d = decoder
        Task.detached { await d?.tearDown() }
    }

    // MARK: - Time provider

    /// Video-local presentation time: session's timeline-
    /// absolute audible time (stashed from the most recent
    /// `update(...)` call, extrapolated by host-time delta +
    /// clock rate) minus the video's start TC. Returns nil
    /// when nothing is loaded or the master clock is outside
    /// the video's range — view-owned renderers then hold
    /// their previous frame.
    public func currentVideoLocalSeconds() -> Double? {
        clockLock.lock()
        let lastAbs = lastAbsoluteSeconds
        let lastHost = lastAbsoluteHostTime
        let rate = clockRate
        clockLock.unlock()
        guard lastHost > 0 else { return nil }
        let now = CACurrentMediaTime()
        let extrapolated = lastAbs + (now - lastHost) * rate
        let local = extrapolated - videoStartTCSeconds
        guard local >= 0, local <= videoDurationSeconds else { return nil }
        return local
    }

    // MARK: - Public API

    /// Drive the player from the current transport state. Called
    /// from `MergeSession.syncVideoPlayer()` on the same ticks
    /// as the legacy `VideoPlayerController.update(...)`. Must
    /// be cheap — runs at the transport tick rate.
    ///
    /// Changes are detected and acted on:
    /// - `video` changed → tear down old source, load new
    /// - `isPlaying` → start/stop decoder + display link
    /// - Big jump in `secondsInVideo` → seek the decoder
    /// - Small drift → nothing (the master clock handles it)
    public func update(
        video: VideoFile?,
        secondsInVideo: Double,
        absoluteSeconds: Double,
        isPlaying: Bool,
        rate: Double
    ) {
        // Stash the master-clock snapshot for the renderer
        // thread. NSLock keeps the three-field write atomic
        // w.r.t. the render-thread read.
        clockLock.lock()
        lastAbsoluteSeconds = absoluteSeconds
        lastAbsoluteHostTime = CACurrentMediaTime()
        clockRate = (isPlaying && rate > 0) ? rate : 0
        clockLock.unlock()

        let newID = video?.id
        let videoChanged = newID != currentVideoID

        if videoChanged {
            print("[CustomVideoPlayer] video changed: \(video?.filename ?? "nil") startTC=\(String(format: "%.3f", video?.timecode?.totalSeconds ?? 0)) dur=\(String(format: "%.3f", video?.duration ?? 0))")
            currentVideoID = newID
            currentVideo = video
            lastObservedVideoSeconds = -1
            // Tear down old decoder + queue asynchronously.
            // Swap in fresh objects synchronously so the next
            // update tick sees valid state. View-owned
            // renderers observe `generation` bumping and will
            // drop their last-drawn frame on their own next
            // display-link tick — we don't broadcast directly.
            let oldDecoder = self.decoder
            self.decoder = nil
            self.frameQueue = nil
            generation &+= 1
            Task.detached { await oldDecoder?.tearDown() }

            if let video {
                videoStartTCSeconds = video.timecode?.totalSeconds ?? 0
                videoDurationSeconds = video.duration
                loadSource(for: video, startAtSeconds: max(0, secondsInVideo))
            } else {
                videoStartTCSeconds = 0
                videoDurationSeconds = 0
                isActivelyPlaying = false
            }
        }

        // Out-of-range check — same shape as legacy controller.
        let inRange = secondsInVideo >= 0 && secondsInVideo <= videoDurationSeconds
        if isAtValidPosition != inRange {
            isAtValidPosition = inRange
        }

        // Play/pause: decoder runs when playing, pauses when
        // not. The renderer keeps running either way so a
        // paused last-frame stays visible.
        let shouldPlay = isPlaying && rate > 0 && inRange && video != nil
        if shouldPlay != isActivelyPlaying {
            isActivelyPlaying = shouldPlay
            if shouldPlay {
                decoder?.start()
            } else {
                Task.detached { [weak self] in
                    await self?.decoder?.stop()
                }
            }
        }

        // Scrub detection + buffer-aware seek.
        // - When playing: only re-seek on big jumps (user
        //   scrubbed mid-playback). Small drift is handled by
        //   AVPlayer-style free-running.
        // - When paused / shuttling in reverse: seek ONLY when
        //   the target falls outside the decoder's buffered
        //   range. The queue retains decoded frames (it's a
        //   ring buffer now, not a drop-on-lookup queue), so
        //   1× reverse ticks walk backward through frames the
        //   decoder already has. When the playhead crosses
        //   the buffer's earliest PTS we seek further back and
        //   refill. This eliminates the seek-per-tick thrash
        //   that made reverse choppy.
        if inRange {
            if shouldPlay {
                if lastObservedVideoSeconds >= 0,
                   abs(secondsInVideo - lastObservedVideoSeconds) > 0.5 {
                    requestScrubSeek(to: secondsInVideo)
                }
            } else if needsSeek(forTarget: secondsInVideo) {
                requestScrubSeek(to: secondsInVideo)
            }
            lastObservedVideoSeconds = secondsInVideo
        }
    }

    /// "Should the decoder be re-seeded for this target time?"
    /// Returns true when the target is outside what the queue
    /// already has (or the queue is empty). The 0.1-second
    /// back-pad below the buffered-range lower bound keeps us
    /// from seeking the instant the playhead nudges one frame
    /// past the edge — the decoder naturally extends the buffer
    /// forward with each decode, so a small under-buffer margin
    /// is sensible.
    private func needsSeek(forTarget target: Double) -> Bool {
        guard let queue = frameQueue,
              let range = queue.bufferedRangeSeconds() else {
            return true
        }
        let lowerPad: Double = 0.1
        // Slightly past the buffer's oldest frame: seek back.
        if target < range.first - lowerPad { return true }
        // Past the buffer's newest: let the decoder catch up
        // naturally (it's pulling forward). Only seek if we're
        // MORE THAN 1s past — the user scrubbed forward fast.
        if target > range.last + 1.0 { return true }
        return false
    }

    /// Schedule a decoder seek, coalescing with any in-flight
    /// seek. If another scrub tick arrives while the decoder
    /// is seeking, we stash the new target and the in-flight
    /// task re-seeks once it returns.
    ///
    /// **Reverse lookahead**: when the user is scrubbing or
    /// shuttling backward, seeking exactly to the target time
    /// means the decoder starts decoding forward from there,
    /// producing frames AFTER the target — not the frames
    /// behind that reverse needs. We seed the seek at
    /// `target - reverseLookahead` so the decoder produces a
    /// chunk of frames spanning the range we'll reverse
    /// through. The retention-ring queue then serves those
    /// frames while the playhead moves backward, and we only
    /// re-seek when the playhead leaves the buffered range.
    private func requestScrubSeek(to target: Double) {
        let seekTarget: Double
        if lastObservedVideoSeconds >= 0,
           target < lastObservedVideoSeconds {
            // Backward scrub / reverse shuttle. Seek 1.25 s
            // before target so the decoder fills the retention
            // ring with frames behind where we're going, ready
            // for the next ~30 reverse ticks.
            seekTarget = max(0, target - 1.25)
        } else {
            seekTarget = max(0, target)
        }
        pendingScrubTargetSeconds = seekTarget
        guard !isSeekingDecoder, let decoder else {
            // Either a seek is already in flight (it'll pick
            // up `pendingScrubTargetSeconds` when it finishes)
            // or there's no decoder yet (loadSource is still
            // bringing one online).
            return
        }
        isSeekingDecoder = true
        // Bump generation so view-owned renderers drop their
        // pre-seek last-drawn frame (avoids a flash of the
        // old position while the decoder refills).
        generation &+= 1
        Task.detached(priority: .userInitiated) { [weak self, decoder] in
            while true {
                let t: Double? = await MainActor.run { [weak self] in
                    guard let self else { return nil }
                    let v = self.pendingScrubTargetSeconds
                    self.pendingScrubTargetSeconds = nil
                    return v
                }
                guard let next = t else {
                    await MainActor.run { self?.isSeekingDecoder = false }
                    return
                }
                try? await decoder.seek(toSeconds: next)
            }
        }
    }

    /// Tear down all playback state. Mirrors the legacy
    /// controller's `teardown()`. View-owned renderers see
    /// `generation` bump + `frameQueue` go nil and will drop
    /// their last-drawn frame automatically.
    public func teardown() {
        let d = decoder
        decoder = nil
        frameQueue = nil
        currentVideoID = nil
        currentVideo = nil
        isAtValidPosition = false
        isActivelyPlaying = false
        generation &+= 1
        Task.detached { await d?.tearDown() }
    }

    // MARK: - Internals

    private func loadSource(for video: VideoFile, startAtSeconds: Double) {
        let url = video.url
        let startedAt = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            // MXF routes to our native `MXFFrameSource` (KLV
            // demux + VTDecompressionSession); everything else
            // (MOV, MP4, M4V) routes to `AVAssetFrameSource`
            // (AVAssetReader-based). Both conform to
            // `VideoFrameSource` and feed the same queue +
            // renderer.
            let source: VideoFrameSource
            do {
                if url.pathExtension.lowercased() == "mxf" {
                    source = try await MXFFrameSource.load(url: url)
                } else {
                    source = try await AVAssetFrameSource.load(url: url)
                }
            } catch {
                print("[CustomVideoPlayer] source load failed for \(url.lastPathComponent): \(error.localizedDescription)")
                return
            }
            let loadElapsed = -startedAt.timeIntervalSinceNow
            print(String(format: "[CustomVideoPlayer] source loaded %@ in %.3f s (%.0fx%.0f @ %.3f fps, %.3fs)",
                         url.lastPathComponent, loadElapsed,
                         source.pixelDimensions.width, source.pixelDimensions.height,
                         source.nominalFrameRate, source.durationSeconds))

            let seekTime = CMTime(seconds: max(0, startAtSeconds), preferredTimescale: 600)
            do {
                try await source.seek(to: seekTime)
            } catch {
                print("[CustomVideoPlayer] initial seek failed: \(error.localizedDescription)")
            }

            // Capacity 60 + lookaheadSeconds 0.5 makes the steady-state
            // buffer cover roughly [target - 1.5 s, target + 0.5 s] at
            // 30 fps. The 1.5 s of back-buffer is what lets a consumer
            // place a clip at an arbitrary timeline position and render
            // the frame at the playhead immediately — without back-
            // buffer the decoder's natural overshoot pushes range.first
            // past target the moment it hits the lookahead threshold,
            // leaving range.first > target and frame() returning nil.
            // (Polymerge's own session-clock workflow never noticed this
            // because the master clock starts at the source's TC so
            // there's a natural alignment; Preem's clip-on-timeline
            // workflow exposes it on every clip drop.)
            let newQueue = PPEFrameQueue(capacity: 60)
            let newDecoder = PPEBackgroundDecoder(source: source, queue: newQueue)
            newDecoder.targetProvider = { [weak self] in
                self?.currentVideoLocalSeconds()
            }
            newDecoder.lookaheadSeconds = 0.5
            await MainActor.run {
                guard let self else { return }
                self.frameQueue = newQueue
                self.decoder = newDecoder
                // Start the decoder eagerly so the queue is
                // warm even before the user hits play (we show
                // a still of the paused frame). View-owned
                // renderers see `frameQueue` populate on their
                // next update() cycle and start pulling.
                newDecoder.start()
                print("[CustomVideoPlayer] queue + decoder attached for \(url.lastPathComponent)")
                // If the user scrubbed during the async load
                // window, fire the deferred seek now so we
                // land at the current position rather than
                // the startAtSeconds we seeded with.
                if let pending = self.pendingScrubTargetSeconds {
                    self.requestScrubSeek(to: pending)
                }
            }
        }
    }

}
