import SwiftUI
import AppKit
import AVFoundation
import PreemCore
import PreemMedia
import PolymergeMediaModel
import PolymergePlayback

/// Right-side viewer that shows whichever `PlacedClip` is under the
/// timeline playhead. Driven by `workspace.playheadTime` +
/// `workspace.activeSequence`. Renders via PolymergePlayback's PPE
/// pipeline so audio and video share one clock (the audio engine's
/// `currentAudibleSeconds`) and can't drift.
struct ProgramViewer: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Program")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(workspace.focusedViewer == .program ? Color.accentColor : Color.secondary)
                if workspace.focusedViewer == .program {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                }
                Spacer()
                // Drop-warning chip lives in the header. The HStack is
                // fixed-height (see `.frame(height:)` below) so the
                // chip can come and go without shifting the picture.
                if workspace.realtimeIsDropping {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text("Dropping frames · Render In to Out for smooth playback")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.orange.opacity(0.12))
                    )
                }
                if let progress = workspace.renderProgress {
                    HStack(spacing: 6) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 80)
                        Text("Rendering \(Int(progress * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                if let spec = sequenceSpec {
                    Text(spec)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("|")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.5))
                }
                Text(formattedTimecode)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if workspace.isPlaying {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 10)
            // Fixed header height — the drop chip insertion/removal
            // never shifts the program content below.
            .frame(height: 28)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            ZStack {
                Color.black
                switch frameAtPlayhead {
                case .video:
                    // Unified realtime compositor — runs the same
                    // OfflineSequenceCompositor path the encoder uses,
                    // so realtime ≡ render by construction.
                    RealtimeProgramHostView(workspace: workspace)
                    // Direct-manipulation overlay: when a clip is
                    // selected and visible at the playhead, the user
                    // can drag the picture to move it or drag a corner
                    // to scale it.
                    ProgramTransformOverlay(workspace: workspace)
                case .audioOnly:
                    VStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("Audio-only")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                case .empty:
                    Text(workspace.activeSequence == nil ? "No sequence" : "No clip under playhead")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 200, minHeight: 160)
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.focusedViewer = .program
        }
    }

    private var formattedTimecode: String {
        let t = workspace.playheadTime.seconds
        let frameRate = workspace.activeSequence?.settings.frameRate ?? .thirty
        return Timecode.format(seconds: t, frameRate: frameRate)
    }

    /// Sequence spec string in the form "3840x2160 23.976" so the user
    /// always sees the active sequence's resolution + frame rate next
    /// to the playhead readout. Returns nil when no sequence is active.
    private var sequenceSpec: String? {
        guard let seq = workspace.activeSequence else { return nil }
        let res = seq.settings.resolution
        let fr = seq.settings.frameRate.rawValue
        return "\(res.width)x\(res.height) \(fr)"
    }

    private enum FrameAtPlayhead { case video, audioOnly, empty }

    private var frameAtPlayhead: FrameAtPlayhead {
        guard let sequence = workspace.activeSequence else { return .empty }
        for track in sequence.videoTracks {
            if track.clips.contains(where: { $0.timelineRange.contains(workspace.playheadTime) }) {
                return .video
            }
        }
        for track in sequence.audioTracks {
            if track.clips.contains(where: { $0.timelineRange.contains(workspace.playheadTime) }) {
                return .audioOnly
            }
        }
        return .empty
    }
}

/// NSView host for PPE — owns one `PPEMetalRenderer` + one
/// `CustomVideoPlayer` per ProgramViewer instance, drives them from
/// the workspace state.
///
/// Two instances exist in the program viewer's ZStack: a `.primary`
/// host always rendering the current clip, and a `.secondary` host
/// that only renders during a cross-dissolve transition (it displays
/// the incoming clip with rising opacity).
private struct PPEProgramHost: NSViewRepresentable {
    enum Role { case primary, secondary }

    @ObservedObject var workspace: WorkspaceModel
    let role: Role

    func makeCoordinator() -> Coordinator {
        Coordinator(workspace: workspace, role: role)
    }

    func makeNSView(context: Context) -> PPEHostView {
        let view = PPEHostView()
        view.attach(renderer: context.coordinator.renderer)
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: PPEHostView, context: Context) {
        context.coordinator.sync(workspace: workspace)
    }

    static func dismantleNSView(_ nsView: PPEHostView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator {
        private weak var workspace: WorkspaceModel?
        let role: Role
        let renderer: PPEMetalRenderer
        let player = CustomVideoPlayer()
        private let bridge = VideoFileBridge()
        private var ticker: CVDisplayLink?
        private var resolvedVideoFiles: [ClipID: VideoFile] = [:]

        init(workspace: WorkspaceModel, role: Role) {
            self.workspace = workspace
            self.role = role
            do {
                renderer = try PPEMetalRenderer()
            } catch {
                fatalError("PPEMetalRenderer init failed: \(error)")
            }
            renderer.controller = player
        }

        func start() {
            renderer.start()
            installTicker()
        }

        func teardown() {
            stopTicker()
            renderer.stop()
            player.teardown()
        }

        func sync(workspace: WorkspaceModel) {
            self.workspace = workspace
            pushUpdate()
        }

        // MARK: - Display link driving update()

        private func installTicker() {
            guard ticker == nil else { return }
            var link: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&link)
            guard let link else { return }
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                guard let self else { return kCVReturnSuccess }
                Task { @MainActor in self.pushUpdate() }
                return kCVReturnSuccess
            }
            CVDisplayLinkStart(link)
            ticker = link
        }

