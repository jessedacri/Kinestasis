import Foundation

/// Generates speed-ramp curves (x: output progress, y: source progress)
/// from higher-level intent, so users get ramps without hand-drawing the
/// curve. Total duration is preserved by `ShotTimingEngine.applyRamp`:
/// holding somewhere means the rest of the shot plays faster.
public enum RampBuilder {

    /// Per-still output shares → a downsampled monotone curve. Dwells are
    /// relative weights (screen time per still). Positive dwells are
    /// floored to keep the curve strictly monotone; exact zeros become
    /// slivers far narrower than one output frame, so those stills are
    /// dropped by the sampler (but wide enough that ToneCurve's x-dedupe
    /// keeps the jump anchors).
    public static func ramp(fromDwells dwells: [Double], maxPoints: Int = 16) -> [CurvePoint] {
        let count = dwells.count
        guard count > 1 else { return [] }
        let floorWeight = max(1e-4, (dwells.max() ?? 1) * 1e-3)
        let zeroWidth = floorWeight * 0.02
        let weights = dwells.map { $0 > 0 ? max(floorWeight, $0) : zeroWidth }
        let total = weights.reduce(0, +)

        var full: [CurvePoint] = [CurvePoint(x: 0, y: 0)]
        var cum = 0.0
        for (i, w) in weights.enumerated() {
            cum += w
            full.append(CurvePoint(x: cum / total, y: Double(i + 1) / Double(count)))
        }
        return downsample(full, maxPoints: maxPoints)
    }

    /// Hold on one still: it gets `holdShare` of the output (0…0.8);
    /// `easeIn` stills before it decelerate into the hold and `easeOut`
    /// stills after it accelerate back out, `ease` shapes both tapers
    /// (0 = gradual, 1 = aggressive). `skipAfter` stills immediately after
    /// the hold are dropped, as if the cadence kept running underneath.
    public static func holdRamp(stillIndex: Int, stillCount: Int,
                                holdShare: Double, easeIn: Int, easeOut: Int,
                                ease: Double, skipAfter: Int = 0) -> [CurvePoint] {
        guard stillCount > 1, stillIndex >= 0, stillIndex < stillCount else { return [] }
        let share = min(0.8, max(0.02, holdShare))
        let othersWeight = Double(stillCount - 1)
        let holdWeight = share / (1 - share) * othersWeight

        // Taper exponent: gradual ease keeps neighbors slow-ish; an
        // aggressive ease snaps to full speed right off the hold.
        let power = 1.0 + min(1, max(0, ease)) * 3.0
        var dwells = [Double](repeating: 1, count: stillCount)
        dwells[stillIndex] = holdWeight
        // Time kept passing during the hold: the next stills are gone
        // by the time it releases (near-zero dwell = dropped sub-frame).
        let skip = max(0, skipAfter)
        if skip > 0 {
            for k in 1...skip where stillIndex + k < stillCount {
                dwells[stillIndex + k] = 0
            }
        }
        func taper(_ span: Int, _ k: Int) -> Double {
            1 + (holdWeight - 1) * pow(1 - Double(k) / Double(span + 1), power) * 0.25
        }
        if easeIn > 0 {
            for k in 1...easeIn where stillIndex - k >= 0 {
                dwells[stillIndex - k] = max(dwells[stillIndex - k], taper(easeIn, k))
            }
        }
        if easeOut > 0 {
            for k in 1...easeOut where stillIndex + skip + k < stillCount {
                dwells[stillIndex + skip + k] = max(dwells[stillIndex + skip + k], taper(easeOut, k))
            }
        }
        return ramp(fromDwells: dwells)
    }

    /// Keep the first/last points plus every point that actually bends the
    /// curve (a point is dropped only if the line from the last kept point
    /// to its successor passes through it); a 200-still recording must not
    /// become 200 editor handles.
    static func downsample(_ points: [CurvePoint], maxPoints: Int) -> [CurvePoint] {
        guard points.count > maxPoints, points.count > 2 else { return points }
        var kept: [CurvePoint] = [points[0]]
        var lastKept = points[0]
        var keepNext = false
        for i in 1..<(points.count - 1) {
            let next = points[i + 1]
            let span = max(next.x - lastKept.x, 1e-12)
            let t = (points[i].x - lastKept.x) / span
            let predicted = lastKept.y + t * (next.y - lastKept.y)
            let corner = abs(predicted - points[i].y) > 0.008
            // A corner's successor is kept too: it anchors the monotone
            // cubic's tangent so a steep jump cannot bleed into the next
            // segment and overshoot stills that should play.
            if corner || keepNext {
                kept.append(points[i])
                lastKept = points[i]
            }
            keepNext = corner
        }
        kept.append(points[points.count - 1])
        // Still too dense (constantly-varying recording): thin uniformly.
        if kept.count > maxPoints {
            let stride = Double(kept.count - 1) / Double(maxPoints - 1)
            kept = (0..<maxPoints).map { kept[Int((Double($0) * stride).rounded())] }
        }
        return kept
    }
}
