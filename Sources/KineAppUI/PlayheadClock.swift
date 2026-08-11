import Foundation

/// Carries the high-frequency program playhead position on its own
/// `ObservableObject` so per-frame playback updates don't fire
/// `objectWillChange` on the whole `WorkspaceModel` (which would
/// re-render the entire SwiftUI tree — inspector, bins, viewers — and
/// re-push the timeline every frame, starving the render display link).
/// Only the timecode readout observes this.
@MainActor
public final class PlayheadClock: ObservableObject {
    @Published public var seconds: Double = 0
    public init() {}
}
