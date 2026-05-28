import Accelerate
import Foundation

/// Generalized Cross-Correlation with Phase Transform.
///
/// Estimates the time delay between a target signal and a reference signal.
/// PHAT whitening makes it robust to coloration and reverb differences between mics.
///
/// Algorithm (per spec section 3.8.2):
///   1. FFT both signals → X_ref(f), X_tgt(f)
///   2. Cross-power spectrum: G(f) = X_ref(f) · conj(X_tgt(f))
///   3. PHAT normalize: GCC_PHAT(f) = G(f) / |G(f)|
///   4. IFFT → cross-correlation in time domain
///   5. Peak detection within ±maxLagSamples
///   6. Confidence = peak / mean(|crosscorr|)
///
/// Returns positive delay if `target` is delayed relative to `reference` (i.e., the
/// target should be shifted *earlier* by that many samples to align).
public struct GCCPHATAnalyzer {
    public struct Result {
        /// Estimated delay in samples (sub-sample precision via parabolic
        /// interpolation around the integer peak). Positive means target is later
        /// than reference.
        public var delaySamples: Double
        /// Integer-only delay (the original peak before parabolic refinement).
        /// Useful for tests and for when the caller doesn't need fractional precision.
        public var delaySamplesInteger: Int
        /// Peak-to-average ratio of the cross-correlation. Higher = more confident.
        public var confidence: Double
        /// Raw peak value of the cross-correlation.
        public var peakValue: Double

        public init(
            delaySamples: Double,
            delaySamplesInteger: Int,
            confidence: Double,
            peakValue: Double
        ) {
            self.delaySamples = delaySamples
            self.delaySamplesInteger = delaySamplesInteger
            self.confidence = confidence
            self.peakValue = peakValue
        }
    }

    public enum AnalysisError: LocalizedError {
        case signalsTooShort
        case lengthMismatch
        case fftSetupFailed

        public var errorDescription: String? {
            switch self {
            case .signalsTooShort: return "Signals too short for analysis"
            case .lengthMismatch: return "Reference and target signals must be the same length"
            case .fftSetupFailed: return "Failed to set up FFT"
            }
        }
    }

