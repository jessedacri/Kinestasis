import Foundation

/// Exact time on a timeline. We never store seconds-as-Double in the project
/// model — float drift over a 90-minute timeline at 23.976 is observable.
///
/// 23.976 fps → rate = 24000, scale = 1001
/// 29.97  fps → rate = 30000, scale = 1001
/// 24     fps → rate = 24,    scale = 1
public struct RationalTime: Hashable, Codable, Sendable {
    public var value: Int64       // numerator
    public var scale: Int32       // denominator (frame rate base)

    public init(value: Int64, scale: Int32) {
        precondition(scale > 0, "scale must be positive")
        self.value = value
        self.scale = scale
    }

    /// Convenience for sources that only know seconds (source-viewer
    /// marks, favorites). `scale` defaults to 600 — the CMTime-style
    /// common timescale; frame alignment is re-applied at placement.
    public init(seconds: Double, scale: Int32 = 600) {
        precondition(scale > 0, "scale must be positive")
        self.value = Int64((seconds * Double(scale)).rounded())
        self.scale = scale
    }

    public static let zero = RationalTime(value: 0, scale: 1)

    public var seconds: Double { Double(value) / Double(scale) }

    public func rescaled(to newScale: Int32) -> RationalTime {
        if scale == newScale { return self }
        let v = Int64((Double(value) * Double(newScale)) / Double(scale))
        return RationalTime(value: v, scale: newScale)
    }

    public static func + (a: RationalTime, b: RationalTime) -> RationalTime {
        if a.scale == b.scale { return RationalTime(value: a.value + b.value, scale: a.scale) }
        let common = lcm(a.scale, b.scale)
        return RationalTime(
            value: a.value * Int64(common / a.scale) + b.value * Int64(common / b.scale),
            scale: common
        )
    }

    public static func - (a: RationalTime, b: RationalTime) -> RationalTime {
        a + RationalTime(value: -b.value, scale: b.scale)
    }
}

public struct TimeRange: Hashable, Codable, Sendable {
    public var start: RationalTime
    public var duration: RationalTime

    public init(start: RationalTime, duration: RationalTime) {
        self.start = start
        self.duration = duration
    }

    public var end: RationalTime { start + duration }

    public func contains(_ t: RationalTime) -> Bool {
        t.seconds >= start.seconds && t.seconds < end.seconds
    }

    public func overlaps(_ other: TimeRange) -> Bool {
        start.seconds < other.end.seconds && other.start.seconds < end.seconds
    }
}

private func gcd(_ a: Int32, _ b: Int32) -> Int32 {
    var (a, b) = (abs(a), abs(b))
    while b != 0 { (a, b) = (b, a % b) }
    return a
}

private func lcm(_ a: Int32, _ b: Int32) -> Int32 {
    a / gcd(a, b) * b
}
