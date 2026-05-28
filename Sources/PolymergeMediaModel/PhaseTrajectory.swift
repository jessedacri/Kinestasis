import Foundation

/// A per-window delay trajectory produced by dynamic-mode phase alignment.
///
/// Where static mode produces a single delay per file, dynamic mode slides an
/// analysis window across the overlap region and computes one delay per
/// window. The trajectory is then median-filtered to reject outliers (per
/// spec section 3.8.2 step 8) and the merger applies a smoothly varying
/// fractional sample shift across the file.
///
/// Coordinates: `sampleCenters[i]` is in *target file* sample space — the
/// position in the source file where the analysis window was centered.
public struct PhaseTrajectory: Equatable {
    /// Center sample positions (in source-file sample space) of each window.
    /// Strictly increasing.
    public var sampleCenters: [Int]
    /// Detected delay (in samples) at each window. Sub-sample precision.
    /// Sign convention matches `phaseDelaySamples` — positive = the target
    /// lags the reference.
    public var delays: [Double]
    /// GCC-PHAT confidence at each window (peak / mean of cross-correlation).
    public var confidences: [Double]
    /// Window size (in samples) used for the analysis.
    public var windowSize: Int
    /// Hop size (in samples) between consecutive windows.
    public var hopSize: Int
    /// Monotone-cubic Hermite tangents at each window center,
    /// one per `sampleCenters` entry. Populated at init via
    /// Fritsch-Carlson so `delay(atSourceSample:)` can return
    /// a smooth (C¹-continuous) interpolated delay without the
    /// slope discontinuities that linear interpolation
    /// introduces at window boundaries. Those discontinuities
    /// were the source of the ~5-cent pitch waver the AAP audit
    /// flagged on sustained-dialog passages. Monotone tangents
    /// (rather than plain Catmull-Rom) guarantee no overshoot
    /// between trajectory points — critical for audio, where an
    /// overshoot turns into a phantom sample shift that
    /// produces audible clicks.
    public var tangents: [Double]

    public init(
        sampleCenters: [Int],
        delays: [Double],
        confidences: [Double],
        windowSize: Int,
        hopSize: Int
    ) {
        precondition(sampleCenters.count == delays.count)
        precondition(sampleCenters.count == confidences.count)
        self.sampleCenters = sampleCenters
        self.delays = delays
        self.confidences = confidences
        self.windowSize = windowSize
        self.hopSize = hopSize
        self.tangents = Self.monotoneCubicTangents(
            x: sampleCenters.map(Double.init),
            y: delays
        )
    }

    /// Number of windows in the trajectory.
    public var count: Int { sampleCenters.count }

    /// Mean delay across all windows (used as a fallback "static delay" for
    /// display and for the merger when dynamic processing is unavailable).
    public var meanDelay: Double {
        guard !delays.isEmpty else { return 0 }
        return delays.reduce(0, +) / Double(delays.count)
    }

    /// Min / max delay observed across the trajectory — drives the UI's
    /// "drift range" readout.
    public var delayRange: ClosedRange<Double> {
        guard let lo = delays.min(), let hi = delays.max() else { return 0...0 }
        return lo...hi
    }

    /// True when the trajectory shows a meaningful time-varying drift
    /// (per-window delay wanders by more than ~1 sample across the
    /// file). For channel-sibling pairs recorded on the same sample-
    /// locked recorder there is no clock drift, so the trajectory is
    /// flat at the acoustic delay — dynamic mode degenerates to a
    /// single delay value and the LIVE DRIFT readout + ribbon
    /// become uninformative (a horizontal line at one value). Views
    /// key off this flag to decide whether to show the drift UI or
    /// fall back to a static-delay badge.
    public var hasMeaningfulDrift: Bool {
        let range = delayRange
        return (range.upperBound - range.lowerBound) > 1.0
    }

    /// Mean GCC-PHAT confidence across the trajectory.
    public var meanConfidence: Double {
        guard !confidences.isEmpty else { return 0 }
        return confidences.reduce(0, +) / Double(confidences.count)
    }