        private func stopTicker() {
            if let link = ticker {
                CVDisplayLinkStop(link)
                ticker = nil
            }
        }

        // MARK: - Where the active clip math lives

        private func pushUpdate() {
            guard let workspace else { return }
            // Both playing and paused: track the visible playhead. The
            // visible playhead is wall-clock driven (minus output
            // latency) so the audio engine's prefill spike doesn't make
            // the video race forward. AVAudioEngine ticks at exactly 1×
            // wall-clock so audio and wall-clock stay locked over time.
            let absoluteSeconds = workspace.playheadTime.seconds

            // Pre-render cache short-circuit: if a baked segment covers
            // this playhead, the primary host plays the cache .mov
            // directly. The cache file already has all layers /
            // transitions baked in, so the secondary host hides through
            // the cached span. Audio stays on the live mixdown — the
            // cache .mov's audio track is for users who want to scrub
            // the segment file in QuickTime; playback uses the live
            // engine so the timeline mix stays the source of truth.
            if let seg = workspace.cacheSegmentAtPlayhead() {
                switch role {
                case .primary:
                    let cacheVideo = ensureCacheVideoFile(for: seg.url)
                    let offset = absoluteSeconds - seg.startSeconds
                    player.update(
                        video: cacheVideo,
                        secondsInVideo: offset,
                        absoluteSeconds: offset,
                        isPlaying: workspace.isPlaying,
                        rate: workspace.isPlaying ? 1 : 0
                    )
                    return
                case .secondary:
                    player.update(
                        video: nil, secondsInVideo: 0,
                        absoluteSeconds: absoluteSeconds,
                        isPlaying: false, rate: 0
                    )
                    return
                }
            }

            // Pick a clip for this host based on role + composite state.
            //   - Cross dissolve: primary = outgoing (then pre-warms to
            //     incoming during the handover tail), secondary = incoming.
            //   - Solo fade: primary = the fading clip, secondary unused.
            //   - Otherwise: primary = topmost clip under playhead.
            let activeTransition = workspace.activeVideoTransition
            let chosen: (PlacedClip, ClipSource)?
            if let t = activeTransition {
                switch role {
                case .primary:
                    chosen = (t.primaryClip, t.primarySource)
                case .secondary:
                    if let sc = t.secondaryClip, let ss = t.secondarySource {
                        chosen = (sc, ss)
                    } else {
                        chosen = nil
                    }
                }
            } else {
                switch role {
                case .primary:
                    chosen = videoClipAndSource(at: absoluteSeconds, workspace: workspace)
                case .secondary:
                    chosen = nil
                }
            }

            guard let (clip, source) = chosen else {
                player.update(video: nil, secondsInVideo: 0, absoluteSeconds: absoluteSeconds,
                              isPlaying: workspace.isPlaying, rate: workspace.isPlaying ? 1 : 0)
                return
            }

            // Paired transitionIn shifts the source-time forward by the
            // partner's transitionOut.duration: the dissolve starts at
            // (cutT - leftHalf), and we want incoming to be playing at
            // its in-point at THAT moment instead of frozen until cutT.
            // After the dissolve the shift continues so playback stays
            // continuous — the cost is that B "consumes" leftHalf
            // seconds of its source upfront.
            let shift: Double = {
                if let sequence = workspace.activeSequence {
                    return workspace.playbackShiftForPairedFadeIn(clip, in: sequence)
                }
                return 0
            }()
            // Secondary may be "held" at a specific source-time
            // during pre-warm — PPE seeks there once and freezes
            // while its decoder fills. Without the hold, advancing
            // source-time during the pre-warm makes PPE race ahead
            // and visibly fast-forward when it finally appears.
            let heldByPreWarm: Bool
            let secondsInVideo: Double
            if role == .secondary, let held = activeTransition?.secondaryHoldSourceTime {
                heldByPreWarm = true
                secondsInVideo = held
            } else {
                heldByPreWarm = false
                secondsInVideo = clip.sourceRange.start.seconds
                    + (absoluteSeconds - clip.timelineRange.start.seconds)
                    + shift
            }
            let videoFile = resolveVideoFile(for: source)

            // PPE expects absoluteSeconds to be a "session-relative" master
            // clock that aligns with the video's `videoStartTCSeconds` to
            // produce source-local time. Preem doesn't tag its VideoFiles
            // with a TC offset, so we feed PPE the source position as
            // both parameters. That makes currentVideoLocalSeconds()
            // return the actual source time and keeps the decoder + buffer
            // aligned with the frame the renderer asks for.
            //
            // Clamp to the clip's chosen in-point — during the dissolve
            // pre-warm window the playhead is BEFORE the incoming clip's
            // timeline start, which would otherwise land PPE at file
            // origin (sourceTime = 0) instead of the clip's intended
            // in-point. The clamp keeps the pre-warm decoder pointed at
            // the first frame the user is about to see.
            let sourceTime = max(clip.sourceRange.start.seconds, secondsInVideo)

            // Only let PPE advance once the playback window has
            // started. For a clip with a paired transitionIn that
            // window is the DISSOLVE start (cutT - leftHalf), not the
            // clip's own timelineRange.start — so motion plays from
            // the dissolve's first frame. For everything else the
            // window starts at the clip's natural timeline-start. The
            // earlier pre-warm (workspace.activeVideoTransition's
            // visibleStart) still feeds PPE the clip so the decoder
            // primes its frame queue with isPlaying=false; we only
            // flip to playing once we cross the playback start.
            let playbackStart = clip.timelineRange.start.seconds - shift
            let clipHasStarted = absoluteSeconds >= playbackStart
            // Held secondary stays paused on the target frame — that's
            // the whole point of the pre-warm.
            let effectiveIsPlaying = !heldByPreWarm && workspace.isPlaying && clipHasStarted
            player.update(
                video: videoFile,
                secondsInVideo: sourceTime,
                absoluteSeconds: sourceTime,
                isPlaying: effectiveIsPlaying,
                rate: effectiveIsPlaying ? 1 : 0
            )
        }

