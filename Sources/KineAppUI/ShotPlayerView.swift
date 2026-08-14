import SwiftUI
import AppKit
import KineCore
import KineMedia

/// The shot player: live-graded frame, transport bar, trim controls, mark
/// star, kept-range strip. One implementation shared by the inspector and
/// the fullscreen processing view. Follows `workspace.previewShot` (hover
/// skim wins, else the selection).
struct ShotPlayerView: View {
    @ObservedObject var workspace: WorkspaceModel
    /// Fullscreen processing view: let the picture take all the space.
    var large = false

    var body: some View {
        let shot = workspace.previewShot
        VStack(spacing: 0) {
            PlayerFrameHost(workspace: workspace, transport: workspace.shotTransport,
                            previews: workspace.previewTicker)
                .frame(minHeight: large ? 280 : 160, idealHeight: large ? nil : 240,
                       maxHeight: large ? .infinity : nil)
                .contentShape(Rectangle())
                .onTapGesture { workspace.toggleShotPlayback() }

            if let shot {
                transportBar(shot)
                trimStrip(shot)
            }
        }
    }

    private func transportBar(_ shot: BurstShot) -> some View {
        let total = max(1, ShotTimingEngine.totalFrames(workspace.scheduleForPreviewShot()))
        return HStack(spacing: 8) {
            playPauseButton
            TransportFrameCounter(transport: workspace.shotTransport, total: total)
            TransportScrub(workspace: workspace, transport: workspace.shotTransport, total: total)
            durationLabel(total: total)
            Divider().frame(height: 12)
            trimButtons(shot)
            TransportMarkControls(workspace: workspace, transport: workspace.shotTransport)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(KineTheme.bgPanel)
    }

    private var playPauseButton: some View {
        Button {
            workspace.toggleShotPlayback()
        } label: {
            Image(systemName: workspace.shotPlayRate != 0 ? "pause.fill" : "play.fill")
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
    }

    private func durationLabel(total: Int64) -> some View {
        Text(String(format: "%.1fs", Double(total) / workspace.shotFrameRate.fps))
            .font(KineTheme.monoSmall)
            .foregroundStyle(KineTheme.textMuted)
    }

    @ViewBuilder private func trimButtons(_ shot: BurstShot) -> some View {
        Button("I") { workspace.setShotTrimInAtPlayhead() }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(KineTheme.accent)
            .help("Trim head to this still (key: I)")
        Button("O") { workspace.setShotTrimOutAtPlayhead() }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(KineTheme.accent)
            .help("Trim tail to this still (key: O)")
        if shot.isTrimmed {
            Text("\(shot.effectiveFrames.count)/\(shot.frames.count)")
                .font(KineTheme.monoSmall)
                .foregroundStyle(KineTheme.textMuted)
            Button {
                workspace.clearShotTrim()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .help("Clear trim (key: I+O together)")
        }
    }

    /// Where the kept range sits inside the full shot: dark ends are
    /// trimmed off and never play in the loop.
    @ViewBuilder private func trimStrip(_ shot: BurstShot) -> some View {
        if shot.isTrimmed, !shot.frames.isEmpty {
            GeometryReader { geo in
                let n = CGFloat(shot.frames.count)
                let x0 = CGFloat(shot.trimIn) / n * geo.size.width
                let x1 = CGFloat(shot.frames.count - shot.trimOut) / n * geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.5))
                    Capsule().fill(KineTheme.accent.opacity(0.85))
                        .frame(width: max(2, x1 - x0))
                        .offset(x: x0)
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .background(KineTheme.bgPanel)
            .help("Kept range inside the full shot. Dark ends are trimmed off and do not play.")
        }
    }

}


/// Layer-backed frame display: swapping the image only touches
/// CALayer.contents, never SwiftUI/AppKit layout. SwiftUI's Image treats
/// per-frame pixel-dimension jitter (2560x1706 vs x1707) as an intrinsic
/// size change and relayouts the whole window at playback rate - that was
/// the Develop-mode pinwheel.
struct FrameLayerView: NSViewRepresentable {
    let image: CGImage?

    func makeNSView(context: Context) -> LayerView { LayerView() }

    func updateNSView(_ view: LayerView, context: Context) {
        view.show(image)
    }

    final class LayerView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.contentsGravity = .resizeAspect
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.minificationFilter = .trilinear
            layer?.magnificationFilter = .linear
        }

        required init?(coder: NSCoder) { nil }

        func show(_ image: CGImage?) {
            // Kill the implicit contents fade: at playback rate the
            // default 0.25s animation stacks into a continuous animation
            // stream that drives full-window layout every frame.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = image
            CATransaction.commit()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            layer?.contentsScale = window?.backingScaleFactor ?? 2
        }
    }
}


