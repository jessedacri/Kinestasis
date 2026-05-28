import Accelerate
import Foundation

/// Windowed-sinc fractional sample delay interpolator.
///
/// Used to apply sub-sample shifts to an audio stream — needed when the GCC-PHAT
/// analyzer detects a non-integer delay between two microphones.
///
/// Implements the standard polyphase windowed-sinc resampling kernel:
///
///     y[n] = sum_{k=-K/2}^{K/2-1}  x[n + k]  *  h[k]
///     where  h[k] = sinc(k - frac)  *  w[k]
///
/// The kernel is built once for a given fractional delay and reused for the
/// whole stream (efficient for static-mode phase alignment).
///
/// For dynamic mode (time-varying delay), use `SincKernelTable` (in this file)
/// to precompute multiple kernels at fractional offsets and look up the closest
/// one per output sample.
public final class SincInterpolator {
    /// Number of taps in the kernel (half on each side of the
    /// output sample). Default 64 taps + Nuttall 4-term minimum
    /// window → ~98 dB stop-band rejection + flat passband across
    /// 20 Hz-20 kHz at 48 kHz. Upgraded from 32-tap Kaiser β=8.6
    /// (80 dB) after the AAP-comparison audit flagged mild 3-8 kHz
    /// droop on half-sample fractional shifts — audible as boom
    /// sounding slightly duller than lav after alignment.
    public let kernelSize: Int

    /// The fractional delay this interpolator was built for, in [0, 1).
    public let fractionalDelay: Double

    /// Precomputed kernel coefficients (`kernelSize` of them).
    public let kernel: [Float]

    /// Number of past samples needed before the current position.
    /// With the j = k - K/2 convention, j ranges [-K/2, K/2-1]; leftSpan = K/2.
    public var leftSpan: Int { kernelSize / 2 }
    /// Number of future samples needed after the current position.
    public var rightSpan: Int { kernelSize / 2 - 1 }

    /// Build a sinc kernel for the given fractional delay.
    /// `fractionalDelay` should be in [0, 1) — the integer part of the delay should
    /// be applied separately by indexing into the input.
    public init(fractionalDelay: Double, kernelSize: Int = 64) {
        precondition(kernelSize % 2 == 0, "Kernel size must be even")
        self.kernelSize = kernelSize
        self.fractionalDelay = fractionalDelay
        self.kernel = Self.buildKernel(fractionalDelay: fractionalDelay, kernelSize: kernelSize)
    }

    /// Compute one output sample using the kernel.
    /// `samples` is the input buffer; `centerIndex` is the current output position
    /// in input coordinates. The interpolator reads samples
    /// `[centerIndex - leftSpan ... centerIndex + rightSpan]` and returns the
    /// fractionally-shifted value. Out-of-range indices are treated as zero.
    @inline(__always)
    public func interpolate(samples: [Float], centerIndex: Int) -> Float {
        var sum: Float = 0
        let n = samples.count
        let start = centerIndex - leftSpan
        for k in 0..<kernelSize {
            let idx = start + k
            if idx >= 0 && idx < n {
                sum += samples[idx] * kernel[k]
            }
        }
        return sum
    }

    /// Same as `interpolate(samples:centerIndex:)` but reads from a sample-providing
    /// closure. Used by the merger to read directly from a FileHandle without
    /// materializing the whole file in memory.
    @inline(__always)
    public func interpolate(centerIndex: Int, sampleAt: (Int) -> Float) -> Float {
        var sum: Float = 0
        let start = centerIndex - leftSpan
        for k in 0..<kernelSize {
            sum += sampleAt(start + k) * kernel[k]
        }
        return sum
    }

    // MARK: - Kernel construction

