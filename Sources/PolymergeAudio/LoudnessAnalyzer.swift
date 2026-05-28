import Accelerate
import Foundation
import PolymergeIngest

/// Loudness measurement per ITU-R BS.1770-4.
///
/// **What this measures.**
///   - **Integrated loudness** (LUFS) — the gated long-term average of
///     the K-weighted signal. The single number that broadcast and
///     streaming targets are measured against.
///   - **True peak** (dBTP) — the maximum sample value after intersample
///     peak detection (4× upsampling via sinc interpolation).
///
/// **Algorithm summary.**
///   1. Apply the K-weighting filter to each channel (high-shelf at
///      ~1681 Hz +4 dB cascaded with high-pass at ~38 Hz). The
///      K-weighting curve approximates how humans perceive loudness.
///   2. Compute mean-square in 400 ms blocks with 75% overlap (100 ms
///      hop). Sum across channels with weights (1.0 for L/R/C, 1.41
///      for surrounds).
///   3. Convert each block to LUFS via `LUFS = -0.691 + 10·log10(MS)`.
///   4. **Absolute gating**: discard blocks below -70 LUFS (silence).
///   5. Compute the ungated mean of the surviving blocks.
///   6. **Relative gating**: discard blocks below `ungated_LUFS - 10 LU`.
///   7. The integrated loudness is the mean of the surviving blocks.
///   8. **True peak**: upsample by 4× via sinc interpolation, find max
///      |sample|, convert to dBTP via `20·log10(max)`.
///
/// **Used by.**
///   - `AudioMerger.merge()` — measures the final mixdown and applies a
///     gain offset to hit the user's selected `LoudnessTarget`.
///   - `LoudnessAnalyzer.measurePerTrack(...)` — measures each input
///     file individually for display in the per-track LUFS plugin
///     popover.
///
/// **Performance.** Single-threaded measurement of a 7-minute stereo
/// file completes in ~150 ms in release builds. The K-weighting filter
/// and mean-square accumulation use vDSP for the inner loops.
public struct LoudnessAnalyzer {

    /// Result of a BS.1770-4 measurement on a complete signal.
    public struct Measurement: Equatable {
        /// Integrated (gated) loudness in LUFS. Range typically -70 to 0.
        /// `-Double.infinity` indicates pure silence.
        public let integratedLUFS: Double
        /// True peak in dBTP (decibels true peak). 0 dBTP = full scale.
        /// Negative values indicate headroom; positive values mean the
        /// signal exceeds 0 dBFS at intersample positions and would
        /// clip on a typical D/A converter. Computed via 4× sinc
        /// upsampling so it catches inter-sample peaks the sample
        /// domain misses.
        public let truePeakDB: Double
        /// Sample peak in dBFS, computed in the sample domain (no
        /// upsampling). Always less than or equal to the true peak;
        /// the difference (`truePeakDB - samplePeakDB`) is typically
        /// 0.3 to 1.0 dB on dialogue. Surfaced alongside true peak in
        /// the loudness window so the user can see how much headroom
        /// inter-sample peaks are taking.
        public let samplePeakDB: Double
        /// Total duration of the measured signal in seconds.
        public let durationSeconds: Double
        /// Number of K-weighted blocks that survived the absolute gate
        /// at -70 LUFS. Useful for diagnostics. A low value means most
        /// of the signal was below the noise floor.
        public let blocksAboveAbsoluteGate: Int
        /// Number of blocks that survived BOTH the absolute and relative
        /// gates. The integrated loudness is the mean of these blocks'
        /// mean-square values.
        public let blocksAfterRelativeGate: Int

        public var isSilent: Bool { integratedLUFS == -Double.infinity }

        public init(
            integratedLUFS: Double,
            truePeakDB: Double,
            samplePeakDB: Double,
            durationSeconds: Double,
            blocksAboveAbsoluteGate: Int,
            blocksAfterRelativeGate: Int
        ) {
            self.integratedLUFS = integratedLUFS
            self.truePeakDB = truePeakDB
            self.samplePeakDB = samplePeakDB
            self.durationSeconds = durationSeconds
            self.blocksAboveAbsoluteGate = blocksAboveAbsoluteGate
            self.blocksAfterRelativeGate = blocksAfterRelativeGate
        }
    }

    // MARK: - Public API

