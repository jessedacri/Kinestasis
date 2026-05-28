import AVFoundation
import Combine
import SwiftUI
import PolymergeMediaModel
import PolymergeIngest

/// Controller for the floating Video Viewer window. Wraps a single
/// `AVPlayer` instance that swaps URLs as the active video changes
/// (when the playhead moves between cameras in a multi-cam shoot, or
/// when the user clicks a different camera in the viewer's selector).
///
/// **Why a single AVPlayer instead of one-per-video**: AVPlayer is a
/// heavy resource (it owns a render pipeline + decode queue + a
/// `CoreVideo` texture cache). For a 4-camera shoot we don't want
/// four parallel pipelines running constantly — only one camera is
/// shown at a time. Swapping `currentItem` is essentially free
/// compared to keeping four players warm.
///
/// **Audio is muted**: PolyMerge plays audio through its own
/// `AudioPlaybackEngine` from the WAV files. The video container's
/// embedded audio is muted on the AVPlayer so it doesn't double-up
/// with the main audio engine.
///
/// **Sync model** (the standard NLE viewer pattern):
/// - **Paused**: precise seek to the in-video time at every playhead
///   change. Tolerance is `.zero` so the displayed frame matches the
///   playhead position exactly.
/// - **Scrubbing**: loose seek (frame-tolerance). Visual feedback
///   needs to feel responsive; sub-frame precision is wasted because
///   the user is moving fast.
/// - **Playing**: hot-reseek to match the playhead at the moment play
///   starts, then call `player.play()` and let AVPlayer run free at
///   the transport's shuttle rate. AVPlayer is wall-clock-locked so
///   it stays in sync with the audio engine as long as both run at
///   the same rate. If drift exceeds 100 ms, we re-seek to correct.
///
/// **Shuttle support**: when the user hits J or L for shuttle, we
/// pass `transport.shuttleSpeed` directly to `player.rate`. AVPlayer
/// supports up to 2× for most codecs natively; higher rates will be
/// clamped by the codec or play choppily. For Stage 3 V1 we accept
/// this — most users only ever shuttle in the 1–4× range.
///
/// **Out-of-range playhead**: when the playhead is outside the
/// active video's time window, the controller pauses the player and
/// sets `isAtValidPosition = false`. The viewer view shows an "out
/// of range" or empty state in this case. The player keeps the last
/// loaded item so the next valid position re-uses the same pipeline.
/// **Threading**: this class is intentionally NOT `@MainActor`
/// because `MergeSession` (which owns it) isn't either. AVPlayer is
/// safe to access from any thread (it has internal serialization),
/// and all of PolyMerge's calls to `update(...)` come from SwiftUI
/// view bodies / `onChange` modifiers, which run on the main actor
/// in practice. The class is `@Observable` for SwiftUI re-render
/// integration but the observed fields (`currentVideoID`,
/// `isAtValidPosition`) are written only from `update(...)`.
@Observable
public final class VideoPlayerController {
    /// Which rendering path is active for the currently loaded
    /// video. AVFoundation-readable containers (MOV/MP4/M4V) go
    /// through `.avPlayer` and the views build an
    /// `AVPlayerLayer` off `self.player`. MXF H.264 (Canon
    /// XF-AVC / Sony XAVC / Panasonic AVC-Intra) goes through
    /// `.mxfDisplay` and the views build an overlay onto the
    /// `AVSampleBufferDisplayLayer` owned by `self.mxfPlayer`.
    /// Observed so SwiftUI re-renders the viewer when the active
    /// video crosses between the two codec families.
    public enum RenderTarget: Equatable {
        case avPlayer
        case mxfDisplay
        case none
    }
    public private(set) var renderTarget: RenderTarget = .none

    /// Shared AVPlayer. Views build their own `AVPlayerLayer` from
    /// this so the same player can drive both the embedded preview
    /// and the floating viewer window simultaneously (CoreAnimation
    /// supports multiple layers reading from one player).
    public let player: AVPlayer

