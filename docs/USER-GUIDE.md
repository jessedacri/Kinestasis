# Preem — User Guide

A short, opinionated guide to using Preem. Last updated 2026-05-27. Mirrors the app as of M2 + the M3 portion shipped through that date.

> **What Preem is:** a macOS-native non-linear video editor. Reference NLEs are Premiere Pro, DaVinci Resolve, and Final Cut Pro. If you know any of those, the layout and shortcuts will feel familiar.

---

## Contents

1. [Setting up](#setting-up)
2. [The interface](#the-interface)
3. [The four panes + focus model](#the-four-panes--focus-model)
4. [Importing media](#importing-media)
5. [Creating a sequence](#creating-a-sequence)
6. [Editing on the timeline](#editing-on-the-timeline)
7. [Source viewer — marks + 3-point edits](#source-viewer--marks--3-point-edits)
8. [Target tracks](#target-tracks)
9. [In/Out marks on the timeline](#inout-marks-on-the-timeline)
10. [Transitions](#transitions)
11. [Transforms + Crop (Effect Controls)](#transforms--crop-effect-controls)
12. [Direct manipulation in the program viewer](#direct-manipulation-in-the-program-viewer)
13. [Aspect handling: how Preem treats different source/sequence aspects](#aspect-handling-how-preem-treats-different-sourcesequence-aspects)
14. [Render In to Out — pre-render cache](#render-in-to-out--pre-render-cache)
15. [Export Sequence](#export-sequence)
16. [Saving + project files](#saving--project-files)
17. [Keyboard shortcuts](#keyboard-shortcuts)
18. [Troubleshooting](#troubleshooting)

---

## Setting up

**Requirements:** macOS 14+ on Apple Silicon (Intel is best-effort). Build with `swift build -c release` and launch with `swift run -c release Preem` — release builds enable Metal shader + VideoToolbox optimizations and you'll want them for any real footage work.

There is no installer yet; the app is built from source.

## The interface

```
┌─────────┬──────────────────────────────────────────┐
│         │   Source Viewer    │   Program Viewer    │
│  Bin    ├────────────────────┴─────────────────────┤
│         │                                          │
│         │              Timeline                    │
└─────────┴──────────────────────────────────────────┘
```

- **Bin** (left rail) — your media + sequences.
- **Source Viewer** (upper-middle) — scrub a clip, set in/out marks, drag to timeline.
- **Program Viewer** (upper-right) — what the timeline plays at the playhead. Shows transform handles when a clip is selected.
- **Timeline** (bottom) — your edit. Multiple V/A tracks, marks, transitions, the works.

A thin accent-colored stroke around any pane means it's focused (see next section).

## The four panes + focus model

Preem uses Premiere's focus model. The pane you last clicked into owns the keyboard. The active pane has an accent stroke around it.

- Click in the **Bin** → focuses the bin. Selecting a clip loads it into the source viewer but keeps focus on the bin (so I/O doesn't accidentally mark the source).
- Click in the **Source Viewer** → focuses source. Now `I`, `O`, `Space`, `JKL`, arrows act on the source clip.
- Click in the **Program Viewer** or **Timeline** → focuses program/timeline. `I`, `O`, `Space`, `JKL`, arrows act on the sequence.

This means: to mark on the source clip, click the source viewer first. To mark on the timeline (set the In/Out region for render/export), click the timeline (or program viewer) first.

## Importing media

Drop a file or a folder onto the bin. Preem reads metadata (codec, fps, resolution, timecode, scene/take from slate OCR where possible) and adds it as a clip. Folders ingest recursively. Audio-only files work.

Behind the scenes, slate OCR / shot classification / transcription start in the background — you'll see a small spinner next to clips while they're being analyzed.

## Creating a sequence

`⌘N` opens the **New Sequence** sheet. Pick a preset (HD 1080p 23.976, UHD 4K 23.976, etc.) or enter custom width × height + frame rate + audio sample rate + channels. Confirm.

You can also just drop a clip into an empty workspace — Preem auto-creates a sequence matching the clip's specs. If you then drop a *mismatched* clip into that sequence, Preem asks: match the sequence to the new clip / keep the sequence settings (the new clip will be aspect-fit) / cancel.

## Editing on the timeline

| What you want | How |
|---|---|
| Drag a clip from the bin to the timeline | Drag and drop. Drop above the top video track to auto-create V_n+1; same for audio below A_last. |
| Drag a clip from the source viewer (with marks) | Same — the dragged portion respects your I/O marks. |
| Select a clip | Click. Shift-click to add. Drag across empty timeline space for rubber-band select. |
| Move a clip | Drag it. Vertical movement between tracks is supported; cross-kind (video → audio row) is rejected. |
| Trim a clip's edge | Hover the left/right edge; cursor changes; drag. |
| Cut at the playhead across all tracks | `V` or `⌘K`. |
| Blade tool (cut one specific clip) | `B` — cursor becomes a razor; click the clip where you want to cut. `A` returns to the pointer. |
| Delete selection | `⌫`. |
| Ripple-delete (close the gap) | `⇧⌫`. |
| Nudge selected clips by 1 frame | `<` / `>` (which is `⇧,` / `⇧.`). |
| Toggle snapping | `N`. |
| Link / unlink V+A halves | `⌘L`. |
| Undo / redo | `⌘Z` / `⇧⌘Z`. |
| Zoom timeline | `⌘+` / `⌘-`, or the slider under the timeline, or trackpad pinch. |

Linked V+A clips (a video clip with attached audio) move and trim together by default. `⌘L` unlinks. Splitting a linked clip splits both halves; the right-side halves get a fresh shared link ID.

## Source viewer — marks + 3-point edits

Click a bin clip to load it in the source viewer. Click into the source viewer to focus it. Then:

- `I` → set In at the current scrub position.
- `O` → set Out.
- `,` → insert from source viewer into the timeline at the playhead (ripples downstream clips forward).
- `.` → overwrite at the playhead (replaces what's there).
- Drag from the source viewer's picture area to drop into the timeline at a specific location.

The 3-point edit lands on the **first targeted V and first targeted A** tracks (see next section).

## Target tracks

Each lane header in the timeline has a button cluster (M / S / L) and a row designator (`V1`, `V2`, `A1`, etc.). The currently-targeted V and A tracks each show a small blue chip next to their name. Click anywhere on a lane header (outside the M/S/L buttons) to set that row as the target. Hover the chip — tooltip says "Source target."

Only one V and one A are targeted at a time. Defaults are V1 and A1.

This routes:
- 3-point insert/overwrite from the source viewer.
- (Future) drag-drop fallback when the user doesn't explicitly drop on a track.

## In/Out marks on the timeline

Focus the **timeline** or **program viewer** (so I/O routes to the sequence, not source). Then:

- `I` → set In at the current playhead.
- `O` → set Out.
- `⌥I` / `⌥O` → clear individual marks.
- `⌥X` → clear both.
- `⇧I` / `⇧O` → jump the playhead to In / Out.

Marks render as blue brackets in the ruler with a faint blue wash across the track band so you can see which clips fall in the marked region. They persist with the project.

In/Out drives **Render In to Out** and is one of the range options for **Export**.

## Transitions

**Cross-dissolve between two clips on the same track:**

1. Click the cut (the small grip between the two abutting clips), or just put the playhead on the cut.
2. `⌘D` adds a cross-dissolve centered on the cut. Default duration is set in the Settings scene (Preem → Settings).
3. `⇧⌘D` removes it.
4. Once a transition exists, the yellow wedge in the timeline has drag-handles on its left and right edges — drag to resize the halves asymmetrically.

**Solo fade-in / fade-out on a single clip's edge:**

1. Right-click the clip's left edge → "Add Fade In", or right edge → "Add Fade Out".
2. The clip draws a yellow triangle (full opacity at the clip edge, tapering to its center-line at the inner tip). Drag the inner tip to resize.

Fades and dissolves are alpha-aware:
- A solo fade-in on a clip over an underlying clip (a V2 clip fading in over V1) properly shows the underlying clip through the fade.
- A cross-dissolve between two clips of different source aspects (e.g. a 4:3 clip dissolving to a 16:9 clip) renders each clip at its own aspect — no squishing — with the underlying layer visible in the regions only one clip covers.

## Transforms + Crop (Effect Controls)

Every clip can carry per-clip transforms. Open the **Effect Controls** panel with `⇧⌘5` (or Clip menu → Effect Controls…). Multi-select works — edits apply to all selected clips.

**Transform**
- **Position** — X / Y in normalized sequence-coordinate units. (0, 0) is the center; (1, 0) is one sequence-width to the right.
- **Scale** — X / Y separately, or use the reset button to snap both back to 1.0. 1.0 = aspect-preserving fit baseline.
- **Opacity** — slider 0–100%.
- **Rotation** — degrees.
- **Fill Mode** — Aspect Fit (default; never stretches) or Stretch to Fill (only path that allows non-uniform scaling; user opt-in only).

**Crop**
- T / R / B / L sliders, 0–90% from each side of the source. Crops happen *before* aspect-fit, so the cropped result re-fits into the sequence.

All transforms are live — you see them through the realtime compositor *and* they bake into renders and exports identically.

## Direct manipulation in the program viewer

When a clip is selected and visible at the playhead:
- A bounding box stroked in accent color appears around it.
- **Drag the picture body** to move the clip (updates Position).
- **Drag a corner handle** to scale uniformly around the rect's center (updates Scale X + Y together).

Each drag is one undo step (`⌘Z` rolls back the whole drag).

## Aspect handling: how Preem treats different source/sequence aspects

Preem **never auto-stretches**. Footage outside its native aspect ratio is always shown:
- letterboxed (black bars top + bottom) if the source is wider than the destination,
- pillarboxed (black bars left + right) if it's taller,
- centered + scale-to-fit if aspects match.

This applies in three places, and they all use the same math so what you see is what you get:
1. **In the sequence** — when a 4:3 clip is placed in a 16:9 sequence, the clip pillarboxes inside the sequence frame.
2. **In the program viewer** — when the sequence aspect doesn't match the viewer pane's aspect, the sequence picture letterboxes inside the viewer.
3. **In the render / export** — same math; the rendered `.mov` contains the sequence with all clips properly fit.

The only way to get non-aspect-preserving scaling is to explicitly set **Fill Mode → Stretch to Fill** on a clip's Transform.

## Render In to Out — pre-render cache

When the realtime compositor can't keep up (heavy stacks of layers, large source codecs, big sequences), the program viewer shows a small orange chip in its header: **"Dropping frames · Render In to Out for smooth playback."**

Set your In and Out around the heavy section. Press `⇧Return` (or Sequence menu → Render In to Out). A progress chip appears: *Rendering 13%*, *Rendering 47%*, etc.

When done:
- A green bar appears in the timeline ruler showing the rendered range.
- Playback in that range uses the cache `.mov` directly — no compositing cost. Smooth as butter.
- The cache lives at `~/Library/Caches/Preem/projects/<project-uuid>/prerender/`.

The cache is invalidated automatically the moment you touch a clip in the rendered range (move, trim, delete, change a transition, etc.). The green bar disappears; re-render when you're ready.

## Export Sequence

`⌘E` opens the export sheet. Left rail = preset library; right side = editable settings.

**Presets (left rail)**

- **Web & Social**: YouTube 4K, YouTube 1080p, Vimeo 1080p, Apple Devices 1080p (HEVC), Apple Devices 4K (HEVC).
- **Professional**: ProRes 422 Proxy / LT / 422 / HQ / 4444 (matches sequence resolution + PCM audio).
- **Audio Only**: WAV 48 kHz/24-bit, AIFF 48 kHz/24-bit, AAC 320 kbps, AAC 256 kbps.

Click a preset to hydrate the form; you're free to override any field afterward.

**Right side — sections**

- **Format**: pick a codec (H.264, HEVC, all ProRes variants, or Audio Only sentinel).
- **Video** (hidden for Audio Only):
  - Resolution: Match Sequence / 4K UHD / 1080p / 720p / 480p / Custom (W × H with aspect lock toggle).
  - Frame Rate: Match Sequence or any standard rate.
  - Target + Maximum Bitrate (H.264 / HEVC only) in Mbps.
  - Profile (H.264 only): Baseline / Main / High / High 10 / High 4:2:2.
  - Keyframe interval in frames.
- **Audio**:
  - Include Audio toggle (for video+audio MOV exports).
  - Codec: PCM or AAC for video containers; WAV / AIFF / AAC for audio-only.
  - Sample Rate: Match Sequence / 48 kHz / 44.1 kHz / 32 kHz.
  - Channels: Mono / Stereo.
  - AAC bitrate: 96 / 128 / 192 / 256 / 320 kbps.
- **Output**:
  - Range: In to Out / Whole Sequence.

The footer shows an estimated file size (live) and Cancel / Export buttons. Hit **Export** — a save panel asks where to put the file. The same encoder that backs Render In to Out runs the job. Progress is shown in the program viewer header. Resulting file plays in QuickTime / Premiere / Resolve etc.

## Saving + project files

- `⌘S` — save the current project (`.preem` file).
- `⇧⌘S` — Save As…
- `⌘O` — open a `.preem`.
- `⇧⌘N` — new project (closes current).
- `⌘N` — new sequence in the current project.

The `.preem` is a JSON document today. Pre-render caches live separately under `~/Library/Caches/Preem/projects/<id>/`, so opening a `.preem` from a different machine works fine — you'll just need to re-render any cached segments you want.

Autosave runs every 60 seconds while the project is dirty. Recovery files live in `~/Library/Caches/Preem/autosave/`.

## Keyboard shortcuts

**Transport**
| Key | Action |
|---|---|
| `Space` | Toggle play on focused viewer |
| `J` / `K` / `L` | Reverse / stop / forward; tap L/J again for 2×, 3×, 4× shuttle |
| Arrows | ±1 frame; Shift + arrows = ±10 frames |
| Home / End | Jump to sequence start / end |

**Editing**
| Key | Action |
|---|---|
| `A` | Pointer tool |
| `B` | Blade tool |
| `V` or `⌘K` | Cut at playhead across all tracks |
| `N` | Toggle snapping |
| `,` / `.` | 3-point insert / overwrite from source viewer |
| `<` / `>` | Nudge selected clips ±1 frame |
| `⌘L` | Toggle V/A linking on selection |
| `⌘D` | Add cross-dissolve at the cut nearest the playhead |
| `⇧⌘D` | Remove transition at the playhead |
| `⌫` / `⇧⌫` | Delete / ripple-delete selection |
| `⌘Z` / `⇧⌘Z` | Undo / redo |
| `⌘+` / `⌘-` | Zoom timeline |

**Marking**
| Key | Action |
|---|---|
| `I` / `O` | Mark in / out on focused viewer (source clip if source is focused, else sequence) |
| `⌥I` / `⌥O` | Clear in / clear out |
| `⌥X` | Clear both |
| `⇧I` / `⇧O` | Go to in / out (seek the playhead) |

**Sequence + render**
| Key | Action |
|---|---|
| `⇧Return` | Render In to Out (bake the marked range to the cache) |
| `⌘E` | Export Sequence… |
| `⇧⌘5` | Show Effect Controls for the selected clip(s) |
| `⇧⌘E` | Export FCPXML (round-trip the timeline to Premiere/Resolve/FCP) |

**File**
| Key | Action |
|---|---|
| `⌘N` | New Sequence |
| `⇧⌘N` | New Project |
| `⌘O` | Open Project |
| `⌘S` | Save |
| `⇧⌘S` | Save As |

## Troubleshooting

**The program viewer plays back at wrong speed.**
Check the debug log at `/tmp/preem-debug.log` for `[Realtime]` entries. If you see runaway speed, that's a frame-cache bug — should be fixed since 2026-05-27. Restart the app; if it persists, open an issue with reproduction steps.

**"Dropping frames" chip is always on.**
The realtime compositor can't keep up with your current sequence. Render In to Out around the heavy region (`⇧Return`) — playback uses the cache after that. Proxy pipeline is on the roadmap for big sources.

**Render In to Out / Export stalls partway through and never finishes.**
Check `/tmp/preem-debug.log` for `[Encoder]` heartbeats — they print every 30 frames with the current fps. If they stop, the writer is probably wedged. Restart, try a smaller range, or pick ProRes (which uses a different encoder path than H.264).

**Colors look wrong / picture is stretched.**
Check the clip's **Effect Controls** → **Fill Mode**. If it's set to "Stretch to Fill," the clip will warp to match the sequence aspect — switch back to "Aspect Fit" for native aspect with letterbox/pillarbox bars.

**A `.preem` from another Mac shows green bars but black playback in cached regions.**
The cache is local — it doesn't move with the `.preem` across machines. Re-render the marked regions.

**The picture in the program viewer is letterboxed but I want it to fill the viewer.**
Resize the program viewer pane to match the sequence aspect, or resize the window. Preem will never auto-stretch — that's a deliberate design choice.

**Source viewer plays but timeline playback is silent.**
Focus is probably still on the source viewer (it has an accent stroke around it). Click into the timeline / program viewer to switch focus, then `Space` plays the sequence.

**Recover a project after a crash.**
Look in `~/Library/Caches/Preem/autosave/` — autosave runs every 60 seconds. The file there has the same name as your project's internal UUID.

---

If you want to know more about *how* Preem works under the hood, see `docs/ARCHITECTURE.md` and `docs/COMPOSITOR.md`. For developers contributing to Preem, see `CLAUDE.md` and `docs/HANDOFF.md`.