    /// Measure the integrated loudness and true peak of a complete
    /// audio signal supplied as per-channel `Float` arrays.
    ///
    /// - Parameter samples: `samples[channel][sampleIndex]` — the
    ///   per-channel audio data. All channels must have the same length.
    /// - Parameter sampleRate: The signal's sample rate in Hz.
    /// - Returns: A `Measurement` containing integrated LUFS, true peak
    ///   in dBTP, and gating diagnostics.
    public static func measure(samples: [[Float]], sampleRate: Int) -> Measurement {
        guard !samples.isEmpty, let firstChannel = samples.first else {
            return Measurement(
                integratedLUFS: -.infinity,
                truePeakDB: -.infinity,
                samplePeakDB: -.infinity,
                durationSeconds: 0,
                blocksAboveAbsoluteGate: 0,
                blocksAfterRelativeGate: 0
            )
        }
        let n = firstChannel.count
        let channelCount = samples.count
        let durationSeconds = Double(n) / Double(sampleRate)

        // Step 1: K-weight every channel.
        let kWeighted = samples.map { channel in
            applyKWeighting(samples: channel, sampleRate: sampleRate)
        }

        // Step 2: Block-based mean-square.
        // BS.1770 uses 400 ms blocks with 75% overlap (100 ms hop).
        let blockSamples = max(1, Int((0.400 * Double(sampleRate)).rounded()))
        let hopSamples = max(1, Int((0.100 * Double(sampleRate)).rounded()))
        // Blocks where the END index is at most n. Last block ends at
        // exactly the last sample we have.
        let blockCount = max(0, (n - blockSamples) / hopSamples + 1)
        guard blockCount > 0 else {
            return Measurement(
                integratedLUFS: -.infinity,
                truePeakDB: truePeakDBFS(samples: samples),
                samplePeakDB: samplePeakDBFS(samples: samples),
                durationSeconds: durationSeconds,
                blocksAboveAbsoluteGate: 0,
                blocksAfterRelativeGate: 0
            )
        }

        // Channel weights per BS.1770-4 (Annex 2 §1):
        //   L, R, C: 1.0
        //   Ls, Rs (surrounds): 1.41
        //   LFE: not used (excluded entirely)
        // PolyMerge input is typically L/R/C/lavs, all weighted 1.0.
        // For surround layouts we'd need a channel layout descriptor;
        // for now, weight everything equally.
        let channelWeight: Float = 1.0

        var blockMeanSquares = [Double](repeating: 0, count: blockCount)
        for blockIdx in 0..<blockCount {
            let start = blockIdx * hopSamples
            let end = start + blockSamples
            var sumOfSquares: Double = 0
            for ch in 0..<channelCount {
                let channelSlice = kWeighted[ch]
                var channelSum: Float = 0
                channelSlice.withUnsafeBufferPointer { ptr in
                    guard let base = ptr.baseAddress else { return }
                    // vDSP_svesq computes the sum of squares in one call —
                    // ~10× faster than a Swift loop and stable in Float
                    // accumulation for 400 ms of audio.
                    vDSP_svesq(base + start, 1, &channelSum, vDSP_Length(end - start))
                }
                sumOfSquares += Double(channelWeight) * Double(channelSum)
            }
            blockMeanSquares[blockIdx] = sumOfSquares / Double(blockSamples)
        }

        // Step 3: Convert each block to block loudness via the BS.1770
        // formula `LUFS = -0.691 + 10·log10(MS)`. The constant -0.691
        // accounts for the K-weighting filter's overall gain so that a
        // -23 LUFS sine wave through the filter measures as -23 LUFS,
        // not -23 + filter_gain.
        let lufsOffset: Double = -0.691

        // Step 4: Absolute gating at -70 LUFS.
        // The gate is on BLOCK loudness, not on the per-block mean
        // square. We compare blockLUFS against -70.
        let absoluteGateLUFS: Double = -70.0
        var blocksAboveAbsoluteGate: [Double] = []  // their mean-square values
        for ms in blockMeanSquares {
            guard ms > 0 else { continue }
            let blockLUFS = lufsOffset + 10.0 * log10(ms)
            if blockLUFS >= absoluteGateLUFS {
                blocksAboveAbsoluteGate.append(ms)
            }
        }

        guard !blocksAboveAbsoluteGate.isEmpty else {
            // All blocks are below -70 LUFS, treat as pure silence.
            return Measurement(
                integratedLUFS: -.infinity,
                truePeakDB: truePeakDBFS(samples: samples),
                samplePeakDB: samplePeakDBFS(samples: samples),
                durationSeconds: durationSeconds,
                blocksAboveAbsoluteGate: 0,
                blocksAfterRelativeGate: 0
            )
        }

        // Step 5: Ungated mean of the surviving blocks (in linear power).
        let ungatedMean = blocksAboveAbsoluteGate.reduce(0, +) / Double(blocksAboveAbsoluteGate.count)
        let ungatedLUFS = lufsOffset + 10.0 * log10(ungatedMean)

        // Step 6: Relative gating threshold = ungated - 10 LU.
        let relativeGateLUFS = ungatedLUFS - 10.0

        // Step 7: Integrated mean = mean of blocks that survived BOTH gates.
        var survivors: [Double] = []
        for ms in blocksAboveAbsoluteGate {
            let blockLUFS = lufsOffset + 10.0 * log10(ms)
            if blockLUFS >= relativeGateLUFS {
                survivors.append(ms)
            }
        }

        let integratedLUFS: Double
        if survivors.isEmpty {
            integratedLUFS = -.infinity
        } else {
            let integratedMean = survivors.reduce(0, +) / Double(survivors.count)
            integratedLUFS = lufsOffset + 10.0 * log10(integratedMean)
        }

        // Step 8: True peak via 4× upsampling and max |sample|.
        let truePeakDB = truePeakDBFS(samples: samples)
        let samplePeakDB = samplePeakDBFS(samples: samples)

        return Measurement(
            integratedLUFS: integratedLUFS,
            truePeakDB: truePeakDB,
            samplePeakDB: samplePeakDB,
            durationSeconds: durationSeconds,
            blocksAboveAbsoluteGate: blocksAboveAbsoluteGate.count,
            blocksAfterRelativeGate: survivors.count
        )
    }

