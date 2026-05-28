import Foundation
import PreemCore

/// A named export preset. Tapping one in the sidebar fills the right-
/// side form with these values. The user can override anything; the
/// preset is just a starting point.
public struct ExportPreset: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let group: Group
    public let summary: String              // 1-liner shown under the name
    public let settings: ExportSettings

    public enum Group: String, CaseIterable {
        case web, professional, audio, custom
        public var displayName: String {
            switch self {
            case .web:          return "Web & Social"
            case .professional: return "Professional"
            case .audio:        return "Audio Only"
            case .custom:       return "Custom"
            }
        }
    }
}

public enum ExportPresets {
    public static var all: [ExportPreset] {
        web + professional + audio
    }

    public static func byGroup() -> [(group: ExportPreset.Group, presets: [ExportPreset])] {
        ExportPreset.Group.allCases.compactMap { g in
            let presets = all.filter { $0.group == g }
            return presets.isEmpty ? nil : (g, presets)
        }
    }

    // MARK: - Web & Social

    public static let web: [ExportPreset] = [
        ExportPreset(
            id: "youtube-4k",
            name: "YouTube 4K",
            group: .web,
            summary: "H.264 · 3840×2160 · 40 Mbps · AAC 256",
            settings: ExportSettings(
                video: .init(
                    codec: .h264,
                    resolution: .preset(width: 3840, height: 2160, label: "4K UHD"),
                    bitrateMbps: 40, maximumBitrateMbps: 56,
                    profile: .high, keyframeIntervalFrames: 60
                ),
                audio: .init(include: true, codec: .aac, bitrateKbps: 256, channels: .stereo),
                range: .wholeSequence, outputURL: nil
            )
        ),
        ExportPreset(
            id: "youtube-1080",
            name: "YouTube 1080p",
            group: .web,
            summary: "H.264 · 1920×1080 · 10 Mbps · AAC 192",
            settings: ExportSettings(
                video: .init(
                    codec: .h264,
                    resolution: .preset(width: 1920, height: 1080, label: "1080p"),
                    bitrateMbps: 10, maximumBitrateMbps: 16,
                    profile: .high, keyframeIntervalFrames: 60
                ),
                audio: .init(include: true, codec: .aac, bitrateKbps: 192, channels: .stereo),
                range: .wholeSequence, outputURL: nil
            )
        ),
        ExportPreset(
            id: "vimeo-1080",
            name: "Vimeo 1080p",
            group: .web,
            summary: "H.264 · 1920×1080 · 20 Mbps · AAC 320",
            settings: ExportSettings(
                video: .init(
                    codec: .h264,
                    resolution: .preset(width: 1920, height: 1080, label: "1080p"),
                    bitrateMbps: 20, maximumBitrateMbps: 30,
                    profile: .high, keyframeIntervalFrames: 30
                ),
                audio: .init(include: true, codec: .aac, bitrateKbps: 320, channels: .stereo),
                range: .wholeSequence, outputURL: nil
            )
        ),
        ExportPreset(
            id: "apple-hevc-1080",
            name: "Apple Devices 1080p",
            group: .web,
            summary: "HEVC · 1920×1080 · 6 Mbps · AAC 192",
            settings: ExportSettings(
                video: .init(
                    codec: .hevc,
                    resolution: .preset(width: 1920, height: 1080, label: "1080p"),
                    bitrateMbps: 6, maximumBitrateMbps: 10,
                    profile: .high, keyframeIntervalFrames: 60
                ),
                audio: .init(include: true, codec: .aac, bitrateKbps: 192, channels: .stereo),
                range: .wholeSequence, outputURL: nil
            )
        ),
        ExportPreset(
            id: "apple-hevc-4k",
            name: "Apple Devices 4K",
            group: .web,
            summary: "HEVC · 3840×2160 · 25 Mbps · AAC 256",
            settings: ExportSettings(
                video: .init(
                    codec: .hevc,
                    resolution: .preset(width: 3840, height: 2160, label: "4K UHD"),
                    bitrateMbps: 25, maximumBitrateMbps: 40,
                    profile: .high, keyframeIntervalFrames: 60
                ),
                audio: .init(include: true, codec: .aac, bitrateKbps: 256, channels: .stereo),
                range: .wholeSequence, outputURL: nil
            )
        ),
    ]

