import Foundation

/// User-facing loudness normalization preset. Each preset has:
///   - A target integrated loudness in **LUFS** (Loudness Units Full Scale)
///   - A true peak ceiling in **dBTP** (decibels true peak)
///
/// PolyMerge measures the merged output's loudness via ITU-R BS.1770-4
/// (K-weighting + block-based gating) and applies a single gain adjustment
/// to hit the target. The true peak ceiling acts as a safety net: if
/// applying the calculated gain would push the loudest sample above the
/// ceiling, the gain is reduced to fit so the file never clips.
///
/// **Why presets, not a single number?** Different delivery targets have
/// different conventions. Broadcast TV is much quieter than streaming
/// music because TV viewers don't expect to need the volume knob between
/// shows; music listeners expect everything at roughly the same level.
/// PolyMerge ships the standard targets so users can pick their delivery
/// pipeline and forget about the math.
public enum LoudnessTarget: Equatable, Hashable {

    /// No normalization — pass the audio through at its raw level.
    case off

    /// EBU R128 — European broadcast TV standard.
    /// Used by BBC, ARD, ZDF, France TV, etc.
    case ebuR128

    /// ATSC A/85 — US broadcast TV standard. Slightly louder than R128.
    /// Used by ABC, CBS, NBC, Fox, PBS, and most US cable.
    case atscA85

    /// Netflix delivery spec. The quietest of the standard presets —
    /// gives the most headroom for cinematic dynamic range.
    case netflix

    /// Spotify streaming target. Significantly louder than broadcast.
    /// Spotify normalizes uploaded music to this level on playback.
    case spotify

    /// Apple Music streaming target. Slightly quieter than Spotify.
    case appleMusic

    /// YouTube Content ID target for uploaded videos. Same level as
    /// Spotify but with a tighter true peak ceiling.
    case youtube

    /// User-defined custom target. The user provides their own LUFS
    /// and dBTP values via the Custom panel in the popover.
    case custom(targetLUFS: Double, truePeakCeilingDB: Double)

    // MARK: - Target values

    /// Integrated loudness target in LUFS. Negative — the more negative,
    /// the quieter the target.
    public var targetLUFS: Double {
        switch self {
        case .off:                           return 0  // unused when off
        case .ebuR128:                       return -23.0
        case .atscA85:                       return -24.0
        case .netflix:                       return -27.0
        case .spotify:                       return -14.0
        case .appleMusic:                    return -16.0
        case .youtube:                       return -14.0
        case .custom(let lufs, _):           return lufs
        }
    }

    /// True peak ceiling in dBTP. Negative — the more negative, the
    /// more headroom below 0 dBTP. Most targets use -1 or -2 dBTP.
    public var truePeakCeilingDB: Double {
        switch self {
        case .off:                           return 0  // unused when off
        case .ebuR128:                       return -1.0
        case .atscA85:                       return -2.0
        case .netflix:                       return -2.0
        case .spotify:                       return -1.0
        case .appleMusic:                    return -1.0
        case .youtube:                       return -1.0
        case .custom(_, let dbtp):           return dbtp
        }
    }

    // MARK: - UI helpers

    /// Short label shown in the toolbar chip and the preset picker.
    public var displayName: String {
        switch self {
        case .off:        return "OFF"
        case .ebuR128:    return "R128"
        case .atscA85:    return "A/85"
        case .netflix:    return "Netflix"
        case .spotify:    return "Spotify"
        case .appleMusic: return "Apple"
        case .youtube:    return "YouTube"
        case .custom:     return "Custom"
        }
    }

    /// Longer label shown in the popover row.
    public var fullName: String {
        switch self {
        case .off:        return "Off"
        case .ebuR128:    return "EBU R128"
        case .atscA85:    return "ATSC A/85"
        case .netflix:    return "Netflix"
        case .spotify:    return "Spotify"
        case .appleMusic: return "Apple Music"
        case .youtube:    return "YouTube"
        case .custom:     return "Custom"
        }
    }

    /// Plain-language description of when to pick this preset.
    /// Shown in the popover so the user can make an informed choice
    /// without having to look up specs.
    public var subtitle: String {
        switch self {
        case .off:
            return "No normalization — raw merged level"
        case .ebuR128:
            return "European TV broadcast (BBC, ARD, ZDF, France TV)"
        case .atscA85:
            return "US TV broadcast (ABC, CBS, NBC, Fox, cable)"
        case .netflix:
            return "Netflix delivery — most headroom for dynamic range"
        case .spotify:
            return "Spotify music streaming"
        case .appleMusic:
            return "Apple Music streaming"
        case .youtube:
            return "YouTube uploaded video / Content ID"
        case .custom:
            return "Set your own target LUFS and dBTP ceiling"
        }
    }

    /// Equality treats `.custom` cases as equal only when both target
    /// values match. Used by the UI to highlight the active preset.
    public static func == (lhs: LoudnessTarget, rhs: LoudnessTarget) -> Bool {
        switch (lhs, rhs) {
        case (.off, .off): return true
        case (.ebuR128, .ebuR128): return true
        case (.atscA85, .atscA85): return true
        case (.netflix, .netflix): return true
        case (.spotify, .spotify): return true
        case (.appleMusic, .appleMusic): return true
        case (.youtube, .youtube): return true
        case (.custom(let l1, let p1), .custom(let l2, let p2)):
            return abs(l1 - l2) < 0.001 && abs(p1 - p2) < 0.001
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .off:        hasher.combine(0)
        case .ebuR128:    hasher.combine(1)
        case .atscA85:    hasher.combine(2)
        case .netflix:    hasher.combine(3)
        case .spotify:    hasher.combine(4)
        case .appleMusic: hasher.combine(5)
        case .youtube:    hasher.combine(6)
        case .custom(let l, let p):
            hasher.combine(7)
            hasher.combine(l)
            hasher.combine(p)
        }
    }

    /// All standard presets in display order. Used to populate the
    /// popover's preset picker. Excludes `.custom` because that's
    /// represented as a separate UI element.
    public static var standardPresets: [LoudnessTarget] {
        [.ebuR128, .atscA85, .netflix, .spotify, .appleMusic, .youtube]
    }
}
