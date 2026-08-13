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

    @State private var playerImage: CGImage?
    @State private var renderGeneration = 0
    private let renderer = ShotGradeRenderer()

    var body: some View {
        let shot = workspace.previewShot
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let playerImage {
                    Image(decorative: playerImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if shot != nil {
                    ProgressView().controlSize(.small)
                }
                if workspace.shotPlayRate != 0 {
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
            .frame(minHeight: large ? 280 : 160, idealHeight: large ? nil : 240,
                   maxHeight: large ? .infinity : nil)
            .contentShape(Rectangle())
            .onTapGesture { workspace.toggleShotPlayback() }

            if let shot {
                transportBar(shot)
                trimStrip(shot)
            }
        }
        .onAppear { rerender() }
        .onReceive(workspace.shotTransport.$playheadFrame) { _ in rerender() }
        .onReceive(workspace.shotTransport.$playRate) { _ in rerender() }
        .onChange(of: workspace.previewVersion) { _, _ in rerender() }
        .onChange(of: workspace.skimShotID) { _, _ in rerender() }
        .onChange(of: workspace.selectedShotID) { _, _ in rerender() }
        .onChange(of: shot?.grade) { _, _ in rerender() }
        .onChange(of: shot?.useJpegSource) { _, _ in rerender() }
    }

    private func transportBar(_ shot: BurstShot) -> some View {
        let total = max(1, ShotTimingEngine.totalFrames(workspace.scheduleForPreviewShot()))
        return HStack(spacing: 8) {
            playPauseButton
            frameCounter(total: total)
            scrubBar(total: total)
            durationLabel(total: total)
            Divider().frame(height: 12)
            trimButtons(shot)
            markControls
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

    private func frameCounter(total: Int64) -> some View {
        Text(String(format: "%d / %d", workspace.shotPlayheadFrame + 1, total))
            .font(KineTheme.monoSmall)
            .foregroundStyle(KineTheme.textMuted)
            .frame(width: 74, alignment: .leading)
    }

    private func scrubBar(total: Int64) -> some View {
        PlayerScrubBar(
            fraction: Binding(
                get: { Double(workspace.shotPlayheadFrame) / Double(max(1, total - 1)) },
                set: { f in
                    workspace.shotStop()
                    workspace.shotPlayheadFrame = Int64((f * Double(total - 1)).rounded())
                }
            )
        )
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

    @ViewBuilder private var markControls: some View {
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

    private var shuttleLabel: String {
        let r = workspace.shotPlayRate
        return (r < 0 ? "◀ " : "▶ ") + (abs(r) == 1 ? "1×" : String(format: "%g×", abs(r)))
    }

    /// Live frame: cached base preview (refined full-quality develop when
    /// parked) + grade applied on top. Sliders and playback stay realtime;
    /// export is the exact RAW develop.
    private func rerender() {
        guard let shot = workspace.previewShot,
              let url = workspace.currentShotFrameURL() else { playerImage = nil; return }
        if workspace.shotPlayRate == 0 { workspace.scheduleRefinedFrame() }
        guard let base = workspace.cachedRefinedFrame(url) ?? workspace.cachedPreviewFrame(url) else {
            workspace.requestPreviewFrame(url)
            return   // previewVersion bump re-triggers when the decode lands
        }
        let grade = shot.grade
        let seed = workspace.shotPlayheadFrame
        let ev = ExposureWobble.evOffset(
            outputFrame: seed, fps: workspace.shotFrameRate.fps,
            intensity: grade.wobbleIntensity, rate: grade.wobbleRate)
        renderGeneration += 1
        let generation = renderGeneration
        let renderer = renderer
        Task.detached(priority: .userInitiated) {
            let image = renderer.gradePreview(base, grade: grade, evOffset: ev, grainSeed: seed) ?? base
            await MainActor.run {
                if generation == self.renderGeneration { self.playerImage = image }
            }
        }
    }
}
