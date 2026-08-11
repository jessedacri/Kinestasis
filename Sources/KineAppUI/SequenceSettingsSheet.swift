import SwiftUI
import KineCore

/// Modal sheet for creating (or editing) a Sequence's settings.
/// Mirrors Premiere's "Sequence Settings" dialog on the General tab,
/// with the v0.1 subset: timebase, frame size, pixel aspect, sample
/// rate, channels. Display format / fields / preview codec / linear
/// color come in later milestones.
public struct SequenceSettingsSheet: View {
    public enum Mode {
        case createNew
        case editExisting(sequenceID: SequenceID)
    }

    public let mode: Mode
    public let initialName: String
    public let initialSettings: SequenceSettings
    public let onConfirm: (String, SequenceSettings) -> Void
    public let onCancel: () -> Void

    @State private var sequenceName: String
    @State private var preset: SequencePreset
    @State private var frameRate: FrameRate
    @State private var width: Int
    @State private var height: Int
    @State private var pixelAspect: PixelAspectRatio
    @State private var sampleRate: Int
    @State private var channels: Int

    public init(
        mode: Mode,
        initialName: String = "Timeline 1",
        initialSettings: SequenceSettings,
        onConfirm: @escaping (String, SequenceSettings) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.initialName = initialName
        self.initialSettings = initialSettings
        self.onConfirm = onConfirm
        self.onCancel = onCancel

        _sequenceName = State(initialValue: initialName)
        _preset = State(initialValue: .custom)
        _frameRate = State(initialValue: initialSettings.frameRate)
        _width = State(initialValue: initialSettings.resolution.width)
        _height = State(initialValue: initialSettings.resolution.height)
        _pixelAspect = State(initialValue: initialSettings.pixelAspectRatio)
        _sampleRate = State(initialValue: initialSettings.audioSampleRate)
        _channels = State(initialValue: initialSettings.audioChannelCount)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    nameRow
                    presetSection
                    videoSection
                    audioSection
                }
                .padding(16)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button("OK") {
                    onConfirm(
                        sequenceName,
                        SequenceSettings(
                            frameRate: frameRate,
                            resolution: PixelSize(width: width, height: height),
                            pixelAspectRatio: pixelAspect,
                            audioSampleRate: sampleRate,
                            audioChannelCount: channels
                        )
                    )
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 540, height: 560)
        .background(KineTheme.bgPanel)
    }

    private var title: String {
        switch mode {
        case .createNew:        return "New Sequence"
        case .editExisting:     return "Sequence Settings"
        }
    }

    private var nameRow: some View {
        HStack {
            Text("Name")
                .frame(width: 100, alignment: .trailing)
                .foregroundStyle(.secondary)
            TextField("", text: $sequenceName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var presetSection: some View {
        HStack {
            Text("Preset")
                .frame(width: 100, alignment: .trailing)
                .foregroundStyle(.secondary)
            Picker("", selection: $preset) {
                ForEach(SequencePreset.allCases, id: \.self) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .onChange(of: preset) { _, newValue in
            applyPreset(newValue)
        }
    }

    private var videoSection: some View {
        GroupBox("Video") {
            VStack(alignment: .leading, spacing: 10) {
                row("Timebase") {
                    Picker("", selection: $frameRate) {
                        ForEach(FrameRate.allCases, id: \.self) { fr in
                            Text("\(fr.rawValue) fps").tag(fr)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                row("Frame Size") {
                    HStack(spacing: 8) {
                        TextField("", value: $width, format: .number).frame(width: 80)
                        Text("×").foregroundStyle(.secondary)
                        TextField("", value: $height, format: .number).frame(width: 80)
                        Text(aspectLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                row("Pixel Aspect") {
                    Picker("", selection: $pixelAspect) {
                        ForEach(PixelAspectRatio.allCases, id: \.self) { pa in
                            Text(pa.displayLabel).tag(pa)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var audioSection: some View {
        GroupBox("Audio") {
            VStack(alignment: .leading, spacing: 10) {
                row("Sample Rate") {
                    Picker("", selection: $sampleRate) {
                        Text("44100 Hz").tag(44_100)
                        Text("48000 Hz").tag(48_000)
                        Text("96000 Hz").tag(96_000)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                row("Channels") {
                    Picker("", selection: $channels) {
                        Text("Mono").tag(1)
                        Text("Stereo").tag(2)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .frame(width: 100, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var aspectLabel: String {
        let g = gcd(width, height)
        guard g > 0 else { return "" }
        return "\(width / g):\(height / g)"
    }

    private func applyPreset(_ p: SequencePreset) {
        guard let s = p.settings else { return }
        frameRate = s.frameRate
        width = s.resolution.width
        height = s.resolution.height
        pixelAspect = s.pixelAspectRatio
        sampleRate = s.audioSampleRate
        channels = s.audioChannelCount
    }
}

public enum SequencePreset: CaseIterable, Hashable {
    case custom
    case hd1080_23_976
    case hd1080_24
    case hd1080_25
    case hd1080_29_97
    case hd1080_30
    case uhd_23_976
    case uhd_29_97
    case uhd_60

    public var label: String {
        switch self {
        case .custom:          return "Custom"
        case .hd1080_23_976:   return "1080p — 23.976 fps"
        case .hd1080_24:       return "1080p — 24 fps"
        case .hd1080_25:       return "1080p — 25 fps"
        case .hd1080_29_97:    return "1080p — 29.97 fps"
        case .hd1080_30:       return "1080p — 30 fps"
        case .uhd_23_976:      return "UHD 4K — 23.976 fps"
        case .uhd_29_97:       return "UHD 4K — 29.97 fps"
        case .uhd_60:          return "UHD 4K — 60 fps"
        }
    }

    public var settings: SequenceSettings? {
        switch self {
        case .custom: return nil
        case .hd1080_23_976:
            return SequenceSettings(frameRate: .twentyThree976, resolution: PixelSize(width: 1920, height: 1080))
        case .hd1080_24:
            return SequenceSettings(frameRate: .twentyFour, resolution: PixelSize(width: 1920, height: 1080))
        case .hd1080_25:
            return SequenceSettings(frameRate: .twentyFive, resolution: PixelSize(width: 1920, height: 1080))
        case .hd1080_29_97:
            return SequenceSettings(frameRate: .twentyNine97, resolution: PixelSize(width: 1920, height: 1080))
        case .hd1080_30:
            return SequenceSettings(frameRate: .thirty, resolution: PixelSize(width: 1920, height: 1080))
        case .uhd_23_976:
            return SequenceSettings(frameRate: .twentyThree976, resolution: PixelSize(width: 3840, height: 2160))
        case .uhd_29_97:
            return SequenceSettings(frameRate: .twentyNine97, resolution: PixelSize(width: 3840, height: 2160))
        case .uhd_60:
            return SequenceSettings(frameRate: .sixty, resolution: PixelSize(width: 3840, height: 2160))
        }
    }
}

private func gcd(_ a: Int, _ b: Int) -> Int {
    var (a, b) = (abs(a), abs(b))
    while b != 0 { (a, b) = (b, a % b) }
    return a
}
