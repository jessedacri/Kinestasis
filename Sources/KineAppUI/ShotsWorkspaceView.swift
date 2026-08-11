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

            Spacer()

            if workspace.importing {
                ProgressView().controlSize(.small)
                Text("Importing…").font(.system(size: 11)).foregroundStyle(.secondary)
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
                .help("Render all shots and lay them on a timeline for trimming")

                Menu {
                    Button("ProRes 422 HQ + XML…") { workspace.exportShots(codec: .proRes422HQ) }
                    Button("ProRes 4444 + XML…") { workspace.exportShots(codec: .proRes4444) }
                } label: {
                    Label("Export \(workspace.orderedShots.count) Shots", systemImage: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                }
                .fixedSize()
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

    // MARK: - Shot grid

    private var shotGrid: some View {
        ThinScrollView(axis: .vertical) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 480), spacing: 12)],
                      alignment: .leading, spacing: 12) {
                ForEach(workspace.orderedShots) { shot in
                    ShotCard(workspace: workspace, shot: shot)
                }
            }
            .padding(14)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                let _ = workspace.previewVersion
                let images = workspace.shotThumbnails[shot.id] ?? []
                if images.isEmpty {
                    Rectangle().fill(Color.black.opacity(0.35))
                        .overlay(ProgressView().controlSize(.small))
                } else {
                    ShotFilmstrip(images: images, aspect: aspect)
                }
                badges
            }
            .frame(height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? KineTheme.accent : Color.black.opacity(0.4),
                            lineWidth: isSelected ? 2 : 0.5)
            )

            HStack(spacing: 6) {
                Text(shot.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
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
        let schedule = ShotTimingEngine.schedule(
            for: shot, projectDefault: workspace.project.settings.burst.timing, rate: rate)
        let seconds = Double(ShotTimingEngine.totalFrames(schedule)) / rate.fps
        return String(format: "%.1fs · %@", seconds, timingModeLabel(mode))
    }
}