    /// Native MXF player (H.264 or ProRes). Instantiated lazily
    /// the first time an MXF video arrives in `update(...)`.
    /// Replaced when the active video changes to a different
    /// MXF (the essence index is per-file). Destroyed when a
    /// non-MXF video becomes active so the CMTimebase + display
    /// layer + file handle don't leak. `AVSampleBufferDisplayLayer`
    /// is a CALayer; views query `mxfPlayer?.displayLayer` to
    /// render it. The protocol surface (`MXFNativePlayer`) is
    /// the same for both codec-specific classes so the branching
    /// lives entirely in `attachMXFPlayer`.
    public private(set) var mxfPlayer: (any MXFNativePlayer)?

    /// File ID of the video currently loaded in the player. Driven
    /// by `update(...)` — never set externally. nil = no item.
    public private(set) var currentVideoID: UUID?

    /// Full `VideoFile` of the currently loaded video. Stable
    /// reference — only changes when the camera under the
    /// playhead changes (hand-off in multicam, or user pins a
    /// different camera). Views that render the display layer
    /// (the floating viewer window and the transport bar's
    /// embedded preview) should observe **this** property, NOT
    /// `session.activeViewerVideo` — the latter recomputes
    /// `videosUnderPlayhead` on access, which subscribes the
    /// observing body to `transport.playheadSample` and forces
    /// a full SwiftUI re-render at every playhead tick. That
    /// main-thread work saturates CoreAnimation and is what
    /// caused the "staccato" MXF playback the user reported
    /// (smooth in the testbed window because it doesn't
    /// observe the session's playhead at all).
    public private(set) var currentVideo: VideoFile?

    /// True when the playhead is currently inside the loaded video's
    /// time range. False when out of range, no video loaded, or
    /// before the first valid update. Drives the viewer view's
    /// "no video at playhead" empty state.
    public private(set) var isAtValidPosition: Bool = false

    /// Decoder output resolution cap. Three quality levels exposed
    /// in the viewer chrome — intended to control how much
    /// GPU/decoder work AVPlayer does per frame.
    ///
    /// **KNOWN LIMITATION (Stage 3 placeholder)**: the current
    /// implementation sets `AVPlayerItem.preferredMaximumResolution`,
    /// which Apple documents as "preferred." It is **primarily an
    /// HLS variant-selection hint** and is NOT consistently honored
    /// for plain on-disk video files. On Apple Silicon the
    /// VideoToolbox hardware decoder is fixed-cost regardless of
    /// output resolution for ProRes / H.264 / HEVC, so AVFoundation
    /// often just decodes at the source resolution and lets
    /// CoreAnimation downsample at render time. The user-visible
    /// effect: the chips toggle but quality looks identical at
    /// typical viewer sizes.
    ///
    /// **Why we're keeping the chip selector anyway**: when 4K+
    /// source files become a real PolyMerge workflow concern, we
    /// can replace the hint with a real downscaler — the path
    /// forward is `AVAssetReader` + `AVAssetReaderTrackOutput`
    /// configured with `kCVPixelBufferWidthKey` /
    /// `kCVPixelBufferHeightKey` output settings, decoding into a
    /// `CVPixelBufferPool` at the capped resolution, then rendering
    /// the buffers via a custom layer (or feeding back into a
    /// hand-rolled `AVSampleBufferDisplayLayer` setup). That's a
    /// real chunk of work — out of scope for Stage 3, but the
    /// chip UI is in place so we don't have to retrofit it later.
    /// Pitfall #54 in DEVELOPMENT.md has the full notes.
    public enum Quality: String, CaseIterable {
        case high   // native — no cap
        case medium // 1280 × 720
        case low    // 640 × 360

        public var label: String {
            switch self {
            case .high: return "HIGH"
            case .medium: return "MED"
            case .low: return "LOW"
            }
        }

