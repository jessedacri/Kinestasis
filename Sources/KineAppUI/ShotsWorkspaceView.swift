import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KineCore
import KineMedia

/// The app's home screen — built around the Kinestasis flow rather than
/// the inherited NLE panes: import a burst folder, review the grouped
/// shots as a card grid, set the global cadence defaults in one bar, and
/// open any shot in the inspector to override timing / grade / texture.
/// The Assemble mode (timeline) is one click away for the final cut.
struct ShotsWorkspaceView: View {
    @ObservedObject var workspace: WorkspaceModel

    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            projectBar
            Divider()
            if workspace.orderedShots.isEmpty {
                emptyDropZone
            } else {
                KineSplitView(
                    isVertical: true,
                    autosaveName: "kine.shots.gridVsInspector",
                    firstSpec: KinePaneSpec(minThickness: 420, holdingPriority: 240),
                    secondSpec: KinePaneSpec(minThickness: 300, maxThickness: 460, holdingPriority: 260),
                    initialFirstThickness: 860,
                    first: { shotGrid },
                    second: { ShotGradePanel(workspace: workspace) }
                )
            }
        }
        .background(KineTheme.bg)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Project bar (global settings, the "step by step" spine)

    private var projectBar: some View {
        HStack(spacing: 14) {
            Button {
                importFolder()
            } label: {
                Label("Import Folder…", systemImage: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
            }

            Divider().frame(height: 16)

            BarValueControl(label: "Rate", value: workspace.project.settings.defaultFrameRate.rawValue + " fps") {
                ForEach(FrameRate.allCases, id: \.self) { rate in
                    BarOptionRow(label: rate.rawValue + " fps",
                                 selected: workspace.project.settings.defaultFrameRate == rate) {
                        workspace.setProjectFrameRate(rate)
                    }
                }
            }

            BarValueControl(label: "Timing", value: timingModeLabel(workspace.project.settings.burst.timing)) {
                TimingOptionRows(current: workspace.project.settings.burst.timing) { mode in
                    workspace.setDefaultShotTiming(mode)
                }
            }

            BarValueControl(label: "Skip", value: skipValueLabel(workspace.project.settings.burst.frameSkip)) {
                ForEach([1, 2, 3, 4, 6, 8], id: \.self) { n in
                    BarOptionRow(label: skipLabel(n),
                                 selected: workspace.project.settings.burst.frameSkip == n) {
                        workspace.setDefaultFrameSkip(n)
                    }
                }
                Text("Use every Nth still. Stacks with the timing mode; shots can override it individually.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }

            BarValueControl(label: "Split gap", value: gapLabel(workspace.project.settings.burst.gapThreshold)) {
                ForEach([0.5, 1.0, 2.0, 3.0, 5.0, 10.0], id: \.self) { gap in
                    BarOptionRow(label: gapLabel(gap),
                                 selected: workspace.project.settings.burst.gapThreshold == gap) {
                        workspace.setBurstGapThreshold(gap)
                    }
                }
                Text("New shots split where the capture gap is longer than this.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }

            BarValueControl(label: "Min burst", value: "\(workspace.project.settings.burst.minBurstCount)+ stills") {
                ForEach([2, 3, 4, 5, 8], id: \.self) { n in
                    BarOptionRow(label: "\(n)+ stills",
                                 selected: workspace.project.settings.burst.minBurstCount == n) {
                        workspace.setMinBurstCount(n)
                    }
                }
                Text("Smaller groups move to Singles. Applies to what is already imported.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }

            Spacer()

            if workspace.importing {
                if let p = workspace.importProgress, p.total > 0 {
                    ProgressView(value: Double(p.done), total: Double(p.total))
                        .controlSize(.small).frame(width: 120)
                    Text("Reading \(p.done.formatted()) / \(p.total.formatted())")
                        .font(KineTheme.monoSmall)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            if let progress = workspace.shotExportProgress {
                ProgressView(value: progress).controlSize(.small).frame(width: 110)
                Text(workspace.shotBatchLabel ?? "Rendering…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button {
                    workspace.cancelShotBatch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop rendering")
            } else if !workspace.orderedShots.isEmpty {
                let included = workspace.exportableShots.count
                Button {
                    workspace.beginShotExport(nil)
                } label: {
                    Label("Export \(included) of \(workspace.orderedShots.count)", systemImage: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                }
                .disabled(included == 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(KineTheme.bgPanel)
    }



    private func gapLabel(_ gap: Double) -> String {
        String(format: gap < 1 ? "%.1f s" : "%.0f s", gap)
    }

    /// Compact bar value: "off" when every still plays, else "every 2nd".
    private func skipValueLabel(_ n: Int) -> String {
        n <= 1 ? "off" : skipLabel(n).lowercased().replacingOccurrences(of: " still", with: "")
    }

    // MARK: - Shot grid (sectioned by capture day)

    private struct DaySection: Identifiable {
        let id: String
        let title: String
        let shots: [BurstShot]
    }

    private var daySections: [DaySection] {
        let calendar = Calendar.current
        let keyed = Dictionary(grouping: workspace.orderedShots) { shot -> Date in
            let t = shot.frames.first?.captureTime ?? 0
            return calendar.startOfDay(for: Date(timeIntervalSince1970: t))
        }
        return keyed.keys.sorted().map { day in
            let shots = keyed[day]!.sorted { ($0.frames.first?.captureTime ?? 0) < ($1.frames.first?.captureTime ?? 0) }
            return DaySection(id: Self.dayFormatter.string(from: day),
                              title: Self.dayFormatter.string(from: day),
                              shots: shots)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d yyyy"
        return f
    }()

    private var shotGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(daySections) { section in
                    HStack(spacing: 8) {
                        Text(section.title.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(KineTheme.accent)
                        Text("\(section.shots.count) shot\(section.shots.count == 1 ? "" : "s") · \(section.shots.reduce(0) { $0 + $1.frames.count }) stills")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 480), spacing: 12)],
                              alignment: .leading, spacing: 12) {
                        ForEach(section.shots) { shot in
                            ShotCard(workspace: workspace, shot: shot)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                if !workspace.project.mediaPool.singles.isEmpty {
                    SinglesSection(workspace: workspace)
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                }
            }
            .padding(.vertical, 8)
        }
        .overlay(alignment: .bottom) {
            if dropTargeted {
                dropHint
            }
        }
    }

    private var dropHint: some View {
        Label("Drop to import", systemImage: "square.and.arrow.down")
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(KineTheme.accent.opacity(0.9))
            .foregroundStyle(.black)
            .clipShape(Capsule())
            .padding(.bottom, 18)
    }

    // MARK: - Empty state

    private var emptyDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.on.rectangle")
                .font(.system(size: 44))
                .foregroundStyle(dropTargeted ? KineTheme.accent : Color.secondary.opacity(0.5))
            Text("Drag files/folders here to begin analysis")
                .font(.system(size: 18, weight: .semibold))
            Button("Choose Folder…") { importFolder() }
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(dropTargeted ? KineTheme.accent : Color.secondary.opacity(0.25),
                        style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .padding(24)
        )
    }

    // MARK: - Import

    private func importFolder() {
        let panel = NSOpenPanel()
        panel.title = "Import Burst Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        if panel.runModal() == .OK {
            workspace.ingest(urls: panel.urls)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            workspace.ingest(urls: urls)
        }
        return true
    }
}

/// The only view that observes the shot transport at playback rate.
private struct TransportPlayheadLine: View {
    @ObservedObject var transport: WorkspaceModel.ShotTransport
    let total: Int64
    let width: CGFloat

    var body: some View {
        if total > 1 {
            let fraction = Double(transport.playheadFrame) / Double(total - 1)
            Rectangle()
                .fill(Color.white)
                .frame(width: 1.5, height: 88)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .offset(x: CGFloat(max(0, min(1, fraction))) * width - 0.75)
        }
    }
}

// MARK: - Singles (non-burst stills)

/// Stills that didn't make a burst: counted, previewed lightly, and
/// prunable to a separate folder on disk so the burst folders stay clean.
private struct SinglesSection: View {
    @ObservedObject var workspace: WorkspaceModel
    @State private var thumbs: [CGImage] = []
    @State private var thumbedCount = -1

    private static let previewCap = 14

    var body: some View {
        let singles = workspace.project.mediaPool.singles
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("SINGLES · NOT A BURST")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(singles.count) stills")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Move to Folder…") { workspace.pruneSinglesToFolder() }
                    .font(.system(size: 10))
                Button("Reveal in Finder") { workspace.revealSinglesInFinder() }
                    .font(.system(size: 10))
                Button("Remove from Project") { workspace.removeSinglesFromProject() }
                    .font(.system(size: 10))
            }
            HStack(spacing: 4) {
                ForEach(Array(thumbs.enumerated()), id: \.offset) { _, img in
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                if singles.count > Self.previewCap {
                    Text("+\(singles.count - Self.previewCap)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, height: 40)
                        .background(Color.black.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            }
            Text("Loose one-offs below the min-burst threshold. Move them out to keep the burst folders clean.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear { refreshThumbs(singles) }
        .onChange(of: singles.count) { _, _ in refreshThumbs(singles) }
    }

    private func refreshThumbs(_ singles: [StillFrame]) {
        guard thumbedCount != singles.count else { return }
        thumbedCount = singles.count
        let urls = singles.prefix(Self.previewCap).map(\.url)
        Task.detached(priority: .utility) {
            let images = urls.compactMap { StillDecoder.preview(url: $0, maxPixel: 120) }
            await MainActor.run { thumbs = images }
        }
    }
}

// MARK: - Shot card

/// One shot in the grid: a tall filmstrip, name + per-shot timing badge,
/// and the live stats line. Click to open it in the inspector.
private struct ShotCard: View {
    @ObservedObject var workspace: WorkspaceModel
    let shot: BurstShot

    private var isSelected: Bool { workspace.selectedShotID == shot.id }
    private var mode: ShotTimingMode { shot.timing(projectDefault: workspace.project.settings.burst.timing) }
    private var rate: FrameRate { workspace.shotFrameRate }
    private var aspect: CGFloat {
        if let s = shot.frames.first?.pixelSize, s.height > 0 {
            return CGFloat(s.width) / CGFloat(s.height)
        }
        return 3.0 / 2.0
    }

    @State private var hoverFraction: Double? = nil

    private var schedule: [StillEvent] {
        workspace.schedule(for: shot)
    }

    /// Frame under the skim cursor (or the transport playhead when this
    /// shot is selected), honoring the RAW/JPEG source toggle.
    private func skimURL(fraction: Double) -> URL? {
        let sched = schedule
        let total = ShotTimingEngine.totalFrames(sched)
        guard total > 0 else { return nil }
        let f = Int64((fraction * Double(total - 1)).rounded())
        let playable = workspace.playbackFrames(for: shot)
        guard let event = ShotTimingEngine.event(at: f, in: sched),
              playable.indices.contains(event.frameIndex) else { return nil }
        return shot.sourceURL(for: playable[event.frameIndex])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    let _ = workspace.previewVersion
                    stripOrSkimFrame
                    trimShade(width: geo.size.width)
                    playheadLine(width: geo.size.width)
                    badges
                    includeToggle
                }
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let p):
                        let frac = geo.size.width > 0 ? Double(p.x / geo.size.width) : 0
                        hoverFraction = max(0, min(1, frac))
                        // Hover skims this shot in the player and hands it
                        // transport focus (space/JKL act on what's under
                        // the cursor) WITHOUT touching the selection — the
                        // inspector keeps the clicked shot.
                        workspace.skimShot(shot.id, fraction: hoverFraction!)
                        if let url = skimURL(fraction: hoverFraction!) {
                            workspace.requestPreviewFrame(url)
                        }
                    case .ended:
                        hoverFraction = nil
                        workspace.endSkim()
                    }
                }
            }
            .frame(height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? KineTheme.accent : Color.black.opacity(0.4),
                            lineWidth: isSelected ? 2 : 0.5)
            )
            .opacity(shot.includeInExport ? 1 : 0.45)

            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(shot.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if let fps = shot.approxCaptureFPSLabel {
                        Text("\(fps) capture")
                            .font(KineTheme.monoSmall)
                            .foregroundStyle(KineTheme.textMuted)
                    }
                }
                .opacity(shot.includeInExport ? 1 : 0.5)
                Spacer(minLength: 0)
                Text(statsLine)
                    .font(KineTheme.monoSmall)
                    .foregroundStyle(KineTheme.textMuted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { workspace.selectShot(shot.id) }
        .onAppear { workspace.scheduleShotThumbnails(for: shot) }
        .contextMenu {
            Menu("Timing") {
                TimingModePicker(current: shot.timingOverride, allowDefault: true,
                                 captureFPS: shot.approxCaptureFPS, outputRate: rate) { mode in
                    workspace.setShotTiming(mode, for: shot.id)
                }
            }
            Menu("Frame Skip") {
                FrameSkipPicker(current: shot.frameSkipOverride, allowDefault: true,
                                projectDefault: workspace.project.settings.burst.frameSkip) {
                    workspace.setShotFrameSkip($0, for: shot.id)
                }
            }
            Button("Copy Grade") { workspace.copyGrade(from: shot.id) }
            Button("Paste Grade") { workspace.pasteGrade(to: shot.id) }
                .disabled(workspace.copiedShotGrade == nil)
            if shot.hasRawJpegPairs {
                Button(shot.useJpegSource ? "Use RAW Source" : "Use JPEG Source") {
                    workspace.setUseJpegSource(!shot.useJpegSource, for: shot.id)
                }
            }
            Button("Export Shot…") { workspace.beginShotExport([shot.id]) }
            Divider()
            Button("Remove Shot", role: .destructive) { workspace.removeShot(shot.id) }
        }
    }

    /// While skimming (or when selected + playing), show the live frame
    /// full-bleed; otherwise the filmstrip.
    @ViewBuilder private var stripOrSkimFrame: some View {
        let images = workspace.shotThumbnails[shot.id] ?? []
        let liveURL: URL? = hoverFraction.flatMap { skimURL(fraction: $0) }
        if let liveURL, let frame = workspace.cachedPreviewFrame(liveURL) {
            GeometryReader { geo in
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        } else if images.isEmpty {
            Rectangle().fill(Color.black.opacity(0.35))
                .overlay(ProgressView().controlSize(.small))
        } else {
            ShotFilmstrip(images: images, aspect: aspect)
        }
    }

    /// Trimmed-off head/tail darkened over the filmstrip, so the kept
    /// range reads at a glance.
    @ViewBuilder private func trimShade(width: CGFloat) -> some View {
        if shot.isTrimmed, !shot.frames.isEmpty {
            let n = CGFloat(shot.frames.count)
            HStack(spacing: 0) {
                Rectangle().fill(Color.black.opacity(0.62))
                    .frame(width: max(0, CGFloat(shot.trimIn) / n * width))
                Spacer(minLength: 0)
                Rectangle().fill(Color.black.opacity(0.62))
                    .frame(width: max(0, CGFloat(shot.trimOut) / n * width))
            }
            .frame(width: width)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder private func playheadLine(width: CGFloat) -> some View {
        if let fraction = hoverFraction {
            Rectangle()
                .fill(Color.white)
                .frame(width: 1.5, height: 88)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .offset(x: CGFloat(fraction) * width - 0.75)
        } else if isSelected {
            // Transport-driven line in its own subview: 24 Hz playback
            // ticks re-render only this overlay, never the card/grid.
            TransportPlayheadLine(transport: workspace.shotTransport,
                                  total: ShotTimingEngine.totalFrames(schedule),
                                  width: width)
        }
    }

    /// One-click include/exclude from export.
    private var includeToggle: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    workspace.setIncludeInExport(!shot.includeInExport, for: shot.id)
                } label: {
                    Image(systemName: shot.includeInExport ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(shot.includeInExport ? KineTheme.accent : .white.opacity(0.55))
                        .shadow(color: .black.opacity(0.6), radius: 2)
                }
                .buttonStyle(.plain)
                .help(shot.includeInExport ? "Included in export. Click to exclude" : "Excluded from export. Click to include")
                .padding(6)
            }
            Spacer()
        }
    }

    private var badges: some View {
        HStack(spacing: 4) {
            Text("\(shot.frames.count)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.6))
                .clipShape(Capsule())
            if shot.timingOverride != nil {
                badge(timingModeLabel(mode))
            }
            if !shot.grade.isIdentity {
                badge("graded")
            }
            if !shot.speedRamp.isEmpty {
                badge("ramp")
            }
        }
        .foregroundStyle(.white)
        .padding(6)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(KineTheme.accent.opacity(0.9))
            .foregroundStyle(.black)
            .clipShape(Capsule())
    }

    private var statsLine: String {
        let seconds = Double(ShotTimingEngine.totalFrames(schedule)) / rate.fps
        let resolvedSkip = workspace.resolvedFrameSkip(for: shot)
        let skip = resolvedSkip > 1 ? " · skip \(resolvedSkip)" : ""
        return String(format: "%.1fs · %@%@ · %@", seconds, timingModeLabel(mode), skip, shot.fileTypeLabel)
    }
}

// MARK: - Project-bar value controls

/// Always-visible setting readout: small caps label over the current value
/// in the accent color. Clicking opens an on-brand popover with the
/// options and any secondary explanation.
struct BarValueControl<Content: View>: View {
    let label: String
    let value: String
    @ViewBuilder let options: () -> Content

    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(label.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(value)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(KineTheme.accent)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering || showing ? Color.white.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                options()
            }
            .padding(10)
            .frame(minWidth: 170)
            .background(KineTheme.bgPanel)
            .preferredColorScheme(.dark)
            .tint(KineTheme.accent)
        }
    }
}

/// One option inside a BarValueControl popover.
struct BarOptionRow: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(KineTheme.accent)
                    .opacity(selected ? 1 : 0)
                Text(label)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(hovering ? KineTheme.accent.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Timing options as popover rows (the context-menu picker stays for
/// per-shot menus; this is the bar's on-brand version).
struct TimingOptionRows: View {
    let current: ShotTimingMode
    let onPick: (ShotTimingMode) -> Void

    var body: some View {
        Group {
            sectionLabel("Fixed")
            ForEach([1, 2, 3, 4, 6, 8, 12], id: \.self) { f in
                BarOptionRow(label: "\(f) frame\(f == 1 ? "" : "s") / still",
                             selected: current == .fixedFramesPerStill(frames: f)) {
                    onPick(.fixedFramesPerStill(frames: f))
                }
            }
            sectionLabel("As Shot")
            BarOptionRow(label: "Real time", selected: current == .asShot(rate: 1.0)) { onPick(.asShot(rate: 1.0)) }
            BarOptionRow(label: "Half speed", selected: current == .asShot(rate: 0.5)) { onPick(.asShot(rate: 0.5)) }
            BarOptionRow(label: "Double speed", selected: current == .asShot(rate: 2.0)) { onPick(.asShot(rate: 2.0)) }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
    }
}
