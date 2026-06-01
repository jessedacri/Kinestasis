# Preem — Media Browser (Bin), Skimming & Favorites

FCP-style media browser. Last updated 2026-05-29. Pairs with `COMPOSITOR.md` (program playback/render runtime), `TIMELINE.md` (editing), `HANDOFF.md` (session state).

## What this is

The bin is a Final Cut Pro–style browser, not a Premiere list. Master clips render as horizontal **filmstrips** you can **skim** (move the mouse across → live in the Source viewer, no click, no play). You mark In/Out on the skimmer and press **F** to save the selection as a **favorite** — a sub-range "subclip." Many favorites per clip; a filter pulls them into their own draggable rows.

The headline design decision: **skim/scrub/paused display is served by a fast still-frame generator; the heavy playback decoder (PPE) is used only while playing.** This is how FCP gets smooth skim without proxies, and it's all on the Apple Silicon media engines (see "Hardware" below).

## User-facing behavior

- **Skim** — mouse across a filmstrip → that frame shows live in the Source viewer; a white skimmer line tracks the cursor. Hovering hands transport focus to the Source viewer, so Space / J-K-L / I-O / F act on the skimmed clip.
- **Click** a clip → loads it into the Source viewer (resets playhead/marks).
- **I / O** → mark In/Out on the skimmed/loaded clip; the selection draws as an accent band on the filmstrip. ⌥I/⌥O clear; ⌥X clears both.
- **F** → favorite the current In/Out selection (full clip if unmarked). Marks clear afterward so the next favorite starts fresh. Favorites draw as yellow bands + a ★count badge on the parent filmstrip.
- **Filter** (header toggle `All` / `★ Favorites`) → the Favorites view lists every favorite across all clips as its own filmstrip sub-row: skimmable, draggable to the timeline (payload `clipID|start|dur`), right-click → Remove Favorite.
- **Space / J-K-L** → play/shuttle the skimmed/loaded clip in the Source viewer.

## Source-viewer display: still vs. player

The Source viewer composites two layers in a ZStack (`ViewerPane.sourceBody`):

1. **`SourceStillView`** (top) — a layer-backed `NSView` whose `layer.contents` is a `CGImage` from `SkimFrameProvider`. Used for skim/scrub/paused and to cover PPE's cold spin-up. Never black: `bestAvailable` returns exact-cached → nearest-cached → nearest low-res thumbnail synchronously, then upgrades to the sharp decode.
2. **`SourcePPEHost`** (bottom) — the PPE Metal player. **Persistent** (mounted whenever a video clip is loaded), driven (decodes) **only while playing**.

### The state machine (load-bearing — don't regress)

Visibility is driven by `workspace.sourceIsPlaying`, `workspace.sourcePlaybackReady`, and a view-local `showStillWhenPaused`:

| State | What the user sees | Mechanism |
|---|---|---|
| **Paused, just stopped** | PPE frozen on its exact last frame | `showStillWhenPaused=false` → still hidden, PPE opacity 1. PPE holds `lastDrawnFrame`. No still pop. |
| **Paused, skimming/scrubbing** | Still (generator) | moving the playhead flips `showStillWhenPaused=true`; still on top, PPE hidden. |
| **Playing (resumed from frozen pause)** | PPE, immediately | warm: PPE has the frame + buffered queue → `sourcePlaybackReady=true` at once, no hold. |
| **Playing (started after skim)** | Still held, then PPE | cold: `sourcePlaybackReady=false`, still held over PPE's seek until PPE reaches the target frame. |

Transitions (`ViewerPane.onChange`):
- **Play start:** if `showStillWhenPaused` (still was visible → PPE must load/seek) hold the still (`ready=false`, 0.8s safety fallback). Else (PPE was frozen, warm) reveal immediately (`ready=true`).
- **Pause:** `showStillWhenPaused=false`, capture `pauseBaseline=sourceTimeSeconds`. PPE freezes.
- **Time change while paused:** any `sourceTimeSeconds != pauseBaseline` → `showStillWhenPaused=true` (skim took over).

### Two PPE invariants this relies on

1. **Push is gated to playback** (`SourcePPEHost.Coordinator.push`): `player.update` is only called while `isPlaying` (plus once on the play→stop transition to freeze). While paused we never feed new times — otherwise every skim/scrub tick would re-seed the `AVAssetReader` (the original lag/black-frame bug). The frozen frame survives because stop doesn't bump `generation`, so the renderer keeps drawing `lastDrawnFrame`.
2. **Reveal is gated on reaching the target** (`PPEMetalRenderer.onFirstFrameAfterReset`): the renderer fires this one-shot only when a post-reset frame's `pts ≈ currentVideoLocalSeconds()`. Without the target gate, the **reverse-lookahead seek** (decoder lands ~1.25s before the target so reverse-scrub has frames ready) would reveal the player ~1.25s early and flash that area before catch-up.

## SkimFrameProvider (`PreemMedia/SkimFrameProvider.swift`)

Fast still-frame source. `@MainActor`.