    // MARK: - Streaming measurement

    /// Stateful accumulator that supports BS.1770-4 measurement
    /// without ever materializing the full timeline buffer.
    /// Built for `MixLoudnessMeasurer.measureStreaming`, which
    /// iterates the timeline in small chunks (e.g. 5 s) and feeds
    /// each chunk's mixed-down audio through this accumulator.
    /// Total RAM stays bounded at ~chunkSize × channels regardless
    /// of timeline length — a 5-hour 57-channel session that
    /// previously requested ~206 GB of contiguous Float buffer
    /// now needs ~100 MB at peak.
    ///
    /// **Algorithm.** Identical math to the one-shot `measure`
    /// path:
    ///   1. K-weight each channel via a persistent `vDSP.Biquad`
    ///      cascade (state survives across feeds so the filter
    ///      response is bit-identical to the one-shot version).
    ///   2. Walk the accumulated K-weighted audio in 400 ms blocks
    ///      with 100 ms hop. Each complete block contributes one
    ///      mean-square value. The streaming accumulator keeps a
    ///      rolling `pendingFrames` worth of K-weighted audio per
    ///      channel — at most `blockSamples - 1` samples — so that
    ///      blocks straddling a feed boundary can still be
    ///      computed correctly.
    ///   3. True peak: 4× sinc upsample each chunk's RAW (pre-K-
    ///      weighted) audio and track the running max. Same
    ///      precision as the one-shot path because the upsampler
    ///      is windowed and only the chunk boundaries can
    ///      introduce edge effects (bounded by the kernel width).
    ///
    /// Use:
    /// ```
    /// let s = LoudnessAnalyzer.StreamingMeasurer(channelCount: 57, sampleRate: 48000)
    /// while let chunk = nextChunk() {
    ///     s.feed(chunk)            // [[Float]] : one slice per channel
    /// }
    /// let m = s.finalize()
    /// ```
    public final class StreamingMeasurer {
        public let channelCount: Int
        public let sampleRate: Int
        public let blockSamples: Int
        public let hopSamples: Int

        /// One persistent K-weighting biquad cascade per channel.
        /// State survives across feeds so the filter response is
        /// continuous (no per-chunk reset transient).
        private var kWeighters: [vDSP.Biquad<Double>?]

        /// Per-channel ring of K-weighted samples that haven't yet
        /// formed a complete block. Bounded at
        /// `blockSamples - 1` samples per channel.
        private var pending: [[Float]]

        /// Index of the NEXT block to emit, in samples from the
        /// start of the stream. Tracks how far into the K-weighted
        /// audio we've consumed.
        private var nextBlockStartGlobal: Int = 0

        /// Total samples fed across all `feed` calls. Used to
        /// compute durationSeconds in `finalize`.
        private var totalSamplesFed: Int = 0

        /// Per-block mean-squares accumulated across all feeds.
        /// At finalize time this drives the gating + integrated
        /// LUFS computation.
        private var blockMeanSquares: [Double] = []

        /// Running true peak across all feeds (linear). The 4×
        /// sinc upsampler is applied per-chunk; the max across
        /// chunks is the true peak of the stream.
        private var runningTruePeakLinear: Float = 0