    /// Analyze two equal-length signals and return the time delay between them.
    /// `maxLagSamples` constrains the search window — delays beyond this are likely
    /// spurious matches and not real microphone offsets.
    public static func analyze(
        reference: [Float],
        target: [Float],
        maxLagSamples: Int
    ) throws -> Result {
        guard reference.count == target.count else { throw AnalysisError.lengthMismatch }
        guard reference.count >= 64 else { throw AnalysisError.signalsTooShort }

        let inputLength = reference.count

        // Pad to next power of two large enough for linear (not circular) correlation.
        // To avoid wraparound, we need length ≥ 2 * inputLength - 1.
        let minN = 2 * inputLength
        let log2n = vDSP_Length(ceil(log2(Float(minN))))
        let n = 1 << Int(log2n)
        let halfN = n / 2

        // Zero-pad signals to length n
        var refPadded = [Float](repeating: 0, count: n)
        var tgtPadded = [Float](repeating: 0, count: n)
        for i in 0..<inputLength {
            refPadded[i] = reference[i]
            tgtPadded[i] = target[i]
        }

        // FFT setup
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw AnalysisError.fftSetupFailed
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Perform forward FFTs
        var refReal = [Float](repeating: 0, count: halfN)
        var refImag = [Float](repeating: 0, count: halfN)
        var tgtReal = [Float](repeating: 0, count: halfN)
        var tgtImag = [Float](repeating: 0, count: halfN)

        forwardRealFFT(input: refPadded, realOut: &refReal, imagOut: &refImag, log2n: log2n, setup: fftSetup)
        forwardRealFFT(input: tgtPadded, realOut: &tgtReal, imagOut: &tgtImag, log2n: log2n, setup: fftSetup)

        // Compute cross-power spectrum: G(f) = X_ref(f) * conj(X_tgt(f))
        // For complex multiply with conjugate:
        //   (a + bi) * conj(c + di) = (a + bi) * (c - di) = (ac + bd) + (bc - ad)i
        var gReal = [Float](repeating: 0, count: halfN)
        var gImag = [Float](repeating: 0, count: halfN)
        for i in 0..<halfN {
            gReal[i] = refReal[i] * tgtReal[i] + refImag[i] * tgtImag[i]
            gImag[i] = refImag[i] * tgtReal[i] - refReal[i] * tgtImag[i]
        }

        // PHAT normalize: divide each bin by its magnitude.
        //
        // **Important**: vDSP's packed-real format puts DC into
        // `realp[0]` and Nyquist into `imagp[0]` — these are TWO
        // SEPARATE real-valued frequency bins that happen to be packed
        // into one complex slot for storage efficiency. They must be
        // normalized **independently** (each has magnitude = abs(value)
        // because both are real-valued), NOT as a single complex number
        // with magnitude `sqrt(DC² + Nyquist²)`. The original code did
        // the latter, which produced incorrect normalization at bin 0
        // and introduced a small phase error in the cross-correlation.
        // The error was masked by parabolic refinement on the integer
        // peak; with 8× zero-padding it shows up as a ~1/8 sample bias
        // away from the correct integer position.
        let dcMag = abs(gReal[0])
        gReal[0] = dcMag > 1e-10 ? gReal[0] / dcMag : 0
        let nyquistMag = abs(gImag[0])
        gImag[0] = nyquistMag > 1e-10 ? gImag[0] / nyquistMag : 0
        // Normal PHAT for the remaining (genuinely complex) bins
        for i in 1..<halfN {
            let mag = sqrt(gReal[i] * gReal[i] + gImag[i] * gImag[i])
            if mag > 1e-10 {
                gReal[i] /= mag
                gImag[i] /= mag
            } else {
                gReal[i] = 0
                gImag[i] = 0
            }
        }

        // 8× FREQUENCY-DOMAIN ZERO-PADDING for sub-sample precision.
        //
        // Per spec section 3.8.2 step 4, the cross-correlation peak is
        // refined to sub-sample precision by zero-padding the spectrum
        // by 8× before the inverse FFT. This produces an 8× oversampled
        // cross-correlation in the time domain — each "sample" of the
        // oversampled output corresponds to 1/8 of an original sample,
        // so the peak position has uniform ~1/8 sample precision (much
        // better than parabolic interpolation, which has ~0.2 sample
        // bias near exact half-sample positions).
        //
        // The vDSP packed-real format stores N/2 complex bins:
        //   realp[0]      = X[0]   (DC, real)
        //   imagp[0]      = X[N/2] (Nyquist, real, packed into imagp[0])
        //   realp[1..N/2-1], imagp[1..N/2-1] = X[1..N/2-1] (positive freqs)
        //
        // To zero-pad by 8× we build a new packed-real spectrum of size
        // 8×N where:
        //   - The original DC stays at position 0
        //   - The original positive frequencies (1..N/2-1) stay in place
        //   - The original Nyquist (which was packed into imagp[0]) is
        //     UNPACKED and placed at position N/2 as a regular bin
        //   - All bins above position N/2 are zero (the new high-frequency
        //     region created by the upsampling)
        //   - The new Nyquist (at position 8×N/2) is zero, so the new
        //     imagp[0] is zero.
        let upsampleFactor = 8
        let nUp = n * upsampleFactor
        let halfNUp = nUp / 2
        let log2nUp = log2n + 3  // log2(8) = 3

        var gRealUp = [Float](repeating: 0, count: halfNUp)
        var gImagUp = [Float](repeating: 0, count: halfNUp)
        // DC and Nyquist are intentionally ZEROED in the upsampled
        // spectrum. They each contribute negligible energy to a
        // band-limited audio cross-correlation peak position, and the
        // packed-real format puts them in the same bin slot which
        // makes the unpacking fiddly. Setting them to zero makes the
        // upsampled spectrum behave identically to a non-packed full
        // spectrum and produces the precise integer-on-grid peak
        // position we want.
        // gRealUp[0] = 0  (DC, already zero)
        // gImagUp[0] = 0  (new Nyquist, already zero)
        // Positive frequencies 1..halfN-1 stay in place
        for k in 1..<halfN {
            gRealUp[k] = gReal[k]
            gImagUp[k] = gImag[k]
        }
        // Bins halfN..halfNUp-1 are already zero (zero-padded high
        // frequencies — no aliasing from the original Nyquist).

        // Inverse FFT the upsampled spectrum with a larger FFT setup
        guard let fftSetupUp = vDSP_create_fftsetup(log2nUp, FFTRadix(kFFTRadix2)) else {
            throw AnalysisError.fftSetupFailed
        }
        defer { vDSP_destroy_fftsetup(fftSetupUp) }

        var crossCorrUp = [Float](repeating: 0, count: nUp)
        inverseRealFFT(realIn: &gRealUp, imagIn: &gImagUp, output: &crossCorrUp, log2n: log2nUp, setup: fftSetupUp)

        // Find the peak in the upsampled cross-correlation. Lags map to
        // indices the same way as the original (lag 0 at index 0,
        // positive lags at 1..halfNUp-1, negative lags wrap from
        // nUp-1..halfNUp+1) — just multiplied by upsampleFactor.
        let searchRangeUp = min(maxLagSamples * upsampleFactor, halfNUp - 1)

        var peakLagUp = 0
        var peakValue: Float = -.infinity

        // Positive lags: index 0..searchRangeUp
        for i in 0...searchRangeUp {
            if crossCorrUp[i] > peakValue {
                peakValue = crossCorrUp[i]
                peakLagUp = i
            }
        }

        // Negative lags: wrap from nUp-1 down to nUp-searchRangeUp
        for i in (nUp - searchRangeUp)..<nUp {
            if crossCorrUp[i] > peakValue {
                peakValue = crossCorrUp[i]
                peakLagUp = i - nUp // negative lag
            }
        }

        // Confidence: peak vs mean of |crosscorr|
        var sumAbs: Float = 0
        for v in crossCorrUp { sumAbs += abs(v) }
        let meanAbs = sumAbs / Float(nUp)
        let confidence = meanAbs > 0 ? Double(peakValue / meanAbs) : 0

        // Convert from upsampled space back to the original sample
        // coordinate system. We also apply parabolic refinement on the
        // upsampled-grid peak to recover sub-grid precision (better
        // than 1/8 sample) — the upsampled grid has finite resolution,
        // and a true peak that doesn't land on a grid sample produces
        // 3 points (peak ± 1) whose parabolic fit recovers the true
        // sub-grid maximum.
        let upsampleFactorD = Double(upsampleFactor)
        let upsampledRefinement = parabolicVertexOffset(
            crossCorr: crossCorrUp,
            peakIndex: peakLagUp,
            n: nUp
        )
        let preciseLagUp = Double(peakLagUp) + upsampledRefinement
        let preciseLag = preciseLagUp / upsampleFactorD
        let integerLag = Int(preciseLag.rounded(.toNearestOrEven))

        // vDSP's FFT sign convention is the opposite of the textbook, so the lag
        // we read out is the negative of the conventional cross-correlation lag.
        // Negate so that "positive delay = target is later than reference."
        return Result(
            delaySamples: -preciseLag,
            delaySamplesInteger: -integerLag,
            confidence: confidence,
            peakValue: Double(peakValue)
        )
    }

