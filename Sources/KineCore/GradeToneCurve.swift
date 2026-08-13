import Foundation

/// The parametric tone function behind the grade sliders: blacks/whites
/// end-point moves, the global halves of highlights/shadows, an S-curve
/// contrast, then the user's hand-drawn curve - composed Lightroom-style
/// and sampled into a LUT for CIColorCurves. Pure math, testable.
public enum GradeToneCurve {

    /// Whether anything here changes pixels (lets the renderer skip the
    /// filter entirely for untouched grades).
    public static func isActive(_ g: ShotGrade, contrastWobble: Double = 0) -> Bool {
        g.contrast != 0 || g.highlights > 0 || g.shadows < 0
            || g.whites != 0 || g.blacks != 0
            || g.toneCurve.count >= 2 || contrastWobble != 0
    }

    public static func evaluate(_ x: Double, grade g: ShotGrade, contrastWobble: Double = 0) -> Double {
        var y = min(1, max(0, x))
        // Blacks and whites: end-zone moves with smooth masks. Positive
        // blacks lift the floor, negative crush; positive whites push the
        // ceiling brighter, negative pull it down.
        if g.blacks != 0 {
            y += g.blacks / 100 * 0.30 * mask(1 - y, start: 0.45)
        }
        if g.whites != 0 {
            y += g.whites / 100 * 0.30 * mask(y, start: 0.45)
        }
        // The global halves of highlights/shadows. The local, radius-aware
        // halves (recovery and lift) run in CIHighlightShadowAdjust:
        // +highlights brightens the top here, -shadows deepens the bottom.
        if g.highlights > 0 {
            y += g.highlights / 100 * 0.35 * mask(y, start: 0.35)
        }
        if g.shadows < 0 {
            y += g.shadows / 100 * 0.35 * mask(1 - y, start: 0.35)
        }
        // Contrast: smooth S around middle gray, not a linear gain.
        let c = min(1.5, max(-1, g.contrast / 100 * 0.9 + contrastWobble))
        if c > 0 {
            let s = y * y * (3 - 2 * y)
            y += (s - y) * c
        } else if c < 0 {
            y += (0.5 + (y - 0.5) * 0.55 - y) * (-c)
        }
        y = min(1, max(0, y))
        // The hand-drawn curve applies last, on top of the parametrics.
        if g.toneCurve.count >= 2 {
            y = ToneCurve(g.toneCurve).evaluate(y)
        }
        return min(1, max(0, y))
    }

    /// LUT samples for CIColorCurves (per-channel, applied to RGB alike).
    public static func samples(grade: ShotGrade, count: Int = 256, contrastWobble: Double = 0) -> [Float] {
        (0..<count).map { i in
            Float(evaluate(Double(i) / Double(count - 1), grade: grade, contrastWobble: contrastWobble))
        }
    }

    /// 0 below `start`, smooth 0 to 1 from `start` up.
    private static func mask(_ v: Double, start: Double) -> Double {
        guard v > start else { return 0 }
        let t = (v - start) / (1 - start)
        return t * t * (3 - 2 * t)
    }
}
