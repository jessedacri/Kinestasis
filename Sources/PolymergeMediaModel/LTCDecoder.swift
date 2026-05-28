import Foundation

/// Decodes SMPTE 12M-1 Linear Timecode (LTC) from a single channel of
/// audio. LTC is timecode encoded as a biphase-mark-coded audio signal
/// — the "TC stripe" you see on production sound recordings where
/// timecode was striped onto a dedicated audio channel instead of
/// stored in BEXT metadata.
///
/// **Encoding refresher (SMPTE 12M-1):**
/// LTC uses biphase mark coding (a.k.a. Manchester coding):
///   - A "0" bit: ONE transition per bit period (level holds for the
///     full bit, then flips at the bit boundary).
///   - A "1" bit: TWO transitions per bit period (mid-bit transition
///     flips polarity, then another flip at the bit boundary).
/// This means the time between zero crossings is either the full bit
/// period (for 0 bits) or half the bit period (for the two halves of
/// a 1 bit). We measure these intervals to recover the bit stream.
///
/// **Frame layout:**
/// Each LTC frame is 80 bits = 10 bytes. Within the frame, BCD digits
/// for HH:MM:SS:FF are packed in fixed positions, separated by user
/// bits and flags. Bits 64-79 are the sync word (`0011 1111 1111 1101`
/// LSB-first), which is impossible to occur elsewhere because of the
/// 12 consecutive 1 bits — BCD digits + flag bits can never produce
/// that pattern. We scan for the sync word to lock onto frame
/// boundaries.
///
/// **Frame rate detection:**
/// Once we have multiple decoded frames, the inter-frame interval in
/// samples gives us the frame rate. For 48 kHz audio:
///   - 24 fps  → 2000 samples/frame
///   - 23.976  → 2002 samples/frame
///   - 25 fps  → 1920 samples/frame
///   - 29.97   → 1601.6 samples/frame
///   - 30 fps  → 1600 samples/frame
/// Combined with the drop-frame flag (bit 10) we can disambiguate
/// 29.97 NDF vs 29.97 DF.
///
/// **Reference:** SMPTE 12M-1 (Time and Control Code), Wikipedia's
/// "Linear timecode" article (especially the bit layout table).
public struct LTCDecoder {

    // MARK: - Public types

    /// One decoded LTC frame.
    public struct DecodedFrame: Equatable {
        public let hours: Int       // 0..23
        public let minutes: Int     // 0..59
        public let seconds: Int     // 0..59
        public let frames: Int      // 0..29 (or higher for 50/60 fps)
        public let dropFrame: Bool  // drop-frame flag (29.97 DF, 59.94 DF)
        public let colorFrame: Bool

        public init(hours: Int, minutes: Int, seconds: Int, frames: Int, dropFrame: Bool, colorFrame: Bool) {
            self.hours = hours
            self.minutes = minutes
            self.seconds = seconds
            self.frames = frames
            self.dropFrame = dropFrame
            self.colorFrame = colorFrame
        }

        public var timecodeString: String {
            let sep = dropFrame ? ";" : ":"
            return String(format: "%02d:%02d:%02d%@%02d",
                          hours, minutes, seconds, sep, frames)
        }
    }

    /// Result of a successful LTC scan over an audio buffer.
    public struct Result {
        /// TC of the FIRST successfully decoded frame in the buffer.
        public let firstFrame: DecodedFrame
        /// Sample index (in the input buffer) where that first frame
        /// begins. The TC at sample 0 of the buffer can be computed
        /// by subtracting `firstFrameSampleOffset / samplesPerFrame`
        /// frames from `firstFrame`.
        public let firstFrameSampleOffset: Int
        /// Frames per second the decoder inferred from inter-frame
        /// intervals. Combined with `firstFrame.dropFrame` this maps
        /// to a `TimecodeValue.FrameRate` enum value.
        public let detectedFrameRate: Double
        /// How many frames the decoder successfully decoded — useful
        /// as a confidence indicator. <2 means we found the sync word
        /// once but couldn't establish frame rate.
        public let totalFramesDecoded: Int