    /// Build a Kaiser-windowed sinc kernel for the given fractional delay.
    /// The kernel is normalized so its sum equals 1.0 (DC unity gain).
    ///
    /// Convention: `y[n] = x_continuous(n - delay)` where `delay > 0` means the
    /// output is a *delayed* version of the input (looks like the input but later
    /// in time). Substituting `j = k - n` in the Whittaker-Shannon interpolation
    /// formula gives:
    ///
    ///     y[n] = sum_j x[n + j] · sinc(j + delay)
    ///
    /// So the kernel coefficient at tap offset `j` is `sinc(j + delay)`.
    /// Tap offsets `j` are computed as `k - K/2`, ranging `[-K/2, K/2 - 1]`.
    ///
    /// Uses the Nuttall 4-term minimum window rather than Kaiser.
    /// Nuttall gives ≈98 dB stop-band rejection (Kaiser β=8.6 is
    /// ≈80 dB) and a flatter passband — matters for sub-sample
    /// sinc shifts on 20 Hz-20 kHz content where half-sample
    /// fractional delays through a 32-tap Kaiser produced audible
    /// 3-8 kHz droop (formant region). Nuttall coefficients are
    /// the standard "minimum 4-term" values from Nuttall's 1981
    /// paper; side-lobe performance vs. rectangular is -93 dB.
    public static func buildKernel(fractionalDelay: Double, kernelSize: Int) -> [Float] {
        let half = kernelSize / 2
        // Nuttall 4-term minimum window coefficients.
        // Canonical form: w[n] = a0 - a1*cos(2πn/(N-1)) + a2*cos(4πn/(N-1)) - a3*cos(6πn/(N-1))
        // The kernel is centered at j=0 so we parameterize the
        // window over the [-1, 1] normalized tap axis via the
        // standard mapping n/(N-1) = (j + half)/(kernelSize - 1).
        let a0 = 0.3635819
        let a1 = 0.4891775
        let a2 = 0.1365995
        let a3 = 0.0106411

        var coeffs = [Double](repeating: 0, count: kernelSize)

        for k in 0..<kernelSize {
            // Tap offset j (integer): negative for past samples, 0 for current,
            // positive for future. With our convention j ∈ [-K/2, K/2-1].
            let j = Double(k - half)
            // sinc argument per the derivation above
            let t = j + fractionalDelay

            // Normalized sinc value (sinc(0) = 1)
            let sincValue: Double
            if abs(t) < 1e-10 {
                sincValue = 1.0
            } else {
                let pt = .pi * t
                sincValue = sin(pt) / pt
            }

            // Nuttall window sampled at this tap. `n` is the
            // 0..(N-1) position along the window. For N=64
            // kernel size, tap j=-32 maps to n=0; j=+31 maps to
            // n=63. At the endpoints the Nuttall window goes
            // effectively to zero.
            let n = Double(k)
            let phi = 2.0 * .pi * n / Double(kernelSize - 1)
            let window = a0
                - a1 * cos(phi)
                + a2 * cos(2 * phi)
                - a3 * cos(3 * phi)

            coeffs[k] = sincValue * window
        }

        // Normalize so DC gain = 1
        var sum = 0.0
        for c in coeffs { sum += c }
        if abs(sum) > 1e-10 {
            for k in 0..<kernelSize { coeffs[k] /= sum }
        }

        return coeffs.map { Float($0) }
    }

    // MARK: - Bulk processing (Accelerate fast path)

