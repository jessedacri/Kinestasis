import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PreemCore

/// Lumetri-style color grading panel — a tab in the Source pane. Edits
/// the `preem.color` effect on the selected timeline clip(s); the Program
/// viewer updates live (WYSIWYG, since the compositor is the same path the
/// export uses). Basic Correction is keyframable via the per-row stopwatch.
struct ColorPanelContent: View {
    @ObservedObject var workspace: WorkspaceModel

    private var leadID: PlacedClipID? { workspace.selectedVideoClipIDs.first }
    private var grade: ColorGrade { leadID.flatMap { workspace.clipColorGrade($0) } ?? .identity }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if leadID == nil {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        basicSection
                        creativeSection
                        curvesSection
                    }
                    .padding(12)
                }
            }
        }
        .background(PreemTheme.bgPanel)
    }

    private var header: some View {
        HStack {
            Text("Color")
                .font(.system(size: 13, weight: .semibold))
            if workspace.selectedVideoClipIDs.count > 1 {
                Text("\(workspace.selectedVideoClipIDs.count) clips")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                workspace.resetColorOnSelection()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Reset all color")
            .disabled(leadID == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "paintpalette")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("Select a clip to grade")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Basic Correction

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Basic Correction")

            HStack(spacing: 8) {
                Text("Input")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)
                Picker("", selection: Binding(
                    get: { grade.inputSpace },
                    set: { workspace.setColorInputSpaceOnSelection($0) }
                )) {
                    ForEach(ColorTransferSpace.allCases, id: \.self) { sp in
                        Text(sp.displayName).tag(sp)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(.bottom, 2)

            groupLabel("White Balance")
            colorSlider(.temperature)
            colorSlider(.tint)

            groupLabel("Tone")
            colorSlider(.exposure)
            colorSlider(.contrast)
            colorSlider(.highlights)
            colorSlider(.shadows)
            colorSlider(.whites)
            colorSlider(.blacks)

            groupLabel("Saturation")
            colorSlider(.saturation)
            colorSlider(.vibrance)
        }
    }

    // MARK: - Creative (LUT)

    private var creativeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Creative")
            HStack(spacing: 8) {
                Text("LUT")
                    .font(.system(size: 11))
                    .frame(width: 78, alignment: .leading)
                Text(grade.lutPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                    .font(.system(size: 11))
                    .foregroundStyle(grade.lutPath == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Load…") { pickLUT() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                if grade.lutPath != nil {
                    Button {
                        workspace.setColorLUTOnSelection(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if grade.lutPath != nil {
                colorSlider(.lutIntensity)
            }
        }
    }

    private func pickLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a .cube LUT"
        if panel.runModal() == .OK, let url = panel.url {
            workspace.setColorLUTOnSelection(url.path)
        }
    }

    // MARK: - Curves

    private var curvesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Curves")
            CurveEditorView(workspace: workspace, leadID: leadID, grade: grade)
        }
    }

    // MARK: - Slider row

    @ViewBuilder
    private func colorSlider(_ p: ColorGradeParameter) -> some View {
        let value = value(for: p)
        let keyed = leadID.flatMap { workspace.findPlacedClip($0)?.hasKeyframes(for: p) } ?? false
        HStack(spacing: 8) {
            Button {
                workspace.toggleColorKeyframingOnSelection(p)
            } label: {
                Image(systemName: keyed ? "stopwatch.fill" : "stopwatch")
                    .font(.system(size: 10))
                    .foregroundStyle(keyed ? PreemTheme.accent : Color.secondary)
            }
            .buttonStyle(.borderless)
            .frame(width: 14)

            Text(p.displayName)
                .font(.system(size: 11))
                .frame(width: 78, alignment: .leading)

            ThinSlider(
                value: Binding(
                    get: { value },
                    set: { workspace.setColorParameterOnSelectionLight(p, $0) }
                ),
                range: p.range,
                onEditingChanged: { editing in
                    if editing { workspace.beginUndoBatch() }
                    else { workspace.endUndoBatch(); workspace.commitTransformEdits() }
                }
            )

            Text(format(value, p))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)

            Button {
                workspace.setColorParameterOnSelection(p, p.defaultValue)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .frame(width: 12)
        }
    }

    private func value(for p: ColorGradeParameter) -> Double {
        let g = grade
        switch p {
        case .temperature:  return g.temperature
        case .tint:         return g.tint
        case .exposure:     return g.exposure
        case .contrast:     return g.contrast
        case .highlights:   return g.highlights
        case .shadows:      return g.shadows
        case .whites:       return g.whites
        case .blacks:       return g.blacks
        case .saturation:   return g.saturation
        case .vibrance:     return g.vibrance
        case .lutIntensity: return g.lutIntensity
        }
    }

    private func format(_ v: Double, _ p: ColorGradeParameter) -> String {
        switch p {
        case .exposure: return String(format: "%+.2f", v)
        default:        return String(format: "%+.0f", v)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }
}
