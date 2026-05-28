import Accelerate
import Foundation

/// Butterworth high-pass IIR filter implemented as cascaded biquad sections.
/// Maintains internal state across `processSample` calls — create one instance per channel.
public final class HighPassFilter {
    public enum Slope: Int, CaseIterable, Codable, Sendable {
        case db12 = 12  // 2nd order: 1 biquad
        case db18 = 18  // 3rd order: 1 first-order + 1 biquad
        case db24 = 24  // 4th order: 2 biquads

        public var displayString: String { "\(rawValue) dB/oct" }
        public var orderString: String { "\(rawValue / 6)nd order" }
    }

    public let frequency: Double
    public let slope: Slope
    public let sampleRate: Double

    private var biquads: [Biquad] = []
    private var firstOrder: FirstOrderHPF?

    public init(frequency: Double, slope: Slope, sampleRate: Double) {
        self.frequency = frequency
        self.slope = slope
        self.sampleRate = sampleRate
        buildSections()
    }

    /// Process a single sample through the filter cascade.
    /// Updates internal state — must be called on samples in order.
    public func processSample(_ input: Float) -> Float {
        var x = input
        if let first = firstOrder {
            x = first.process(x)
        }
        for biquad in biquads {
            x = biquad.process(x)
        }
        return x
    }

    /// Reset the internal filter state. Call before processing a new stream.
    public func reset() {
        firstOrder?.reset()
        for biquad in biquads { biquad.reset() }
    }

    /// Apply this filter to an entire buffer using `vDSP_biquad`. Roughly
    /// 20-50× faster than calling `processSample` in a loop, because
    /// `vDSP_biquad` processes all samples in optimized SIMD/Accelerate
    /// code with no per-sample method-call overhead.
    ///
    /// `input` and `output` may alias (in-place processing is fine).
    /// `count` is the number of samples to process.
    ///
    /// NOTE: this builds a one-shot vDSP setup each call. The setup is
    /// cheap (just an array of doubles + a small alloc) — fine for the
    /// "rebuild a track once when the user changes HPF" use case. If we
    /// ever need to apply HPF in a streaming render loop we should cache
    /// the setup.
    public func processBuffer(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        count: Int
    ) {
        // Build a flat coefficient array of [b0, b1, b2, a1, a2] per section.
        // Order doesn't matter for cascaded sections — they're equivalent —
        // but we keep first-order before biquads for consistency with
        // `processSample`.
        var coeffs: [Double] = []
        if let first = firstOrder {
            // First-order section as a "biquad" with b2 = a2 = 0.
            coeffs.append(contentsOf: first.asBiquadCoefficients())
        }
        for biquad in biquads {
            coeffs.append(biquad.b0)
            coeffs.append(biquad.b1)
            coeffs.append(biquad.b2)
            coeffs.append(biquad.a1)
            coeffs.append(biquad.a2)
        }
        let sectionCount = vDSP_Length(coeffs.count / 5)
        guard sectionCount > 0 else {
            output.update(from: input, count: count)
            return
        }

        guard var biquad = vDSP.Biquad(
            coefficients: coeffs,
            channelCount: 1,
            sectionCount: sectionCount,
            ofType: Float.self
        ) else {
            output.update(from: input, count: count)
            return
        }

        let inputBuffer = UnsafeBufferPointer(start: input, count: count)
        var outputBuffer = UnsafeMutableBufferPointer(start: output, count: count)
        biquad.apply(input: inputBuffer, output: &outputBuffer)
    }

    /// Compute the magnitude response (linear, not dB) at a given frequency.
    /// Used for the frequency response curve in the UI.
    public func magnitudeResponse(at f: Double) -> Double {
        var mag = 1.0
        if let first = firstOrder {
            mag *= first.magnitudeResponse(at: f, sampleRate: sampleRate)
        }
        for biquad in biquads {
            mag *= biquad.magnitudeResponse(at: f, sampleRate: sampleRate)
        }
        return mag
    }

    // MARK: - Section Construction

    private func buildSections() {
        biquads.removeAll()
        firstOrder = nil

        switch slope {
        case .db12:
            // 2nd order: single biquad with Q = 1/sqrt(2)
            biquads.append(Biquad.highPass(frequency: frequency, sampleRate: sampleRate, q: 1.0 / sqrt(2.0)))

        case .db18:
            // 3rd order: 1 first-order + 1 biquad with Q = 1.0
            firstOrder = FirstOrderHPF(frequency: frequency, sampleRate: sampleRate)
            biquads.append(Biquad.highPass(frequency: frequency, sampleRate: sampleRate, q: 1.0))

        case .db24:
            // 4th order: 2 biquads with Butterworth Q values
            biquads.append(Biquad.highPass(frequency: frequency, sampleRate: sampleRate, q: 0.5411961))
            biquads.append(Biquad.highPass(frequency: frequency, sampleRate: sampleRate, q: 1.3065630))
        }
    }
}