        public init(firstFrame: DecodedFrame, firstFrameSampleOffset: Int, detectedFrameRate: Double, totalFramesDecoded: Int) {
            self.firstFrame = firstFrame
            self.firstFrameSampleOffset = firstFrameSampleOffset
            self.detectedFrameRate = detectedFrameRate
            self.totalFramesDecoded = totalFramesDecoded
        }
    }

    /// Internal: a frame found at a particular sample position.
    private struct FoundFrame {
        let frame: DecodedFrame
        let samplePosition: Int  // sample index where the frame's first bit starts
    }

    // MARK: - Public API

    /// Try to decode LTC from a single channel of audio.
    ///
    /// Returns nil if no valid LTC is found — either the channel
    /// doesn't contain LTC at all (returns quickly after a few
    /// hundred ms of unsuccessful sync search), or the signal is
    /// too noisy / inconsistent to lock onto.
    ///
    /// - Parameters:
    ///   - samples: mono audio samples in [-1, 1]. For multi-channel
    ///     files, call this once per channel and pick the result with
    ///     the highest `totalFramesDecoded`.
    ///   - sampleRate: audio sample rate in Hz (typically 48000).
    public static func decode(samples: [Float], sampleRate: Int) -> Result? {
        guard samples.count > sampleRate / 4 else { return nil }  // need >250 ms

        // 1. Find every zero crossing in the signal
        let crossings = findZeroCrossings(samples: samples)
        guard crossings.count > 100 else { return nil }

        // 2. Estimate the bit period from the distribution of inter-
        //    crossing intervals
        guard let bitPeriod = estimateBitPeriod(
            crossings: crossings,
            sampleRate: sampleRate
        ) else { return nil }

        // 3. Decode the biphase-mark stream into a bit array, keeping
        //    a parallel array of sample positions so we can locate
        //    frame boundaries on the original audio.
        let (bits, bitPositions) = decodeBitStream(
            crossings: crossings,
            bitPeriod: bitPeriod
        )
        guard bits.count >= 80 else { return nil }

        // 4. Scan for sync words and decode frames at each match.
        let foundFrames = decodeFrames(
            bits: bits,
            bitPositions: bitPositions
        )
        guard !foundFrames.isEmpty else { return nil }

        // 5. Compute the frame rate from inter-frame sample intervals
        //    (use the median if we have several).
        let detectedRate = estimateFrameRate(
            frames: foundFrames,
            sampleRate: sampleRate
        )

        return Result(
            firstFrame: foundFrames[0].frame,
            firstFrameSampleOffset: foundFrames[0].samplePosition,
            detectedFrameRate: detectedRate,
            totalFramesDecoded: foundFrames.count
        )
    }

    /// Convenience: scan every channel of a multi-channel buffer and
    /// return the best LTC result (the channel with the most decoded
    /// frames). Returns nil + -1 channel if no channel contains LTC.
    public static func decodeBestChannel(channels: [[Float]], sampleRate: Int) -> (channel: Int, result: Result)? {
        var best: (channel: Int, result: Result)?
        for (i, channel) in channels.enumerated() {
            if let result = decode(samples: channel, sampleRate: sampleRate) {
                if best == nil || result.totalFramesDecoded > best!.result.totalFramesDecoded {
                    best = (i, result)
                }
            }
        }
        return best
    }

    // MARK: - Step 1: Zero crossings

    /// Find every sample index where the signal changes sign. This
    /// is the raw "edge" stream that biphase decoding operates on.
    private static func findZeroCrossings(samples: [Float]) -> [Int] {
        var crossings: [Int] = []
        crossings.reserveCapacity(samples.count / 4)
        var prev: Float = 0
        for i in 1..<samples.count {
            let curr = samples[i]
            // Sign change between prev and curr — record `i` as the
            // crossing position.
            if (prev >= 0 && curr < 0) || (prev < 0 && curr >= 0) {
                crossings.append(i)
            }
            prev = curr
        }
        return crossings
    }

    // MARK: - Step 2: Bit period estimation

