import Foundation

/// Mutually-exclusive playback state across the program and source
/// viewers. There's only ever ONE active playback target; switching
/// targets stops the other first (Premiere-style).
///
/// `rate` follows JKL conventions:
/// - `+1.0` = 1× forward (audio engine drives, has sound)
/// - `+2.0` … `+4.0` = silent fast shuttle forward (wall-clock driven)
/// - `-1.0` … `-4.0` = silent reverse shuttle
/// - `0` = paused/stopped (also `.stopped` works)
public enum PlaybackState: Equatable, Sendable {
    case stopped
    case program(rate: Double)
    case source(rate: Double)

    public var isPlaying: Bool {
        if case .stopped = self { return false }
        return rate != 0
    }

    public var isProgramPlaying: Bool {
        if case .program = self { return rate != 0 }
        return false
    }

    public var isSourcePlaying: Bool {
        if case .source = self { return rate != 0 }
        return false
    }

    public var rate: Double {
        switch self {
        case .stopped: return 0
        case .program(let r), .source(let r): return r
        }
    }

    /// Whether playback uses the audio engine (true only at +1× program).
    public var usesAudioEngine: Bool {
        if case .program(let r) = self, abs(r - 1.0) < 0.01 { return true }
        return false
    }
}