    /// Monotone-cubic-Hermite interpolated delay at an arbitrary
    /// source-file sample position. Used by the dynamic time-
    /// shift kernel to look up a per-output-sample delay value.
    /// Out-of-range positions clamp to the nearest endpoint
    /// (avoids edge artifacts at the file boundaries).
    ///
    /// **Why monotone cubic** instead of plain linear (old) or
    /// plain cubic / Catmull-Rom: the delay trajectory's
    /// interpolated path becomes the per-sample time-shift the
    /// merger applies via `vDSP_conv` of a sinc kernel. Any
    /// SLOPE DISCONTINUITY in that path shows up as a
    /// micro-frequency-modulation step in the output — the
    /// ±5-cent "pitch waver" artifact the AAP audit identified
    /// on sustained-dialog passages. Plain cubic smooths the
    /// slopes but can OVERSHOOT between trajectory points,
    /// which would introduce phantom sample shifts and
    /// potential clicks. Fritsch-Carlson monotone cubic
    /// guarantees the interpolated curve stays bounded between
    /// trajectory points while keeping the first derivative
    /// continuous. That's exactly the property we want: no
    /// artifacts between adjacent delay measurements, no
    /// overshoot outside their envelope.
    /// Linearly interpolated confidence at a source sample
    /// position. Used by the dynamic-shift application path to
    /// scale how much of the per-sub-chunk delay actually gets
    /// applied (high confidence → full shift; low confidence →
    /// pulled toward the trajectory's anchor / mean). Cubic
    /// interpolation isn't needed here — confidence is already a
    /// smoothed-out metric and small inter-sample bumps in the
    /// weight don't audibly matter.
    public func confidence(atSourceSample s: Int) -> Double {
        guard !sampleCenters.isEmpty else { return 0 }
        if sampleCenters.count == 1 { return confidences[0] }
        let sd = Double(s)
        if sd <= Double(sampleCenters[0]) { return confidences[0] }
        if sd >= Double(sampleCenters[sampleCenters.count - 1]) {
            return confidences[confidences.count - 1]
        }
        var lo = 0
        var hi = sampleCenters.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if Double(sampleCenters[mid]) <= sd { lo = mid } else { hi = mid }
        }
        let x0 = Double(sampleCenters[lo])
        let x1 = Double(sampleCenters[hi])
        let h = x1 - x0
        guard h > 0 else { return confidences[lo] }
        let t = (sd - x0) / h
        return confidences[lo] * (1 - t) + confidences[hi] * t
    }

    public func delay(atSourceSample s: Int) -> Double {
        guard !sampleCenters.isEmpty else { return 0 }
        if sampleCenters.count == 1 { return delays[0] }

        let sd = Double(s)
        // Clamp to the trajectory range.
        if sd <= Double(sampleCenters[0]) { return delays[0] }
        if sd >= Double(sampleCenters[sampleCenters.count - 1]) {
            return delays[delays.count - 1]
        }

        // Binary search the bracketing window.
        var lo = 0
        var hi = sampleCenters.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if Double(sampleCenters[mid]) <= sd { lo = mid } else { hi = mid }
        }
        let x0 = Double(sampleCenters[lo])
        let x1 = Double(sampleCenters[hi])
        let y0 = delays[lo]
        let y1 = delays[hi]
        let m0 = tangents[lo]
        let m1 = tangents[hi]
        let h = x1 - x0
        guard h > 0 else { return y0 }
        let t = (sd - x0) / h

        // Hermite cubic basis functions, evaluated at t ∈ [0, 1].
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2.0 * t3 - 3.0 * t2 + 1.0
        let h10 = t3 - 2.0 * t2 + t
        let h01 = -2.0 * t3 + 3.0 * t2
        let h11 = t3 - t2
        return y0 * h00 + h * m0 * h10 + y1 * h01 + h * m1 * h11
    }

    /// Fritsch-Carlson monotone cubic tangent computation. For
    /// each knot we compute a derivative that (a) approximates
    /// the local slope for smoothness and (b) satisfies the
    /// Fritsch-Carlson monotonicity conditions so the Hermite
    /// interpolant never overshoots between adjacent points.
    ///
    /// Reference: Fritsch, F. N.; Carlson, R. E. (1980),
    /// "Monotone piecewise cubic interpolation", SIAM Journal
    /// on Numerical Analysis 17 (2): 238-246.
    public static func monotoneCubicTangents(x: [Double], y: [Double]) -> [Double] {
        let n = x.count
        if n == 0 { return [] }
        if n == 1 { return [0] }

        // Secant slopes between adjacent knots.
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = x[i + 1] - x[i]
            d[i] = dx > 0 ? (y[i + 1] - y[i]) / dx : 0
        }

        // Initial tangents = average of adjacent secants
        // (3-point formula at interior, single-secant at ends).
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) {
            m[i] = 0.5 * (d[i - 1] + d[i])
        }

        // Fritsch-Carlson monotonicity adjustment.
        for i in 0..<(n - 1) {
            if d[i] == 0 {
                // Flat segment — tangents at both ends of this
                // interval must be zero to prevent ripple.
                m[i] = 0
                m[i + 1] = 0
                continue
            }
            let alpha = m[i] / d[i]
            let beta = m[i + 1] / d[i]
            // If the initial tangents would produce an overshoot
            // per the Fritsch-Carlson criterion (α² + β² > 9),
            // scale them back uniformly.
            let r = alpha * alpha + beta * beta
            if r > 9 {
                let tau = 3.0 / sqrt(r)
                m[i] = tau * alpha * d[i]
                m[i + 1] = tau * beta * d[i]
            }
        }
        return m
    }

    // MARK: - Smoothing

    /// Apply a median filter of the given radius to the delay sequence.
    /// Outliers from low-correlation windows get replaced by the local
    /// median, leaving the bulk of the trajectory intact.
    ///
    /// `radius = 2` → 5-point median window, the typical default.
    public static func medianFilter(_ delays: [Double], radius: Int) -> [Double] {
        guard radius > 0, delays.count > 1 else { return delays }
        var out = [Double](repeating: 0, count: delays.count)
        for i in 0..<delays.count {
            let lo = max(0, i - radius)
            let hi = min(delays.count - 1, i + radius)
            var slice = Array(delays[lo...hi])
            slice.sort()
            out[i] = slice[slice.count / 2]
        }
        return out
    }

    /// Light box-average smoothing applied AFTER the median filter to soften
    /// step discontinuities at window boundaries when the trajectory is
    /// linearly interpolated between windows. Radius 1 → 3-tap box average.
    public static func boxSmooth(_ delays: [Double], radius: Int) -> [Double] {
        guard radius > 0, delays.count > 1 else { return delays }
        var out = [Double](repeating: 0, count: delays.count)
        for i in 0..<delays.count {
            let lo = max(0, i - radius)
            let hi = min(delays.count - 1, i + radius)
            var sum = 0.0
            for k in lo...hi { sum += delays[k] }
            out[i] = sum / Double(hi - lo + 1)
        }
        return out
    }

    /// Build a smoothed trajectory from raw per-window analysis output.
    /// Drops windows below `minConfidence` (replaced with the nearest
    /// valid neighbor's delay), median-filters the result, then box-
    /// smooths it. The nearest-neighbor fill preserves a coherent
    /// *estimate* of the delay everywhere, which the classifier needs
    /// to distinguish "real static offset" from "nothing to do here."
    ///
    /// Per-window gating of the APPLIED shift (zero out unconfident
    /// regions so we don't extrapolate across multi-minute "actors
    /// in different rooms" gaps) is a future concern — it needs
    /// threading the confidence array into
    /// `PhaseAligner.applyDynamicTimeShift` so the time-varying
    /// shift can taper to zero in unreliable regions. Doing the
    /// zeroing here silently crushed the classifier's mean-delay
    /// readout, which flipped every take to `.alreadyAligned` even
    /// when confident windows had found real ~9 ms boom-lav offsets.
    public static func smoothed(
        sampleCenters: [Int],
        rawDelays: [Double],
        confidences: [Double],
        windowSize: Int,
        hopSize: Int,
        minConfidence: Double,
        medianRadius: Int = 2,
        smoothRadius: Int = 1,
        clampSamples: Double? = nil
    ) -> PhaseTrajectory {
        precondition(sampleCenters.count == rawDelays.count)
        precondition(sampleCenters.count == confidences.count)

        // **Compute anchor from raw confident windows FIRST.** The
        // nearest-neighbor fill below propagates high-confidence
        // delays into low-confidence regions, which can pollute a
        // post-fill median if many confident windows happened to
        // be flails (common on boom-vs-lav content where GCC-PHAT's
        // correlation surface has multiple near-equal peaks).
        // Using pre-fill confident-only median keeps the anchor
        // honest.
        let anchorValue: Double? = {
            guard let clamp = clampSamples, clamp > 0, !rawDelays.isEmpty else { return nil }
            let confidentRaw = zip(rawDelays, confidences)
                .filter { $1 >= minConfidence }
                .map { $0.0 }
                .sorted()
            // Require at least max(5, 10%) confident windows before
            // trusting an anchor. Otherwise fall back to global
            // median — still better than nothing because at least
            // a few legitimate readings are likely in there.
            if confidentRaw.count >= max(5, rawDelays.count / 10) {
                return confidentRaw[confidentRaw.count / 2]
            }
            let all = rawDelays.sorted()
            return all[all.count / 2]
        }()

        // Replace low-confidence windows with the nearest high-
        // confidence neighbor's delay so the median filter isn't
        // thrown off by a long run of garbage windows in a quiet
        // section.
        var delays = rawDelays
        let confident = (0..<delays.count).filter { confidences[$0] >= minConfidence }
        if !confident.isEmpty {
            for i in 0..<delays.count where confidences[i] < minConfidence {
                var bestIdx = confident[0]
                var bestDist = abs(bestIdx - i)
                for c in confident where abs(c - i) < bestDist {
                    bestIdx = c
                    bestDist = abs(c - i)
                }
                delays[i] = rawDelays[bestIdx]
            }
        }

        // **Anchor-based clamp.** Out-of-range windows are replaced
        // with the anchor value (not pinned to the band edge). This
        // keeps the post-clamp trajectory range reflecting REAL in-
        // range variation (not a clamp artifact — edge-pinning would
        // always inflate the range to exactly 2× the tolerance and
        // make the "DYNAMIC DRIFT ±X ms" badge meaningless).
        //
        // Healthy tracker (< 50% flail): only the bad windows snap
        // to anchor; the 80%+ of real data passes through untouched
        // and the ribbon shows believable motion.
        //
        // Broken tracker (≥ 50% flail): everything collapses toward
        // the anchor naturally (since most windows are bad). The
        // outcome classifier will detect the tiny drift range and
        // likely pick `.staticOffset` or `.alreadyAligned` instead
        // of `.dynamicDrift`, which is the correct UX — it tells
        // the user "this take's alignment is a static offset, not a
        // moving one" without misleading them about phantom drift.
        if let clamp = clampSamples, let a = anchorValue, clamp > 0 {
            let lo = a - clamp
            let hi = a + clamp
            var flailed = 0
            for i in 0..<delays.count {
                if delays[i] > hi || delays[i] < lo {
                    delays[i] = a
                    flailed += 1
                }
            }
            let pct = Double(flailed) / Double(max(1, delays.count)) * 100
            let warn = pct >= 50 ? " [tracker unreliable — trajectory dominated by anchor]" : ""
            print("[PhaseTrajectory] clamp anchor=\(String(format: "%.3f", a)) tol=±\(String(format: "%.3f", clamp))samples — replaced \(flailed)/\(delays.count) flailing windows with anchor (\(String(format: "%.0f", pct))%)\(warn)")
        }

        delays = medianFilter(delays, radius: medianRadius)
        delays = boxSmooth(delays, radius: smoothRadius)

        return PhaseTrajectory(
            sampleCenters: sampleCenters,
            delays: delays,
            confidences: confidences,
            windowSize: windowSize,
            hopSize: hopSize
        )
    }

    /// Fraction of windows whose GCC-PHAT confidence clears the given
    /// floor. Used by the outcome classifier — a file where the
    /// actors are in the same room for 20% of the take and a different
    /// room for 80% still yields real alignment data on that 20%, so
    /// we shouldn't throw the whole take out just because the mean is
    /// low.
    public func confidentFraction(minConfidence: Double) -> Double {
        guard !confidences.isEmpty else { return 0 }
        let count = confidences.reduce(0) { $0 + ($1 >= minConfidence ? 1 : 0) }
        return Double(count) / Double(confidences.count)
    }
}