// MARK: - Biquad Section

/// A single biquad filter section in Direct Form II Transposed.
final class Biquad {
    var b0: Double = 1, b1: Double = 0, b2: Double = 0
    var a1: Double = 0, a2: Double = 0

    private var z1: Double = 0
    private var z2: Double = 0

    func process(_ input: Float) -> Float {
        let x = Double(input)
        let out = b0 * x + z1
        z1 = b1 * x - a1 * out + z2
        z2 = b2 * x - a2 * out
        return Float(out)
    }

    func reset() {
        z1 = 0
        z2 = 0
    }

    /// Magnitude response at frequency f (Hz).
    /// |H(z)| where z = e^(j*2π*f/fs).
    func magnitudeResponse(at f: Double, sampleRate: Double) -> Double {
        let omega = 2.0 * .pi * f / sampleRate
        let cos_w = cos(omega)
        let cos_2w = cos(2.0 * omega)
        let sin_w = sin(omega)
        let sin_2w = sin(2.0 * omega)

        // Numerator: b0 + b1*e^(-jω) + b2*e^(-2jω)
        let numRe = b0 + b1 * cos_w + b2 * cos_2w
        let numIm = -b1 * sin_w - b2 * sin_2w

        // Denominator: 1 + a1*e^(-jω) + a2*e^(-2jω)
        let denRe = 1.0 + a1 * cos_w + a2 * cos_2w
        let denIm = -a1 * sin_w - a2 * sin_2w

        let numMag = sqrt(numRe * numRe + numIm * numIm)
        let denMag = sqrt(denRe * denRe + denIm * denIm)

        guard denMag > 0 else { return 0 }
        return numMag / denMag
    }

    /// Construct a high-pass biquad using the RBJ Audio EQ Cookbook formulas.
    static func highPass(frequency: Double, sampleRate: Double, q: Double) -> Biquad {
        let bq = Biquad()
        let omega = 2.0 * .pi * frequency / sampleRate
        let cos_w = cos(omega)
        let alpha = sin(omega) / (2.0 * q)

        let b0 = (1.0 + cos_w) / 2.0
        let b1 = -(1.0 + cos_w)
        let b2 = (1.0 + cos_w) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cos_w
        let a2 = 1.0 - alpha

        // Normalize by a0
        bq.b0 = b0 / a0
        bq.b1 = b1 / a0
        bq.b2 = b2 / a0
        bq.a1 = a1 / a0
        bq.a2 = a2 / a0

        return bq
    }
}

// MARK: - First-Order High-Pass Section

/// A first-order IIR high-pass filter (6 dB/oct), used to make 18 dB/oct (3rd order)
/// when cascaded with a 12 dB/oct biquad.
final class FirstOrderHPF {
    fileprivate let b0: Double
    fileprivate let b1: Double
    fileprivate let a1: Double

    private var x1: Double = 0
    private var y1: Double = 0

    init(frequency: Double, sampleRate: Double) {
        // Bilinear transform of analog 1st-order high-pass: H(s) = s / (s + ω0)
        let omega = tan(.pi * frequency / sampleRate)
        let norm = 1.0 / (1.0 + omega)
        self.b0 = norm
        self.b1 = -norm
        self.a1 = (omega - 1.0) * norm
    }

    func process(_ input: Float) -> Float {
        let x = Double(input)
        let y = b0 * x + b1 * x1 - a1 * y1
        x1 = x
        y1 = y
        return Float(y)
    }

    func reset() {
        x1 = 0
        y1 = 0
    }

    func magnitudeResponse(at f: Double, sampleRate: Double) -> Double {
        let omega = 2.0 * .pi * f / sampleRate
        let cos_w = cos(omega)
        let sin_w = sin(omega)

        let numRe = b0 + b1 * cos_w
        let numIm = -b1 * sin_w
        let denRe = 1.0 + a1 * cos_w
        let denIm = -a1 * sin_w

        let numMag = sqrt(numRe * numRe + numIm * numIm)
        let denMag = sqrt(denRe * denRe + denIm * denIm)

        guard denMag > 0 else { return 0 }
        return numMag / denMag
    }

    /// Express this 1st-order section as a biquad with b2 = a2 = 0 so it
    /// can be passed to `vDSP_biquad` alongside true 2nd-order sections.
    func asBiquadCoefficients() -> [Double] {
        return [b0, b1, 0, a1, 0]
    }
}
