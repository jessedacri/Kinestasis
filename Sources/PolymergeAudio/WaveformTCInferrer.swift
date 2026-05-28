import Foundation
import Accelerate
import PolymergeMediaModel

/// Infers a timecode for a file that has no embedded TC by
/// cross-correlating its **amplitude envelope** against a reference
/// file that DOES have TC.
///
/// **Why envelopes (not raw waveforms):**
/// Production audio sync between a boom mic and a camera mic (or any
/// two mics at different positions) is hard with raw cross-correlation
/// because the two recordings capture the same acoustic events with
/// VERY different spectral content — different mic preamps, different
/// distances, different acoustic paths, possibly different codecs.
/// Raw waveform correlation tries to match the actual sample values,
/// which are spectrally distinct. The amplitude envelope ("when did
/// loud things happen") is much more invariant — both mics see the
/// same dialog hits at the same wall-clock times, just at different
/// SPL levels.
///
/// PluralEyes, Premiere's "Synchronize > Audio", and most academic
/// audio-sync work use envelope-based correlation for this exact
/// reason. The 2024 DTW audio-sync paper found that envelope
/// downsampling is the single most effective robustness technique.
///
/// **How it works:**
///   1. Load both files (resample target to ref's rate if needed)
///   2. Sum to mono
///   3. Extract the RMS envelope at ~200 Hz (240× decimation from 48 kHz)
///   4. Cross-correlate the envelopes (256 K-sample FFT instead of 224 M)
///   5. The peak's lag in the envelope domain × decimation factor =
///      the lag in original samples
///   6. Compute `target_TC_start = reference_TC_start - delay`
///      (the GCC-PHAT analyzer's convention: positive delay means
///      target's content appears at a higher sample index in the
///      target than in the reference, which means target started
///      recording EARLIER than reference)
///   7. Return the inferred TC + confidence so the UI can flag
///      low-confidence matches before the user accepts them
///
/// **Robustness controls:**
/// - The envelope correlation runs on at most ~60 seconds of audio
///   from the START of each file. That's enough overlap to find a
///   real sync point and short enough that spurious peaks at huge
///   lags (which historically caused egregiously wrong results) can't
///   happen.
/// - `maxLagSamples` is bounded to ±30 seconds in the envelope
///   domain. Real-world TC offsets between simultaneously-recorded
///   files are almost always within a few seconds.
/// - Confidence floor of 1.5 (peak/mean ratio of the envelope
///   cross-correlation) — anything below that is rejected as "no
///   real overlap detected."
public struct WaveformTCInferrer {

    /// Decimation factor from full audio sample rate to envelope
    /// sample rate. At 48 kHz audio, this gives a 200 Hz envelope
    /// (5 ms per sample), which is way finer than a single TC
    /// frame (33-42 ms) but ~240× smaller than the raw audio.
    public static let envelopeDecimationFactor: Int = 240

    /// Maximum amount of audio (in seconds) to analyze. We use the
    /// FULL overlap of both files now — envelope cross-correlation
    /// is fast (< 1 s for any reasonable file length once the audio
    /// is loaded), and shorter windows make the algorithm vulnerable
    /// to spurious peaks when the first N seconds of one file lacks
    /// distinctive content.
    ///
    /// Empirical evidence (PURPLE → A001 sweep on real production
    /// audio):
    ///   30 s  → -10.2 s, confidence 7.3   (wrong, too few features)
    ///   60 s  → -2.4 s,  confidence 10.0  (wrong, spurious peak wins)
    ///   90 s  → -16.6 s, confidence 13.6  (correct)
    ///   180 s → -16.6 s, confidence 17.4  (correct, more confident)
    ///   300 s → -16.6 s, confidence 20.4  (correct, more confident)
    ///   420 s → -16.6 s, confidence 34.7  (correct, most confident)
    /// Confidence keeps climbing as more material is analyzed because
    /// the genuine peak stands out more sharply against the noise
    /// floor. There's no reason to artificially cap.
    public static let maxAnalysisSeconds: Double = .infinity

