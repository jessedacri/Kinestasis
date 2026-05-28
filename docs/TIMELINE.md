# Preem — Timeline editing patterns

Everything that happens between the user's mouse/keyboard and a mutation on `Project.sequences`. Runtime playback architecture is in `COMPOSITOR.md`.

## Tools + keymap

| Key | Action |
|---|---|
| **A** | Pointer tool (default). Click to select, drag to move/trim, drag in empty space for rubber-band select. |
| **B** | Blade tool. Cursor flips to a custom scissors icon. Click on a clip to split that clip (and its linked siblings) at the click position. Click on empty space does nothing. |
| **V** | Cut at playhead — splits every clip across every track that the playhead intersects. |
| **N** | Toggle snapping (`PreemSettings.snappingEnabled`, persisted). |
| **,** / **.** | 3-point insert / overwrite from source viewer (no shift). |
| **<** / **>** (shift+, / shift+.) | Nudge selected clips ±1 frame. Frame-precise, per-clip clamp at t=0, no overlap-finalize so selection IDs persist. |
| **⌘K** | Same as V (split at playhead). |
| **⌘L** | Toggle V/A linking on selection. |
| **⌘D** | Add cross-dissolve at the cut nearest the playhead. |
| **⇧⌘D** | Remove transition at the playhead. |
| **⌘+ / ⌘-** | Zoom timeline (range 4–800 px/s). Trackpad pinch also works. Slider below timeline mirrors. |
| **⌘Z / ⇧⌘Z** | Undo / redo. |
| **⌫ / ⇧⌫** | Delete / ripple-delete selection (clips or gaps). |
| **Space** | Toggle play on focused viewer. |
| **JKL** | Reverse / stop / forward, 1×–4× shuttle. |
| **I / O** | Mark in / out — on the source viewer when it's focused with a clip loaded, otherwise on the program/timeline. |
| **⌥I / ⌥O** | Clear in / clear out on the focused viewer. |
| **⌥X** | Clear both in & out on the focused viewer. |
| **⇧I / ⇧O** | Go to in / out on the focused viewer (seek playhead). |
| **arrows** | Step playhead 1 frame (shift: 10 frames). |
| **⇧⌘5** | Open the Effect Controls inspector for the selected clip(s). |
| **⇧Return** | Render In to Out — bake the marked range to a ProRes 422 LT segment in the per-project cache. |
| **⌘E** | Open the Export Sequence sheet (preset rail + sectioned settings). |

## Pane focus model

Premiere-style: the last pane the user clicked into owns the transport keystrokes (Space / J K L / I O / arrows). Four focusable panes — `bin`, `source`, `program`, `timeline` — each renders an accent stroke around its border while focused. `FocusedViewer` enum lives in `PreemAppUI/FocusedViewer.swift`.

- Bin click selects + loads source but focuses **bin** (not source). The user must click into the source viewer to mark on it; this prevents accidental I/O on source after just picking a clip.
- Timeline NSView's `mouseDown` fires `didReceiveFocus` → `.timeline`.
- Source / program viewers set focus via outer-VStack `onTapGesture`.
- For routing, `.timeline` and `.program` behave identically (both target the active sequence). `.bin` falls through to program for I/O. Only `.source` (with a source clip loaded) targets source marks.

`ActiveTool` enum lives in `PreemTimelineUI/PreemTimelineUI.swift`. `WorkspaceModel.activeTool` is the source of truth; pushed into `PreemTimelineView.activeTool` each `updateNSView`.

## Drag and drop

### Bin → timeline

- Pasteboard string: just `"<uuid>"`.
- `attemptInsertClip` runs on drop. If no active sequence, `createMatchingSequenceForClip` auto-creates one matching the clip's frame rate / resolution / sample rate / channels and drops at `t=0`.
- If the target sequence has different settings, `PendingMismatch` modal asks: match the sequence to the clip / keep mismatched / cancel.

### Source viewer → timeline

- Same pasteboard format, with optional suffix when I/O marks are set: `"<uuid>|<sourceStart>|<duration>"`. Parsed by `PreemTimelineView.DragPayload.parse`.
- Workspace's `attemptInsertClipFragment` honors the sourceStart + duration.

