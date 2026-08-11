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
    @State private var bitrateMbps: Int = 50

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
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $codec) {
                        ForEach(BurstShotExporter.Codec.allCases, id: \.self) { c in
                            Text(c.shortName).tag(c)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    Text(codec.displayName)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    .onChange(of: codec) { _, newCodec in
                        if newCodec.usesBitrate { bitrateMbps = newCodec.defaultBitrateMbps }
                    }
                    if codec.usesBitrate {
                        HStack(spacing: 6) {
                            Text("Bitrate")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            ThinSlider(
                                value: Binding(
                                    get: { Double(bitrateMbps) },
                                    set: { bitrateMbps = Int($0.rounded()) }
                                ),
                                range: 5...200
                            )
                            .frame(width: 140)
                            Text("\(bitrateMbps) Mbps")
                                .font(KineTheme.monoSmall)
                                .foregroundStyle(KineTheme.textMuted)
                                .frame(width: 62, alignment: .trailing)
                        }
                    }
                    if codec == .h264, capExceedsH264 {
                        Text("H.264 tops out at a 3840 long edge; output is capped there.")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
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

            row("Size") {
                Text(sizeEstimate)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
        .padding(20)
        .frame(width: 560)
        .background(KineTheme.bgPanel)
        .preferredColorScheme(.dark)
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

    private var capExceedsH264: Bool {
        guard let size = shots.first?.effectiveFrames.first?.pixelSize else { return false }
        let edge = resolutionChoice.longEdge ?? max(size.width, size.height)
        return edge > 3840
    }

    /// Whole-batch size estimate for the selected codec and resolution.
    /// H.264/HEVC follow the bitrate directly; ProRes scales Apple's
    /// 1080p24 target rates by pixel rate.
    private var sizeEstimate: String {
        let rate = workspace.shotFrameRate
        var totalSeconds = 0.0
        for shot in shots {
            totalSeconds += Double(ShotTimingEngine.totalFrames(workspace.schedule(for: shot))) / rate.fps
        }
        guard totalSeconds > 0 else { return "No shots selected" }

        let native = shots.first?.effectiveFrames.first?.pixelSize ?? PixelSize(width: 1920, height: 1080)
        var edge = resolutionChoice.longEdge ?? max(native.width, native.height)
        if let limit = codec.longEdgeLimit { edge = min(edge, limit) }
        let scale = Double(edge) / Double(max(native.width, native.height))
        let w = min(1, scale) * Double(native.width)
        let h = min(1, scale) * Double(native.height)

        let mbps: Double
        if codec.usesBitrate {
            mbps = Double(bitrateMbps)
        } else {
            let referenceMbps: Double
            switch codec {
            case .proRes422:   referenceMbps = 117
            case .proRes422HQ: referenceMbps = 176
            case .proRes4444:  referenceMbps = 264
            default:           referenceMbps = 176
            }
            let pixelRate = (w * h * rate.fps) / (1920.0 * 1080.0 * 24.0)
            mbps = referenceMbps * pixelRate
        }
        let bytes = Int64(mbps * 1_000_000 / 8 * totalSeconds)
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let clips = shots.count == 1 ? "1 clip" : "\(shots.count) clips"
        return String(format: "About %@ for %@ (%.0f seconds total)", formatted, clips, totalSeconds)
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
                              longEdge: resolutionChoice.longEdge,
                              bitrateMbps: codec.usesBitrate ? bitrateMbps : nil,
                              writeSidecar: writeSidecar)
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