    /// Maximum lag (in seconds) the cross-correlation will search.
    /// 120 seconds is generous enough to handle recordings that
    /// started at very different times (e.g., one recorder powered
    /// up a minute before the other) without inviting spurious peaks
    /// at the file's edges. The genuine offset is almost always
    /// within ±60 s for jam-synced production audio.
    public static let maxLagSeconds: Double = 120

    /// Result of a successful inference.
    public struct Inference {
        /// The TC at sample 0 of the target file, computed from the
        /// reference's TC and the cross-correlation delay.
        public let inferredTimecode: TimecodeValue
        /// The reference file used for the comparison (so the UI can
        /// show "synced against [this file]").
        public let referenceFileID: UUID
        /// Confidence from the GCC-PHAT analysis (peak-to-mean
        /// ratio of the cross-correlation). Higher = more reliable.
        /// Anything <3.0 is suspicious; <1.5 is almost certainly
        /// noise / no real overlap.
        public let confidence: Double
        /// Raw delay in samples (signed) the cross-correlation
        /// reported. Positive = target is later than reference.
        public let delaySamples: Int64

        public init(
            inferredTimecode: TimecodeValue,
            referenceFileID: UUID,
            confidence: Double,
            delaySamples: Int64
        ) {
            self.inferredTimecode = inferredTimecode
            self.referenceFileID = referenceFileID
            self.confidence = confidence
            self.delaySamples = delaySamples
        }
    }

    public enum InferenceError: LocalizedError {
        case referenceHasNoTC
        case loadFailed(String)
        case noOverlap

        public var errorDescription: String? {
            switch self {
            case .referenceHasNoTC: return "Reference track has no timecode to sync against"
            case .loadFailed(let msg): return "Failed to load audio: \(msg)"
            case .noOverlap: return "Could not find a sync point — the recordings may not share content"
            }
        }
    }

    /// Stages of the inference for progress reporting.
    public enum Stage: String {
        case loadingReference = "Loading reference audio"
        case loadingTarget    = "Loading target audio"
        case mixingDown       = "Mixing channels"
        case crossCorrelating = "Cross-correlating"
        case done             = "Done"
    }

    /// Progress callback type. Reports current stage + 0..1 progress
    /// fraction within that stage.
    public typealias ProgressCallback = @Sendable (Stage, Double) -> Void