- One reused `AVAssetImageGenerator` at a time (random-access friendly, async, cancelable — `AVAssetReader` can't seek). Swapping clips cancels the prior clip's in-flight decode.
- **Coalescing:** `cancelAllCGImageGeneration()` + a monotonic `token` so rapid skim runs ~1 active decode and only the latest result is delivered.
- **Cache:** LRU `CGImage` cache (256 frames, 0.05s buckets) → re-visited positions are instant.
- `maximumSize` height 720, tolerance 0.12s — snappy; the thumbnail seed covers the decode gap.
- Lives on `WorkspaceModel.skimProvider`; cleared with `previewCache` on project/pool change.

Filmstrip thumbnails reuse the existing `ClipPreviewCache` (24 evenly-spaced frames per clip), not a new generator.

## Favorites data model (`PreemCore/MediaPool.swift`)

```
FavoriteRange { id: UUID, range: TimeRange, name: String?, rating: .favorite | .rejected }
ClipSource.favorites: [FavoriteRange]
```

- `ClipSource` has a **custom `init(from:)`** that `decodeIfPresent`s `favorites` (→ `[]`) so projects saved before favorites still load. Covered by `Tests/PreemCoreTests/FavoriteRangeTests.swift` (round-trip + missing-key back-compat).
- `RationalTime(seconds:scale:)` convenience (scale defaults to 600) builds favorite ranges from the Double-valued source marks.
- Workspace helpers (`WorkspaceModel`): `favoriteSourceSelection(rating:)`, `removeFavorite(_:from:)`, `renameFavorite(_:in:to:)`, `updateClipSource` (mutates the pool + keeps the published `sourceClip` copy in sync).

## Transport / marks routing

- `WorkspaceModel.sourceMarksActive` = source clip present AND (`focusedViewer == .source` || `.bin`). Drives I/O/F routing in the key monitor (`PreemAppUI.swift`).
- Hovering a filmstrip sets `focusedViewer = .source`, so Space / J-K-L / I-O / F all target the skimmed clip.
- `skimSource(to:seconds:)` sets the source clip (no reset) + playhead; `loadSourceClip(_:)` is the only path that resets playhead/marks/playback (click/double-click).

## Hardware

Both decode paths already use the Apple Silicon media engines: `AVAssetReader` wraps a hardware VTDecompressionSession with Metal-compatible output; `AVAssetImageGenerator` is hardware-accelerated too. The skim bottleneck was never decode horsepower — it was `AVAssetReader`'s rebuild-per-seek (no random access). Proxies are **not** required for smooth skim; they'd only be a "nice to have" for the sharp-frame decode on very heavy 4K.

## Key files

- `PreemAppUI/BinBrowserView.swift` — `FilmstripClipRow`, `FavoriteClipRow`, `Filmstrip` (Canvas), `WaveformStrip`, filter toggle, skim hover.
- `PreemAppUI/ViewerPane.swift` — Source pane, the still/PPE state machine, `SourceStillView`/`StillLayerView`, `SourcePPEHost` (persistent, gated push, `onFirstFrame`).
- `PreemMedia/SkimFrameProvider.swift` — fast still-frame generator.
- `PolymergePlayback/PPE/PPEMetalRenderer.swift` — `onFirstFrameAfterReset` (target-gated).
- `PreemCore/MediaPool.swift` — `FavoriteRange`, `ClipSource.favorites`, custom decode.
- `PreemAppUI/WorkspaceModel.swift` — `skimProvider`, `skimSource`/`loadSourceClip`, favorites helpers, `sourceMarksActive`, `binFilter`, source playhead tick (`sourceTick`).
- `PreemAppUI/PreemAppUI.swift` — I/O/F key routing.
- `PreemAppUI/FocusedViewer.swift` — `BinFilter`.

## Current state

Working and feels good: filmstrip skim (instant, no black, hardware-decoded), In/Out + F favorites, Favorites filter + drag-to-timeline, and clean play/pause/skim transitions (no still pop, no cold-start flash, no reverse-seek flash, instant warm resume).

## Backlog — fleshing out the bin

- **Folders / bins.** `BinItem.bin` nesting exists in the model but the UI is flat. Real sub-bins + smart collections (filter by rating/keyword) are the next structural step.
- **Reject rating + keywords.** `FavoriteRange.Rating.rejected` exists but has no key binding/UI (FCP: Delete on a selection = reject). Keywords aren't modeled yet.
- **Source playback doesn't advance the scrub bar / filmstrip line** during *playback* — `sourceTick` updates `sourceTimeSeconds`, but verify the bar/line track it during play (skim/pause are fine).
- **Skim sharpness on heavy 4K** — sharp decode capped at 720px / 0.12s tolerance; tunable. Proxies optional.
- **Favorite editing** — rename UI, drag favorite edges to adjust range, reorder.
- **Sort / search** in the bin; column/metadata views; multi-clip selection.
- **Skim audio** (FCP plays scrub audio) — currently video-only skim.
- **Persistent skim host across clips** — `SkimFrameProvider` already persists the cache; PPE remount on clip switch only affects playback now (low priority).