    /// Apply integer + fractional shift to an entire signal in one pass using
    /// `vDSP_conv` from Accelerate. Roughly 20× faster than the per-sample
    /// `interpolate(...)` approach for full-file shifts.
    ///
    /// Returns a new array of the same length as `samples`, where:
    ///     output[i] = signal at fractional source position (i + intShift - frac)
    ///
    /// `fractionalDelay` is in [0, 1). When it's smaller than 0.05 sample
    /// (~1 µs at 48 kHz, well below human perception), this skips the sinc
    /// pass and uses an integer shift only — much faster.
    public static func processFull(
        samples: [Float],
        intShift: Int,
        fractionalDelay: Double,
        kernelSize: Int = 64
    ) -> [Float] {
        let n = samples.count
        var output = [Float](repeating: 0, count: n)

        // Step 1: integer shift via index translation (cheap)
        // shifted[i] = samples[i + intShift] (with zeros outside the valid range)
        var shifted = [Float](repeating: 0, count: n)
        let srcStart = intShift
        let dstStart = max(0, -srcStart)
        let srcStartClamped = max(0, srcStart)
        let copyLen = min(n - dstStart, n - srcStartClamped)
        if copyLen > 0 {
            samples.withUnsafeBufferPointer { srcPtr in
                shifted.withUnsafeMutableBufferPointer { dstPtr in
                    memcpy(
                        dstPtr.baseAddress! + dstStart,
                        srcPtr.baseAddress! + srcStartClamped,
                        copyLen * MemoryLayout<Float>.size
                    )
                }
            }
        }

        // Step 2: fractional shift via vDSP_conv (or skip if effectively zero)
        if abs(fractionalDelay) < 0.05 {
            return shifted
        }

        let interp = SincInterpolator(fractionalDelay: fractionalDelay, kernelSize: kernelSize)
        let kernel = interp.kernel
        let leftSpan = interp.leftSpan

        // Pad the input so vDSP_conv can read kernelSize samples per output position.
        // Padding layout: [leftSpan zeros] [shifted samples] [rightSpan zeros]
        // Total length: n + kernelSize - 1
        let paddedLen = n + kernelSize - 1
        var padded = [Float](repeating: 0, count: paddedLen)
        shifted.withUnsafeBufferPointer { srcPtr in
            padded.withUnsafeMutableBufferPointer { dstPtr in
                memcpy(
                    dstPtr.baseAddress! + leftSpan,
                    srcPtr.baseAddress!,
                    n * MemoryLayout<Float>.size
                )
            }
        }

        // vDSP_conv computes a CORRELATION: C[i] = sum_k A[i + k] * F[k]
        // For our sinc convention, with the padded buffer offset by leftSpan,
        // C[i] = sum_k samples_shifted[i - leftSpan + k] * kernel[k] = output[i]
        vDSP_conv(padded, 1, kernel, 1, &output, 1, vDSP_Length(n), vDSP_Length(kernelSize))

        return output
    }

    /// Modified Bessel function of the first kind, order 0.
    /// Used by the Kaiser window. Power series expansion — converges quickly for
    /// the values we use here (β ≤ 10).
    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let halfXSquared = (x * 0.5) * (x * 0.5)
        for k in 1...50 {
            term *= halfXSquared / (Double(k) * Double(k))
            sum += term
            if term < 1e-12 * sum { break }
        }
        return sum
    }
}

// MARK: - Kernel table for time-varying delays

/// Precomputed table of sinc kernels at fractional offsets in [0, 1).
/// Used by dynamic mode (per-window varying delay) so we don't have to rebuild
/// the kernel for every output sample.
///
/// All fields are immutable after init, so the table is safe to share across
/// threads — `@unchecked Sendable` is sound here.
public final class SincKernelTable: @unchecked Sendable {
    public let kernelSize: Int
    public let resolution: Int     // number of fractional steps in [0, 1)
    private let kernels: [[Float]]

    public init(kernelSize: Int = 64, resolution: Int = 256) {
        self.kernelSize = kernelSize
        self.resolution = resolution
        var k: [[Float]] = []
        k.reserveCapacity(resolution)
        for i in 0..<resolution {
            let frac = Double(i) / Double(resolution)
            k.append(SincInterpolator.buildKernel(fractionalDelay: frac, kernelSize: kernelSize))
        }
        self.kernels = k
    }

    /// Look up the kernel closest to the given fractional delay.
    @inline(__always)
    public func kernel(for fractionalDelay: Double) -> [Float] {
        var f = fractionalDelay
        // Wrap to [0, 1)
        f -= floor(f)
        let idx = min(resolution - 1, max(0, Int(f * Double(resolution))))
        return kernels[idx]
    }

    public var leftSpan: Int { kernelSize / 2 }
    public var rightSpan: Int { kernelSize / 2 - 1 }
}