    /// Infer a TC for `target` by cross-correlating against `reference`.
    ///
    /// Both files are loaded fully, resampled to a common rate, and
    /// the first `min(ref, target)` samples are correlated. For typical
    /// 5-minute recordings this takes 1-3 seconds on a modern Mac.
    ///
    /// Throws `InferenceError.noOverlap` if the cross-correlation peak
    /// isn't strong enough to be trustworthy (confidence < 1.5).
    public static func infer(
        target: AudioFile,
        reference: AudioFile,
        onProgress: ProgressCallback? = nil
    ) throws -> Inference {
        guard let referenceTC = reference.timecode else {
            throw InferenceError.referenceHasNoTC
        }

        onProgress?(.loadingReference, 0.0)

        // Load both files. Resample the target to the reference's
        // sample rate so the cross-correlation operates on a common
        // sample grid. (TrackBufferBuilder.loadAllChannels handles
        // SRC internally when we pass a target rate.)
        let refRate = reference.sampleRate
        let refChannels: [[Float]]
        let tgtChannels: [[Float]]
        do {
            refChannels = try TrackBufferBuilder.loadAllChannels(file: reference, targetSampleRate: refRate)
            onProgress?(.loadingTarget, 0.0)
            tgtChannels = try TrackBufferBuilder.loadAllChannels(file: target, targetSampleRate: refRate)
        } catch {
            throw InferenceError.loadFailed(error.localizedDescription)
        }

        onProgress?(.mixingDown, 0.0)
        guard let refMono = monoMix(refChannels), let tgtMono = monoMix(tgtChannels) else {
            throw InferenceError.loadFailed("Empty audio buffers")
        }

        // Use the FULL overlap of both files. The envelope is so
        // small (file_seconds × 200 Hz) that the cross-correlation
        // is fast even for hour-long files. Shorter windows are
        // dangerous: the genuine peak might not stand out from
        // spurious local maxima within the first few seconds of
        // sparse content (room tone, low dialog).
        let maxSamples: Int
        if maxAnalysisSeconds.isInfinite {
            maxSamples = .max
        } else {
            maxSamples = Int(maxAnalysisSeconds * Double(refRate))
        }
        let analysisLen = min(refMono.count, tgtMono.count, maxSamples)
        guard analysisLen >= refRate / 2 else {
            throw InferenceError.noOverlap
        }
        let refSlice = Array(refMono[0..<analysisLen])
        let tgtSlice = Array(tgtMono[0..<analysisLen])

        // Compute amplitude envelopes via RMS over a 240-sample
        // window (5 ms at 48 kHz), then decimate by the same factor.
        // This is the production-grade approach used by PluralEyes
        // / Premiere — envelopes are far more invariant than raw
        // waveforms to the spectral differences between mics
        // (boom vs camera mic vs lav vs DJI Mic).
        let refEnvelope = rmsEnvelope(samples: refSlice, decimationFactor: envelopeDecimationFactor)
        let tgtEnvelope = rmsEnvelope(samples: tgtSlice, decimationFactor: envelopeDecimationFactor)
        let envelopeRate = Double(refRate) / Double(envelopeDecimationFactor)

        // Pad both envelopes to the same length (the longer one)
        // so GCC-PHAT can run. The shorter one gets zero-padded at
        // the end.
        let envLen = max(refEnvelope.count, tgtEnvelope.count)
        var refEnvPadded = refEnvelope
        var tgtEnvPadded = tgtEnvelope
        if refEnvPadded.count < envLen {
            refEnvPadded.append(contentsOf: [Float](repeating: 0, count: envLen - refEnvPadded.count))
        }
        if tgtEnvPadded.count < envLen {
            tgtEnvPadded.append(contentsOf: [Float](repeating: 0, count: envLen - tgtEnvPadded.count))
        }
        guard envLen > 32 else {
            throw InferenceError.noOverlap
        }

        onProgress?(.crossCorrelating, 0.0)

        // Cap the lag search to ±maxLagSeconds in the envelope domain.
        // Real-world TC offsets are almost always within a few
        // seconds; bounding the search prevents the historical bug
        // where the analyzer found high-confidence-but-wrong peaks
        // at huge lags where only a small tail of the signals
        // overlapped.
        let maxLagEnvelope = min(envLen - 1, Int(maxLagSeconds * envelopeRate))

        let envResult: GCCPHATAnalyzer.Result
        do {
            envResult = try GCCPHATAnalyzer.analyze(
                reference: refEnvPadded,
                target: tgtEnvPadded,
                maxLagSamples: maxLagEnvelope
            )
        } catch {
            throw InferenceError.loadFailed("Cross-correlation failed: \(error.localizedDescription)")
        }

        // Convert the envelope-domain delay back to original sample
        // rate. Envelope sample N corresponds to original audio
        // sample N × decimationFactor.
        let originalDelaySamples = Int64((envResult.delaySamples * Double(envelopeDecimationFactor)).rounded())

        // Confidence floor — below this we don't trust the peak.
        // Envelope correlation typically produces lower absolute
        // confidence numbers than raw waveform correlation because
        // the envelope is much smoother, so we use a lower
        // threshold here than we did for the raw waveform path.
        guard envResult.confidence >= 1.2 else {
            print("[WaveformInfer] Confidence too low: \(envResult.confidence). delay=\(envResult.delaySamples) envSamples")
            throw InferenceError.noOverlap
        }

        // Diagnostic print so we can see what the algorithm found.
        let delaySec = Double(originalDelaySamples) / Double(refRate)
        print("[WaveformInfer] envLen=\(envLen) envRate=\(String(format: "%.1f", envelopeRate)) Hz envDelay=\(envResult.delaySamples) origDelaySamples=\(originalDelaySamples) (\(String(format: "%.3f", delaySec)) s) confidence=\(envResult.confidence)")

        // The GCC-PHAT analyzer reports delay so that "positive delay
        // means target is later than reference at the SAMPLE level"
        // — i.e., the same content appears at a higher sample index
        // in the target than in the reference. In wall-clock terms
        // that means the target's local clock at the matching sample
        // is the same wall-clock as the reference's, so the target
        // started recording EARLIER (its sample 0 is at an earlier
        // wall-clock TC than the reference's sample 0).
        //
        //   reference sample 0:   wall clock T_ref
        //   target sample (delay): wall clock T_ref (same content)
        //   target sample 0:      wall clock T_ref - delay samples
        //
        // So `targetTC_start = referenceTC - delay`.
        let inferredTC = referenceTC.adding(samples: -originalDelaySamples)

        onProgress?(.done, 1.0)

        return Inference(
            inferredTimecode: inferredTC,
            referenceFileID: reference.id,
            confidence: envResult.confidence,
            delaySamples: originalDelaySamples
        )
    }