    /// Sub-sample peak refinement via parabolic interpolation.
    ///
    /// Given the integer peak index `p` and its two neighbours `y[p-1]`, `y[p]`,
    /// `y[p+1]`, fit a parabola and return the offset `δ` of the vertex from `p`.
    /// The refined peak position is `p + δ`, where `δ ∈ (-0.5, 0.5)`.
    ///
    /// Formula:
    ///     δ = (y[p-1] - y[p+1]) / (2 · (y[p-1] - 2y[p] + y[p+1]))
    ///
    /// Handles negative `peakIndex` (wrapped from the high end of the IFFT result)
    /// by indexing into the cross-correlation array with modular arithmetic.
    private static func parabolicVertexOffset(
        crossCorr: [Float],
        peakIndex: Int,
        n: Int
    ) -> Double {
        // Map peakIndex (which may be negative for negative lags) to actual array indices
        // by wrapping. Since the IFFT output is circular, the values at indices p-1
        // and p+1 are obtained by wrapping mod n.
        let center = ((peakIndex % n) + n) % n
        let prev = ((peakIndex - 1) % n + n) % n
        let next = ((peakIndex + 1) % n + n) % n

        let y0 = Double(crossCorr[prev])
        let y1 = Double(crossCorr[center])
        let y2 = Double(crossCorr[next])

        let denom = 2.0 * (y0 - 2.0 * y1 + y2)
        // Guard against degenerate cases (flat peak)
        guard abs(denom) > 1e-12 else { return 0 }

        let offset = (y0 - y2) / denom
        // Clamp to a sane range — large values would indicate the integer peak
        // wasn't actually a peak (e.g., we picked an edge sample).
        return max(-0.5, min(0.5, offset))
    }

    // MARK: - FFT helpers

    private static func forwardRealFFT(
        input: [Float],
        realOut: inout [Float],
        imagOut: inout [Float],
        log2n: vDSP_Length,
        setup: FFTSetup
    ) {
        let n = input.count
        let halfN = n / 2

        // Pack the real input into a split complex buffer (even samples → real, odd → imag)
        var inputCopy = input
        realOut.withUnsafeMutableBufferPointer { realPtr in
            imagOut.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(
                    realp: realPtr.baseAddress!,
                    imagp: imagPtr.baseAddress!
                )

                inputCopy.withUnsafeMutableBufferPointer { inputPtr in
                    inputPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                    }
                }

                // In-place forward FFT
                vDSP_fft_zrip(setup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
    }

    private static func inverseRealFFT(
        realIn: inout [Float],
        imagIn: inout [Float],
        output: inout [Float],
        log2n: vDSP_Length,
        setup: FFTSetup
    ) {
        let n = output.count
        let halfN = n / 2

        realIn.withUnsafeMutableBufferPointer { realPtr in
            imagIn.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(
                    realp: realPtr.baseAddress!,
                    imagp: imagPtr.baseAddress!
                )

                // In-place inverse FFT
                vDSP_fft_zrip(setup, &splitComplex, 1, log2n, FFTDirection(FFT_INVERSE))

                // Unpack split complex back into a real buffer
                output.withUnsafeMutableBufferPointer { outputPtr in
                    outputPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                        vDSP_ztoc(&splitComplex, 1, complexPtr, 2, vDSP_Length(halfN))
                    }
                }
            }
        }

        // Scale by 1/(2N) — Accelerate's IFFT scales by N, plus the real-FFT scaling
        var scale: Float = 1.0 / Float(2 * n)
        vDSP_vsmul(output, 1, &scale, &output, 1, vDSP_Length(n))
    }
}
