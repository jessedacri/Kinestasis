import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import KineCore

/// Premiere-style export panel. Left rail with named presets; right
/// side with sectioned settings (Format / Video / Audio / Output).
/// Selecting a preset hydrates the right-side form; the user is free
/// to override anything afterwards.
struct ExportSheet: View {
    @ObservedObject var workspace: WorkspaceModel

    @State private var settings: ExportSettings = ExportPresets.web[1].settings
    @State private var selectedPresetID: String = "youtube-1080"
    @State private var lockAspect: Bool = true
    @State private var aspectRatio: Double = 16.0 / 9.0

    var body: some View {
        HSplitView {
            presetRail
                .frame(minWidth: 220, idealWidth: 230, maxWidth: 280)
            settingsForm
                .frame(minWidth: 440, idealWidth: 520)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 560, idealHeight: 620)
        .background(KineTheme.bgPanel)
        .onAppear { syncAspectRatioFromCurrent() }
    }

    // MARK: - Preset rail

    private var presetRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Presets")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(ExportPresets.byGroup(), id: \.group) { group, presets in
                        Text(group.displayName.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .tracking(0.5)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        ForEach(presets) { preset in
                            presetRow(preset)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(KineTheme.bgCard)
    }

    private func presetRow(_ preset: ExportPreset) -> some View {
        let selected = selectedPresetID == preset.id
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconForGroup(preset.group))
                .font(.system(size: 12))
                .foregroundStyle(selected ? KineTheme.accent : .secondary)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Text(preset.summary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(selected ? KineTheme.accent.opacity(0.18) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            applyPreset(preset)
        }
    }

    private func iconForGroup(_ group: ExportPreset.Group) -> String {
        switch group {
        case .web:          return "globe"
        case .professional: return "film.stack"
        case .audio:        return "waveform"
        case .custom:       return "slider.horizontal.3"
        }
    }

    // MARK: - Settings form

    private var settingsForm: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    formatSection
                    if !settings.isAudioOnly {
                        videoSection
                    }
                    audioSection
                    outputSection
                }
                .padding(20)
            }
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Export Sequence")
                .font(.system(size: 15, weight: .semibold))
            if let seq = workspace.activeSequence {
                Text("·")
                    .foregroundStyle(.secondary)
                Text(seq.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                let res = seq.settings.resolution
                Text("\(res.width)×\(res.height)  \(seq.settings.frameRate.rawValue) fps")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Text(estimatedSizeText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) {
                    workspace.showingExportSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Export") {
                    chooseDestinationAndExport()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(workspace.activeSequence == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(KineTheme.bgPanel)
    }

    // MARK: - Format section

    private var formatSection: some View {
        section(title: "Format") {
            row("Codec") {
                Picker("", selection: $settings.video.codec) {
                    ForEach(ExportSettings.VideoSettings.Codec.allCases) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
                .onChange(of: settings.video.codec) { _, newCodec in
                    if newCodec == .audioOnly {
                        // Audio-only export wants a compatible audio codec.
                        if !settings.audio.codec.isAudioOnly && settings.audio.codec != .aac {
                            settings.audio.codec = .wav
                        }
                        settings.audio.include = true
                    } else {
                        // Switching back from audio-only — default to PCM
                        // for ProRes, AAC for H.264/HEVC.
                        if newCodec.isProRes { settings.audio.codec = .pcm }
                        else { settings.audio.codec = .aac }
                    }
                }
            }
        }
    }

    // MARK: - Video section

    private var videoSection: some View {
        section(title: "Video") {
            row("Resolution") {
                Picker("", selection: resolutionBinding) {
                    Text("Match Sequence").tag(0)
                    Text("3840 × 2160 (4K UHD)").tag(1)
                    Text("1920 × 1080 (1080p)").tag(2)
                    Text("1280 × 720 (720p)").tag(3)
                    Text("854 × 480 (480p)").tag(4)
                    Text("Custom…").tag(5)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
            }

            if case .custom(let w, let h) = settings.video.resolution {
                row("") {
                    HStack(spacing: 8) {
                        numberField(value: w, range: 16...8192) { newW in
                            updateCustomDimension(width: newW)
                        }
                        Text("×")
                            .foregroundStyle(.secondary)
                        numberField(value: h, range: 16...8192) { newH in
                            updateCustomDimension(height: newH)
                        }
                        Button {
                            lockAspect.toggle()
                            if lockAspect { syncAspectRatioFromCurrent() }
                        } label: {
                            Image(systemName: lockAspect ? "lock.fill" : "lock.open")
                                .foregroundStyle(lockAspect ? KineTheme.accent : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Lock aspect ratio")
                    }
                }
            }

            row("Frame Rate") {
                Picker("", selection: frameRateBinding) {
                    Text("Match Sequence").tag("match")
                    ForEach(FrameRate.allCases, id: \.rawValue) { fr in
                        Text("\(fr.rawValue) fps").tag(fr.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
            }

            if !settings.video.codec.isProRes && settings.video.codec != .audioOnly {
                row("Target Bitrate") {
                    HStack(spacing: 6) {
                        numberField(value: settings.video.bitrateMbps, range: 1...500) { v in
                            settings.video.bitrateMbps = v
                            if settings.video.maximumBitrateMbps < v {
                                settings.video.maximumBitrateMbps = v
                            }
                        }
                        Text("Mbps")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                row("Maximum Bitrate") {
                    HStack(spacing: 6) {
                        numberField(value: settings.video.maximumBitrateMbps, range: 1...500) { v in
                            settings.video.maximumBitrateMbps = max(v, settings.video.bitrateMbps)
                        }
                        Text("Mbps")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                if settings.video.codec == .h264 {
                    row("Profile") {
                        Picker("", selection: $settings.video.profile) {
                            ForEach(ExportSettings.VideoSettings.H264Profile.allCases) { p in
                                Text(p.displayName).tag(p)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220)
                    }
                }
                row("Keyframe Every") {
                    HStack(spacing: 6) {
                        numberField(value: settings.video.keyframeIntervalFrames, range: 1...600) { v in
                            settings.video.keyframeIntervalFrames = v
                        }
                        Text("frames")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        }
    }

    // MARK: - Audio section

    private var audioSection: some View {
        section(title: "Audio") {
            if !settings.isAudioOnly {
                row("Include Audio") {
                    Toggle("", isOn: $settings.audio.include).labelsHidden()
                }
            }

            if settings.audio.include {
                row("Codec") {
                    Picker("", selection: $settings.audio.codec) {
                        ForEach(audioCodecChoices) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                }
                row("Sample Rate") {
                    Picker("", selection: sampleRateBinding) {
                        Text("Match Sequence").tag(0)
                        Text("48 kHz").tag(48000)
                        Text("44.1 kHz").tag(44100)
                        Text("32 kHz").tag(32000)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                }
                // Multi-track layout — MOV container only (audio-only
                // export is always a single mixed stream).
                if !settings.isAudioOnly {
                    row("Tracks") {
                        Picker("", selection: $settings.audio.layout) {
                            ForEach(ExportSettings.AudioSettings.Layout.allCases) { l in
                                Text(l.displayName).tag(l)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220)
                    }
                }
                row("Channels") {
                    Picker("", selection: $settings.audio.channels) {
                        ForEach(ExportSettings.AudioSettings.Channels.allCases) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    .disabled(settings.audio.layout.preservesSourceChannels)
                    .help(settings.audio.layout.preservesSourceChannels
                          ? "Each track keeps its source channel count"
                          : "")
                }
                if settings.audio.codec == .aac {
                    row("Bitrate") {
                        Picker("", selection: $settings.audio.bitrateKbps) {
                            Text("96 kbps").tag(96)
                            Text("128 kbps").tag(128)
                            Text("192 kbps").tag(192)
                            Text("256 kbps").tag(256)
                            Text("320 kbps").tag(320)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220)
                    }
                }
            }
        }
    }

    private var audioCodecChoices: [ExportSettings.AudioSettings.AudioCodec] {
        if settings.isAudioOnly {
            return [.wav, .aiff, .aac]
        } else {
            return [.pcm, .aac]
        }
    }

    // MARK: - Output section

    private var outputSection: some View {
        section(title: "Output") {
            row("Range") {
                Picker("", selection: $settings.range) {
                    Text("In to Out").tag(ExportSettings.Range.inToOut)
                    Text("Whole Sequence").tag(ExportSettings.Range.wholeSequence)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
        }
    }

    // MARK: - Section / row helpers

    @ViewBuilder
    private func section<Content: View>(
        title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            VStack(spacing: 8) {
                content()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(KineTheme.bgCard.opacity(0.6))
            )
        }
    }

    @ViewBuilder
    private func row<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    private func numberField(
        value: Int, range: ClosedRange<Int>, onChange: @escaping (Int) -> Void
    ) -> some View {
        let bind = Binding<Int>(
            get: { value },
            set: { onChange(max(range.lowerBound, min(range.upperBound, $0))) }
        )
        return TextField("", value: bind, formatter: Self.intFormatter)
            .font(.system(size: 11, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
    }

    private static let intFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.allowsFloats = false
        f.minimum = 1
        return f
    }()

    // MARK: - Bindings + sync

    private var resolutionBinding: Binding<Int> {
        Binding(
            get: {
                switch settings.video.resolution {
                case .matchSequence: return 0
                case .preset(let w, let h, _):
                    if w == 3840 && h == 2160 { return 1 }
                    if w == 1920 && h == 1080 { return 2 }
                    if w == 1280 && h == 720  { return 3 }
                    if w == 854 && h == 480   { return 4 }
                    return 5
                case .custom: return 5
                }
            },
            set: { tag in
                switch tag {
                case 0: settings.video.resolution = .matchSequence
                case 1: settings.video.resolution = .preset(width: 3840, height: 2160, label: "4K UHD")
                case 2: settings.video.resolution = .preset(width: 1920, height: 1080, label: "1080p")
                case 3: settings.video.resolution = .preset(width: 1280, height: 720,  label: "720p")
                case 4: settings.video.resolution = .preset(width: 854,  height: 480,  label: "480p")
                default:
                    let (w, h) = settings.video.resolution.dimensions(seq: workspace.activeSequence ?? defaultSequence)
                    settings.video.resolution = .custom(width: w, height: h)
                }
                syncAspectRatioFromCurrent()
            }
        )
    }

    private var frameRateBinding: Binding<String> {
        Binding(
            get: {
                switch settings.video.frameRateMode {
                case .matchSequence: return "match"
                case .fixed(let f):  return f.rawValue
                }
            },
            set: { value in
                if value == "match" {
                    settings.video.frameRateMode = .matchSequence
                } else if let fr = FrameRate(rawValue: value) {
                    settings.video.frameRateMode = .fixed(fr)
                }
            }
        )
    }

    private var sampleRateBinding: Binding<Int> {
        Binding(
            get: {
                switch settings.audio.sampleRate {
                case .matchSequence: return 0
                case .rate(let r):   return r
                }
            },
            set: { v in
                if v == 0 { settings.audio.sampleRate = .matchSequence }
                else      { settings.audio.sampleRate = .rate(v) }
            }
        )
    }

    private var defaultSequence: Sequence {
        Sequence(name: "Default",
                 settings: SequenceSettings(frameRate: .twentyFour, resolution: PixelSize(width: 1920, height: 1080)))
    }

    private func syncAspectRatioFromCurrent() {
        let seq = workspace.activeSequence ?? defaultSequence
        let (w, h) = settings.video.resolution.dimensions(seq: seq)
        if h > 0 { aspectRatio = Double(w) / Double(h) }
    }

    private func updateCustomDimension(width: Int? = nil, height: Int? = nil) {
        guard case .custom(let curW, let curH) = settings.video.resolution else { return }
        if let w = width {
            let h = lockAspect ? max(2, Int((Double(w) / aspectRatio).rounded())) : curH
            settings.video.resolution = .custom(width: w, height: h)
        } else if let h = height {
            let w = lockAspect ? max(2, Int((Double(h) * aspectRatio).rounded())) : curW
            settings.video.resolution = .custom(width: w, height: h)
        }
    }

    private func applyPreset(_ preset: ExportPreset) {
        // Preserve any outputURL the user already chose.
        var s = preset.settings
        s.outputURL = settings.outputURL
        settings = s
        selectedPresetID = preset.id
        syncAspectRatioFromCurrent()
    }

    // MARK: - Estimated file size

    private var estimatedSizeText: String {
        guard let seq = workspace.activeSequence else { return " " }
        let (startSec, endSec): (Double, Double)
        switch settings.range {
        case .inToOut:
            let inS = seq.inMark?.seconds ?? 0
            let outS = seq.outMark?.seconds ?? sequenceDuration(seq)
            (startSec, endSec) = (inS, outS)
        case .wholeSequence:
            (startSec, endSec) = (0, sequenceDuration(seq))
        }
        let dur = max(0, endSec - startSec)
        let v: Double = settings.isAudioOnly ? 0 : videoBitsPerSecond()
        let a: Double = settings.audio.include ? audioBitsPerSecond() : 0
        let bits = (v + a) * dur
        let mb = bits / 8 / 1_000_000
        if mb <= 0 { return " " }
        if mb >= 1024 { return String(format: "Estimated: %.2f GB", mb / 1024) }
        return String(format: "Estimated: %.0f MB", mb)
    }

    private func videoBitsPerSecond() -> Double {
        switch settings.video.codec {
        case .h264, .hevc:
            return Double(settings.video.bitrateMbps) * 1_000_000
        case .proRes422Proxy:
            return proResApproxBps(perPixelPerSec: 0.30)
        case .proRes422LT:
            return proResApproxBps(perPixelPerSec: 0.55)
        case .proRes422:
            return proResApproxBps(perPixelPerSec: 0.85)
        case .proRes422HQ:
            return proResApproxBps(perPixelPerSec: 1.30)
        case .proRes4444:
            return proResApproxBps(perPixelPerSec: 2.00)
        case .audioOnly:
            return 0
        }
    }

    private func proResApproxBps(perPixelPerSec: Double) -> Double {
        guard let seq = workspace.activeSequence else { return 0 }
        let (w, h) = settings.video.resolution.dimensions(seq: seq)
        let fps = settings.video.frameRateMode.frameRate(seq: seq).fps
        return Double(w * h) * fps * perPixelPerSec
    }

    private func audioBitsPerSecond() -> Double {
        switch settings.audio.codec {
        case .aac:
            return Double(settings.audio.bitrateKbps) * 1000
        case .pcm:
            // 32-bit float in MOV container.
            return Double(audioSampleRateHz()) * Double(settings.audio.channels.count) * 32
        case .wav, .aiff:
            // 24-bit PCM.
            return Double(audioSampleRateHz()) * Double(settings.audio.channels.count) * 24
        }
    }

    private func audioSampleRateHz() -> Int {
        switch settings.audio.sampleRate {
        case .matchSequence:
            return workspace.activeSequence?.settings.audioSampleRate ?? 48_000
        case .rate(let r):
            return r
        }
    }

    private func sequenceDuration(_ seq: Sequence) -> Double {
        let all = seq.videoTracks.flatMap(\.clips) + seq.audioTracks.flatMap(\.clips)
        return all.map { $0.timelineRange.end.seconds }.max() ?? 0
    }

    // MARK: - Save panel

    private func chooseDestinationAndExport() {
        let panel = NSSavePanel()
        let ext = settings.defaultFileExtension
        if let utType = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [utType]
        }
        panel.title = "Export Sequence"
        panel.nameFieldStringValue = "\(workspace.project.name).\(ext)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            workspace.showingExportSheet = false
            var final = settings
            final.outputURL = url
            workspace.exportSequence(final)
        }
    }
}