    // MARK: - Professional

    public static let professional: [ExportPreset] = [
        ExportPreset(
            id: "prores-422",
            name: "ProRes 422 — Master",
            group: .professional,
            summary: "ProRes 422 · Match Sequence · PCM",
            settings: ExportSettings(
                video: .init(codec: .proRes422, resolution: .matchSequence),
                audio: .init(include: true, codec: .pcm, channels: .stereo),
                range: .wholeSequence, outputURL: nil
            )
        ),
        ExportPreset(
            id: "prores-lt",
            name: "ProRes 422 LT — Editorial",
            group: .professional,
            summary: "ProRes 422 LT · Match Sequence · PCM",
            settings: ExportSettings(
                video: .init(codec: .proRes422LT, resolution: .matchSequence),
                audio: .init(include: true, codec: .pcm, channels: .stereo),
                range: .wholeSequence, outputURL: nil
            )
        ),
        ExportPreset(
            id: "prores-hq",
            name: "ProRes 422 HQ — Delivery",
            group: .professional,
            summary: "ProRes 422 HQ · Match Sequence · PCM",
            settings: ExportSettings(
                video: .init(codec: .proRes422HQ, resolution: .matchSequence),
                audio: .init(include: true, codec: .pcm, channels: .stereo),
                range: .wholeSequence, outputURL: nil
            )
        ),
        ExportPreset(
            id: "prores-proxy",
            name: "ProRes 422 Proxy — Offline",
            group: .professional,
            summary: "ProRes 422 Proxy · Match Sequence · PCM",
            settings: ExportSettings(
                video: .init(codec: .proRes422Proxy, resolution: .matchSequence),
                audio: .init(include: true, codec: .pcm, channels: .stereo),
                range: .wholeSequence, outputURL: nil
            )
        ),
        ExportPreset(
            id: "prores-4444",
            name: "ProRes 4444 — With Alpha",
            group: .professional,
            summary: "ProRes 4444 · Match Sequence · PCM",
            settings: ExportSettings(
                video: .init(codec: .proRes4444, resolution: .matchSequence),
                audio: .init(include: true, codec: .pcm, channels: .stereo),
                range: .wholeSequence, outputURL: nil
            )
        ),
    ]

    // MARK: - Audio only

    public static let audio: [ExportPreset] = [
        ExportPreset(
            id: "audio-wav",
            name: "Audio · WAV 48kHz 24-bit",
            group: .audio,
            summary: "Uncompressed · Stereo",
            settings: ExportSettings(
                video: .init(codec: .audioOnly),
                audio: .init(include: true, codec: .wav, sampleRate: .rate(48000), channels: .stereo),
                range: .wholeSequence, outputURL: nil
            )
        ),
        ExportPreset(
            id: "audio-aiff",
            name: "Audio · AIFF 48kHz 24-bit",
            group: .audio,
            summary: "Uncompressed · Stereo",
            settings: ExportSettings(
                video: .init(codec: .audioOnly),
                audio: .init(include: true, codec: .aiff, sampleRate: .rate(48000), channels: .stereo),
                range: .wholeSequence, outputURL: nil
            )
        ),
        ExportPreset(
            id: "audio-aac-320",
            name: "Audio · AAC 320 kbps",
            group: .audio,
            summary: "Compressed · Stereo",
            settings: ExportSettings(
                video: .init(codec: .audioOnly),
                audio: .init(include: true, codec: .aac, sampleRate: .rate(48000), bitrateKbps: 320, channels: .stereo),
                range: .wholeSequence, outputURL: nil
            )
        ),
        ExportPreset(
            id: "audio-aac-256",
            name: "Audio · AAC 256 kbps",
            group: .audio,
            summary: "Compressed · Stereo",
            settings: ExportSettings(
                video: .init(codec: .audioOnly),
                audio: .init(include: true, codec: .aac, sampleRate: .rate(48000), bitrateKbps: 256, channels: .stereo),
                range: .wholeSequence, outputURL: nil
            )
        ),
    ]
}