        /// Cap to apply via `AVPlayerItem.preferredMaximumResolution`.
        /// `.zero` means "no cap" (CGSize.zero is AVFoundation's
        /// sentinel for "use the source resolution").
        public var maxResolution: CGSize {
            switch self {
            case .high: return .zero
            case .medium: return CGSize(width: 1280, height: 720)
            case .low: return CGSize(width: 640, height: 360)
            }
        }
    }

    /// Active quality preset. Default `.high` because most production
    /// camera files are 1080p, where capping decode resolution gives
    /// only ~50% savings — not enough to be worth defaulting to
    /// degraded quality. Users with 4K+ source files (where the
    /// savings are 4-6×) can drop to MED or LOW manually. The
    /// quality knob is more about throughput tuning than perceived
    /// quality at typical viewer sizes.
    public var quality: Quality = .high {
        didSet {
            applyQualityToCurrentItem()
        }
    }

    /// Sync state — set to true on the first hot-seek of a play
    /// session, then NEVER touched again until playback stops or the
    /// active video changes. This is the "let AVPlayer run free"
    /// optimization that eliminates re-seek thrash. AVPlayer is
    /// wall-clock locked, so once both engines are aligned at the
    /// same instant, drift between them is < 1 frame per minute in
    /// practice and far below perceptual threshold.
    private var hotSeekedThisPlayback: Bool = false

    /// Last frame index we seeked the MXF player to while
    /// paused or scrubbing. Used to suppress redundant seek
    /// calls at the ~93 Hz transport tick rate — without this
    /// guard, `flushAndRemoveImage` fires every tick and the
    /// display layer never stabilizes on a frame.
    private var lastSeekedFrameIndex: Int = -1

    /// Last `secondsInVideo` we asked AVPlayer to seek to while
    /// paused. Paired with `lastSeekedFrameIndex` for the MXF
    /// branch, this prevents `update(...)` from firing a precise
    /// (tolerance: .zero) AVPlayer seek on every playhead tick
    /// when the transport is parked — that was forcing AVPlayer
    /// to flush+redecode the same frame 30 times per second and
    /// produced visible stutter on paused clips.
    private var lastSeekedSecondsInVideo: Double = -1

    /// Last `secondsInVideo` observed while AVPlayer was in
    /// steady-state playback. Used to detect real scrubs
    /// mid-playback (delta > 500 ms) vs. normal drift (delta ≈
    /// 1/30 s per tick). Drift is tolerated; real scrubs get a
    /// re-seek.
    private var lastPlayingSecondsInVideo: Double = -1

    /// Host-time of the last flush-free drift correction we
    /// sent to AVPlayer via `setRate(_:time:atHostTime:)`.
    /// Throttled to ~once every 500 ms so we don't thrash the
    /// AVPlayer clock — `setRate` is cheap compared to `seek`,
    /// but invoking it every tick would still produce audible
    /// micro-speed variations.
    private var lastDriftCorrectionHost: CFTimeInterval = 0

    /// Drift threshold for the rare re-seek case (when the user
    /// scrubs a tiny amount mid-playback). 250 ms is well above the
    /// jitter we'd see from natural drift but tight enough that any
    /// real positional change forces a correction.
    private static let driftThresholdSeconds: Double = 0.25

    /// Callback fired when an attached `AVPlayerItem` goes to
    /// `.failed` status — AVFoundation couldn't decode the file
    /// (e.g. MXF ProRes without Apple's Pro Video Formats
    /// installed, or the rare 4K+ ProRes HQ resolutions the
    /// hardware decoder refuses). The caller (MergeSession) uses
    /// this to mark the video's `livePlaybackEnabled = false` so
    /// the timeline / viewer surface switches to the placeholder
    /// state instead of rendering a blank frame indefinitely.
    public var onItemFailed: ((UUID, Error?) -> Void)?