### Drag ghost

`DragGhost: DragGhost?` (private struct in `PreemTimelineView`) holds clip ID + source + start time + duration + `newVideoTracksAbove`. Drawn translucent yellow with a dashed border. Snap targets are the playhead + other clips' edges within 8 pixels (honored only when `snappingEnabled`).

### Phantom tracks above V_top / below A_last

Drag a clip above the topmost video row → a dashed yellow "+ V3" hint appears in a phantom band; on release, `WorkspaceModel.moveSingleClipToTrack` extends `videoTracks` to include the requested index and lands the clip there. Same for audio (drag below the lowest audio row).

Works for both initial bin-drop AND existing-clip drags. `phantomTracksAbove(yInView:)` and `phantomAudioTracksBelow(yInView:in:)` compute the depth; the `MoveTargetTrack.index` ends at `videoTracks.count + depth - 1` (one beyond existing); workspace's `while newIdx >= sequence.videoTracks.count` loop creates the new tracks.

### Drop overwrite

`splitOverlappingClips` slices anything on the destination track that overlaps the new clip's timelineRange. Fully covered → deleted. Straddling → trimmed. Containing → split into left + right with the right half getting a fresh `linkID`.

### Vertical drag between tracks

The model mutates **horizontally** during the drag; `floatingDraggedClip: FloatingDraggedClip?` carries the visual destination so the dragged clip renders on the cursor's row without committing the track change. On `mouseUp`, if the cursor ended on a different track, the move commits (with overwrite on the destination). Cross-kind moves (video → audio row or vice versa) render red and are rejected on release.

**`mouseUp` must subtract `grab` from cursor X** when computing the commit position (same as `mouseDragged`). Don't use `timeForX(p.x)` raw or the clip jumps forward by the cursor-to-clip-start distance.

### Callback timing

`view.callbacks.moveClip` fires synchronously via `MainActor.assumeIsolated`, NOT `Task { @MainActor ... }` — the Task hop introduces a one-runloop delay that produces a flicker frame where the model hasn't caught up to the user's release.

## Snapping

`PreemSettings.shared.snappingEnabled` (Bool, persisted, toggled with N). When on, drags + trims + transition-edge resizes + nudges snap to neighbor clip edges + the playhead within `PreemTimelineView.snapThresholdPixels` (8 px at current zoom).

`PreemTimelineView.snapTime(_:excluding:)` is the single bottleneck. Anything that produces a "target time" from a cursor X should pass through it. Don't roll your own snap.

## Selection types (mutually exclusive)

Three distinct selection types, mutated through dedicated `WorkspaceModel` methods:

| Type | Property | Trigger |
|---|---|---|
| Clip selection | `selectedClipIDs: Set<PlacedClipID>` | Click a clip; shift-click adds. Box-drag in empty space selects intersecting. |
| Gap selection | `selectedGap: GapSelection?` | Click in empty space on a track between clips. |
| Cut selection | `selectedCut: CutSelection?` | Click the small white grip between two abutting clips on the same track. |
| Clip-edge selection | `selectedClipEdge: ClipEdgeSelection?` | Right-click a clip's left or right edge (for "Add Fade In/Out"). |

`WorkspaceModel.select(_:additive:)`, `selectGap(_:)`, `selectCut(_:)`, `selectClipEdge(_:)` each clear the OTHER three when called. `clearSelection()` clears all four.

Visual feedback: selected clips render with a yellow stroke; gaps render with a yellow dashed translucent rect; cuts render with a brighter handle + yellow ring on the wedge if a transition exists; clip edges illuminate on hover (white→brighter, ~3px wide) and stay highlighted yellow when clicked-selected.

## Target tracks (3-point insert / overwrite)

Each video track has a chip displayed next to its name (`V1`, `A1`, etc.) showing which V and which A track receive a 3-point insert (`,`) or overwrite (`.`) from the source viewer. One V and one A are targeted at a time per sequence; clicking anywhere on a lane header (outside the M / S / L buttons) sets that row as the target. Hovering the chip shows the "Source target" tooltip. Defaults: V1 + A1.

