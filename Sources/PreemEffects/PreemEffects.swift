import Foundation
import PreemCore
import PreemRender

/// PreemEffects hosts the starter effect arsenal. Each effect publishes a
/// key (matching `EffectInstance.effectKey`) and a parameter schema. The
/// render graph (PreemRender, M3) resolves an `EffectInstance` to one of
/// these and asks it to emit Metal fragment work.
public enum PreemEffects {
    /// The keys Preem ships with at M1 scaffold time. M3 fills in
    /// `Transform` / `Opacity` / `CrossDissolve` implementations; M4
    /// expands to the rest.
    public static let builtinKeys: [String] = [
        "preem.transform",        // scale, rotate, position, anchor
        "preem.crop",             // T/R/B/L + feather
        "preem.opacity",          // 0…1 with keyframes
        "preem.color",            // Lumetri-style grade: exposure, contrast, WB, sat, curves, LUT
        "preem.crossDissolve",    // transition between two layers
        "preem.audio.hpf",        // re-uses Polymerge HighPassFilter
        "preem.audio.lpf",
        "preem.audio.gain",
    ]
}
