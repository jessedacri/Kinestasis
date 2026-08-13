import Foundation

/// Deterministic per-frame exposure variation — the gentle flicker of a
/// hand-cranked camera. Smooth value noise: fixed pseudo-random nodes at
/// `rate` Hz, smoothstep-interpolated, scaled by intensity. Deterministic
/// in the frame index so renders are reproducible.
public enum ExposureWobble {
    /// Peak EV swing at intensity 100. The renderer also derives a
    /// contrast flutter from this signal, so full-intensity wobble reads
    /// as real projector breathing, not a subtle brightness shimmer.
    public static let maxEV = 0.85

    /// EV offset for an output frame. `intensity` 0…100, `rate` in Hz.
    public static func evOffset(outputFrame: Int64, fps: Double, intensity: Double, rate: Double) -> Double {
        guard intensity > 0, fps > 0, rate > 0 else { return 0 }
        let t = Double(outputFrame) / fps * rate
        let k = Int64(t.rounded(.down))
        let frac = t - Double(k)
        let a = node(k)
        let b = node(k + 1)
        let s = frac * frac * (3 - 2 * frac)   // smoothstep
        return (a + (b - a) * s) * (intensity / 100) * maxEV
    }

    /// Hash → [-1, 1]. SplitMix64 finalizer.
    private static func node(_ k: Int64) -> Double {
        var z = UInt64(bitPattern: k) &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53) * 2 - 1
    }
}