Implementation: `VideoTrack.isTargeted: Bool` / `AudioTrack.isTargeted: Bool`. Defaults to `true` on V1 + A1 of new sequences via `Sequence`'s default init args; existing projects without target flags fall back to V1/A1 in `WorkspaceModel.firstTargetedVideoIndex/firstTargetedAudioIndex`. Click handling lives in `PreemTimelineView.mouseDown`'s lane-header fall-through (after the M/S/L button hit test) → `requestSetVideoTarget` / `requestSetAudioTarget` callbacks → `WorkspaceModel.setVideoTarget(at:)` / `setAudioTarget(at:)` (exclusive — sets the chosen index, clears the others).

## In/Out marks (sequence-level)

Each sequence carries `inMark: RationalTime?` / `outMark: RationalTime?` (persisted in the project file). Set with `I` / `O` while the program/timeline is focused — they mark on the sequence. Same keys while the source viewer is focused mark on the loaded source clip instead. `⌥I` / `⌥O` clear individual marks; `⌥X` clears both; `⇧I` / `⇧O` jump the playhead to the marks.

Drawn in the timeline ruler as blue brackets at each mark position with a thin blue band along the top of the ruler between them, plus a faint blue wash across the track band so it's easy to see which clips fall inside the marked region.

In/Out marks drive **Render In to Out** (`⇧Return`) and **Export Sequence**'s "In to Out" range option.

## Pre-render cache + Effect Controls

The bottom of the ruler shows a thin green bar for every pre-rendered segment on the active sequence — these regions skip the realtime compositor and play back directly from the cache `.mov`. The orange "Dropping frames" chip in the program viewer header tells you when realtime is choking and recommends rendering the active range.

Per-clip transforms (position / scale / opacity / rotation / crop) are edited via the **Effect Controls** inspector (`⇧⌘5`) — Premiere-style sliders + numeric inputs. Multi-select aware. Live preview through the realtime compositor; same values bake into renders.

**Direct manipulation in the program viewer**: with a clip selected, a bounding box appears around its picture. Drag the center to move (updates `positionX/Y`). Drag a corner to scale uniformly. One drag = one undo step.

## V/A linking

`PlacedClip.linkID: UUID?` groups V+A halves of a single source clip. Every mutation (`moveClip`, `trimLeft/Right`, `deleteSelected`, `rippleDeleteSelected`, `splitAtPlayhead`, `splitClipAndLinked`, `nudgeSelectedClips`) calls `expandToLinked(_:)` to include linked siblings. Splitting linked clips assigns a fresh shared `linkID` to the right halves so both sides of the cut stay grouped.

`toggleLinkOnSelection` (⌘L) toggles links: if any selected clip is linked, all selected clips get unlinked; otherwise they're grouped under a new shared ID.

**Vertical drag only moves the directly-dragged clip**, not its linked siblings. The siblings stay on their tracks but follow the horizontal motion.

## No same-track overlap invariant

Two clips on the same track never coexist at the same time. Enforced via:

- **Drop**: `splitOverlappingClips` runs in `insertClip` and `moveSingleClipToTrack`.
- **End-of-drag/trim**: `finalizeOverlapsForClip(_:)` on the `endClipDragOrTrim` callback. Pulls the dragged clip out, slices any other clip on the same track(s) that overlaps its range, re-adds the dragged clip. Linked siblings get the same treatment so V/A stays in sync.
- **Nudge is the exception**: deliberately does NOT finalize. The user wanted nudge to be a pure shift that preserves selection IDs end-to-end. If the user nudges into an overlap, the next drag/trim that touches the area will finalize.

## Cut handles + transitions UX

Between any two abutting clips on the same track, `PreemTimelineView` lays out a `LaidOutCut` hit zone (~6 px wide at the boundary). Click to select the cut. Right-click for "Add Transition" / "Remove Transition" using `PreemSettings.defaultTransitionKind` + `defaultTransitionFrames`.

