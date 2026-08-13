import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KineCore
import KineMedia

/// Per-shot inspector: a real player up top (space/JKL transport, scrub
/// bar, live-graded frames from the preview cache), then timing, grade,
/// LUT, texture, ramp, looks, and the EXIF of the frame on screen.
struct ShotGradePanel: View {
    @ObservedObject var workspace: WorkspaceModel
    /// False in the fullscreen processing view, where the big shared
    /// player renders elsewhere and this panel is sections only.
    var showPlayer = true

    @State private var exifFields: [ExifReader.Field] = []
    @State private var exifURL: URL?
    @State private var holdFrames = 24
    @State private var holdEaseIn = 3
    @State private var holdEaseOut = 3
    @State private var holdEase = 0.5
    @State private var holdSkipAfter = 0

    var body: some View {
        if let shot = workspace.selectedShot {
            VStack(spacing: 0) {
                if showPlayer {
                    ShotPlayerView(workspace: workspace)
                    Divider()
                }
                ThinScrollView(axis: .vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        timingSection(shot)
                        if shot.hasRawJpegPairs {
                            Divider()
                            sourceSection(shot)
                        }
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
                        Divider()
                        exifSection(shot)
                    }
                    .padding(12)
                }
            }
            .onAppear {
                workspace.prefetchPreviewFrames(for: shot)
                refreshCurrentExif()
            }
            .onChange(of: shot.id) { _, _ in
                workspace.shotStop()
                workspace.shotPlayheadFrame = 0
                workspace.prefetchPreviewFrames(for: shot)
                refreshCurrentExif()
            }
            .onReceive(workspace.shotTransport.$playheadFrame) { _ in refreshCurrentExif() }
            .onChange(of: workspace.skimShotID) { _, _ in refreshCurrentExif() }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("Hover or click a shot to load it here")
                    .foregroundStyle(.secondary)
                Text("space play · J K L shuttle · ← → step")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func refreshCurrentExif() {
        if let url = workspace.currentShotFrameURL() { refreshExif(url) }
    }

    private func refreshExif(_ url: URL) {
        guard exifURL != url else { return }
        exifURL = url
        Task.detached(priority: .utility) {
            let fields = ExifReader.read(url: url)
            await MainActor.run {
                if self.exifURL == url { self.exifFields = fields }
            }
        }
    }

    // MARK: - Timing

    private func timingSection(_ shot: BurstShot) -> some View {
        let projectDefault = workspace.project.settings.burst.timing
        let mode = shot.timing(projectDefault: projectDefault)
        let rate = workspace.shotFrameRate
        let schedule = workspace.schedule(for: shot)
        let seconds = Double(ShotTimingEngine.totalFrames(schedule)) / rate.fps
        return VStack(alignment: .leading, spacing: 6) {
            Text("TIMING").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            HStack {
                Menu {
                    TimingModePicker(current: shot.timingOverride, allowDefault: true,
                                     captureFPS: shot.approxCaptureFPS, outputRate: rate) { picked in
                        workspace.setShotTiming(picked, for: shot.id)
                    }
                } label: {
                    Label(timingModeLabel(mode) + (shot.timingOverride == nil ? " (default)" : ""),
                          systemImage: "timer")
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Toggle(isOn: Binding(
                    get: { shot.includeInExport },
                    set: { workspace.setIncludeInExport($0, for: shot.id) }
                )) {
                    Text("Export").font(.system(size: 10))
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Menu {
                    FrameSkipPicker(current: shot.frameSkipOverride, allowDefault: true,
                                    projectDefault: workspace.project.settings.burst.frameSkip) {
                        workspace.setShotFrameSkip($0, for: shot.id)
                    }
                } label: {
                    Label(skipLabel(workspace.resolvedFrameSkip(for: shot))
                              + (shot.frameSkipOverride == nil ? " (default)" : ""),
                          systemImage: "square.3.layers.3d.middle.filled")
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Text(metadataBits(shot, seconds: seconds, rate: rate).joined(separator: " · "))
                .font(KineTheme.monoSmall)
                .foregroundStyle(KineTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metadataBits(_ shot: BurstShot, seconds: Double, rate: FrameRate) -> [String] {
        var bits: [String] = []
        bits.append("\(shot.frames.count) stills"
            + (shot.isTrimmed ? " (trimmed to \(shot.effectiveFrames.count))" : ""))
        bits.append(shot.fileTypeLabel)
        if shot.captureSpan > 0 {
            if let fps = shot.approxCaptureFPSLabel {
                bits.append(String(format: "shot over %.1fs at %@", shot.captureSpan, fps))
            } else {
                bits.append(String(format: "shot over %.1fs", shot.captureSpan))
            }
        }
        let resolvedSkip = workspace.resolvedFrameSkip(for: shot)
        if resolvedSkip > 1 {
            bits.append(skipLabel(resolvedSkip).lowercased())
        }
        bits.append(String(format: "plays %.1fs @ %@", seconds, rate.rawValue))
        return bits
    }

    // MARK: - Frame source (RAW / JPEG pairs)

    private func sourceSection(_ shot: BurstShot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FRAME SOURCE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { shot.useJpegSource },
                set: { workspace.setUseJpegSource($0, for: shot.id) }
            )) {
                Text(CameraFileType.label(forExtension: shot.frames.first?.url.pathExtension ?? "raw")).tag(false)
                Text("Camera JPEG").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            Text("This burst has RAW+JPEG pairs. RAW gives the full develop; JPEG bakes the camera's look and previews faster.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
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

            HStack(spacing: 8) {
                Menu {
                    ForEach([6, 12, 18, 24, 36, 48, 72], id: \.self) { f in
                        Button(holdFramesLabel(f)) { holdFrames = f }
                    }
                } label: {
                    Text("Hold \(holdFrames)f").font(.system(size: 10))
                }
                .fixedSize()
                .help("How many output frames the held still occupies")
                Menu {
                    ForEach([0, 1, 2, 3, 5, 8], id: \.self) { n in
                        Button("\(n) still\(n == 1 ? "" : "s")") { holdEaseIn = n }
                    }
                } label: {
                    Text("In \(holdEaseIn)").font(.system(size: 10))
                }
                .fixedSize()
                .help("Stills that slow down into the hold")
                Menu {
                    ForEach([0, 1, 2, 3, 5, 8], id: \.self) { n in
                        Button("\(n) still\(n == 1 ? "" : "s")") { holdEaseOut = n }
                    }
                } label: {
                    Text("Out \(holdEaseOut)").font(.system(size: 10))
                }
                .fixedSize()
                .help("Stills that race back out of the hold")
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Menu {
                    Button("Gentle") { holdEase = 0.15 }
                    Button("Medium") { holdEase = 0.5 }
                    Button("Sharp") { holdEase = 1.0 }
                } label: {
                    Text(easeLabel).font(.system(size: 10))
                }
                .fixedSize()
                Menu {
                    ForEach([0, 1, 2, 3, 5, 8, 12], id: \.self) { n in
                        Button(n == 0 ? "None" : "\(n) still\(n == 1 ? "" : "s")") { holdSkipAfter = n }
                    }
                } label: {
                    Text("Then skip \(holdSkipAfter)").font(.system(size: 10))
                }
                .fixedSize()
                .help("Drop this many stills when the hold releases, as if the cadence kept running underneath")
                Spacer(minLength: 0)
                Button("Hold on This Still") {
                    workspace.holdRampOnCurrentStill(
                        holdFrames: holdFrames, easeIn: holdEaseIn, easeOut: holdEaseOut,
                        ease: holdEase, skipAfter: holdSkipAfter)
                }
                .font(.system(size: 10, weight: .semibold))
                .help("Linger on the still under the playhead; the rest of the shot speeds up around it")
            }
        }
    }

    private func holdFramesLabel(_ frames: Int) -> String {
        String(format: "%d frames (%.1fs)", frames, Double(frames) / workspace.shotFrameRate.fps)
    }

    private var easeLabel: String {
        holdEase < 0.3 ? "Gentle" : holdEase < 0.8 ? "Medium" : "Sharp"
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

    // MARK: - EXIF

    private func exifSection(_ shot: BurstShot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EXIF · FRAME ON SCREEN")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            if exifFields.isEmpty {
                Text("No metadata").font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                ForEach(exifFields) { field in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(field.label)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 78, alignment: .leading)
                        Text(field.value)
                            .font(KineTheme.monoSmall)
                            .foregroundStyle(KineTheme.textMuted)
                            .textSelection(.enabled)
                    }
                }
            }
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

/// Slim scrub bar for the shot player.
struct PlayerScrubBar: View {
    @Binding var fraction: Double

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.22)).frame(height: 3)
                Capsule().fill(KineTheme.accent.opacity(0.8))
                    .frame(width: CGFloat(max(0, min(1, fraction))) * w, height: 3)
                Rectangle().fill(Color.white)
                    .frame(width: 1.5, height: 12)
                    .offset(x: CGFloat(max(0, min(1, fraction))) * w - 0.75)
                    .shadow(color: .black.opacity(0.5), radius: 1)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { v in
                    fraction = max(0, min(1, Double(v.location.x / w)))
                }
            )
        }
        .frame(height: 14)
    }
}