    /// Estimate the LTC bit period (in samples) from the distribution
    /// of inter-crossing intervals. Biphase coding produces intervals
    /// at either bitPeriod (for 0 bits) or bitPeriod/2 (for the two
    /// halves of 1 bits), so the SHORTEST common interval should be
    /// ~half the bit period — multiply by 2 to get the full period.
    /// Returns nil if the resulting bit rate isn't in a plausible LTC
    /// range (1500-3000 bits/sec covers all standard rates 24-60 fps).
    private static func estimateBitPeriod(
        crossings: [Int],
        sampleRate: Int
    ) -> Double? {
        guard crossings.count > 200 else { return nil }
        // Use the first ~1000 intervals for stability
        let n = min(1000, crossings.count - 1)
        var intervals: [Double] = []
        intervals.reserveCapacity(n)
        for i in 1...n {
            intervals.append(Double(crossings[i] - crossings[i - 1]))
        }
        intervals.sort()

        // Take the median of the SHORTEST 40% — this should be
        // dominated by half-bit intervals (1 bits).
        let shortCount = max(10, intervals.count * 4 / 10)
        let shortIntervals = Array(intervals.prefix(shortCount))
        let medianShort = shortIntervals[shortIntervals.count / 2]

        let bitPeriod = medianShort * 2
        let bitRate = Double(sampleRate) / bitPeriod

        // LTC bit rates: 1920 (24 fps), 2000 (25 fps), 2400 (30 fps),
        // up to 4800 (60 fps). Anything outside 1500-5000 isn't LTC.
        guard bitRate >= 1500, bitRate <= 5000 else { return nil }
        return bitPeriod
    }

    // MARK: - Step 3: Bit stream decoding

    /// Walk the crossing list and decode biphase-mark bits. Each "0"
    /// is one full-period crossing pair; each "1" is two half-period
    /// crossings. Returns the bit stream + a parallel array of sample
    /// positions for the start of each bit (used to locate frames in
    /// the original audio later).
    private static func decodeBitStream(
        crossings: [Int],
        bitPeriod: Double
    ) -> (bits: [Bool], positions: [Int]) {
        var bits: [Bool] = []
        var positions: [Int] = []
        bits.reserveCapacity(crossings.count / 2)
        positions.reserveCapacity(crossings.count / 2)

        let halfBit = bitPeriod / 2
        let tolerance = bitPeriod * 0.30  // 30% tolerance for jitter

        var i = 0
        while i + 1 < crossings.count {
            let interval = Double(crossings[i + 1] - crossings[i])
            if abs(interval - bitPeriod) <= tolerance {
                // Full-period interval = 0 bit
                bits.append(false)
                positions.append(crossings[i])
                i += 1
            } else if abs(interval - halfBit) <= tolerance {
                // Half-period interval = first half of a 1 bit. The
                // next interval should also be ~halfBit (the second
                // half of the same 1 bit).
                guard i + 2 < crossings.count else { break }
                let next = Double(crossings[i + 2] - crossings[i + 1])
                if abs(next - halfBit) <= tolerance {
                    bits.append(true)
                    positions.append(crossings[i])
                    i += 2
                } else {
                    // Malformed pair — skip ahead one crossing and try
                    // to re-sync.
                    i += 1
                }
            } else {
                // Out-of-spec interval — skip and try to re-sync
                i += 1
            }
        }
        return (bits, positions)
    }

    // MARK: - Step 4: Frame decoding via sync word search

    /// SMPTE 12M-1 sync word, LSB-first, occupying bits 64-79 of
    /// every 80-bit LTC frame: `0011 1111 1111 1101`. Twelve
    /// consecutive 1 bits make this pattern impossible to occur
    /// inside normal LTC data, so we can use it as an unambiguous
    /// frame boundary marker.
    private static let syncWord: [Bool] = [
        false, false,                                           // bits 64-65
        true, true, true, true, true, true, true, true,         // bits 66-73
        true, true, true, true,                                 // bits 74-77
        false, true                                             // bits 78-79
    ]