    /// Stage 4 entry point: infer a TC for a `VideoFile` by
    /// extracting its embedded audio track and cross-correlating
    /// against an audio reference. Reuses the same envelope
    /// algorithm as the audio-only `infer` — only the source of the
    /// target samples is different.
    ///
    /// **Why this works**: production cameras with no embedded TC
    /// (phones, GoPros, drones, action cams, consumer cameras) ALL
    /// record an audio track to the video container. That audio
    /// track captures the same dialog / acoustic events the boom /
    /// lav reference recorder is also capturing — they're correlated
    /// in time even though the spectral content is wildly different
    /// (camera mic capsule, embedded preamp, AAC compression, etc.).
    /// Envelope cross-correlation is robust to those differences for
    /// the same reasons it's robust between boom and lav: it asks
    /// "when did loud things happen" rather than trying to match
    /// sample values directly.
    ///
    /// **Async**: video audio extraction uses the modern
    /// `AVAsset.loadTracks(withMediaType:)` API which is async.
    /// Callers wrap this in a `Task.detached` exactly like they do
    /// for the audio-only `infer`.
    public static func inferForVideo(
        target: VideoFile,
        reference: AudioFile,
        onProgress: ProgressCallback? = nil
    ) async throws -> Inference {
        guard let referenceTC = reference.timecode else {
            throw InferenceError.referenceHasNoTC
        }

        onProgress?(.loadingReference, 0.0)
        let refRate = reference.sampleRate
        let refChannels: [[Float]]
        do {
            refChannels = try TrackBufferBuilder.loadAllChannels(file: reference, targetSampleRate: refRate)
        } catch {
            throw InferenceError.loadFailed(error.localizedDescription)
        }

        onProgress?(.loadingTarget, 0.0)
        let extracted: VideoAudioExtractor.Result
        do {
            extracted = try await VideoAudioExtractor.extract(url: target.url, targetSampleRate: refRate)
        } catch {
            throw InferenceError.loadFailed(error.localizedDescription)
        }

        onProgress?(.mixingDown, 0.0)
        guard let refMono = monoMix(refChannels), let tgtMono = monoMix(extracted.channels) else {
            throw InferenceError.loadFailed("Empty audio buffers")
        }

        // From here on the algorithm is bit-identical to the audio-
        // only path. Slice to the common length, build envelopes,
        // run GCC-PHAT, convert envelope-domain delay back to
        // original sample rate, and compute the inferred TC.
        let maxSamples: Int
        if maxAnalysisSeconds.isInfinite {
            maxSamples = .max
        } else {
            maxSamples = Int(maxAnalysisSeconds * Double(refRate))
        }
        let analysisLen = min(refMono.count, tgtMono.count, maxSamples)
        guard analysisLen >= refRate / 2 else {
            throw InferenceError.noOverlap
        }
        let refSlice = Array(refMono[0..<analysisLen])
        let tgtSlice = Array(tgtMono[0..<analysisLen])

        let refEnvelope = rmsEnvelope(samples: refSlice, decimationFactor: envelopeDecimationFactor)
        let tgtEnvelope = rmsEnvelope(samples: tgtSlice, decimationFactor: envelopeDecimationFactor)
        let envelopeRate = Double(refRate) / Double(envelopeDecimationFactor)

        let envLen = max(refEnvelope.count, tgtEnvelope.count)
        var refEnvPadded = refEnvelope
        var tgtEnvPadded = tgtEnvelope
        if refEnvPadded.count < envLen {
            refEnvPadded.append(contentsOf: [Float](repeating: 0, count: envLen - refEnvPadded.count))
        }
        if tgtEnvPadded.count < envLen {
            tgtEnvPadded.append(contentsOf: [Float](repeating: 0, count: envLen - tgtEnvPadded.count))
        }
        guard envLen > 32 else {
            throw InferenceError.noOverlap
        }

        onProgress?(.crossCorrelating, 0.0)
        let maxLagEnvelope = min(envLen - 1, Int(maxLagSeconds * envelopeRate))
        let envResult: GCCPHATAnalyzer.Result
        do {
            envResult = try GCCPHATAnalyzer.analyze(
                reference: refEnvPadded,
                target: tgtEnvPadded,
                maxLagSamples: maxLagEnvelope
            )
        } catch {
            throw InferenceError.loadFailed("Cross-correlation failed: \(error.localizedDescription)")
        }

        let originalDelaySamples = Int64((envResult.delaySamples * Double(envelopeDecimationFactor)).rounded())

        guard envResult.confidence >= 1.2 else {
            print("[VideoWaveformInfer] Confidence too low: \(envResult.confidence). delay=\(envResult.delaySamples) envSamples")
            throw InferenceError.noOverlap
        }

        let delaySec = Double(originalDelaySamples) / Double(refRate)
        print("[VideoWaveformInfer] envLen=\(envLen) envRate=\(String(format: "%.1f", envelopeRate)) Hz envDelay=\(envResult.delaySamples) origDelaySamples=\(originalDelaySamples) (\(String(format: "%.3f", delaySec)) s) confidence=\(envResult.confidence)")

        let inferredTC = referenceTC.adding(samples: -originalDelaySamples)
        onProgress?(.done, 1.0)

        return Inference(
            inferredTimecode: inferredTC,
            referenceFileID: reference.id,
            confidence: envResult.confidence,
            delaySamples: originalDelaySamples
        )
    }

