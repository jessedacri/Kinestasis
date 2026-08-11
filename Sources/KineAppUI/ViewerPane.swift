import SwiftUI
import AppKit
import AVFoundation
import KineCore
import KineMedia
import PolymergeMediaModel
import PolymergePlayback

/// Source pane. Tabbed Premiere-style: a "Source" tab with the source
/// viewer + scrubber, and an "Effect Controls" tab that edits the
/// selected timeline clip's Transform/Crop (and keyframes) live —
/// Program viewer updates as the user drags.
///
/// The tab state lives on `WorkspaceModel.sourcePaneTab` so `⇧⌘5` and
/// other shortcuts can flip it from anywhere.
struct ViewerPane: View {
    let title: String
    let clip: ClipSource?
    @ObservedObject var workspace: WorkspaceModel

    /// While paused, show the still layer (skim/scrub) vs. let the PPE
    /// player hold its last frame frozen. Pausing freezes PPE (seamless,
    /// no blur pop); moving the playhead (skim/scrub) flips to the still.
    @State private var showStillWhenPaused = true
    /// `sourceTimeSeconds` captured at the moment of pause — any change
    /// from it while paused means the user is skimming/scrubbing.
    @State private var pauseBaseline: Double = -1

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch workspace.sourcePaneTab {
                case .source:
                    sourceBody
                case .effectControls:
                    EffectControlsContent(workspace: workspace)
                case .color:
                    ColorPanelContent(workspace: workspace)
                case .shotGrade:
                    ShotGradePanel(workspace: workspace)
                }
            }
        }
        .frame(minWidth: 200, minHeight: 160)
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.focusedViewer = .source
        }
        .onChange(of: workspace.sourceIsPlaying) { _, playing in
            if playing {
                if showStillWhenPaused {
                    // The still was the visible surface (skim/scrub), so PPE
                    // must load/seek to the new position — hold the still over
                    // its cold spin-up until the first frame lands.
                    workspace.sourcePlaybackReady = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        if workspace.sourceIsPlaying { workspace.sourcePlaybackReady = true }
                    }
                } else {
                    // Resume from a frozen pause: PPE already holds the exact
                    // frame + buffered frames, so reveal it immediately — no
                    // hold, no lag.
                    workspace.sourcePlaybackReady = true
                }
            } else {
                // Pause: freeze PPE on its last frame (no still pop). The
                // still only takes over once the user moves the playhead.
                showStillWhenPaused = false
                pauseBaseline = workspace.sourceTimeSeconds
            }
        }
        .onChange(of: workspace.sourceTimeSeconds) { _, t in
            if !workspace.sourceIsPlaying && t != pauseBaseline {
                showStillWhenPaused = true
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(title: "Source", tab: .source) {
                if workspace.sourceIsPlaying {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tint)
                }
            }
            tabButton(title: "Effect Controls", tab: .effectControls) {
                if !workspace.selectedClipIDs.isEmpty {
                    Text("\(workspace.selectedClipIDs.count)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .foregroundStyle(.secondary)
                }
            }
            tabButton(title: "Color", tab: .color) {
                EmptyView()
            }
            tabButton(title: "Shot", tab: .shotGrade) {
                if let shot = workspace.selectedShot, !shot.grade.isIdentity {
                    Circle()
                        .fill(KineTheme.accent)
                        .frame(width: 5, height: 5)
                }
            }
            Spacer()
            if workspace.sourcePaneTab == .source, let clip {
                Text(clip.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.trailing, 10)
            }
        }
        .frame(height: 26)
        .background(KineTheme.bgPanel)
    }

    @ViewBuilder
    private func tabButton<Accessory: View>(
        title: String,
        tab: SourcePaneTab,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        let isActive = workspace.sourcePaneTab == tab
        let isFocused = workspace.focusedViewer == .source
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(
                    isActive
                        ? (isFocused ? KineTheme.accent : Color.primary)
                        : Color.secondary
                )
            accessory()
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(
            ZStack(alignment: .bottom) {
                Color.clear
                Rectangle()
                    .fill(isActive ? KineTheme.accent : Color.clear)
                    .frame(height: 2)
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.sourcePaneTab = tab
            workspace.focusedViewer = .source
        }
    }

    /// Still on top covers PPE when opacity 1. While playing it's held
    /// until PPE's first frame; while paused it shows only for skim/scrub.
    private var stillOpacity: Double {
        if workspace.sourceIsPlaying {
            return workspace.sourcePlaybackReady ? 0 : 1
        }
        return showStillWhenPaused ? 1 : 0
    }

    private var ppeOpacity: Double {
        if workspace.sourceIsPlaying { return 1 }
        return showStillWhenPaused ? 0 : 1
    }

    /// Only run the image generator when the still is actually the visible
    /// paused surface — not during playback or paused-frozen.
    private var stillActive: Bool {
        !workspace.sourceIsPlaying && showStillWhenPaused
    }

    private var sourceBody: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let clip, !clip.videoTracks.isEmpty {
                    // PPE is PERSISTENT (mounted whenever a video clip is
                    // loaded), not remounted per play/pause — so transitions
                    // don't churn a Metal renderer + display link. It is
                    // driven (decodes) ONLY while playing (push is gated), so
                    // skim/scrub never seed the decoder. On pause it freezes
                    // its last frame; the still only takes over when the user
                    // moves the playhead.
                    SourcePPEHost(
                        clip: clip,
                        sourceTimeSeconds: workspace.sourceTimeSeconds,
                        isPlaying: workspace.sourceIsPlaying,
                        onFirstFrame: { workspace.sourcePlaybackReady = true }
                    )
                    .opacity(ppeOpacity)

                    // Still layer: skim/scrub frames (fast image generator)
                    // and the play-start hold (covers PPE's cold spin-up).
                    SourceStillView(
                        clip: clip,
                        seconds: workspace.sourceTimeSeconds,
                        active: stillActive,
                        provider: workspace.skimProvider,
                        thumbnails: workspace.previewCache.thumbnails(for: clip.id)?.images ?? []
                    )
                    .opacity(stillOpacity)
                    .allowsHitTesting(false)
                } else if clip != nil {
                    Image(systemName: "waveform")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No clip loaded")
                        .foregroundStyle(.secondary)
                }
            }
            .onDrag {
                guard let clip else { return NSItemProvider() }
                let total = clip.duration.seconds
                let inMark = workspace.sourceInMark ?? 0
                let outMark = workspace.sourceOutMark ?? total
                let hasMarks = workspace.sourceInMark != nil || workspace.sourceOutMark != nil
                let payload: String
                if hasMarks {
                    payload = "\(clip.id.rawValue.uuidString)|\(inMark)|\(outMark - inMark)"
                } else {
                    payload = clip.id.rawValue.uuidString
                }
                return NSItemProvider(object: payload as NSString)
            }

            if let clip {
                ScrubBar(
                    seconds: Binding(
                        get: { workspace.sourceTimeSeconds },
                        set: { workspace.sourceTimeSeconds = $0 }
                    ),
                    duration: clip.duration.seconds,
                    inMark: workspace.sourceInMark,
                    outMark: workspace.sourceOutMark
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(KineTheme.bgPanel)
            }
        }
    }
}

