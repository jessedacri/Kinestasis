import Foundation

public struct DropFrameCalculator {
    /// Convert a total frame count to HH:MM:SS:FF for drop-frame timecode.
    /// For 29.97 DF: frames 0 and 1 are skipped at the start of each minute, except every 10th minute.
    /// For 59.94 DF: frames 0, 1, 2, 3 are skipped at the start of each minute, except every 10th minute.
    public static func framesToTimecode(_ totalFrames: Int, dropCount: Int, nominalRate: Int) -> (h: Int, m: Int, s: Int, f: Int) {
        // dropCount: number of frame numbers dropped per minute (2 for 29.97, 4 for 59.94)
        let framesPerMinute = nominalRate * 60 - dropCount
        let framesPer10Min = framesPerMinute * 10 + dropCount // add back the non-dropped 10th minute

        let tenMinBlocks = totalFrames / framesPer10Min
        var remaining = totalFrames % framesPer10Min

        var minutes = tenMinBlocks * 10

        // First minute in the 10-min block has no drops
        if remaining >= nominalRate * 60 {
            remaining -= nominalRate * 60
            minutes += 1
            // Subsequent minutes in the block have drops
            let additionalMinutes = remaining / framesPerMinute
            remaining = remaining % framesPerMinute
            minutes += additionalMinutes
            // Add back the dropped frames for display
            remaining += dropCount
        }

        let h = minutes / 60
        let m = minutes % 60
        let s = remaining / nominalRate
        let f = remaining % nominalRate

        return (h, m, s, f)
    }

    /// Convert HH:MM:SS:FF to a total frame count for drop-frame timecode.
    public static func timecodeToFrames(h: Int, m: Int, s: Int, f: Int, dropCount: Int, nominalRate: Int) -> Int {
        let totalMinutes = h * 60 + m
        let nonDropMinutes = totalMinutes / 10  // every 10th minute has no drop
        let dropMinutes = totalMinutes - nonDropMinutes

        return totalMinutes * nominalRate * 60
            - dropCount * dropMinutes
            + s * nominalRate
            + f
    }
}