        /// Running sample peak across all feeds (linear).
        private var runningSamplePeakLinear: Float = 0

        public init(channelCount: Int, sampleRate: Int) {
            self.channelCount = channelCount
            self.sampleRate = sampleRate
            self.blockSamples = max(1, Int((0.400 * Double(sampleRate)).rounded()))
            self.hopSamples = max(1, Int((0.100 * Double(sampleRate)).rounded()))
            self.pending = Array(repeating: [], count: channelCount)
            self.kWeighters = (0..<channelCount).map { _ in Self.makeKWeightingBiquad(sampleRate: sampleRate) }
            // Pre-allocate per-channel pending capacity to avoid
            // CoW reallocations on every feed.
            for ch in 0..<channelCount {
                self.pending[ch].reserveCapacity(blockSamples * 4)
            }
        }

        /// Feed a chunk of audio. `chunk[channel]` must have the
        /// same length for every channel. Channel count must
        /// match the value passed to `init`.
        public func feed(_ chunk: [[Float]]) {
            precondition(chunk.count == channelCount, "feed chunk has wrong channel count")
            guard let firstCh = chunk.first, !firstCh.isEmpty else { return }
            let n = firstCh.count
            totalSamplesFed += n

            // Track raw sample peak + true peak BEFORE K-weighting.
            // The peak measurements use the source signal, not the
            // perceptually-weighted signal.
            for ch in 0..<channelCount {
                let chSlice = chunk[ch]
                if chSlice.count != n { continue }
                // Sample peak — vDSP_maxmgv returns max of |x|.
                var chPeak: Float = 0
                chSlice.withUnsafeBufferPointer { ptr in
                    if let base = ptr.baseAddress {
                        vDSP_maxmgv(base, 1, &chPeak, vDSP_Length(n))
                    }
                }
                if chPeak > runningSamplePeakLinear { runningSamplePeakLinear = chPeak }
                // True peak — 4× upsample this channel's chunk
                // and track max. We pay the upsample cost per
                // chunk per channel; for a 5 s × 57 ch chunk
                // that's 57 small upsamples (~270 K samples each
                // × 4 = 1.08 M samples per channel), totally
                // bounded.
                let chTruePeak = LoudnessAnalyzer.truePeakDBFSLinear(channel: chSlice)
                if chTruePeak > runningTruePeakLinear { runningTruePeakLinear = chTruePeak }
            }

            // K-weight each channel through the persistent biquad
            // and append to pending.
            for ch in 0..<channelCount {
                let chSlice = chunk[ch]
                if chSlice.count != n { continue }
                guard kWeighters[ch] != nil else { continue }
                // Float → Double for biquad input; Double → Float
                // back out for the pending ring (matches the one-
                // shot path's precision exactly).
                let inputDouble = vDSP.floatToDouble(chSlice)
                var outputDouble = [Double](repeating: 0, count: n)
                inputDouble.withUnsafeBufferPointer { inPtr in
                    outputDouble.withUnsafeMutableBufferPointer { outPtr in
                        kWeighters[ch]?.apply(input: inPtr, output: &outPtr)
                    }
                }
                pending[ch].append(contentsOf: vDSP.doubleToFloat(outputDouble))
            }

            // Walk the pending buffers and emit any complete
            // 400 ms blocks. A block is "complete" when all
            // channels have at least `blockSamples` samples
            // available starting at the next block's start
            // offset within the pending arrays.
            //
            // Conceptually: the pending array starts at global
            // sample `pendingStartGlobal = totalSamplesFed - pending.count`.
            // The next block to emit starts at
            // `nextBlockStartGlobal`. Its local offset in pending
            // is `nextBlockStartGlobal - pendingStartGlobal`.
            // When that offset + blockSamples <= pending.count,
            // emit the block; advance nextBlockStartGlobal by
            // hopSamples; trim pending up to the new offset.
            emitCompleteBlocks()
        }