private struct ScrubBar: View {
    @Binding var seconds: Double
    let duration: Double
    let inMark: Double?
    let outMark: Double?

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(formatTimecode(seconds))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 88, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Track
                        Rectangle()
                            .fill(Color.secondary.opacity(0.25))
                            .frame(height: 4)
                            .frame(maxWidth: .infinity)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)

                        // In/out range fill
                        if duration > 0, let inMark, let outMark, outMark > inMark {
                            let x0 = (inMark / duration) * geo.size.width
                            let x1 = (outMark / duration) * geo.size.width
                            Rectangle()
                                .fill(KineTheme.accent.opacity(0.35))
                                .frame(width: max(2, x1 - x0), height: 4)
                                .position(x: (x0 + x1) / 2, y: geo.size.height / 2)
                        }

                        // In mark
                        if duration > 0, let inMark {
                            let x = (inMark / duration) * geo.size.width
                            markBracket(direction: .leading)
                                .position(x: x, y: geo.size.height / 2)
                        }
                        // Out mark
                        if duration > 0, let outMark {
                            let x = (outMark / duration) * geo.size.width
                            markBracket(direction: .trailing)
                                .position(x: x, y: geo.size.height / 2)
                        }

                        // Playhead handle
                        if duration > 0 {
                            let x = max(0, min(1, seconds / duration)) * geo.size.width
                            Circle()
                                .fill(Color.white)
                                .frame(width: 10, height: 10)
                                .shadow(radius: 1)
                                .position(x: x, y: geo.size.height / 2)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard duration > 0 else { return }
                                let frac = max(0, min(1, value.location.x / geo.size.width))
                                seconds = frac * duration
                            }
                    )
                }
                .frame(height: 14)

                Text(formatTimecode(duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 88, alignment: .trailing)
            }
            HStack(spacing: 6) {
                Spacer()
                Text("I").markPill(active: inMark != nil)
                Text(inMark.map(formatTimecode) ?? "—")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("O").markPill(active: outMark != nil)
                Text(outMark.map(formatTimecode) ?? "—")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("press I/O to mark, , insert  .  overwrite")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private enum BracketDir { case leading, trailing }

    @ViewBuilder
    private func markBracket(direction: BracketDir) -> some View {
        let color = KineTheme.accent
        Path { p in
            switch direction {
            case .leading:
                p.move(to: CGPoint(x: 0, y: -7))
                p.addLine(to: CGPoint(x: 0, y: 7))
                p.addLine(to: CGPoint(x: 6, y: 7))
                p.move(to: CGPoint(x: 0, y: -7))
                p.addLine(to: CGPoint(x: 6, y: -7))
            case .trailing:
                p.move(to: CGPoint(x: 0, y: -7))
                p.addLine(to: CGPoint(x: 0, y: 7))
                p.addLine(to: CGPoint(x: -6, y: 7))
                p.move(to: CGPoint(x: 0, y: -7))
                p.addLine(to: CGPoint(x: -6, y: -7))
            }
        }
        .stroke(color, lineWidth: 2)
        .frame(width: 6, height: 14)
    }

    private func formatTimecode(_ t: Double) -> String {
        let totalMs = Int((max(0, t) * 1000).rounded())
        let h = totalMs / 3_600_000
        let m = (totalMs % 3_600_000) / 60_000
        let s = (totalMs % 60_000) / 1000
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}

private extension Text {
    func markPill(active: Bool) -> some View {
        self
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(active ? Color.white : Color.secondary)
            .background(active ? KineTheme.accent : Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

/// PPE-backed host for the source viewer. One CustomVideoPlayer +
/// PPEMetalRenderer per `clip.id`; SwiftUI's `.id(clip.id)` ensures
/// the host is rebuilt when the clip changes (so PPE tears down
/// cleanly between clips).
private struct SourcePPEHost: NSViewRepresentable {
    let clip: ClipSource
    let sourceTimeSeconds: Double
    let isPlaying: Bool
    var onFirstFrame: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PPEHostView {
        let view = PPEHostView()
        view.attach(renderer: context.coordinator.renderer)
        context.coordinator.onFirstFrame = onFirstFrame
        context.coordinator.start()
        context.coordinator.push(clip: clip, sourceTimeSeconds: sourceTimeSeconds, isPlaying: isPlaying)
        return view
    }

    func updateNSView(_ nsView: PPEHostView, context: Context) {
        context.coordinator.onFirstFrame = onFirstFrame
        context.coordinator.push(clip: clip, sourceTimeSeconds: sourceTimeSeconds, isPlaying: isPlaying)
    }

    static func dismantleNSView(_ nsView: PPEHostView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator {
        let renderer: PPEMetalRenderer
        let player = CustomVideoPlayer()
        private var cachedVideo: VideoFile?
        private var cachedClipID: ClipID?
        private var wasPlaying = false
        var onFirstFrame: (() -> Void)?

        init() {
            do {
                renderer = try PPEMetalRenderer()
            } catch {
                fatalError("PPEMetalRenderer init failed: \(error)")
            }
            renderer.controller = player
            // Renderer fires this on the main queue (see its
            // DispatchQueue.main.async) — assume isolation to reach the
            // main-actor Coordinator without a Task hop.
            renderer.onFirstFrameAfterReset = { [weak self] in
                MainActor.assumeIsolated { self?.onFirstFrame?() }
            }
        }

        func start() {
            renderer.start()
        }

        func teardown() {
            renderer.stop()
            player.teardown()
        }

        func push(clip: ClipSource, sourceTimeSeconds: Double, isPlaying: Bool) {
            let video = videoFile(for: clip)
            // For source viewer, absoluteSeconds == sourceTimeSeconds (it's
            // not part of a timeline). PPE uses it for host-time
            // interpolation between updates.
            //
            // Only drive the playback decoder when actually playing. While
            // paused / skimming / scrubbing the still layer shows the frame
            // (via SkimFrameProvider), so we must NOT push new times here —
            // that would re-seed the AVAssetReader on every hover tick and
            // starve the image generator (the laggy/black-frame behavior).
            // We push exactly once when playback stops so PPE freezes on the
            // current frame, then go quiet until the next play.
            if isPlaying {
                player.update(
                    video: video,
                    secondsInVideo: max(0, sourceTimeSeconds),
                    absoluteSeconds: sourceTimeSeconds,
                    isPlaying: true,
                    rate: 1
                )
                wasPlaying = true
            } else if wasPlaying {
                player.update(
                    video: video,
                    secondsInVideo: max(0, sourceTimeSeconds),
                    absoluteSeconds: sourceTimeSeconds,
                    isPlaying: false,
                    rate: 0
                )
                wasPlaying = false
            }
        }

        private func videoFile(for clip: ClipSource) -> VideoFile? {
            if cachedClipID == clip.id, let cachedVideo { return cachedVideo }
            guard !clip.videoTracks.isEmpty, let v = clip.videoTracks.first else { return nil }
            let fr = Double(v.frameRate.rationalRate) / max(1, Double(v.frameRate.rationalScale))
            let video = VideoFile(
                url: clip.url,
                duration: clip.duration.seconds,
                videoWidth: v.resolution.width,
                videoHeight: v.resolution.height,
                videoFrameRate: fr,
                videoCodec: clip.format.videoCodec ?? "unknown",
                audioTrackCount: clip.audioTracks.count,
                audioSampleRate: clip.audioTracks.first?.sampleRate,
                audioChannelCount: clip.audioTracks.first?.channelCount ?? 0,
                color: KineTheme.accent
            )
            cachedVideo = video
            cachedClipID = clip.id
            return video
        }
    }
}

/// Still-frame display for the source viewer when paused / skimming /
/// scrubbing. Draws a `CGImage` from `SkimFrameProvider` into a layer:
/// first the instant best-available frame (cached or nearest thumbnail —
/// never black), then upgrades to the sharp decoded frame when it arrives.
private struct SourceStillView: NSViewRepresentable {
    let clip: ClipSource
    let seconds: Double
    let active: Bool
    let provider: SkimFrameProvider
    let thumbnails: [CGImage]

    func makeNSView(context: Context) -> StillLayerView {
        let v = StillLayerView()
        refresh(v)
        return v
    }

    func updateNSView(_ v: StillLayerView, context: Context) {
        refresh(v)
    }

    private func refresh(_ v: StillLayerView) {
        // Hidden during playback (PPE is on top); skip generation entirely.
        guard active else { return }
        if let immediate = provider.bestAvailable(clip: clip, seconds: seconds, thumbnails: thumbnails) {
            v.setImage(immediate)
        }
        provider.requestSharp(clip: clip, seconds: seconds) { [weak v] sharp in
            v?.setImage(sharp)
        }
    }
}

final class StillLayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func setImage(_ img: CGImage) {
        layer?.contents = img
    }
}