        private func videoClipAndSource(at seconds: Double, workspace: WorkspaceModel) -> (PlacedClip, ClipSource)? {
            guard let sequence = workspace.activeSequence else { return nil }
            let probe = RationalTime(value: Int64(seconds * 1000), scale: 1000)
            // Iterate top-down: V_last is the topmost layer in the
            // compositing stack, so it shadows everything below it.
            for track in sequence.videoTracks.reversed() {
                if let placed = track.clips.first(where: { $0.timelineRange.contains(probe) }),
                   let source = workspace.project.mediaPool.clips[placed.sourceClipID] {
                    return (placed, source)
                }
            }
            return nil
        }

        // MARK: - Pre-render cache video file resolution

        /// Cache of `VideoFile` descriptors for pre-rendered cache .mov
        /// files. The probe is synchronous via AVURLAsset's classic
        /// `duration` / `naturalSize` properties — cache files are
        /// local, native MOV containers with ProRes, so the probe is
        /// fast (no I/O beyond opening the file).
        private var cacheVideoFiles: [URL: VideoFile] = [:]

        private func ensureCacheVideoFile(for url: URL) -> VideoFile? {
            if let cached = cacheVideoFiles[url] { return cached }
            let asset = AVURLAsset(url: url)
            let duration = asset.duration.seconds
            guard duration > 0,
                  let track = asset.tracks(withMediaType: .video).first
            else { return nil }
            let size = track.naturalSize
            let fps = Double(track.nominalFrameRate)
            let video = VideoFile(
                url: url,
                duration: duration,
                videoWidth: Int(size.width),
                videoHeight: Int(size.height),
                videoFrameRate: fps > 0 ? fps : 30,
                videoCodec: "prores422lt",
                audioTrackCount: asset.tracks(withMediaType: .audio).count,
                audioSampleRate: 48_000,
                audioChannelCount: 2,
                color: .accentColor
            )
            cacheVideoFiles[url] = video
            return video
        }

        private func resolveVideoFile(for source: ClipSource) -> VideoFile? {
            if let cached = resolvedVideoFiles[source.id] { return cached }
            let synchronouslyResolved: VideoFile? = {
                guard !source.videoTracks.isEmpty, let v = source.videoTracks.first else { return nil }
                let fr = Double(v.frameRate.rationalRate) / max(1, Double(v.frameRate.rationalScale))
                return VideoFile(
                    url: source.url,
                    duration: source.duration.seconds,
                    videoWidth: v.resolution.width,
                    videoHeight: v.resolution.height,
                    videoFrameRate: fr,
                    videoCodec: source.format.videoCodec ?? "unknown",
                    audioTrackCount: source.audioTracks.count,
                    audioSampleRate: source.audioTracks.first?.sampleRate,
                    audioChannelCount: source.audioTracks.first?.channelCount ?? 0,
                    color: .accentColor
                )
            }()
            if let v = synchronouslyResolved {
                resolvedVideoFiles[source.id] = v
            }
            return synchronouslyResolved
        }
    }
}

/// NSView that hosts PPE's `CAMetalLayer` as its backing layer.
final class PPEHostView: NSView {
    private var metalLayer: CAMetalLayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    func attach(renderer: PPEMetalRenderer) {
        guard metalLayer !== renderer.layer else { return }
        metalLayer = renderer.layer
        renderer.layer.frame = bounds
        renderer.layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        // PPE now configures `presentsWithTransaction = true` +
        // `isOpaque = false` at init time so its CAMetalLayer
        // composites through CA's transaction system — the dual-PPE
        // cross-dissolve in ProgramViewer alpha-blends correctly.
        layer?.addSublayer(renderer.layer)
    }

    override func layout() {
        super.layout()
        if let metalLayer {
            metalLayer.frame = bounds
            metalLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        }
    }
}