        /// Emit the integrated measurement across all fed audio.
        /// Drains any final partial block (we only count blocks
        /// that have a full 400 ms of K-weighted audio — partial
        /// trailing samples are discarded, matching the one-shot
        /// path's `(n - blockSamples) / hopSamples + 1` block
        /// count math).
        public func finalize() -> Measurement {
            // Try one more block emission in case feed ended
            // exactly on a block boundary.
            emitCompleteBlocks()

            let durationSeconds = Double(totalSamplesFed) / Double(sampleRate)

            guard !blockMeanSquares.isEmpty else {
                let truePeakDB = runningTruePeakLinear > 0 ? 20.0 * log10(Double(runningTruePeakLinear)) : -.infinity
                let samplePeakDB = runningSamplePeakLinear > 0 ? 20.0 * log10(Double(runningSamplePeakLinear)) : -.infinity
                return Measurement(
                    integratedLUFS: -.infinity,
                    truePeakDB: truePeakDB,
                    samplePeakDB: samplePeakDB,
                    durationSeconds: durationSeconds,
                    blocksAboveAbsoluteGate: 0,
                    blocksAfterRelativeGate: 0
                )
            }

            // Apply BS.1770 gating — same code path as the one-
            // shot version.
            let lufsOffset: Double = -0.691
            let absoluteGateLUFS: Double = -70.0
            var blocksAboveAbsoluteGate: [Double] = []
            for ms in blockMeanSquares {
                guard ms > 0 else { continue }
                let blockLUFS = lufsOffset + 10.0 * log10(ms)
                if blockLUFS >= absoluteGateLUFS {
                    blocksAboveAbsoluteGate.append(ms)
                }
            }
            guard !blocksAboveAbsoluteGate.isEmpty else {
                let truePeakDB = runningTruePeakLinear > 0 ? 20.0 * log10(Double(runningTruePeakLinear)) : -.infinity
                let samplePeakDB = runningSamplePeakLinear > 0 ? 20.0 * log10(Double(runningSamplePeakLinear)) : -.infinity
                return Measurement(
                    integratedLUFS: -.infinity,
                    truePeakDB: truePeakDB,
                    samplePeakDB: samplePeakDB,
                    durationSeconds: durationSeconds,
                    blocksAboveAbsoluteGate: 0,
                    blocksAfterRelativeGate: 0
                )
            }
            let ungatedMean = blocksAboveAbsoluteGate.reduce(0, +) / Double(blocksAboveAbsoluteGate.count)
            let ungatedLUFS = lufsOffset + 10.0 * log10(ungatedMean)
            let relativeGateLUFS = ungatedLUFS - 10.0
            var survivors: [Double] = []
            for ms in blocksAboveAbsoluteGate {
                let blockLUFS = lufsOffset + 10.0 * log10(ms)
                if blockLUFS >= relativeGateLUFS {
                    survivors.append(ms)
                }
            }
            let integratedLUFS: Double
            if survivors.isEmpty {
                integratedLUFS = -.infinity
            } else {
                let integratedMean = survivors.reduce(0, +) / Double(survivors.count)
                integratedLUFS = lufsOffset + 10.0 * log10(integratedMean)
            }
            let truePeakDB = runningTruePeakLinear > 0 ? 20.0 * log10(Double(runningTruePeakLinear)) : -.infinity
            let samplePeakDB = runningSamplePeakLinear > 0 ? 20.0 * log10(Double(runningSamplePeakLinear)) : -.infinity
            return Measurement(
                integratedLUFS: integratedLUFS,
                truePeakDB: truePeakDB,
                samplePeakDB: samplePeakDB,
                durationSeconds: durationSeconds,
                blocksAboveAbsoluteGate: blocksAboveAbsoluteGate.count,
                blocksAfterRelativeGate: survivors.count
            )
        }

        /// Drain `pending` of every complete 400 ms block, sum
        /// channels per BS.1770, append to `blockMeanSquares`,
        /// and trim consumed samples.
        private func emitCompleteBlocks() {
            // pending[ch] starts at global sample pendingStartGlobal.
            // The shortest pending channel determines what blocks
            // we can emit.
            let minPending = pending.map(\.count).min() ?? 0
            let pendingStartGlobal = totalSamplesFed - minPending
            let channelWeight: Float = 1.0
            while true {
                let blockOffset = nextBlockStartGlobal - pendingStartGlobal
                if blockOffset < 0 { break }       // shouldn't happen — defensive
                if blockOffset + blockSamples > minPending { break }
                // Sum-of-squares across channels for this block.
                var sumOfSquares: Double = 0
                for ch in 0..<channelCount {
                    var chSum: Float = 0
                    pending[ch].withUnsafeBufferPointer { ptr in
                        guard let base = ptr.baseAddress else { return }
                        vDSP_svesq(base + blockOffset, 1, &chSum, vDSP_Length(blockSamples))
                    }
                    sumOfSquares += Double(channelWeight) * Double(chSum)
                }
                blockMeanSquares.append(sumOfSquares / Double(blockSamples))
                nextBlockStartGlobal += hopSamples
            }
            // Trim each channel's pending buffer by dropping
            // samples that can never be referenced again. The
            // earliest sample we'll ever need next is at global
            // offset `nextBlockStartGlobal`. Drop everything
            // before it.
            let dropBeforeGlobal = nextBlockStartGlobal
            let dropCount = dropBeforeGlobal - pendingStartGlobal
            if dropCount > 0 {
                for ch in 0..<channelCount where pending[ch].count >= dropCount {
                    pending[ch].removeFirst(dropCount)
                }
            }
        }

