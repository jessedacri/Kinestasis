import Foundation
import KineCore
import KineRender

/// KineEffects hosts the starter effect arsenal. Each effect publishes a
/// key (matching `EffectInstance.effectKey`) and a parameter schema. The
/// render graph (KineRender, M3) resolves an `EffectInstance` to one of
/// these and asks it to emit Metal fragment work.
public enum KineEffects {
    /// The keys Kine ships with at M1 scaffold time. M3 fills in
    /// `Transform` / `Opacity` / `CrossDissolve` implementations; M4
    /// expands to the rest.
    public static let builtinKeys: [String] = [
        "kine.transform",        // scale, rotate, position, anchor
        "kine.crop",             // T/R/B/L + feather
        "kine.opacity",          // 0…1 with keyframes
        "kine.color",            // Lumetri-style grade: exposure, contrast, WB, sat, curves, LUT
        "kine.crossDissolve",    // transition between two layers
        "kine.audio.hpf",        // re-uses Polymerge HighPassFilter
        "kine.audio.lpf",
        "kine.audio.gain",
    ]
}
