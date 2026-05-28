// Module umbrella file for PreemTimelineUI. The concrete timeline view
// lives in PreemTimelineView.swift; placeholders for future tools
// (BladeTool, SelectTool, PenTool) will land alongside it.

import Foundation
import PreemCore

/// A selected gap on a specific track. Mutually exclusive with clip
/// selection — selecting a gap clears the clip selection and vice
/// versa. Used by the gap-ripple-delete flow: click in empty space,
/// hit Delete, all tracks shift left by `duration` to close the hole.
public struct GapSelection: Equatable, Sendable {
    /// 0 = video, 1 = audio. Matches `PreemTimelineView.MoveTargetTrack.kind`.
    public var trackKind: Int
    /// Index into the track-kind's array (0-based).
    public var trackIndex: Int
    /// Gap start time on the sequence timeline, in seconds.
    public var startSeconds: Double
    /// Gap length, in seconds. Always positive.
    public var durationSeconds: Double

    public var endSeconds: Double { startSeconds + durationSeconds }

    public init(trackKind: Int, trackIndex: Int, startSeconds: Double, durationSeconds: Double) {
        self.trackKind = trackKind
        self.trackIndex = trackIndex
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
    }
}

/// A selected cut between two abutting clips on a single track. Used to
/// drive the right-click "Add Transition" menu and the transition edge
/// drag handles. Mutually exclusive with clip + gap selection.
public struct CutSelection: Equatable, Sendable {
    public var trackKind: Int           // 0 = video, 1 = audio
    public var trackIndex: Int
    public var cutSeconds: Double
    public var leftClipID: PlacedClipID
    public var rightClipID: PlacedClipID

    public init(trackKind: Int, trackIndex: Int, cutSeconds: Double, leftClipID: PlacedClipID, rightClipID: PlacedClipID) {
        self.trackKind = trackKind
        self.trackIndex = trackIndex
        self.cutSeconds = cutSeconds
        self.leftClipID = leftClipID
        self.rightClipID = rightClipID
    }
}

/// Which timeline tool is active. Drives PreemTimelineView's mouseDown
/// dispatch: pointer = select / drag / trim; blade = click-to-split at
/// the click position. Premiere-style A/B keyboard shortcuts toggle.
public enum ActiveTool: String, Sendable {
    case pointer
    case blade
}

/// A selected edge of a single clip (the in point or the out point).
/// Drives the right-click "Add Fade" menu and the solo-fade edge drag.
/// Mutually exclusive with all other selection types.
public struct ClipEdgeSelection: Equatable, Sendable {
    public enum Side: Int, Sendable { case left = 0, right = 1 }
    public var clipID: PlacedClipID
    public var trackKind: Int
    public var trackIndex: Int
    public var side: Side

    public init(clipID: PlacedClipID, trackKind: Int, trackIndex: Int, side: Side) {
        self.clipID = clipID
        self.trackKind = trackKind
        self.trackIndex = trackIndex
        self.side = side
    }
}
