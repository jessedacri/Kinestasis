import SwiftUI
import AppKit
import KineCore
import KineMedia

/// On-brand export dialog for shots. One shot or the whole included set:
/// destination, codec, output resolution, optional FCPXML sidecar. Plain
/// language, no system-alert chrome.
struct ShotExportSheet: View {
    @ObservedObject var workspace: WorkspaceModel

    @State private var destination: URL?
    @State private var codec: BurstShotExporter.Codec = .proRes422HQ
    @State private var resolutionChoice: ResolutionChoice = .native
    @State private var writeSidecar = false

    private enum ResolutionChoice: String, CaseIterable {
        case native = "Native"
        case uhd = "3840 long edge"
        case hd = "1920 long edge"

        var longEdge: Int? {
            switch self {
            case .native: return nil
            case .uhd: return 3840
            case .hd: return 1920
            }
        }
    }

    private var shots: [BurstShot] { workspace.shotsForExportTarget }

    private var nativeSummary: String {
        guard let size = shots.first?.effectiveFrames.first?.pixelSize else { return "source size" }
        return "\(size.width) x \(size.height)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(shots.count == 1 ? "Export Shot" : "Export \(shots.count) Shots")
                .font(.system(size: 15, weight: .semibold))
                .padding(.bottom, 2)
            Text(shots.count == 1
                 ? "Creates one ProRes clip."
                 : "Creates a folder of \(shots.count) ProRes clips, one per shot.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)

            row("Destination") {
                HStack(spacing: 8) {
                    Text(destination?.path(percentEncoded: false) ?? "Choose a folder")
                        .font(.system(size: 11))
                        .foregroundStyle(destination == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseDestination() }
                        .controlSize(.small)
                }
            }

            row("Codec") {
                Picker("", selection: $codec) {
                    Text("ProRes 422 HQ").tag(BurstShotExporter.Codec.proRes422HQ)
                    Text("ProRes 4444").tag(BurstShotExporter.Codec.proRes4444)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }

            row("Resolution") {
                VStack(alignment: .leading, spacing: 3) {
                    Picker("", selection: $resolutionChoice) {
                        ForEach(ResolutionChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    Text("Native is \(nativeSummary), straight from the photos.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            row("Handoff") {
                Toggle(isOn: $writeSidecar) {
                    Text("Write FCPXML sidecar for Resolve / Final Cut")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
            }

            Divider().padding(.vertical, 12)

            HStack {
                Spacer()
                Button("Cancel") { workspace.showingShotExportSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Export") { runExport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(destination == nil || shots.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
        .background(KineTheme.bgPanel)
    }

    @ViewBuilder
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            content()
        }
        .padding(.vertical, 6)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        if panel.runModal() == .OK { destination = panel.url }
    }

    private func runExport() {
        guard let destination else { return }
        workspace.showingShotExportSheet = false
        workspace.exportShots(workspace.shotExportTarget, codec: codec, to: destination,
                              longEdge: resolutionChoice.longEdge, writeSidecar: writeSidecar)
    }
}

/// On-brand replacement for system alerts.
struct KineNoticeSheet: View {
    let notice: WorkspaceModel.Notice
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(notice.title)
                .font(.system(size: 14, weight: .semibold))
            ScrollView {
                Text(notice.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            HStack {
                Spacer()
                Button("OK", action: dismiss)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 400)
        .background(KineTheme.bgPanel)
    }
}
