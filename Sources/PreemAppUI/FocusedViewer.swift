import Foundation

/// Which pane currently captures transport keystrokes (space, J/K/L,
/// arrows, I/O). Premiere-style — the last pane the user clicked into
/// owns the keys. The first click anywhere in a pane focuses it.
///
/// - `.source` — source viewer (transport + I/O acts on source clip).
/// - `.program` — program viewer (transport + I/O acts on the active sequence).
/// - `.timeline` — timeline NSView (same routing as `.program`; distinct
///   so the focus stroke can highlight the timeline specifically).
/// - `.bin` — bin browser (no transport; I/O falls back to program).
public enum FocusedViewer: Sendable {
    case source
    case program
    case timeline
    case bin

    /// True when the source viewer specifically owns I/O + transport.
    public var isSource: Bool { self == .source }
}

/// Which subview the Source pane is currently showing. Premiere-style
/// tabs: the same pane region hosts either the source clip viewer or
/// the Effect Controls inspector for the timeline selection.
public enum SourcePaneTab: Sendable, Equatable {
    case source
    case effectControls
}
