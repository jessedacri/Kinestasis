import SwiftUI
import AppKit
import KineCore
import KineMedia

/// On-brand GIF export for one shot: pick a size, save, done. Frame
/// delays come from the shot's real cadence (ramps included); loops
/// forever; plays everywhere a GIF plays.
struct GIFExportSheet: View {
    @ObservedObject var workspace: WorkspaceModel
    let request: WorkspaceModel.GIFExportRequest

    @State private var maxPixel = 640
    @State private var boomerang = false
    @State private var exporting = false

    private var shot: BurstShot? { workspace.project.mediaPool.shots[request.shotID] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export GIF")
                .font(.system(size: 15, weight: .semibold))
            if let shot {
                Text(summary(shot))
                    .font(KineTheme.monoSmall)
                    .foregroundStyle(KineTheme.textMuted)
                Picker("", selection: $maxPixel) {
                    Text("480 px").tag(480)
                    Text("640 px").tag(640)
                    Text("960 px").tag(960)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                Text("640 px is the size most of the internet uses: sharp enough, small enough, plays everywhere.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Toggle(isOn: $boomerang) {
                    Text("Boomerang (forward, then back, perfect loop)")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { workspace.gifExportRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button(exporting ? "Exporting…" : "Save GIF…") { runExport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(shot == nil || exporting)
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(KineTheme.bgPanel)
        .preferredColorScheme(.dark)
        .onAppear {
            let saved = UserDefaults.standard.integer(forKey: "gifExport.maxPixel")
            if saved > 0 { maxPixel = saved }
            boomerang = UserDefaults.standard.bool(forKey: "gifExport.boomerang")
        }
    }

    private func summary(_ shot: BurstShot) -> String {
        let seconds = Double(ShotTimingEngine.totalFrames(workspace.schedule(for: shot))) / workspace.shotFrameRate.fps
        let count = workspace.playbackFrames(for: shot).count
        return String(format: "%@ · %d stills · %.1fs loop", shot.name, count, seconds)
    }

    private func runExport() {
        guard let shot else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(shot.name).gif"
        panel.allowedContentTypes = [.gif]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(maxPixel, forKey: "gifExport.maxPixel")
        UserDefaults.standard.set(boomerang, forKey: "gifExport.boomerang")
        exporting = true
        let mode = shot.timing(projectDefault: workspace.project.settings.burst.timing)
        let skip = workspace.project.settings.burst.frameSkip
        let rate = workspace.shotFrameRate
        let pixels = maxPixel
        let pingPong = boomerang
        Task.detached(priority: .userInitiated) {
            do {
                try GIFExporter.export(shot: shot, mode: mode, skipDefault: skip,
                                       rate: rate, maxPixel: pixels,
                                       boomerang: pingPong, to: url)
                await MainActor.run {
                    workspace.gifExportRequest = nil
                    workspace.presentNotice(title: "GIF saved",
                                            message: "\(url.lastPathComponent) is in \(url.deletingLastPathComponent().lastPathComponent).")
                }
            } catch {
                await MainActor.run {
                    workspace.gifExportRequest = nil
                    workspace.presentNotice(title: "GIF export failed",
                                            message: error.localizedDescription)
                }
            }
        }
    }
}
