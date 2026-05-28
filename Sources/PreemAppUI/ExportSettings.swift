import Foundation
import AVFoundation
import PreemCore

/// Full set of knobs the Export sheet exposes to the user. Mirrors
/// Premiere's export panel grouping: source → video → audio → output.
/// The encoder reads this directly; presets construct instances of it.
public struct ExportSettings: Equatable {
    public var video: VideoSettings
    public var audio: AudioSettings
    public var range: Range
    public var outputURL: URL?

    /// `true` when the user picked an audio-only format. The encoder
    /// dispatches to a different pipeline (no compositor, no video
    /// input on the writer) when this is set.
    public var isAudioOnly: Bool { video.codec == .audioOnly }

    public init(
        video: VideoSettings,
        audio: AudioSettings,
        range: Range,
        outputURL: URL?
    ) {
        self.video = video
        self.audio = audio
        self.range = range
        self.outputURL = outputURL
    }

    public enum Range: Equatable {
        case inToOut
        case wholeSequence
    }

    // MARK: - Video

    public struct VideoSettings: Equatable {
        public var codec: Codec
        public var resolution: Resolution
        public var frameRateMode: FrameRateMode
        public var bitrateMbps: Int          // target, ignored by ProRes / audio-only
        public var maximumBitrateMbps: Int   // VBR ceiling, ignored by ProRes / audio-only
        public var profile: H264Profile      // H.264 only
        public var keyframeIntervalFrames: Int
        public var passes: Int               // 1 supported today; 2 reserved

        public init(
            codec: Codec,
            resolution: Resolution = .matchSequence,
            frameRateMode: FrameRateMode = .matchSequence,
            bitrateMbps: Int = 40,
            maximumBitrateMbps: Int = 60,
            profile: H264Profile = .high,
            keyframeIntervalFrames: Int = 30,
            passes: Int = 1
        ) {
            self.codec = codec
            self.resolution = resolution
            self.frameRateMode = frameRateMode
            self.bitrateMbps = bitrateMbps
            self.maximumBitrateMbps = maximumBitrateMbps
            self.profile = profile
            self.keyframeIntervalFrames = keyframeIntervalFrames
            self.passes = passes
        }

        public enum Codec: String, CaseIterable, Identifiable, Equatable {
            case h264, hevc
            case proRes422Proxy, proRes422LT, proRes422, proRes422HQ, proRes4444
            /// Sentinel — flips ExportSettings into audio-only mode.
            case audioOnly

            public var id: String { rawValue }
            public var displayName: String {
                switch self {
                case .h264:           return "H.264"
                case .hevc:           return "HEVC (H.265)"
                case .proRes422Proxy: return "ProRes 422 Proxy"
                case .proRes422LT:    return "ProRes 422 LT"
                case .proRes422:     return "ProRes 422"
                case .proRes422HQ:    return "ProRes 422 HQ"
                case .proRes4444:     return "ProRes 4444"
                case .audioOnly:      return "Audio Only"
                }
            }
            public var av: AVVideoCodecType? {
                switch self {
                case .h264:           return .h264
                case .hevc:           return .hevc
                case .proRes422Proxy: return .proRes422Proxy
                case .proRes422LT:    return .proRes422LT
                case .proRes422:      return .proRes422
                case .proRes422HQ:    return .proRes422HQ
                case .proRes4444:     return .proRes4444
                case .audioOnly:      return nil
                }
            }
            public var isProRes: Bool {
                switch self {
                case .proRes422Proxy, .proRes422LT, .proRes422, .proRes422HQ, .proRes4444:
                    return true
                default: return false
                }
            }
            public var defaultFileExtension: String {
                switch self {
                case .audioOnly: return "wav"   // overridden by audio.codec
                default:         return "mov"
                }
            }
        }

        public enum H264Profile: String, CaseIterable, Identifiable, Equatable {
            case baseline, main, high, high10, high422