    /// Closure called from `update(...)` to decide whether the
    /// app-level video preview master switch is currently ON.
    /// When false, we skip the AVPlayer / MXF attachment entirely
    /// — same as a per-file `livePlaybackEnabled = false`. The
    /// host app (which owns `AppSettings`) wires this up; the
    /// library has no opinion about which preference store
    /// drives it. Default returns `true` so a brand-new controller
    /// works out of the box.
    public var videoPreviewEnabled: () -> Bool = { true }

    /// Combine sink for the current AVPlayerItem's status. Replaced
    /// every time `replaceCurrentItem` runs so we don't stack
    /// observers across item swaps. nil when no item is attached.
    private var statusCancellable: AnyCancellable?

    public init() {
        player = AVPlayer()
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.preventsDisplaySleepDuringVideoPlayback = false
        // Leave `automaticallyWaitsToMinimizeStalling` at its default
        // (true). Setting it false tells AVPlayer "play immediately
        // even if you have to stutter," which is the OPPOSITE of
        // what we want for smooth scrubbing/playback. The default
        // lets the player buffer enough to play without stalling
        // before frames are displayed.
    }

    /// Apply the current quality preset to the loaded item. Called
    /// after `quality.didSet` and on every `replaceCurrentItem`.
    private func applyQualityToCurrentItem() {
        guard let item = player.currentItem else { return }
        item.preferredMaximumResolution = quality.maxResolution
    }

