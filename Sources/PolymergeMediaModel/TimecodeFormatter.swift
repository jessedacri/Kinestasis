import Foundation

public struct TimecodeFormatter {
    public static func string(from timecode: TimecodeValue) -> String {
        timecode.timecodeString
    }

    /// Parse a timecode string like "01:02:14:08" or "01:02:14;08" (DF)
    public static func parse(_ string: String, sampleRate: Int, frameRate: TimecodeValue.FrameRate) -> TimecodeValue? {
        // Accept both : and ; as separators
        let parts = string.split(whereSeparator: { $0 == ":" || $0 == ";" }).map(String.init)
        guard parts.count == 4,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              let s = Int(parts[2]),
              let f = Int(parts[3]) else {
            return nil
        }
        guard h >= 0, h < 24, m >= 0, m < 60, s >= 0, s < 60,
              f >= 0, f < frameRate.nominalRate else {
            return nil
        }
        return TimecodeValue(hours: h, minutes: m, seconds: s, frames: f,
                             sampleRate: sampleRate, frameRate: frameRate)
    }

    /// Format a duration in seconds to a compact string like "00:04:23"
    public static func durationString(from seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