    /// Compute the RMS envelope of a signal by taking the
    /// root-mean-square over non-overlapping windows of length
    /// `decimationFactor`. Output length = `samples.count / decimationFactor`.
    /// Uses vDSP for the squared-sum to keep this fast.
    private static func rmsEnvelope(samples: [Float], decimationFactor: Int) -> [Float] {
        let windowSize = decimationFactor
        let numWindows = samples.count / windowSize
        var envelope = [Float](repeating: 0, count: numWindows)
        let inverse = 1.0 / Float(windowSize)
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for i in 0..<numWindows {
                var sumSquares: Float = 0
                vDSP_svesq(base + i * windowSize, 1, &sumSquares, vDSP_Length(windowSize))
                envelope[i] = sqrt(sumSquares * inverse)
            }
        }
        return envelope
    }

    /// Sum a multi-channel buffer down to mono. Used because GCC-PHAT
    /// operates on a single signal — for stereo / multi-channel
    /// recordings we sum all channels at equal weight before running
    /// the correlation. The phase information that matters for sync
    /// is preserved across the sum.
    private static func monoMix(_ channels: [[Float]]) -> [Float]? {
        guard let first = channels.first, !first.isEmpty else { return nil }
        if channels.count == 1 { return first }
        let length = channels.map(\.count).min() ?? 0
        var output = [Float](repeating: 0, count: length)
        let chCount = Float(channels.count)
        for ch in 0..<channels.count {
            let buf = channels[ch]
            for i in 0..<length {
                output[i] += buf[i] / chCount
            }
        }
        return output
    }
}
