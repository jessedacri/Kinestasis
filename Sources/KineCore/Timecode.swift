import Foundation

/// SMPTE-style timecode formatting for the program viewer + ruler.
///
/// 23.976 / 24 / 25 / 30 / 50 / 60 fps render in non-drop-frame form
/// `HH:MM:SS:FF`. The two NTSC drop-frame rates (29.97 and 59.94)
/// emit drop-frame timecode `HH:MM:SS;FF` — the algorithm drops two
/// frame numbers per minute except every tenth minute, which keeps
/// the wall-clock-to-timecode error within one frame over 24 hours.
public enum Timecode {

    /// Format the given seconds as SMPTE timecode for the active
    /// frame rate. Uses semicolon for drop-frame, colon otherwise.
    public static func format(seconds: Double, frameRate: FrameRate) -> String {
        if frameRate == .twentyNine97 || frameRate == .fiftyNine94 {
            return dropFrame(seconds: max(0, seconds), frameRate: frameRate)
        }
        return nonDropFrame(seconds: max(0, seconds), frameRate: frameRate)
    }

    // MARK: - Non-drop-frame (23.976 / 24 / 25 / 30 / 50 / 60)

    /// Whole-number FPS path. Uses the rounded integer FPS as the
    /// frame-per-second divisor; 23.976 displays as `HH:MM:SS:FF`
    /// with FF in [0, 23].
    private static func nonDropFrame(seconds: Double, frameRate: FrameRate) -> String {
        let nominalFPS = nominalFPS(for: frameRate)
        let realFPS = frameRate.fps
        let totalFrames = Int((seconds * realFPS).rounded())
        let frames = totalFrames % nominalFPS
        let totalSeconds = totalFrames / nominalFPS
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, frames)
    }

    // MARK: - Drop-frame (29.97 / 59.94)

    /// Convert seconds → drop-frame TC. For 29.97 fps:
    ///   - Nominal rate is 30 fps.
    ///   - Two frame numbers (00 and 01) are skipped at the start of
    ///     each minute, except at minutes divisible by 10.
    ///   - Net dropped per 10 minutes: 18 frames (= 2 × 9).
    /// 59.94 mirrors the same logic doubled (drop four numbers, four
    /// to seventy-four et cetera) — but we implement the general
    /// case by scaling the constants from the 29.97 algorithm.
    private static func dropFrame(seconds: Double, frameRate: FrameRate) -> String {
        let nominalFPS = nominalFPS(for: frameRate)              // 30 or 60
        let realFPS = frameRate.fps                              // 29.97… or 59.94…
        let dropPerMinute = (frameRate == .fiftyNine94) ? 4 : 2
        let framesPerMinute = nominalFPS * 60 - dropPerMinute
        let framesPer10Minutes = nominalFPS * 60 * 10 - dropPerMinute * 9

        var frameNumber = Int((seconds * realFPS).rounded())

        // Adjust the frame index so the TC ticks past skipped numbers.
        let d = frameNumber / framesPer10Minutes
        let m = frameNumber % framesPer10Minutes
        if m > dropPerMinute {
            frameNumber += dropPerMinute * 9 * d
                + dropPerMinute * ((m - dropPerMinute) / framesPerMinute)
        } else {
            frameNumber += dropPerMinute * 9 * d
        }

        let frames = frameNumber % nominalFPS
        let totalSeconds = frameNumber / nominalFPS
        let s = totalSeconds % 60
        let mm = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        // Drop-frame uses a semicolon between SS and FF — the canonical
        // SMPTE convention used by Premiere / Resolve / FCP for NTSC.
        return String(format: "%02d:%02d:%02d;%02d", h, mm, s, frames)
    }

    private static func nominalFPS(for fr: FrameRate) -> Int {
        switch fr {
        case .twentyThree976: return 24
        case .twentyFour:     return 24
        case .twentyFive:     return 25
        case .twentyNine97:   return 30
        case .thirty:         return 30
        case .fifty:          return 50
        case .fiftyNine94:    return 60
        case .sixty:          return 60
        }
    }
}
