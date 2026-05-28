import Foundation

public struct TimecodeValue: Equatable, Comparable, Hashable, Sendable, CustomStringConvertible {
    public let samplesSinceMidnight: UInt64
    public let sampleRate: Int
    public let frameRate: FrameRate

    public enum FrameRate: String, Sendable, CaseIterable, Hashable {
        case fps23_976 = "23.976"
        case fps24 = "24"
        case fps25 = "25"
        case fps29_97_NDF = "29.97 NDF"
        case fps29_97_DF = "29.97 DF"
        case fps30 = "30"
        case fps48 = "48"
        case fps50 = "50"
        case fps59_94 = "59.94"
        case fps60 = "60"

        /// The actual frame rate as a double
        public var effectiveRate: Double {
            switch self {
            case .fps23_976: return 24000.0 / 1001.0
            case .fps24: return 24.0
            case .fps25: return 25.0
            case .fps29_97_NDF, .fps29_97_DF: return 30000.0 / 1001.0
            case .fps30: return 30.0
            case .fps48: return 48.0
            case .fps50: return 50.0
            case .fps59_94: return 60000.0 / 1001.0
            case .fps60: return 60.0
            }
        }

        /// The nominal (integer) frame rate used for TC display
        public var nominalRate: Int {
            switch self {
            case .fps23_976: return 24
            case .fps24: return 24
            case .fps25: return 25
            case .fps29_97_NDF, .fps29_97_DF: return 30
            case .fps30: return 30
            case .fps48: return 48
            case .fps50: return 50
            case .fps59_94: return 60
            case .fps60: return 60
            }
        }

        public var isDropFrame: Bool {
            switch self {
            case .fps29_97_DF: return true
            default: return false
            }
        }

        /// Exact rational rate string for iXML `<TIMECODE_RATE>`.
        ///
        /// The iXML spec (and every pro recorder — Sound Devices,
        /// Tentacle, Zaxcom) writes the rate as a `numerator/denominator`
        /// pair so the EXACT rate is preserved across the metadata
        /// boundary. The previous implementation in WAVWriter wrote
        /// `nominalRate` (an `Int`) which rounds 23.976 to 24, and
        /// downstream NLEs (DaVinci Resolve, Premiere) then read the
        /// integer "24" and labelled the file as 24.000 — silently
        /// breaking sync against 23.976 video tracks.
        ///
        /// This accessor returns the exact form. Pair it with `isDropFrame`
        /// (which goes in `<TIMECODE_FLAG>`) to fully describe the rate.
        public var iXMLRate: String {
            switch self {
            case .fps23_976:                return "24000/1001"
            case .fps24:                    return "24/1"
            case .fps25:                    return "25/1"
            case .fps29_97_NDF, .fps29_97_DF: return "30000/1001"
            case .fps30:                    return "30/1"
            case .fps48:                    return "48/1"
            case .fps50:                    return "50/1"
            case .fps59_94:                 return "60000/1001"
            case .fps60:                    return "60/1"
            }
        }

        /// Number of frame numbers dropped per minute for DF rates
        public var dropCount: Int {
            switch self {
            case .fps29_97_DF: return 2
            case .fps59_94: return 4  // 59.94 DF drops 4 frame numbers
            default: return 0
            }
        }

        /// Infer frame rate from a numeric rate value and optional DF flag
        public static func from(rate: Double, isDropFrame: Bool = false) -> FrameRate? {
            let rounded = rate.rounded()
            switch rounded {
            case 24 where rate < 24:
                return .fps23_976
            case 24:
                return .fps24
            case 25:
                return .fps25
            case 30 where rate < 30:
                return isDropFrame ? .fps29_97_DF : .fps29_97_NDF
            case 30:
                return .fps30
            case 48:
                return .fps48
            case 50:
                return .fps50
            case 60 where rate < 60:
                return .fps59_94
            case 60:
                return .fps60
            default:
                return nil
            }
        }
    }

    // MARK: - Initializers

    public init(samplesSinceMidnight: UInt64, sampleRate: Int, frameRate: FrameRate) {
        self.samplesSinceMidnight = samplesSinceMidnight
        self.sampleRate = sampleRate
        self.frameRate = frameRate
    }

    public init(hours: Int, minutes: Int, seconds: Int, frames: Int, sampleRate: Int, frameRate: FrameRate) {
        self.sampleRate = sampleRate
        self.frameRate = frameRate

        if frameRate.isDropFrame || frameRate.dropCount > 0 {
            let totalFrames = DropFrameCalculator.timecodeToFrames(
                h: hours, m: minutes, s: seconds, f: frames,
                dropCount: frameRate.dropCount,
                nominalRate: frameRate.nominalRate
            )
            let samplesPerFrame = Double(sampleRate) / frameRate.effectiveRate
            self.samplesSinceMidnight = UInt64(Double(totalFrames) * samplesPerFrame)
        } else {
            let totalFrames = hours * 3600 * frameRate.nominalRate
                + minutes * 60 * frameRate.nominalRate
                + seconds * frameRate.nominalRate
                + frames
            let samplesPerFrame = Double(sampleRate) / frameRate.effectiveRate
            self.samplesSinceMidnight = UInt64(Double(totalFrames) * samplesPerFrame)
        }
    }

    // MARK: - Computed Properties

    public var totalSeconds: Double {
        Double(samplesSinceMidnight) / Double(sampleRate)
    }

    public var totalFrames: Int {
        Int(totalSeconds * frameRate.effectiveRate)
    }

    public var hours: Int { components.h }
    public var minutes: Int { components.m }
    public var seconds: Int { components.s }
    public var frames: Int { components.f }

    private var components: (h: Int, m: Int, s: Int, f: Int) {
        let frames = totalFrames
        if frameRate.isDropFrame || frameRate.dropCount > 0 {
            return DropFrameCalculator.framesToTimecode(
                frames,
                dropCount: frameRate.dropCount,
                nominalRate: frameRate.nominalRate
            )
        } else {
            let nominal = frameRate.nominalRate
            let f = frames % nominal
            let totalSec = frames / nominal
            let s = totalSec % 60
            let totalMin = totalSec / 60
            let m = totalMin % 60
            let h = totalMin / 60
            return (h, m, s, f)
        }
    }

    public var timecodeString: String {
        let c = components
        let sep = frameRate.isDropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", c.h, c.m, c.s, sep, c.f)
    }

    public var description: String { timecodeString }

    // MARK: - Arithmetic

    public func sampleOffset(to other: TimecodeValue) -> Int64 {
        Int64(other.samplesSinceMidnight) - Int64(samplesSinceMidnight)
    }

    public func adding(samples: Int64) -> TimecodeValue {
        let newSamples: UInt64
        if samples < 0 {
            newSamples = samplesSinceMidnight - UInt64(-samples)
        } else {
            newSamples = samplesSinceMidnight + UInt64(samples)
        }
        return TimecodeValue(samplesSinceMidnight: newSamples, sampleRate: sampleRate, frameRate: frameRate)
    }

    public var endTimecode: TimecodeValue? { nil } // placeholder, AudioFile provides its own

    // MARK: - Comparable

    public static func < (lhs: TimecodeValue, rhs: TimecodeValue) -> Bool {
        lhs.samplesSinceMidnight < rhs.samplesSinceMidnight
    }
}