/// The only views that observe the shot transport at playback rate (the
/// grid footgun): each is a leaf whose relayout cannot ripple outward.
private struct PlayerFrameHost: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var transport: WorkspaceModel.ShotTransport
    @ObservedObject var previews: WorkspaceModel.PreviewTicker

    @State private var playerImage: CGImage?
    @State private var renderGeneration = 0
    @State private var renderInFlight = false
    @State private var renderQueued = false
    /// One renderer (one CIContext) for the app's player. A per-struct
    /// renderer re-inited on every parent re-evaluation leaked a Metal
    /// context per slider tick and ground the session down over time.
    private static let renderer = ShotGradeRenderer()

    var body: some View {
        let shot = workspace.previewShot
        ZStack {
            Color.black
            FrameLayerView(image: playerImage)
            if playerImage == nil, shot != nil {
                ProgressView().controlSize(.small)
            }
            if transport.playRate != 0 {
                VStack {
                    HStack {
                        Spacer()
                        Text(shuttleLabel)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Capsule())
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                    Spacer()
                }
            }
        }
        .onAppear { rerender() }
        .onReceive(transport.$playheadFrame) { _ in rerender() }
        .onReceive(transport.$playRate) { _ in rerender() }
        .onChange(of: previews.version) { _, _ in rerender() }
        .onChange(of: workspace.skimShotID) { _, _ in rerender() }
        .onChange(of: workspace.selectedShotID) { _, _ in rerender() }
        .onChange(of: shot?.grade) { _, _ in rerender() }
        .onChange(of: shot?.useJpegSource) { _, _ in rerender() }
    }

    private var shuttleLabel: String {
        let r = transport.playRate
        return (r < 0 ? "\u{25C0} " : "\u{25B6} ") + (abs(r) == 1 ? "1x" : String(format: "%gx", abs(r)))
    }

    /// Live frame: cached base (full develop when primed) + grade applied
    /// on top. Export is the exact RAW develop.
    private func rerender() {
        guard let shot = workspace.previewShot,
              let url = workspace.currentShotFrameURL() else { playerImage = nil; return }
        if workspace.shotPlayRate == 0 { workspace.scheduleRefinedFrame() }
        workspace.requestPreviewFrame(url)
        guard let base = workspace.cachedRefinedFrame(url) ?? workspace.cachedPreviewFrame(url) else {
            return   // previewVersion bump re-triggers when the decode lands
        }
        let grade = shot.grade
        let seed = workspace.shotPlayheadFrame
        let ev = ExposureWobble.evOffset(
            outputFrame: seed, fps: workspace.shotFrameRate.fps,
            intensity: grade.wobbleIntensity, rate: grade.wobbleRate)
        // One render in flight at a time: scrubbing used to pile up
        // stale full-size CI renders until every keystroke waited in
        // line behind them.
        if renderInFlight {
            renderQueued = true
            return
        }
        renderInFlight = true
        renderGeneration += 1
        let generation = renderGeneration
        Task.detached(priority: .userInitiated) {
            let image = Self.renderer.gradePreview(base, grade: grade, evOffset: ev, grainSeed: seed) ?? base
            await MainActor.run {
                self.renderInFlight = false
                if generation == self.renderGeneration { self.playerImage = image }
                if self.renderQueued {
                    self.renderQueued = false
                    self.rerender()
                }
            }
        }
    }
}

private struct TransportFrameCounter: View {
    @ObservedObject var transport: WorkspaceModel.ShotTransport
    let total: Int64

    var body: some View {
        Text(String(format: "%d / %d", transport.playheadFrame + 1, total))
            .font(KineTheme.monoSmall)
            .foregroundStyle(KineTheme.textMuted)
            .frame(width: 74, alignment: .leading)
    }
}

private struct TransportScrub: View {
    let workspace: WorkspaceModel
    @ObservedObject var transport: WorkspaceModel.ShotTransport
    let total: Int64

    var body: some View {
        PlayerScrubBar(
            fraction: Binding(
                get: { Double(transport.playheadFrame) / Double(max(1, total - 1)) },
                set: { f in
                    workspace.shotStop()
                    workspace.shotPlayheadFrame = Int64((f * Double(total - 1)).rounded())
                }
            )
        )
    }
}

private struct TransportMarkControls: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var transport: WorkspaceModel.ShotTransport

    var body: some View {
        if let current = workspace.currentShotFrame() {
            let marked = current.shot.markedStillIDs.contains(current.frame.id)
            Divider().frame(height: 12)
            Button {
                workspace.toggleStillMark(current.frame.id, in: current.shot.id)
            } label: {
                Image(systemName: marked ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(marked ? KineTheme.accent : KineTheme.textMuted)
            }
            .buttonStyle(.plain)
            .help("Mark this still for export (key: M)")
            if current.shot.markedStillIDs.count > 0 {
                Text("\(current.shot.markedStillIDs.count)")
                    .font(KineTheme.monoSmall)
                    .foregroundStyle(KineTheme.textMuted)
            }
        }
    }
}