    /// Update the player's loaded video, position, and play state to
    /// reflect the current transport. Call on every relevant change
    /// (playhead, isPlaying, shuttleSpeed, active video).
    ///
    /// - Parameters:
    ///   - video: the video file to display, or nil to clear the player
    ///   - secondsInVideo: position WITHIN that video, in seconds.
    ///     A negative or > duration value indicates the playhead is
    ///     outside the video's range — the player will pause and
    ///     `isAtValidPosition` will be set to false.
    ///   - isPlaying: whether the master transport is currently playing
    ///   - rate: playback rate from `transport.shuttleSpeed` (1.0 normal,
    ///     2.0 = 2× forward, -1.0 = 1× reverse, etc.). Reverse rates
    ///     are clamped to a paused player because AVPlayer can't
    ///     natively reverse most codecs.
    ///   - scrubbing: true when the user is dragging the playhead
    ///     manually. Loosens seek tolerance for snappier feedback.
    public func update(
        video: VideoFile?,
        secondsInVideo: Double,
        isPlaying: Bool,
        rate: Double,
        scrubbing: Bool
    ) {
        // 1. Swap currentItem if the active video changed. Apply the
        //    current quality cap to the new item. Reset the hot-seek
        //    latch since the new item starts un-positioned.
        let newID = video?.id
        let videoChanged = newID != currentVideoID
        if videoChanged {
            currentVideoID = newID
            currentVideo = video
            hotSeekedThisPlayback = false
            if let video {
                // **Skip AVPlayer attachment for metadata-only
                // files or user-disabled playback.** For Canon
                // CRM / RED R3D / Blackmagic RAW / ARRIRAW,
                // AVFoundation can't decode the codec, so
                // attaching the asset just wastes memory on the
                // decode pipeline initialization and probably
                // spews decode errors into the log. For
                // user-disabled realtime playback (the LIVE/OFF
                // toggle), we skip the attachment to save the
                // AVPlayerItem allocation cost on sessions where
                // the user doesn't care about seeing frames.
                if case .metadataOnly = video.playbackCapability {
                    tearDownAVPlayerItem()
                    tearDownMXFPlayer()
                    renderTarget = .none
                    isAtValidPosition = false
                    return
                }
                if !video.livePlaybackEnabled || !videoPreviewEnabled() {
                    tearDownAVPlayerItem()
                    tearDownMXFPlayer()
                    renderTarget = .none
                    isAtValidPosition = false
                    return
                }
                // MXF route: try the native H.264 demuxer +
                // VideoToolbox path before touching AVPlayer.
                // AVFoundation can't open MXF without Apple's
                // Pro Video Formats installed, so an AVPlayer
                // attachment would just fail and mark the
                // video as non-playable. MXFH264Player works
                // without any external dependency.
                if video.url.pathExtension.lowercased() == "mxf" {
                    if attachMXFPlayer(for: video) {
                        tearDownAVPlayerItem()
                        return
                    }
                    // Native path rejected the file (not H.264
                    // or header unreadable) — fall through to
                    // AVPlayer so the user still gets the
                    // standard failure signal that marks
                    // livePlaybackEnabled = false.
                }
                tearDownMXFPlayer()
                let asset = AVURLAsset(url: video.url)
                let item = AVPlayerItem(asset: asset)
                player.replaceCurrentItem(with: item)
                renderTarget = .avPlayer
                applyQualityToCurrentItem()
                // Observe the new item's status. AVPlayerItem
                // status goes `.unknown` → `.readyToPlay` (normal
                // path) or `.unknown` → `.failed` (decoder can't
                // handle the codec / container — e.g. MXF ProRes
                // on a system without Apple Pro Video Formats).
                // On `.failed`, notify the session so it can mark
                // `livePlaybackEnabled = false` and swap the UI
                // over to the PREVIEW DISABLED placeholder.
                let failedVideoID = video.id
                statusCancellable = item.publisher(for: \.status)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self, weak item] status in
                        guard let self = self else { return }
                        switch status {
                        case .failed:
                            let err = item?.error
                            print("[VideoPlayer] item failed for \(failedVideoID): \(err?.localizedDescription ?? "unknown")")
                            self.onItemFailed?(failedVideoID, err)
                        default:
                            break
                        }
                    }
            } else {
                tearDownAVPlayerItem()
                tearDownMXFPlayer()
                renderTarget = .none
                isAtValidPosition = false
                return
            }
        }

        // MXF branch: once an MXFH264Player is attached, every
        // transport change drives the CMTimebase directly. No
        // AVPlayer operations touch the MXF renderer.
        //
        // **Transport ticks at ~93 Hz**, so everything in this
        // path runs ~93 times per second during playback. We must
        // be extremely conservative about mutating @Observable
        // state here — Swift's @Observable notifies observers on
        // every write regardless of value equality, which
        // triggers the SwiftUI viewer body to re-evaluate and
        // ultimately re-lay-out the `AVSampleBufferDisplayLayer`'s
        // NSView frame. That layout tick disrupts the display
        // layer's own render pipeline and produces visible
        // staccato playback. Each assignment below guards
        // against redundant writes.
        if renderTarget == .mxfDisplay, let mxf = mxfPlayer, let video {
            let videoDuration = video.duration
            if secondsInVideo < 0 || secondsInVideo > videoDuration {
                if isAtValidPosition { isAtValidPosition = false }
                mxf.pause()
                hotSeekedThisPlayback = false
                return
            }
            if !isAtValidPosition { isAtValidPosition = true }
            let frameRate = mxf.nominalFrameRate > 0 ? mxf.nominalFrameRate : 24
            let frameIndex = max(0, Int((secondsInVideo * frameRate).rounded()))
            if isPlaying && rate > 0 {
                if !hotSeekedThisPlayback || videoChanged {
                    mxf.seek(toFrame: frameIndex)
                    mxf.play()
                    hotSeekedThisPlayback = true
                }
                // Steady-state playback — let the CMTimebase run.
                // Reverse / shuttle > 1× not supported on MXF
                // H.264 yet (the enqueue loop is forward-only).
            } else {
                mxf.pause()
                hotSeekedThisPlayback = false
                // Only re-seek when the target frame actually
                // changed. Scrubbing legitimately wants a seek
                // per playhead tick; pausing with no playhead
                // movement should NOT retrigger seek (which
                // flushes the display layer and forces a full
                // re-decode of the paused frame, producing the
                // stutter the user sees in the main viewer).
                if frameIndex != lastSeekedFrameIndex {
                    mxf.seek(toFrame: frameIndex)
                    lastSeekedFrameIndex = frameIndex
                }
            }
            return
        }

        // 2. No video loaded → nothing else to do.
        guard video != nil else {
            isAtValidPosition = false
            return
        }

        // 3. Validate the seek position. If out of range, pause and
        //    bail. Don't unload the item — we want to keep the
        //    pipeline warm for when the playhead re-enters the range.
        let videoDuration = video?.duration ?? 0
        if secondsInVideo < 0 || secondsInVideo > videoDuration {
            isAtValidPosition = false
            player.pause()
            hotSeekedThisPlayback = false
            return
        }
        isAtValidPosition = true

        // 4. Branch on transport state. The PLAYING branch idles
        //    most of the time — once we hot-seek to align at the
        //    start of a play session, we let AVPlayer run free at
        //    wall-clock rate, with periodic drift correction via
        //    a loose-tolerance re-seek (tolerance = 1 frame ≈ 33 ms,
        //    which AVPlayer can satisfy from its existing decode
        //    queue without a full pipeline flush — unlike a
        //    zero-tolerance seek which is what produced the
        //    staccato behavior the user first reported).
        //
        // An earlier attempt used `setRate(_:time:atHostTime:)` —
        // Apple's documented A/V-sync API — but that put AVPlayer
        // into a host-time-scheduled state that `pause()` did not
        // cleanly cancel on this macOS release, producing a
        // runaway video and a locked-up transport. Loose-tolerance
        // seeks are simpler and roll back predictably.
        if isPlaying && rate > 0 {
            let targetRate = Float(min(rate, 2.0))
            if !hotSeekedThisPlayback || videoChanged {
                // Hot-seek: align video to current playhead position
                // and start playing. This IS a flush — the only one
                // per play session.
                let cmTime = CMTime(seconds: secondsInVideo, preferredTimescale: 600)
                let tolerance = CMTime(value: 1, timescale: 30)
                player.seek(to: cmTime, toleranceBefore: tolerance, toleranceAfter: tolerance)
                player.rate = targetRate
                hotSeekedThisPlayback = true
                lastPlayingSecondsInVideo = secondsInVideo
            } else {
                // Real scrub mid-playback: secondsInVideo jumps by
                // half a second or more. That's the ONLY case that
                // warrants a re-seek during steady-state playback.
                //
                // **No drift correction during playback.** Every
                // flavor we've tried (tight-tolerance seek, loose-
                // tolerance seek, `setRate(_:time:atHostTime:)`)
                // either flushes the decoder (staccato) or puts
                // AVPlayer into a host-time schedule that `pause`
                // can't cleanly cancel (runaway). Accepting 10-30 ms
                // of audio-engine vs. AVPlayer clock drift over a
                // typical 2-5 minute play session is the safe
                // default — it's below or at the lip-sync
                // perceptual threshold and doesn't sacrifice
                // playback smoothness. If the user notices larger
                // drift, pause/play hot-re-seeks and re-aligns.
                let delta = abs(secondsInVideo - lastPlayingSecondsInVideo)
                if delta > 0.5 {
                    let cmTime = CMTime(seconds: secondsInVideo, preferredTimescale: 600)
                    let tolerance = CMTime(value: 1, timescale: 30)
                    player.seek(to: cmTime, toleranceBefore: tolerance, toleranceAfter: tolerance)
                }
                lastPlayingSecondsInVideo = secondsInVideo
                if abs(player.rate - targetRate) > 0.01 {
                    player.rate = targetRate
                }
            }
        } else {
            // Paused / scrubbing / reverse: precise seek, no play.
            // Reset the hot-seek latch so the next play session
            // re-aligns from scratch. **Guard against redundant
            // seeks**: at 30 Hz ticks with the playhead parked on
            // a paused video, we were calling `player.seek(...,
            // tolerance: .zero)` 30 times per second to the same
            // time, which forces AVPlayer to flush + decode the
            // same frame repeatedly. Only seek when the target
            // time actually moved.
            player.pause()
            hotSeekedThisPlayback = false
            let threshold: Double = scrubbing ? 0.010 : 0.001
            if abs(secondsInVideo - lastSeekedSecondsInVideo) > threshold {
                let cmTime = CMTime(seconds: secondsInVideo, preferredTimescale: 600)
                let tolerance: CMTime = scrubbing
                    ? CMTime(value: 1, timescale: 15)
                    : .zero
                player.seek(to: cmTime, toleranceBefore: tolerance, toleranceAfter: tolerance)
                lastSeekedSecondsInVideo = secondsInVideo
            }
        }
    }

    /// Pause the player and clear the loaded item. Called on bin
    /// switches and project clears so the next bin starts fresh.
    public func teardown() {
        player.pause()
        tearDownAVPlayerItem()
        tearDownMXFPlayer()
        currentVideoID = nil
        currentVideo = nil
        isAtValidPosition = false
        hotSeekedThisPlayback = false
        renderTarget = .none
    }

    // MARK: - MXF branch helpers

    /// Try to attach an `MXFH264Player` for the given video.
    /// Returns true on success; false if the MXF isn't H.264 or
    /// the native reader rejected it (caller then falls through
    /// to the AVPlayer path so the standard failure signal still
    /// fires). All disk I/O for the essence scan happens here —
    /// on a background priority task (a 4 GB MXF scans in ~0.1 s
    /// thanks to the KLV-header-only walk).
    private func attachMXFPlayer(for video: VideoFile) -> Bool {
        // Essence scan blocks the caller's thread. For a typical
        // camera MXF this finishes in well under 100 ms, but for
        // a 193 GB ARRI take on a spinning drive it can run a
        // couple of seconds. The caller is the main-thread
        // `syncVideoPlayer` path, which runs whenever the user
        // clicks into a new camera — a small pause on that
        // single user action is acceptable vs. the alternative
        // (async path requires Task + re-entrancy guards that
        // add complexity across the whole player surface).
        guard let idx = try? MXFEssenceReader.scanAudioIndex(url: video.url) else {
            print("[VideoPlayer] MXF essence scan failed for \(video.url.lastPathComponent)")
            return false
        }
        let player: any MXFNativePlayer
        switch idx.picture.codec {
        case .h264:
            do {
                player = try MXFH264Player(url: video.url, index: idx.picture)
            } catch {
                print("[VideoPlayer] MXFH264Player init failed: \(error.localizedDescription)")
                return false
            }
        case .prores:
            do {
                player = try MXFProResPlayer(url: video.url, index: idx.picture)
            } catch {
                print("[VideoPlayer] MXFProResPlayer init failed: \(error.localizedDescription)")
                return false
            }
        case .unknown:
            print("[VideoPlayer] MXF has unclassified codec; deferring to AVPlayer path")
            return false
        }
        mxfPlayer = player
        renderTarget = .mxfDisplay
        player.showFirstFrame()
        return true
    }

    /// Detach the AVPlayer item (if any) without disturbing the
    /// MXF path. Used when switching between MXF videos or when
    /// the MXF attach succeeds after a prior AVPlayer load.
    private func tearDownAVPlayerItem() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusCancellable = nil
    }

    /// Stop the MXF player (if any) and drop it. Display layer
    /// + CMTimebase + FileHandle all get cleaned up by ARC once
    /// the reference drops.
    private func tearDownMXFPlayer() {
        mxfPlayer?.pause()
        mxfPlayer = nil
    }
}