Once a transition exists, the yellow "X" wedge spans `[cutT - leftHalf, cutT + rightHalf]`. The wedge's L and R edges are drag handles — drag to resize asymmetrically. `PreemSettings` defaults are persisted, configurable in the Settings scene.

**Solo fades** on any clip edge: right-click the left edge for "Add Fade In", right-click the right edge for "Add Fade Out". The clip itself draws a yellow triangle (full opacity at the clip edge, tapers to its center-line at the inner tip). The inner tip is a drag handle to resize.

Renderer dispatch for transitions is `WorkspaceModel.activeVideoTransition` — see `COMPOSITOR.md`.

## Undo / redo

`WorkspaceModel.undoStack: [Data]` — JSON-encoded `Project` snapshots. Push before every distinct user action via `pushUndoSnapshot()`. Drag/trim use `beginUndoBatch()` / `endUndoBatch()` so a multi-tick gesture is one undo step. `undoSilenced: Bool` flag is checked in `pushUndoSnapshot` to skip mid-batch snapshots.

`applyRestoredProject(_:)` is the restore path — stops playback, swaps the project, validates `activeSequenceID`, cleans up `selectedClipIDs` of dropped IDs.

**If you add a new mutation method**, call `pushUndoSnapshot()` at the top OR route through `updateSequence` / `insertClip` / `insertClipFragment` / `createSequence` which already do. `updateSequenceWithoutUndo` exists for finalizers that run inside an existing undo batch (e.g. `finalizeOverlapsForClip`).

## Sequence settings + mismatch flow

`Sequence.settings: SequenceSettings` — timebase / resolution / pixel aspect / audio rate / channels. New sequences come from `SequenceSettingsSheet` (Premiere-style preset picker + custom fields).

When a clip is dropped onto an EMPTY sequence whose settings differ, `attemptInsertClip` raises a `PendingMismatch` modal: match the sequence to the clip / keep mismatched / cancel. After the first clip lands, the sequence is "locked" — further drops insert without re-prompting. The auto-create-sequence path bypasses this since the sequence is brand-new.

## Frame quantization

Transition durations + nudge offsets snap to whole frames using the active sequence's fps. Two helpers:

- `WorkspaceModel.quantizeToFrame(_:)` — round seconds to the nearest frame boundary.
- `WorkspaceModel.clampHalf(_:neighborDuration:)` (static nonisolated) — clamp a transition half-duration to `[0.05s, neighborDuration / 2]`.

Sub-frame drift accumulates over many edits if you skip these. Use them on any time mutation that the user can repeat.

## Timeline zoom

`pixelsPerSecond: Double` on `WorkspaceModel`, clamped 4–800. Bound to:

- The slider in `TimelineWithZoomBar` (below the NSView timeline).
- `⌘+` / `⌘-` keyboard shortcuts (`zoomIn()` / `zoomOut()`, 1.5× factor).
- Trackpad pinch via `magnify(with:)` override in `PreemTimelineView` (uses `event.magnification`).
- Pushed into `PreemTimelineView.pixelsPerSecond` each `updateNSView`.

## Preview cache (waveforms + thumbnails)

`PreemMedia.ClipPreviewCache` generates downsampled audio peaks (via `AVAudioFile` chunked read) and evenly-spaced video thumbnails (via `AVAssetImageGenerator`) on background tasks. Cached per source `ClipID`. The timeline view receives flat dictionaries (`audioPeaks: [ClipID: [Float]]`, `videoThumbnails: [ClipID: [CGImage]]`) and slices them by each `PlacedClip`'s `sourceRange`.

Scheduled at ingest time and on project open via `WorkspaceModel.schedulePreviews(for:)`. `previewVersion` is published so SwiftUI re-renders push fresh snapshots into the NSView.

## Layout (NSSplitView)

`PreemSplitView` wraps `NSSplitViewController` with autosave names so divider positions persist across launches. Three nested splits: `preem.root.binVsMain`, `preem.root.viewersVsTimeline`, `preem.viewers.sourceVsProgram`. Holding priorities cap the bin (260) and viewers row (260) so the timeline absorbs extra window height.

Whole app is forced dark via `.preferredColorScheme(.dark)` — video editors live in the dark regardless of system appearance.