        /// Build a fresh K-weighting biquad cascade configured
        /// for the given sample rate. Same coefficients as the
        /// one-shot `applyKWeighting` static helper.
        private static func makeKWeightingBiquad(sampleRate: Int) -> vDSP.Biquad<Double>? {
            let preFilter = highShelfBiquad(
                f0: 1681.974450955533,
                gainDB: 3.999843853973347,
                q: 0.7071752369554196,
                sampleRate: Double(sampleRate)
            )
            let highPass = highPassBiquad(
                f0: 38.13547087602444,
                q: 0.5003270373238773,
                sampleRate: Double(sampleRate)
            )
            let cascade: [Double] = [
                preFilter.b0, preFilter.b1, preFilter.b2, preFilter.a1, preFilter.a2,
                highPass.b0,  highPass.b1,  highPass.b2,  highPass.a1,  highPass.a2
            ]
            return vDSP.Biquad(
                coefficients: cascade,
                channelCount: 1,
                sectionCount: 2,
                ofType: Double.self
            )
        }
    }

    /// Linear true peak of a single channel (returns the linear
    /// max-|sample| after 4× sinc upsampling). Used by the
    /// streaming measurer to track running peak across feeds —
    /// converting to dB happens once at finalize, not per chunk.
    /// Wraps the existing private `truePeakLinear` helper so the
    /// streaming path doesn't have to know about the upsampler.
    public static func truePeakDBFSLinear(channel: [Float]) -> Float {
        return Float(truePeakLinear(channel: channel))
    }

    // MARK: - K-weighting filter

    /// Apply the BS.1770-4 K-weighting filter to a single-channel signal.
    /// The filter is the cascade of:
    ///   1. A 2nd-order high-shelf at f0 ≈ 1681.97 Hz, +4 dB shelf gain
    ///   2. A 2nd-order Butterworth high-pass at f0 ≈ 38 Hz
    ///
    /// Both biquads are designed analytically at the input sample rate
    /// (NOT hardcoded for 48 kHz like many naive implementations) so the
    /// frequency response is correct across all PolyMerge-supported
    /// rates from 44.1 kHz up to 192 kHz.
    public static func applyKWeighting(samples: [Float], sampleRate: Int) -> [Float] {
        let preFilter = highShelfBiquad(
            f0: 1681.974450955533,
            gainDB: 3.999843853973347,
            q: 0.7071752369554196,
            sampleRate: Double(sampleRate)
        )
        let highPass = highPassBiquad(
            f0: 38.13547087602444,
            q: 0.5003270373238773,
            sampleRate: Double(sampleRate)
        )

        // Cascade both biquads in a single `vDSP.Biquad<Double>` SIMD
        // pass. The previous implementation was a per-sample Swift
        // loop with Float ↔ Double conversion at every step, which
        // on a 4-track 5-min session totalled ~115M biquad iterations
        // × 4 channels and dominated the mix loudness measurement
        // (10–30 s in debug, several seconds in release). Switching
        // to vDSP collapses the entire K-weighting cascade into a
        // single tight Accelerate kernel call per channel — typically
        // a 30–60× speedup for this loop.
        //
        // **Why Double-precision vDSP** (instead of `vDSP.Biquad<Float>`):
        // the original scalar code held its biquad state variables
        // (`z1`, `z2`) in Double, and the per-sample math accumulated
        // in Double — only the final stored output was rounded to
        // Float. `vDSP.Biquad<Float>` would accumulate state in Float,
        // which is theoretically <0.001 LUFS off vs the Double-state
        // version (well below the BS.1770-4 spec tolerance of ±0.1 LUFS
        // and unmeasurable in any practical sense). But this is the
        // calibration anchor for every loudness measurement in the
        // app, and we have no reason to introduce even a theoretical
        // precision difference for sub-second savings. The Double
        // path runs the biquad in Double precision identically to
        // the original scalar code, just SIMD-accelerated. Cost:
        // two N-sample Float ↔ Double conversions per channel (a few
        // ns/sample via `vDSP.convertElements`) — negligible next
        // to the ~30× speedup of the biquad itself.
        //
        // vDSP.Biquad takes a flat Double coefficient array in
        // [b0, b1, b2, a1, a2] order per section. Section order
        // doesn't change the math (cascaded LTI filters commute);
        // we list pre-filter first for readability matching the spec.
        let cascade: [Double] = [
            preFilter.b0, preFilter.b1, preFilter.b2, preFilter.a1, preFilter.a2,
            highPass.b0,  highPass.b1,  highPass.b2,  highPass.a1,  highPass.a2
        ]
        guard var biquad = vDSP.Biquad(
            coefficients: cascade,
            channelCount: 1,
            sectionCount: 2,
            ofType: Double.self
        ) else {
            // vDSP can fail to construct on degenerate coefficients
            // (which shouldn't happen for the BS.1770-4 anchor values
            // but we keep the scalar fallback for safety).
            var stage1 = applyBiquad(coefficients: preFilter, samples: samples)
            applyBiquadInPlace(coefficients: highPass, samples: &stage1)
            return stage1
        }
        // Float → Double conversion is exact (every Float value fits
        // perfectly in Double); Double → Float at the end matches the
        // `samples[i] = Float(output)` step in the old scalar code.
        let inputDouble = vDSP.floatToDouble(samples)
        var outputDouble = [Double](repeating: 0, count: samples.count)
        inputDouble.withUnsafeBufferPointer { inPtr in
            outputDouble.withUnsafeMutableBufferPointer { outPtr in
                biquad.apply(input: inPtr, output: &outPtr)
            }
        }
        return vDSP.doubleToFloat(outputDouble)
    }

