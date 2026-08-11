import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KineCore
import KineMedia

/// Camera-raw-style grade panel for the selected burst shot: live preview
/// on top, thin-chrome sliders below. Edits write straight to the shot's
/// grade; the preview re-develops debounced.
struct ShotGradePanel: View {
    @ObservedObject var workspace: WorkspaceModel

    @State private var preview: CGImage?
    @State private var renderGeneration = 0
    @State private var previewFrameIndex = 0

    private let renderer = ShotGradeRenderer()

    var body: some View {
        if let shot = workspace.selectedShot {
            VStack(spacing: 0) {
                previewArea(shot)
                Divider()
                ThinScrollView(axis: .vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        timingSection(shot)
                        Divider()
                        controls(shot)
                        Divider()
                        lutSection(shot)
                        Divider()
                        textureSection(shot)
                        Divider()
                        rampSection(shot)
                        Divider()
                        looksSection(shot)
                    }
                    .padding(12)
                }
            }
            .onAppear { rerender(shot) }
            .onChange(of: shot.grade) { _, _ in rerender(shot) }
            .onChange(of: shot.id) { _, _ in previewFrameIndex = shot.frames.count / 2; rerender(shot) }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("Click a shot in the bin to grade it")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Preview

    private func previewArea(_ shot: BurstShot) -> some View {
        ZStack {
            Color.black
            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack {
                Spacer()
                HStack {
                    Text(shot.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    if shot.frames.count > 1 {
                        ThinSlider(
                            value: Binding(
                                get: { Double(previewFrameIndex) },
                                set: { previewFrameIndex = Int($0.rounded()); rerender(shot) }
                            ),
                            range: 0...Double(shot.frames.count - 1)
                        )
                        .frame(width: 120)
                        .help("Preview still")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
        .frame(minHeight: 160, idealHeight: 240)
    }

    private func rerender(_ shot: BurstShot) {
        guard !shot.frames.isEmpty else { preview = nil; return }
        let idx = min(max(0, previewFrameIndex), shot.frames.count - 1)
        let url = shot.frames[idx].url
        let grade = shot.grade
        renderGeneration += 1
        let generation = renderGeneration
        let renderer = renderer
        Task.detached(priority: .userInitiated) {
            let image = renderer.render(url: url, grade: grade, maxPixel: 1024)
            await MainActor.run {
                if generation == self.renderGeneration { self.preview = image }
            }
        }
    }

    // MARK: - Timing

    private func timingSection(_ shot: BurstShot) -> some View {
        let projectDefault = workspace.project.settings.burst.timing
        let mode = shot.timing(projectDefault: projectDefault)
        let rate = workspace.shotFrameRate
        let schedule = ShotTimingEngine.schedule(for: shot, projectDefault: projectDefault, rate: rate)
        let seconds = Double(ShotTimingEngine.totalFrames(schedule)) / rate.fps
        return VStack(alignment: .leading, spacing: 6) {
            Text("TIMING").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            HStack {
                Menu {
                    TimingModePicker(current: shot.timingOverride, allowDefault: true) { picked in
                        workspace.setShotTiming(picked, for: shot.id)
                    }
                } label: {
                    Label(timingModeLabel(mode) + (shot.timingOverride == nil ? "  (project default)" : ""),
                          systemImage: "timer")
                        .font(.system(size: 11))
                }
                .fixedSize()
                Spacer()
            }
            Text(String(format: "%d stills · shot over %.1fs · plays %.1fs @ %@",
                        shot.frames.count, shot.captureSpan, seconds, rate.rawValue))
                .font(KineTheme.monoSmall)
                .foregroundStyle(KineTheme.textMuted)
        }
    }

    // MARK: - Sliders

    private func controls(_ shot: BurstShot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            gradeRow(shot, "Exposure", range: -5...5, format: "%+.2f",
                     get: \.exposure) { $0.exposure = $1 }
            gradeRow(shot, "Contrast", range: -100...100, format: "%+.0f",
                     get: \.contrast) { $0.contrast = $1 }
            gradeRow(shot, "Temperature", range: -100...100, format: "%+.0f",
                     get: \.temperature) { $0.temperature = $1 }
            gradeRow(shot, "Tint", range: -100...100, format: "%+.0f",
                     get: \.tint) { $0.tint = $1 }
            gradeRow(shot, "Highlights", range: -100...100, format: "%+.0f",
                     get: \.highlights) { $0.highlights = $1 }
            gradeRow(shot, "Shadows", range: -100...100, format: "%+.0f",
                     get: \.shadows) { $0.shadows = $1 }
            gradeRow(shot, "Saturation", range: -100...100, format: "%+.0f",
                     get: \.saturation) { $0.saturation = $1 }
                .disabled(shot.grade.blackAndWhite)
                .opacity(shot.grade.blackAndWhite ? 0.4 : 1)

            HStack {
                Toggle(isOn: Binding(
                    get: { shot.grade.blackAndWhite },
                    set: { on in mutate(shot) { $0.blackAndWhite = on } }
                )) {
                    Text("Black & White").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                Spacer()
                Button("Reset") {
                    mutate(shot) { g in
                        let lut = g.lutPath; let intensity = g.lutIntensity
                        g = .identity
                        g.lutPath = lut; g.lutIntensity = intensity
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(KineTheme.accent)
            }
        }
    }

    private func gradeRow(
        _ shot: BurstShot, _ label: String, range: ClosedRange<Double>, format: String,
        get: KeyPath<ShotGrade, Double>, set: @escaping (inout ShotGrade, Double) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            ThinSlider(
                value: Binding(
                    get: { shot.grade[keyPath: get] },
                    set: { v in mutate(shot) { set(&$0, v) } }
                ),
                range: range
            )
            Text(String(format: format, shot.grade[keyPath: get]))
                .font(KineTheme.monoSmall)
                .foregroundStyle(KineTheme.textMuted)
                .frame(width: 44, alignment: .trailing)
                .onTapGesture(count: 2) { mutate(shot) { set(&$0, 0) } }
        }
    }

    // MARK: - LUT

    private func lutSection(_ shot: BurstShot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LUT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if shot.grade.lutPath != nil {
                    Button("Clear") { mutate(shot) { $0.lutPath = nil } }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(KineTheme.accent)
                }
            }
            HStack(spacing: 8) {
                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
                    if panel.runModal() == .OK, let url = panel.url {
                        mutate(shot) { $0.lutPath = url.path }
                    }
                } label: {
                    Label(shot.grade.lutPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Load .cube…",
                          systemImage: "square.3.layers.3d")
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
            }
            if shot.grade.lutPath != nil {
                HStack(spacing: 8) {
                    Text("Intensity")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 78, alignment: .leading)
                    ThinSlider(
                        value: Binding(
                            get: { shot.grade.lutIntensity },
                            set: { v in mutate(shot) { $0.lutIntensity = v } }
                        ),
                        range: 0...100
                    )
                    Text(String(format: "%.0f%%", shot.grade.lutIntensity))
                        .font(KineTheme.monoSmall)
                        .foregroundStyle(KineTheme.textMuted)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Texture (grain + wobble)

    private func textureSection(_ shot: BurstShot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TEXTURE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            gradeRow(shot, "Grain", range: 0...100, format: "%.0f",
                     get: \.grainAmount) { $0.grainAmount = $1 }
            if shot.grade.grainAmount > 0 {
                gradeRow(shot, "Grain Size", range: 0.5...4, format: "%.1f",
                         get: \.grainSize) { $0.grainSize = $1 }
                gradeRow(shot, "Response", range: -100...100, format: "%+.0f",
                         get: \.grainResponse) { $0.grainResponse = $1 }
                Text("Response < 0 favors shadows, > 0 highlights")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            gradeRow(shot, "Wobble", range: 0...100, format: "%.0f",
                     get: \.wobbleIntensity) { $0.wobbleIntensity = $1 }
            if shot.grade.wobbleIntensity > 0 {
                gradeRow(shot, "Wobble Rate", range: 0.5...12, format: "%.1f Hz",
                         get: \.wobbleRate) { $0.wobbleRate = $1 }
                Text("Per-frame exposure flicker — shows on export/playback, not this still")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Speed ramp

    private func rampSection(_ shot: BurstShot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SPEED RAMP").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if !shot.speedRamp.isEmpty {
                    Button("Reset") { workspace.setShotRamp([], for: shot.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(KineTheme.accent)
                }
            }
            RampCurveEditor(
                points: shot.speedRamp,
                onChange: { pts in workspace.setShotRamp(pts, for: shot.id) }
            )
            .frame(height: 120)
            Text("Steep = fast, flat = linger. Duration stays the same.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Looks + copy/paste

    private func looksSection(_ shot: BurstShot) -> some View {
        HStack(spacing: 10) {
            Menu {
                Button("Save Look…") { saveLook(shot) }
                let looks = workspace.availableLooks()
                if !looks.isEmpty {
                    Divider()
                    ForEach(looks, id: \.url) { look in
                        Button(look.name) {
                            if let grade = workspace.loadLook(from: look.url) {
                                workspace.setShotGrade(grade, for: shot.id)
                            }
                        }
                    }
                }
            } label: {
                Label("Looks", systemImage: "paintpalette")
                    .font(.system(size: 11))
            }
            .fixedSize()

            Spacer()

            Button("Copy Grade") { workspace.copyGrade(from: shot.id) }
                .font(.system(size: 10))
            Button("Paste Grade") { workspace.pasteGrade(to: shot.id) }
                .font(.system(size: 10))
                .disabled(workspace.copiedShotGrade == nil)
        }
    }

    private func saveLook(_ shot: BurstShot) {
        let alert = NSAlert()
        alert.messageText = "Save Look"
        alert.informativeText = "Name this look:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        field.stringValue = shot.name
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { workspace.saveLook(shot.grade, name: name) }
        }
    }

    private func mutate(_ shot: BurstShot, _ change: (inout ShotGrade) -> Void) {
        var grade = shot.grade
        change(&grade)
        workspace.setShotGrade(grade, for: shot.id)
    }
}