            public var id: String { rawValue }
            public var displayName: String {
                switch self {
                case .baseline: return "Baseline"
                case .main:     return "Main"
                case .high:     return "High"
                case .high10:   return "High 10"
                case .high422:  return "High 4:2:2"
                }
            }
            public var avProfileLevel: String {
                switch self {
                case .baseline: return AVVideoProfileLevelH264BaselineAutoLevel
                case .main:     return AVVideoProfileLevelH264MainAutoLevel
                case .high:     return AVVideoProfileLevelH264HighAutoLevel
                case .high10:   return AVVideoProfileLevelH264HighAutoLevel   // AVF doesn't expose High10 as a string constant
                case .high422:  return AVVideoProfileLevelH264HighAutoLevel
                }
            }
        }

        public enum Resolution: Equatable {
            case matchSequence
            case preset(width: Int, height: Int, label: String)
            case custom(width: Int, height: Int)

            public var label: String {
                switch self {
                case .matchSequence:                       return "Match Sequence"
                case .preset(_, _, let l):                 return l
                case .custom(let w, let h):                return "\(w) × \(h)"
                }
            }
            public func dimensions(seq: Sequence) -> (Int, Int) {
                switch self {
                case .matchSequence:
                    return (seq.settings.resolution.width, seq.settings.resolution.height)
                case .preset(let w, let h, _),
                     .custom(let w, let h):
                    return (w, h)
                }
            }
        }

        public enum FrameRateMode: Equatable {
            case matchSequence
            case fixed(FrameRate)

            public var label: String {
                switch self {
                case .matchSequence:    return "Match Sequence"
                case .fixed(let f):     return "\(f.rawValue) fps"
                }
            }
            public func frameRate(seq: Sequence) -> FrameRate {
                switch self {
                case .matchSequence: return seq.settings.frameRate
                case .fixed(let f):  return f
                }
            }
        }
    }

    // MARK: - Audio

    public struct AudioSettings: Equatable {
        public var include: Bool
        public var codec: AudioCodec
        public var sampleRate: SampleRate
        public var bitrateKbps: Int    // for AAC
        public var channels: Channels

        public init(
            include: Bool = true,
            codec: AudioCodec = .aac,
            sampleRate: SampleRate = .matchSequence,
            bitrateKbps: Int = 256,
            channels: Channels = .stereo
        ) {
            self.include = include
            self.codec = codec
            self.sampleRate = sampleRate
            self.bitrateKbps = bitrateKbps
            self.channels = channels
        }

        public enum AudioCodec: String, CaseIterable, Identifiable, Equatable {
            case pcm                // 32-bit float, interleaved — for MOV video container
            case aac                // M4A or in-container AAC
            case wav                // 16/24-bit PCM in WAV (audio-only)
            case aiff               // 16/24-bit PCM in AIFF (audio-only)

            public var id: String { rawValue }
            public var displayName: String {
                switch self {
                case .pcm:  return "Linear PCM (uncompressed)"
                case .aac:  return "AAC"
                case .wav:  return "WAV"
                case .aiff: return "AIFF"
                }
            }
            /// True when this codec is only valid for audio-only export
            /// (i.e., can't be muxed into a .mov alongside video).
            public var isAudioOnly: Bool {
                switch self { case .wav, .aiff: return true; default: return false }
            }
            public var defaultFileExtension: String {
                switch self {
                case .pcm, .wav: return "wav"
                case .aac:       return "m4a"
                case .aiff:      return "aif"
                }
            }
        }

        public enum SampleRate: Equatable {
            case matchSequence
            case rate(Int)

            public var label: String {
                switch self {
                case .matchSequence: return "Match Sequence"
                case .rate(let r):   return "\(r) Hz"
                }
            }
            public func hz(seq: Sequence) -> Int {
                switch self {
                case .matchSequence: return seq.settings.audioSampleRate
                case .rate(let r):   return r
                }
            }
        }

        public enum Channels: String, CaseIterable, Identifiable, Equatable {
            case mono, stereo
            public var id: String { rawValue }
            public var displayName: String {
                switch self {
                case .mono:   return "Mono"
                case .stereo: return "Stereo"
                }
            }
            public var count: Int { self == .mono ? 1 : 2 }
        }
    }

    /// Default file extension for the active codec selection. Used by
    /// the save panel's nameFieldStringValue + the panel's filter.
    public var defaultFileExtension: String {
        if isAudioOnly { return audio.codec.defaultFileExtension }
        return video.codec.defaultFileExtension
    }
}