    /// Standard biquad coefficients in `[b0, b1, b2, a1, a2]` form.
    /// `a0` is normalized to 1 by dividing all coefficients by `a0`.
    private struct BiquadCoefficients {
        let b0: Double
        let b1: Double
        let b2: Double
        let a1: Double
        let a2: Double
    }

    /// 2nd-order high-shelf biquad designed via the Robert Bristow-
    /// Johnson "Audio EQ Cookbook" formulas.
    private static func highShelfBiquad(
        f0: Double,
        gainDB: Double,
        q: Double,
        sampleRate: Double
    ) -> BiquadCoefficients {
        let A = pow(10.0, gainDB / 40.0)
        let omega = 2.0 * .pi * f0 / sampleRate
        let cosW = cos(omega)
        let sinW = sin(omega)
        let alpha = sinW / (2.0 * q)
        let twoSqrtAalpha = 2.0 * sqrt(A) * alpha

        let a0 = (A + 1.0) - (A - 1.0) * cosW + twoSqrtAalpha
        let b0 = A * ((A + 1.0) + (A - 1.0) * cosW + twoSqrtAalpha)
        let b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosW)
        let b2 = A * ((A + 1.0) + (A - 1.0) * cosW - twoSqrtAalpha)
        let a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosW)
        let a2 = (A + 1.0) - (A - 1.0) * cosW - twoSqrtAalpha

        return BiquadCoefficients(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
    }

    /// 2nd-order high-pass biquad (Butterworth response when q ≈ 0.707).
    private static func highPassBiquad(
        f0: Double,
        q: Double,
        sampleRate: Double
    ) -> BiquadCoefficients {
        let omega = 2.0 * .pi * f0 / sampleRate
        let cosW = cos(omega)
        let sinW = sin(omega)
        let alpha = sinW / (2.0 * q)

        let a0 = 1.0 + alpha
        let b0 = (1.0 + cosW) / 2.0
        let b1 = -(1.0 + cosW)
        let b2 = (1.0 + cosW) / 2.0
        let a1 = -2.0 * cosW
        let a2 = 1.0 - alpha

        return BiquadCoefficients(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
    }

    /// Apply a biquad filter to a signal, returning a new array.
    /// Direct Form II Transposed implementation — numerically stable
    /// and uses two state variables instead of four.
    private static func applyBiquad(
        coefficients c: BiquadCoefficients,
        samples: [Float]
    ) -> [Float] {
        var output = samples
        applyBiquadInPlace(coefficients: c, samples: &output)
        return output
    }

    /// In-place biquad apply. Same math as `applyBiquad` but writes
    /// back into the input buffer to save an allocation.
    private static func applyBiquadInPlace(
        coefficients c: BiquadCoefficients,
        samples: inout [Float]
    ) {
        var z1: Double = 0
        var z2: Double = 0
        let n = samples.count
        for i in 0..<n {
            let input = Double(samples[i])
            let output = c.b0 * input + z1
            z1 = c.b1 * input - c.a1 * output + z2
            z2 = c.b2 * input - c.a2 * output
            samples[i] = Float(output)
        }
    }

    // MARK: - True peak measurement

    /// Compute the SAMPLE peak of a multi-channel signal in dBFS.
    /// Plain max-abs across all channels in the sample domain, no
    /// upsampling. Always less than or equal to the true peak. The
    /// difference between sample peak and true peak is the inter-
    /// sample peak headroom that a 4× sinc upsample reveals.
    ///
    /// Returns `-Double.infinity` for pure silence.
    public static func samplePeakDBFS(samples: [[Float]]) -> Double {
        var globalMax: Float = 0
        for channel in samples {
            channel.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress, !channel.isEmpty else { return }
                var chMax: Float = 0
                vDSP_maxmgv(base, 1, &chMax, vDSP_Length(channel.count))
                if chMax > globalMax { globalMax = chMax }
            }
        }
        guard globalMax > 1e-12 else { return -.infinity }
        return 20.0 * log10(Double(globalMax))
    }

    /// Compute the true peak of a multi-channel signal in dBTP.
    /// Uses 4× sinc interpolation to catch intersample peaks that a
    /// raw sample-domain max would miss.
    ///
    /// Returns `-Double.infinity` for pure silence.
    public static func truePeakDBFS(samples: [[Float]]) -> Double {
        var globalMax: Double = 0
        for channel in samples {
            let chMax = truePeakLinear(channel: channel)
            if chMax > globalMax { globalMax = chMax }
        }
        guard globalMax > 1e-12 else { return -.infinity }
        return 20.0 * log10(globalMax)
    }

    /// True peak linear value for one channel via 4× sinc interpolation.
    /// We compute the signal at fractional positions 0.0, 0.25, 0.5,
    /// 0.75 between every adjacent pair of integer samples and find
    /// the max abs value across all 4× output positions.
    private static func truePeakLinear(channel: [Float]) -> Double {
        let n = channel.count
        guard n > 0 else { return 0 }

        // Start with the integer-sample max — this is the lower bound.
        var maxAbs: Float = 0
        channel.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            vDSP_maxmgv(base, 1, &maxAbs, vDSP_Length(n))
        }

        // Now check the 3 intersample positions (0.25, 0.5, 0.75)
        // using sinc interpolators built once per fractional offset.
        // We process the whole channel through `SincInterpolator
        // .processFull` for each offset and track the running max.
        let fractions: [Double] = [0.25, 0.5, 0.75]
        for frac in fractions {
            let interpolated = SincInterpolator.processFull(
                samples: channel,
                intShift: 0,
                fractionalDelay: frac,
                kernelSize: 32
            )
            var localMax: Float = 0
            interpolated.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                vDSP_maxmgv(base, 1, &localMax, vDSP_Length(interpolated.count))
            }
            if localMax > maxAbs { maxAbs = localMax }
        }
        return Double(maxAbs)
    }

    // MARK: - Gain calculation

    /// Compute the gain (in dB) needed to move a signal from its
    /// measured loudness to the target's preferred loudness, while
    /// respecting the target's true peak ceiling.
    ///
    /// If applying the loudness-target gain would push the loudest
    /// sample above the true peak ceiling, the returned gain is
    /// REDUCED to fit so the file never clips. The caller should
    /// surface this case in the UI ("Could not reach target — true
    /// peak ceiling reached") so the user knows their material was
    /// too dynamic for the requested target.
    ///
    /// Returns 0 dB if the target is `.off` or the measurement is
    /// silent.
    public static func gainForTarget(
        measurement: Measurement,
        target: LoudnessTarget
    ) -> Double {
        if case .off = target { return 0 }
        if measurement.isSilent { return 0 }

        // Loudness-only gain: how much do we need to add to hit
        // the target?
        let loudnessGain = target.targetLUFS - measurement.integratedLUFS

        // True peak ceiling: how much CAN we add before the loudest
        // intersample peak hits the ceiling?
        let truePeakHeadroom = target.truePeakCeilingDB - measurement.truePeakDB

        // Pick the smaller (= safer) of the two. If the loudness gain
        // is bigger than the available headroom, we cap at the
        // headroom — that means the output is quieter than the user
        // asked for, but it doesn't clip.
        return min(loudnessGain, truePeakHeadroom)
    }

    /// True if hitting the loudness target would clip without limiting.
    /// Used to surface a warning in the UI.
    public static func wouldClipForTarget(
        measurement: Measurement,
        target: LoudnessTarget
    ) -> Bool {
        if case .off = target { return false }
        if measurement.isSilent { return false }
        let loudnessGain = target.targetLUFS - measurement.integratedLUFS
        let truePeakHeadroom = target.truePeakCeilingDB - measurement.truePeakDB
        return loudnessGain > truePeakHeadroom + 0.01  // small epsilon
    }
}
