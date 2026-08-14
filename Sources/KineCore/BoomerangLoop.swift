import Foundation

/// Where a boomerang loop turns around: forward through the whole shot,
/// then backward through the interior only, so neither end is doubled and
/// the loop is seamless in both directions.
///
/// The player and the GIF encoder both read this, which is what makes the
/// preview honest. Ramps hold one still across several schedule events, so
/// the ends are runs to be measured, not single events.
public struct BoomerangLoop: Equatable, Sendable {
    /// First frame after the opening still: the return pass stops here.
    public let firstStillEnd: Int64
    /// First frame of the closing still: the return pass starts one before.
    public let lastStillStart: Int64
    /// Length of the whole loop, forward pass plus return pass.
    public let totalFrames: Int64

    /// Nil when there is no interior to mirror (two stills or fewer), which
    /// is exactly when `GIFExporter.boomerangEntries` leaves a shot alone.
    public init?(schedule: [StillEvent]) {
        guard let first = schedule.first, let last = schedule.last else { return nil }

        var distinct = 1
        var previous = first.frameIndex
        for event in schedule.dropFirst() where event.frameIndex != previous {
            distinct += 1
            previous = event.frameIndex
        }
        guard distinct > 2 else { return nil }

        var firstEnd = first.startFrame + first.frameCount
        for event in schedule.dropFirst() {
            guard event.frameIndex == first.frameIndex else { break }
            firstEnd = event.startFrame + event.frameCount
        }
        var lastStart = last.startFrame
        for event in schedule.reversed().dropFirst() {
            guard event.frameIndex == last.frameIndex else { break }
            lastStart = event.startFrame
        }

        let total = last.startFrame + last.frameCount
        firstStillEnd = firstEnd
        lastStillStart = lastStart
        totalFrames = total + max(0, lastStart - firstEnd)
    }
}