    /// Scan the bit stream for sync words and decode the 80-bit
    /// frame that ends at each match. Returns every successfully
    /// decoded frame in order of appearance.
    private static func decodeFrames(
        bits: [Bool],
        bitPositions: [Int]
    ) -> [FoundFrame] {
        var found: [FoundFrame] = []
        var i = 0
        // Scan for the sync word at every position. Once we find one,
        // the frame's first bit is at index (i + syncWord.count - 80)
        // = (i - 64).
        while i + syncWord.count <= bits.count {
            if matches(bits, at: i, pattern: syncWord) {
                let frameStart = i - 64
                if frameStart >= 0 {
                    let frameBits = Array(bits[frameStart..<(frameStart + 80)])
                    if let decoded = decodeFrameBits(frameBits) {
                        let pos = bitPositions[frameStart]
                        found.append(FoundFrame(frame: decoded, samplePosition: pos))
                    }
                }
                // Skip past this sync word so we don't double-count
                i += syncWord.count
            } else {
                i += 1
            }
        }
        return found
    }

    private static func matches(_ bits: [Bool], at offset: Int, pattern: [Bool]) -> Bool {
        for k in 0..<pattern.count {
            if bits[offset + k] != pattern[k] { return false }
        }
        return true
    }

    /// Decode the H/M/S/F + flags from an 80-bit LTC frame. Returns
    /// nil if the BCD digits are out of range (sanity check against
    /// false sync word matches).
    private static func decodeFrameBits(_ bits: [Bool]) -> DecodedFrame? {
        // Bit positions (LSB first within each field):
        //   0-3   frame units (BCD 0-9)
        //   8-9   frame tens (BCD 0-3, only 2 bits)
        //   10    drop-frame flag
        //   11    color-frame flag
        //   16-19 seconds units
        //   24-26 seconds tens (3 bits, 0-5)
        //   32-35 minutes units
        //   40-42 minutes tens (3 bits, 0-5)
        //   48-51 hours units
        //   56-57 hours tens (2 bits, 0-2)
        let frameUnits = bcd(bits, start: 0, count: 4)
        let frameTens = bcd(bits, start: 8, count: 2)
        let dropFrame = bits[10]
        let colorFrame = bits[11]
        let secondsUnits = bcd(bits, start: 16, count: 4)
        let secondsTens = bcd(bits, start: 24, count: 3)
        let minutesUnits = bcd(bits, start: 32, count: 4)
        let minutesTens = bcd(bits, start: 40, count: 3)
        let hoursUnits = bcd(bits, start: 48, count: 4)
        let hoursTens = bcd(bits, start: 56, count: 2)

        let frames = frameTens * 10 + frameUnits
        let seconds = secondsTens * 10 + secondsUnits
        let minutes = minutesTens * 10 + minutesUnits
        let hours = hoursTens * 10 + hoursUnits

        // Sanity-check the values. False sync word matches happen
        // occasionally on noisy signals — reject anything that
        // doesn't look like a valid clock TC.
        guard frames >= 0, frames < 60,
              seconds >= 0, seconds < 60,
              minutes >= 0, minutes < 60,
              hours >= 0, hours < 24
        else { return nil }

        return DecodedFrame(
            hours: hours,
            minutes: minutes,
            seconds: seconds,
            frames: frames,
            dropFrame: dropFrame,
            colorFrame: colorFrame
        )
    }

    /// Decode a small BCD field from the bit stream (LSB first).
    private static func bcd(_ bits: [Bool], start: Int, count: Int) -> Int {
        var value = 0
        for k in 0..<count {
            if bits[start + k] {
                value |= (1 << k)
            }
        }
        return value
    }

    // MARK: - Step 5: Frame rate estimation

    /// Compute the average inter-frame interval from a sequence of
    /// decoded frames and convert it to frames-per-second. Returns
    /// 0 if there are <2 frames (not enough to measure).
    private static func estimateFrameRate(
        frames: [FoundFrame],
        sampleRate: Int
    ) -> Double {
        guard frames.count >= 2 else { return 0 }
        // Use the MEDIAN inter-frame interval to be robust against
        // any spurious decoded frames.
        var intervals: [Int] = []
        intervals.reserveCapacity(frames.count - 1)
        for i in 1..<frames.count {
            intervals.append(frames[i].samplePosition - frames[i - 1].samplePosition)
        }
        intervals.sort()
        let median = intervals[intervals.count / 2]
        guard median > 0 else { return 0 }
        return Double(sampleRate) / Double(median)
    }
}
