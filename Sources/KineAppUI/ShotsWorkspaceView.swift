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

            barMenu(title: "Rate", value: workspace.project.settings.defaultFrameRate.rawValue + " fps") {
                ForEach(FrameRate.allCases, id: \.self) { rate in
                    Button {
                        workspace.setProjectFrameRate(rate)
                    } label: {
                        if workspace.project.settings.defaultFrameRate == rate {
                            Label(rate.rawValue + " fps", systemImage: "checkmark")
                        } else {
                            Text(rate.rawValue + " fps")
                        }
                    }
                }
            }

            barMenu(title: "Timing", value: timingModeLabel(workspace.project.settings.burst.timing)) {
                TimingModePicker(current: workspace.project.settings.burst.timing, allowDefault: false) { mode in
                    if let mode { workspace.setDefaultShotTiming(mode) }
                }
            }

            barMenu(title: "Split gap", value: gapLabel(workspace.project.settings.burst.gapThreshold)) {
                ForEach([0.5, 1.0, 2.0, 3.0, 5.0, 10.0], id: \.self) { gap in
                    Button {
                        workspace.setBurstGapThreshold(gap)
                    } label: {
                        if workspace.project.settings.burst.gapThreshold == gap {
                            Label(gapLabel(gap), systemImage: "checkmark")
                        } else {
                            Text(gapLabel(gap))
                        }
                    }
                }
            }

            barMenu(title: "Min burst", value: "\(workspace.project.settings.burst.minBurstCount)+") {
                ForEach([2, 3, 4, 5, 8], id: \.self) { n in
                    Button {
                        workspace.setMinBurstCount(n)
                    } label: {
                        if workspace.project.settings.burst.minBurstCount == n {
                            Label("\(n)+ stills", systemImage: "checkmark")
                        } else {
                            Text("\(n)+ stills")
                        }
                    }
                }
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
                Text("Rendering…").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if !workspace.orderedShots.isEmpty {
                Button {
                    workspace.assembleShots()
                } label: {
                    Label("Assemble", systemImage: "timeline.selection")
                        .font(.system(size: 11, weight: .semibold))
                }
                .help("Render the included shots and lay them on a timeline for trimming")

                let included = workspace.exportableShots.count
                Menu {
                    Button("ProRes 422 HQ + XML…") { workspace.exportShots(codec: .proRes422HQ) }
                    Button("ProRes 4444 + XML…") { workspace.exportShots(codec: .proRes4444) }
                } label: {
                    Label("Export \(included) of \(workspace.orderedShots.count)", systemImage: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                }
                .fixedSize()
                .disabled(included == 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(KineTheme.bgPanel)
    }

    @ViewBuilder
    private func barMenu<Items: View>(title: String, value: String, @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 11, weight: .medium))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func gapLabel(_ gap: Double) -> String {
        String(format: gap < 1 ? "%.1f s" : "%.0f s", gap)
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
        ThinScrollView(axis: .vertical) {
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
            Text("Drop a burst folder")
                .font(.system(size: 18, weight: .semibold))
            VStack(spacing: 4) {
                Text("JPEG + RAW stills are grouped into shots by capture gaps.")
                Text("Set cadence per shot, grade, then batch-export ProRes + XML.")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
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
                Text("SINGLES — NOT A BURST")
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
        ShotTimingEngine.schedule(for: shot, projectDefault: workspace.project.settings.burst.timing, rate: rate)
    }

    /// Frame under the skim cursor (or the transport playhead when this
    /// shot is selected), honoring the RAW/JPEG source toggle.
    private func skimURL(fraction: Double) -> URL? {
        let sched = schedule
        let total = ShotTimingEngine.totalFrames(sched)
        guard total > 0 else { return nil }
        let f = Int64((fraction * Double(total - 1)).rounded())
        guard let event = ShotTimingEngine.event(at: f, in: sched),
              shot.frames.indices.contains(event.frameIndex) else { return nil }
        return shot.sourceURL(for: shot.frames[event.frameIndex])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    let _ = workspace.previewVersion
                    stripOrSkimFrame
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
                        // Hover hands transport focus to this shot — same
                        // as the source-viewer filmstrips: space/JKL act
                        // on what's under the cursor.
                        workspace.skimShot(shot.id, fraction: hoverFraction!)
                        if let url = skimURL(fraction: hoverFraction!) {
                            workspace.requestPreviewFrame(url)
                        }
                    case .ended:
                        hoverFraction = nil
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

            HStack(spacing: 6) {
                Text(shot.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
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
                TimingModePicker(current: shot.timingOverride, allowDefault: true) { mode in
                    workspace.setShotTiming(mode, for: shot.id)
                }
            }
            Button("Copy Grade") { workspace.copyGrade(from: shot.id) }
            Button("Paste Grade") { workspace.pasteGrade(to: shot.id) }
                .disabled(workspace.copiedShotGrade == nil)
            Menu("Export Shot") {
                Button("ProRes 422 HQ…") { workspace.exportShots([shot.id], codec: .proRes422HQ) }
                Button("ProRes 4444…") { workspace.exportShots([shot.id], codec: .proRes4444) }
            }
            Divider()
            Button("Remove Shot", role: .destructive) { workspace.removeShot(shot.id) }
        }
    }

    /// While skimming (or when selected + playing), show the live frame
    /// full-bleed; otherwise the filmstrip.
    @ViewBuilder private var stripOrSkimFrame: some View {
        let images = workspace.shotThumbnails[shot.id] ?? []
        let liveURL: URL? = {
            if let f = hoverFraction { return skimURL(fraction: f) }
            if isSelected && workspace.shotPlayRate != 0 { return workspace.currentShotFrameURL() }
            return nil
        }()
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

    @ViewBuilder private func playheadLine(width: CGFloat) -> some View {
        let fraction: Double? = {
            if let f = hoverFraction { return f }
            guard isSelected else { return nil }
            let total = ShotTimingEngine.totalFrames(schedule)
            guard total > 1 else { return nil }
            return Double(workspace.shotPlayheadFrame) / Double(total - 1)
        }()
        if let fraction {
            Rectangle()
                .fill(Color.white)
                .frame(width: 1.5, height: 88)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .offset(x: CGFloat(fraction) * width - 0.75)
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
                .help(shot.includeInExport ? "Included in export — click to exclude" : "Excluded from export — click to include")
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
        return String(format: "%.1fs · %@ · %@", seconds, timingModeLabel(mode), shot.fileTypeLabel)
    }
}
