import SwiftUI
import AppKit
import AVFoundation
import PreemCore
import PreemMedia
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
                }
            }
        }
        .frame(minWidth: 200, minHeight: 160)
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.focusedViewer = .source
        }
        .onChange(of: clip?.id) { _, _ in
            workspace.sourceTimeSeconds = 0
            workspace.clearSourceMarks()
            workspace.stopSource()
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
        .background(Color(NSColor.windowBackgroundColor))
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
                        ? (isFocused ? Color.accentColor : Color.primary)
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
                    .fill(isActive ? Color.accentColor : Color.clear)
                    .frame(height: 2)
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.sourcePaneTab = tab
            workspace.focusedViewer = .source
        }
    }

    private var sourceBody: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let clip, !clip.videoTracks.isEmpty {
                    SourcePPEHost(
                        clip: clip,
                        sourceTimeSeconds: workspace.sourceTimeSeconds,
                        isPlaying: workspace.sourceIsPlaying
                    )
                    .id(clip.id)
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
                .background(Color(NSColor.windowBackgroundColor))
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
                                .fill(Color.accentColor.opacity(0.35))
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
        let color = Color.accentColor
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
            .background(active ? Color.accentColor : Color.secondary.opacity(0.15))
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PPEHostView {
        let view = PPEHostView()
        view.attach(renderer: context.coordinator.renderer)
        context.coordinator.start()
        context.coordinator.push(clip: clip, sourceTimeSeconds: sourceTimeSeconds, isPlaying: isPlaying)
        return view
    }

    func updateNSView(_ nsView: PPEHostView, context: Context) {
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

        init() {
            do {
                renderer = try PPEMetalRenderer()
            } catch {
                fatalError("PPEMetalRenderer init failed: \(error)")
            }
            renderer.controller = player
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
            player.update(
                video: video,
                secondsInVideo: max(0, sourceTimeSeconds),
                absoluteSeconds: sourceTimeSeconds,
                isPlaying: isPlaying,
                rate: isPlaying ? 1 : 0
            )
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
                color: .accentColor
            )
            cachedVideo = video
            cachedClipID = clip.id
            return video
        }
    }
}
