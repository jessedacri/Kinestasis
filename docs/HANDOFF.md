# Preem — Handoff Notes

Snapshot for the next session. Last updated 2026-05-29. Pairs with `CLAUDE.md` (developer guide), `ARCHITECTURE.md` (load-bearing decisions), `TIMELINE.md` (editing patterns), `BROWSER.md` (bin / skimming / favorites), `COMPOSITOR.md` (playback + render runtime), `ROADMAP.md` (milestones), `APPLE-SILICON.md` (API matrix).

## Where things stand

**M1 + M2 are functionally complete.** Big M3 chunks landed across the 2026-05-26 → 2026-05-28 push: pre-render + Export, unified realtime compositor, Transform/Crop, alpha-aware cross-dissolves — see prior HANDOFF entries (in git) for the May 26/27 details.

**2026-05-29:** playback chop is **solved** (frame-boundary source sampling — see that section below) and the live path is now frame-accurate WYSIWYG. A full cleanliness/perf audit also shipped (see 2026-05-28 sections). All of it is on the `audit/cleanup-and-perf` branch — **merge to `main` next.** Two clearly-scoped follow-ups remain (pre-render cache reader stall; overlap-aware keying).

**The 2026-05-28 push (this session) shipped:**

- **Keyframes on Transform / Crop** — full vertical slice. Schema (`Sources/PreemCore/Sequence.swift`) already had `ParameterValue.keyframed([Keyframe])`; this push wired it end-to-end.
  - `PlacedClip.transform(at: clipLocalSeconds)` samples per-frame at clip-local time (so keyframes ride along through slip/ripple).
  - `sampleDouble` (`Sources/PreemCore/ClipTransform.swift`) handles linear, hold, easeIn, easeOut, and bezier — cubic Hermite with end-keyframe-aware tangents. `Interpolation` enum has `.easeIn` / `.easeOut` added (backward-compatible with already-saved `.bezier`).
  - **Premiere semantics**: when sampling segment A→B, A.interpolation drives the OUT side (slow start when easeOut/bezier), B.interpolation drives the IN side (slow end when easeIn/bezier). Right-click END keyframe → Ease In → curve decelerates into it.
  - Compositor (`OfflineSequenceCompositor.layerUniforms`) and cross-dissolve pull clip-local times for each clip.
- **Effect Controls as a Source-pane tab** (no more `⇧⌘5` modal sheet). `SourcePaneTab.{source, effectControls}` on `WorkspaceModel`. `⇧⌘5` flips to the tab and focuses the source pane. The inspector is `EffectControlsContent` inside `ViewerPane`, live-coupled to the Program viewer through workspace.
- **Per-parameter inspector + stopwatches.** Sliders write per-param (`workspace.setTransformParameterOnSelection`) so paired params like ScaleX/Y don't trample each other. Each row has a Premiere-style stopwatch toggle that creates/collapses keyframes at the playhead. Reset, Scale-lock (chain icon), Rotation slider + degrees field + reset-to-0°.
- **Keyframe strip** (bottom of inspector) with diamond markers per keyframed param, drag-to-retime, double-click to delete, right-click → interpolation menu (`Linear / Hold / Ease In / Ease Out / Ease In/Out` + Delete). Diamond SHAPES distinguish modes (filled diamond, square for hold, half-diamond for easeIn/easeOut, outlined for bezier). Strip has +/- zoom (50× max) + Fit, bigger hit targets (22 px contentShape over 10 px visual), and uses a lightweight `moveKeyframeLight` drag path that skips cache/audio invalidation per tick.
- **Scale display in %** with chain-link X/Y lock (default ON). Underlying schema still stores multiplier (1.0 = 100%). Reset (↺) snaps both axes to 100%.
- **Crop decoupled from aspect-fit.** Previously cropping the top of a 16:9 source pillarboxed the picture; now destRect = full-source aspect-fit, cropRect just trims sample regions inside it. T/R/B/L are independent. Auto-feather only on edges with non-zero crop (Premiere model).
- **Rotation pixel-aspect fix.** Shader's rotation now uses the destRect's PIXEL aspect (passed via `rotation.z`) so a square stays square; previously rotation squished the picture because the aspect math used UV ratios.
- **On-canvas direct manipulation finished.** `ProgramTransformOverlay`:
  - Outer bounding box = full picture rect; dashed inner stroke = visible-after-crop area.
  - Corner handles = uniform scale (existing).
  - Edge handles (T/R/B/L) = non-uniform scaleX / scaleY.
  - Rotation grip = small knob 22 px above the top edge, drag to rotate around picture center.
  - All write through `setTransformParameter…`, so dragging on-canvas with a stopwatch ON writes keyframes at the playhead.
- **App lifecycle (Final Cut style).**
  - Window close button (red X / ⌘W) HIDES the window; app stays alive.
  - Dock-icon click re-shows the hidden window (`applicationShouldHandleReopen`).
  - Window frame autosaved (`preem.main.window`) so size+position survive relaunches.
  - ⌘Q with unsaved changes → Save / Cancel / Discard alert. Save routes through `workspace.save()` and only quits if it actually completed.
  - `WorkspaceModel.current` static weak handle so AppDelegate can read `isDirty` without runtime singleton plumbing.
- **Foolproof transition delete.**
  - Click ANY part of the cross-dissolve wedge or solo-fade triangle to select it (was: only 4-6 px edge grips + narrow cut handle).
  - Delete / Backspace removes a selected cut or edge (checked AFTER clip selection, BEFORE gap selection).
  - Selected wedge gets a stronger fill (55% vs 18%) and a 2 px outline.
- **Title bar shows project name correctly.** Root cause: `saveAs` set `project.name` AFTER `performSave`, so the saved file persisted "Untitled" forever. Fixed by reordering + a defensive `loaded.name = url.deletingPathExtension().lastPathComponent` fallback in `performOpen` for files saved before the fix.
- **Drop chip — never shifts the picture.** Lives in a fixed-height (28 px) header HStack. Mitigations to the drop-detection logic:
  - Nil drawables no longer count as drops (window hidden ≠ render miss — was making the chip stick ON after restore).
  - `consecutiveDrops` capped at 12, decays by 2 per good tick.
  - Hysteresis: chip turns ON at 6 sustained drops, OFF below 3.
  - `realtimeIsDropping` is only written when the value actually changes — was firing a SwiftUI re-render per display-link tick.
- **Audio-linked siblings filtered from transform ops.** `WorkspaceModel.selectedVideoClipIDs` skips audio-track residents. Selecting a V+A pair now reads as one selection in the keyframe strip; multi-set transform/keyframe writes only touch video clips (audio can't carry Transform/Crop anyway).
- **Custom slim chrome.**
  - `Sources/PreemAppUI/ThinSlider.swift` — SwiftUI-native, 3 px pill track, 4×12 vertical-pill thumb (grows to 6×16 on hover/drag). Replaces SwiftUI's chunky `Slider` on Opacity, Rotation, Crop sliders, and the timeline zoom slider.
  - `Sources/PreemAppUI/ThinScrollView.swift` — NSScrollView wrapper with `ThinScroller` (NSScroller subclass): legacy style + `autohidesScrollers=false` so the bar always shows when content overflows, 10 px channel, 5 px white pill knob over a 3 px dark track. Ignores macOS "Show scroll bars" system preference. Used by the keyframe strip; reusable anywhere.
- **Critical bug — stale compositor sequence — fixed.** `OfflineSequenceCompositor` previously stored `let sequence` snapshotted at construction; the realtime host only rebuilt the compositor when `(sequenceID, width, height)` changed, so transform edits never reached the realtime path. Made `sequence` and `mediaPool` `var`; `ensureCompositorMatchesSequence` now pushes fresh snapshots every tick when the spec is unchanged (safe under the host's `inFlight` guard).

The app is a real NLE: import → cut → trim → blade → ripple-delete → drag-between-tracks → fade in/out → cross-dissolve → animate transforms with keyframes (linear/hold/easeIn/easeOut/bezier) → render In to Out → export to ProRes/H.264/HEVC.

## How to read this codebase

Order:

1. `CLAUDE.md` — tech stack, module layout, build commands, conventions.
2. `ARCHITECTURE.md` — data model, module dependency graph, project-file format.
3. `TIMELINE.md` — every user-facing editing pattern: tools, keymap, drag/drop, snapping, selection types, V/A linking, no-overlap invariant, undo batching, frame quantization, zoom, preview cache, focus model, In/Out marks.
4. `BROWSER.md` — FCP-style bin: filmstrip skimming, still-vs-PPE source viewer state machine, `SkimFrameProvider`, favorites/subclips + filter, transport/marks routing.
5. `COLOR.md` — Lumetri-style grading: Basic Correction + Curves, the color-managed per-layer compositor pipeline, `ColorGrade` model, color-management roadmap.
6. `COMPOSITOR.md` — runtime architecture: playback state machine, audio pipelines, **realtime compositor**, transitions (cross-dissolve + solo fade), pre-render cache, transform/crop, keyframe sampling, timecode.
7. `ROADMAP.md` — what's in M1 → M6+.
8. `APPLE-SILICON.md` — which Apple API for which job, and why.

## 2026-05-29 (second push) — FCP-style filmstrip bin + skimming + favorites (DONE)

The bin is now an FCP-style media browser. Shipped this session:

- **Filmstrip rows.** `BinBrowserView` master clips render as horizontal filmstrips (`FilmstripClipRow` → `Filmstrip`, a `Canvas` that tiles the existing `ClipPreviewCache` thumbnails edge-to-edge at the source's natural aspect; audio-only clips get a `WaveformStrip`). The compact text `ClipRow` is gone. Thumbnails reuse `previewCache.ensureThumbnails` (kicked on `.onAppear`) and re-render off `previewVersion`.
- **Skim.** `.onContinuousHover` over a filmstrip maps cursor-x → fraction → `workspace.skimSource(to:seconds:)`, which sets `sourceClip` (if changed) + `sourceTimeSeconds` WITHOUT the load reset, so the Source viewer follows the cursor live. A white skimmer line on the active row reflects `sourceTimeSeconds`. The old passive `ViewerPane.onChange(of: clip?.id)` reset was removed; clicking a clip now goes through `workspace.loadSourceClip(_:)` (the only path that resets playhead/marks/playback).
- **Mark In/Out on the skimmer.** `sourceMarksActive` is true when the source viewer OR the bin is focused with a `sourceClip` — so I/O (and ⌥I/⌥O clear, ⌥X clear-both) now mark the skimmed bin clip, not just the source viewer. The In/Out selection draws as an accent band on the active filmstrip.
- **F = favorite the selection.** New `f`/`F` key → `workspace.favoriteSourceSelection()` creates a `FavoriteRange` (subclip) from the current In/Out (full clip if unmarked) and clears the marks so the next one starts fresh. Many favorites per clip. Favorites draw as yellow bands on the parent filmstrip + a ★count badge.
- **Favorites filter.** Header toggle (`All` / `★ Favorites`, bound to `workspace.binFilter: BinFilter`). The Favorites view lists every favorite across all clips as its own `FavoriteClipRow` — a sub-range filmstrip you can skim, drag to the timeline (payload `clipID|start|dur`, same as a marked source drag), or right-click → Remove Favorite.

**Data model:** `PreemCore/MediaPool.swift` gained `FavoriteRange` (`id`, `range: TimeRange`, `name`, `rating: .favorite|.rejected`) and `ClipSource.favorites: [FavoriteRange]`. ClipSource got a **custom `init(from:)`** that `decodeIfPresent`s `favorites` (→ `[]`) so projects saved before favorites still load — covered by `Tests/PreemCoreTests/FavoriteRangeTests.swift` (round-trip + missing-key back-compat). `RationalTime(seconds:scale:)` convenience added (scale defaults to 600).

**Verified:** debug + release builds clean; 30 unit tests pass; app smoke-launches without crash. **Interactive skim/favorite gestures were NOT manually tested with footage** — that's the first thing to confirm next session (skim a 4K clip, mark In/Out, press F, flip to the Favorites filter, drag a favorite to the timeline).

### Skim performance — decoupled from the playback decoder (2026-05-29, follow-up)

First cut drove skimming through the PPE playback decoder (`CustomVideoPlayer` → `AVAssetReader`), which is built for *sequential* decode: every hover tick re-seeded the reader and the cold reader showed black on first hover. Fixed by reserving PPE for actual playback and serving skim/scrub/paused frames from a fast still generator:

- **`PreemMedia/SkimFrameProvider.swift`** — a single reused `AVAssetImageGenerator` (random-access friendly, async, cancelable), request coalescing (`cancelAllCGImageGeneration` + a monotonic token so only the latest decode is delivered), an LRU `CGImage` cache (256 frames, 0.05s buckets), and `bestAvailable(...)` which returns the exact cached frame → nearest cached → **nearest low-res thumbnail** so the viewer is never black. `maximumSize` height 720, tolerance 0.12s for snappy decode. Lives on `WorkspaceModel.skimProvider`; cleared alongside `previewCache`.
- **`ViewerPane` source viewer is now two layers.** `SourceStillView` (a `StillLayerView` setting `layer.contents` to the generated `CGImage`) shows the frame whenever paused/skimming/scrubbing — instant thumbnail seed, then upgrades to the sharp decode. `SourcePPEHost` is visible (`opacity`) **only while playing**. `SourceStillView` skips all work when `active == false` (playing).
- **PPE no longer thrashes when paused.** `SourcePPEHost.Coordinator.push` only calls `player.update` when `isPlaying` (plus once on the play→stop transition to freeze the last frame). While paused it stays quiet — no per-tick `AVAssetReader` re-seed. PPE spins up on Play (current time), seeks once, plays.

Net: skim shows an instant (thumbnail) frame, sharpens within ~tens of ms, and re-visited positions are cache-instant. Cross-clip skim swaps the generator (cancels the prior clip's in-flight decode).

**Hardware note:** both decode paths already use the Apple Silicon media engines — `AVAssetReader` wraps a VTDecompressionSession (Metal-compatible output, hardware decode), and `AVAssetImageGenerator` is hardware-accelerated too. The skim bottleneck was never decode horsepower; it was `AVAssetReader`'s rebuild-per-seek (no random access). Proxies are NOT required for smooth skim — the generator gets us there on the same hardware.

**Three follow-up fixes (same session):**
- **PPE mounts ONLY while playing.** `ViewerPane` conditionally includes `SourcePPEHost` on `sourceIsPlaying`, so skimming/scrubbing never creates/tears-down a Metal renderer + CVDisplayLink (the cross-clip skim hitch). Paused/skim is purely the still layer.
- **Play-after-skim works.** Hovering a bin filmstrip now sets `focusedViewer = .source` (was `.bin`), so Space / J-K-L / I-O / F act on the skimmed clip. (Was routing transport to the program.)
- **No play-start black flash.** `PPEMetalRenderer.onFirstFrameAfterReset` (new, fork) fires on the main queue the first time a fresh frame draws after a generation reset. `ViewerPane` holds the still over PPE (`sourcePlaybackReady`) from play-start until that fires; a 1s safety net reveals anyway if a decode never lands. `SourceStillView` is gated `active = !playing` so it freezes the play-start frame instead of regenerating.

**Verify interactively:** skim (instant, no black, no lag) → press Space (plays from skim position, still holds until video lands) → I/O/F on the skimmed clip.

**Known follow-ups for the bin:**
- **Skim sharpness on heavy 4K.** Sharp decode is capped at 720px, 0.12s tolerance — fast, but heavy 4K H.264 still pays a GOP decode for the sharp frame (thumbnail seed covers the gap). Tunable; proxies would only be a "nice to have," not a requirement.
- **Source playback doesn't advance `sourceTimeSeconds`** (pre-existing) — the scrub bar / filmstrip skimmer line don't move during source *playback*. Separate from skim; worth wiring a source playhead clock.
- **`.id(clip.id)` PPE remount on clip switch** now only affects *playback* (per-clip), never skim. Low priority.
- **Favorites as bins/folders.** User asked for "filtered OR in a folder" — the filter shipped; folders = real `Bin` nesting in the media pool (`BinItem.bin` exists but the UI is flat). Smart collections by rating/keyword would build on this.
- **Reject rating + keyword tagging.** `FavoriteRange.Rating.rejected` exists in the model but no key binding/UI yet (FCP uses Delete on a selection to reject). Keywords aren't modeled.

Key files: `BinBrowserView.swift` (rewritten — `FilmstripClipRow`, `FavoriteClipRow`, `Filmstrip`, `WaveformStrip`, filter toggle), `WorkspaceModel.swift` (`loadSourceClip`/`skimSource` ~:1390, `favoriteSourceSelection`/`removeFavorite`/`renameFavorite` ~:1430, `sourceMarksActive` ~:117, `binFilter` ~:97), `PreemAppUI.swift` (I/O routing via `sourceMarksActive`, new `f`/`F` case ~:255), `FocusedViewer.swift` (`BinFilter` enum), `PreemCore/MediaPool.swift` (`FavoriteRange` + `ClipSource.favorites` + custom decode).

## Other backlog (recommended order)

1. **Cache↔live boundary micro-hiccup** — see "Known follow-ups" below (a tightening pass on the playback engine).
2. **Multi-track audio export** — clips with multi-cam camera audio still collapse to one stream on export. Needs: `ClipAudioLoader` rewrite on `AVAssetReader` with one output per source `AVAssetTrack` (current `AVAudioFile` path collapses to one stream); per-track `AVAssetWriterInput` in `SequenceEncoder`; `ExportSettings.audio.tracksMode = .mixdown | .preserveSource`.
3. **Proxy pipeline** — ProRes 422 LT background transcode on import for heavy source codecs (e.g. the 4K H.264 in the test project). Realtime drop chip already prompts the user; proxies are the next-level fix and pair naturally with the bin/skim work (skimming 4K H.264 is decode-heavy).
4. **Bezier handles for keyframes** — today `.bezier` / `.easeIn` / `.easeOut` use cubic Hermite with fixed zero tangents at the eased ends. After Effects–style draggable Bezier handles would need: schema additions (`Keyframe.inHandle`, `Keyframe.outHandle`), updated `sampleDouble`, and per-handle drag UI in the strip.
5. **Rotated chrome in the program viewer overlay.** The bounding box + handles stay axis-aligned today (AABB of the rotated picture). Rotating the chrome to follow the picture requires applying inverse rotation to cursor deltas in the corner/edge gesture math — `ProgramTransformOverlay.cornerScaleGesture` and friends.
6. **Customizable keymap presets** — `PreemSettings`-backed save/load for the keymap. User flagged this when the V/B/A keymap landed.
7. **`.preem` package format** — currently a flat JSON file. Waveform / thumbnail / proxy caches will want to live inside the project bundle. Pre-render cache lives at `~/Library/Caches/Preem/projects/<id>/prerender/` and survives renames; not urgent.
8. **Render-graph fusion** — multiple `effects` on a clip iterate one Metal pass each. Fusing into one pass per layer would matter as the effect arsenal grows.

## Playback choppiness — SOLVED (2026-05-28 → 2026-05-29)

Two separate causes, both fixed. See the 2026-05-29 section below for the headline one (frame-boundary sampling). The 2026-05-28 audit first cleared three per-tick costs paid on the main actor every display-link frame:

1. **Per-frame disk scan (prime suspect).** The realtime tick called `cacheSegmentAtPlayhead()` → `PreRenderCache.allSegments`, doing a synchronous `FileManager.contentsOfDirectory` + string parse + array alloc every frame. Now `WorkspaceModel` mirrors the segment list in memory (`renderSegments()` / `refreshRenderSegmentCache()`) and refreshes only on mutation (render complete, cache clear, sequence switch). `PreRenderCache.segmentContaining` was removed.
2. **`@Published` publish storm.** `playheadTime` / `sourceTimeSeconds` were written unconditionally every tick, firing `objectWillChange` on the whole model even when the value was unchanged. Now guarded on value change.
3. **O(tracks·clips) per-frame recompute.** `activeVideoTransition` re-sorted every track's clips and scanned all pairs on each access — and was only consumed by the dead dual-PPE host. Deleted along with that host.

Also fixed a slow memory climb: `OfflineSequenceCompositor` now evicts `frameSources` / `lastDeliveredFrame` / `lastSourceTime` for clips no longer in the sequence (`pruneUnusedSources()`, gated on clip-count change so steady-state playback stays allocation-free). Previously it retained a decoder + held `CVPixelBuffer` per source ever placed.

## 2026-05-29 — the real playback chop + WYSIWYG preview

A second, more stubborn chop (a clip choppy on load, smooth the instant you moved it) was chased to two things:

1. **Frame-boundary source sampling (THE chop).** The realtime compose time is frame-quantized to the sequence grid (`quantizeToFrame`, anchored at 0). When a clip's source-in equals its timeline-in — i.e. a **contiguous blade**, the common case — `sourceTime` lands *exactly* on source frame boundaries, where `pullFrame`'s `[pts, pts+dur)` window test is fragile to cross-timescale rounding and intermittently grabs the adjacent frame: a steady ~22% stream of 1-frame skips. **Fix:** `pullFrame` samples 4 ms *into* the frame (`t + 0.004`) so selection sits robustly inside one frame. Moving the clip "fixed" it only because it broke `srcIn == tlIn`. **Don't remove the epsilon.** (Diagnosed via source-cadence telemetry — the only metric that caught it; clock/push/pull/compose all read clean.)
2. **WYSIWYG + main-actor decongestion.** Along the way the live path got real wins that stay: `playheadTime` is **no longer `@Published`** — per-frame playback no longer re-renders the whole SwiftUI tree or re-pushes the timeline. The per-frame value rides a tiny `PlayheadClock` (observed only by the timecode) + an `onPlayheadChange` callback. The timeline **playhead is a CALayer overlay** (`movePlayhead` / `positionPlayheadLayer`), so moving it doesn't force a full `draw(rect:)`. The render link computes its compose time straight from the wall clock (`composePlayheadSeconds`) instead of reading a value the *playback* link updates at a different phase. Scrub/seek still sends one `objectWillChange` (`setPlayhead`) so paused edits refresh everything.

**Reverted dead end:** per-*placed-clip* frame-cache keying (tried for same-source overlays) froze playback at every same-source cut — a bladed clip cold-seeked a separate decoder at the cut. Back to `source.id` keying (seamless cuts). The same-source-*overlay* case is a known follow-up.

If playback ever regresses, the fastest diagnostic is source-frame cadence: count delivered-PTS steps between cache misses in `pullFrame`; steady playback should be all 1-frame advances, ~0 jumps. See [[preem_frame_boundary_sampling]].

## Playback engine — done 2026-05-29 (second pass)

Both prior follow-ups shipped, plus boundary fixes:
- **Overlap-aware frame keying** — DONE. `DecoderKey` keys by `source.id` (seamless same-source cuts) but isolates clips that overlap a same-source sibling in time (`refreshIsolationIfNeeded`, O(n²) only on edits) so layering a clip over itself doesn't thrash one decoder.
- **Pre-render cache reader stall** — DONE. `presentSingleSourceFrame` blends over a persistent 1×1 black texture (no per-frame scratch alloc + black-fill).
- **Cache↔live frame-grid alignment** — DONE. Pre-render start/end snapped to frame boundaries; `CacheFrameReader` samples 4ms into the frame (matching `pullFrame`); the cache-vs-live lookup (`cacheSegment(atSeconds:)`) uses the host's frame-quantized compose time so the lookup and the render agree on the same frame.
- **Prewarm re-arm** — DONE. `lastPrewarmedSegEnd` resets when the playhead leaves the warm window, so every approach (not just the first) warms the live decoder; prewarm runs AFTER present so it never delays the visible frame.

## Known follow-ups (clearly scoped)
- **Cache↔live boundary micro-hiccup (TIGHTENING PASS).** Crossing OUT of a pre-rendered region into live still shows a ~1-frame hiccup. Ruled out: compose stall (transition frames are 0.2–4ms, zero inflight skips), content-grid misalignment, cache/live lookup-vs-compose time mismatch, cold decoder seek (prewarm warms it). **Leading hypothesis:** present-pipeline latency asymmetry — the cache path is a single-pass blit (`presentSingleSourceFrame`), the live path is a two-pass composite (`composeAsync` → scratch → aspect-fit), so the live frame's GPU completes ~1 vsync later at the switch. `present()` is non-blocking so this doesn't show in compose-ms. **To investigate:** add a Metal `addCompletedHandler` to log GPU-completion time around the transition; if confirmed, unify the two paths (route the cached frame through the same two-pass present, or give both the same pipeline depth) so latency is identical across the boundary. Low user impact (one frame, only at I/O-render edges); deferred by user as a polish pass.

## 2026-05-28 audit follow-through

A full cleanliness/perf audit ran after the M3 keyframe push. Beyond the choppiness fixes above:
- **⌘Q quit-on-save** for an untitled project now waits for the async `NSSavePanel` via `save(completion:)` instead of polling `isDirty` next-runloop (which always read still-dirty and aborted the quit).
- **Effect Controls** reads `currentTransform` from `leadClipID` (the video lead) so the sliders and keyframe strip can't describe different clips when a V+A pair is selected (`Set.first` was nondeterministic).
- **Drag batching:** slider drags and on-canvas direct manipulation use light setters (`setTransformParameterOnSelectionLight` / `setClipTransformLight`) bracketed by `beginUndoBatch` + `commitTransformEdits`, so a drag no longer floods the undo stack + pre-render cache per tick (mirrors the keyframe-diamond drag).
- **Keyframes:** round (not truncate) ms quantization; per-sample re-sort skipped when already sorted; `moveKeyframe` dedups same-time collisions; inverted `easeIn`/`easeOut` doc comments fixed (the sampling math was already correct).
- **Realtime gate** (`inFlight`) releases in a `defer` so a thrown compose can't freeze the viewer permanently.
- **Dead code removed:** the dual-PPE `PPEProgramHost` + Coordinator in `ProgramViewer`, the `VideoFileBridge` actor, `ActiveTransition` / `playbackShiftForPairedFadeIn` / `underlyingVideoClipAndSource`, and dead `paramRow` / `trackName` helpers. `PPEHostView` stays — still used by the Source viewer.
- **Project is now a git repo** (`main` + the audit work). `themarket.mp4` is gitignored (large test footage).

Media is streamed, not RAM-resident: each source clip is decoded on demand through an `AVAssetFrameSource` (AVAssetReader + VideoToolbox); seek = tear down + rebuild the reader at the new time. The only live-path caching is one warm decoder + one held frame per source.

## MXF support (2026-05-30)

AVFoundation can't open MXF, but PPE has a native demuxer (`MXFFrameSource`, Canon XF-AVC / Sony XAVC / ARRI ProRes-in-MXF). MXF is now routed to it at all three decode points:
- **Import probe** — `MediaProber.probeMXF` uses `MXFFrameSource.load` (dims/fps/duration) + `MXFSoundDescriptorReader.readAll` (audio channels). Verified on real Canon footage (3840×2160 23.976 219s 4ch, ~1.7s index scan). Previously MXF imported with empty tracks (unusable).
- **Compositor (program + export)** — `frameSources` is now typed `VideoFrameSource`; `ensureFrameSource` branches `.mxf → MXFFrameSource.load`.
- **Source viewer still/skim** — `SkimFrameProvider` decodes MXF stills via a cached `MXFFrameSource` + `CIContext→CGImage` (serialized, latest-wins), since `AVAssetImageGenerator` can't open MXF. PPE already handled MXF *playback* in the source viewer.

**Decode throughput — fixed (2026-05-30).** Real Canon footage is **4K All-Intra** H.264 (every frame IDR). `MXFFrameSource` originally decoded synchronously one-frame-at-a-time → measured **23.5 fps** (under the 23.976 needed) → constant drops. Rewrote the decode loop as an **async VT decode-ahead pipeline** (submit up to `maxAhead=4` frames so the Media Engine overlaps decodes; all-Intra → no reordering, frames keyed by index, generation counter discards post-seek callbacks). Now **~54 fps** — comfortably real-time for the source viewer (PPE) and the compositor pull path. Explicit `EnableHardwareAcceleratedVideoDecoder` hint added too. (`MXFFrameSource.swift` — `pump`/`submitFrame`/`serviceWaiter`.)

**Filmstrip — fixed.** `ClipPreviewCache.generateMXFThumbnails` decodes evenly-spaced frames via `MXFFrameSource` + Core Image (AVAssetImageGenerator can't open MXF).

**Native MXF audio — DONE (2026-05-31).** `ClipAudioLoader.decode` branches `.mxf → MXFAudioExtractor.extract` (native KLV PCM demux → per-channel Float, off-actor), preserving **all native channels** (verified: Canon = 4 discrete mono, 48 kHz, non-silent) with no temp WAV / transcode. Sample rate conformed to the engine rate only if it differs (`conform`, AVAudioConverter); 48 kHz → pass-through. Channels flow through the existing N-channel `TrackBuffer` path → summed to the stereo monitor (per-channel mute/solo already in the engine for future routing UI). `VideoAudioExtractor.extractMXFAndWriteWAV` is unrelated (a separate camera-audio→WAV workflow) and unused for playback.
  - **Ranged/streaming audio — DONE (2026-05-31).** `MXFAudioReader` (in `MXFAudioExtractor.swift`) builds the sound-packet index ONCE (cached per URL, holds a file handle) and `decodeRange(startFrame:frameCount:)` reads + decodes only the packets covering the span. `ClipAudioLoader.loadRange` (+ an LRU range cache) routes the **timeline** pipeline (`TimelineAudioPipeline.buildBuffer`) to decode just each clip's trimmed span. Measured: index open ~0.15–1.7s (once), 10s span ≈ **0.7s** (was ~12s whole-track). The **source viewer** still whole-decodes via the same cached reader (`decodeMXF` → `decodeRange(0, total)`) — fine for preview; a windowed source decode is the remaining nicety.
  - **Shared single-walk index — DONE (2026-06-01).** `MXFEssenceReader` now caches the combined picture+sound `ExtendedIndex` per URL (keyed by size+mtime, LRU 16); `scanIndex` delegates to `scanAudioIndex`. So import/compositor/source/audio share ONE file walk instead of each re-scanning. Verified: cold walk 1.75s, subsequent video/audio index lookups ~0ms.
  - **Windowed source-viewer audio — DONE (2026-06-01).** `SourceAudioPipeline` decodes only a 60s window around the play position for MXF (via `loadRange`), rebuilding on out-of-window seeks; non-MXF keeps the whole-clip buffer. So source-viewer MXF audio starts fast instead of whole-track decode.
  - **Skipped: batched packet reads.** Sound essence is frame-wrapped and interleaved with (large 4K) video, so packets for one track are ~1 video-frame apart on disk — reading contiguous spans would pull MBs of video between them (worse I/O). The cost is seek latency, not throughput; ranged + cached decode already covers it. A per-content-package read (all tracks' sound packets of one frame are contiguous) could cut seeks ~4× if ever needed.

**Remaining MXF gaps (follow-ups):**
- **Redundant index scans** — import, source-still, compositor, and thumbnails each `MXFFrameSource.load` (≈1.7s index scan for the 10GB file) independently. A shared index cache keyed by URL would cut startup cost.
- **All-Intra assumption** — `buildSampleBuffer` marks every frame a keyframe; correct for this footage (verified IDR-only) but **Long-GOP XF-AVC would need real keyframe detection + seek-to-keyframe** (the index has no frame-type info yet).

## Known gotchas / footguns

- **Realtime host's compose must NEVER block main actor.** `composeAsync(at:into outputTexture:)` is the async path; the sync variant (with `DispatchSemaphore.wait()` inside `syncEffectiveLayers`) is for the encoder pump only. Bridging the sync version into main freezes the entire UI — happened twice during the refactor.
- **Compositor sequence/mediaPool are `var` now.** The realtime host pushes fresh snapshots every tick when spec matches. If you re-introduce a path that builds the compositor without refreshing those, transform / keyframe edits won't reach the realtime path.
- **Keyframes are stored in clip-local time** (seconds since `clip.timelineRange.start`). `PlacedClip.transform(at: clipLocalSeconds)` is the read path; pass `t - clip.timelineRange.start.seconds` from the compositor.
- **Interpolation semantics**: a keyframe's `.interpolation` applies to BOTH the segment leaving it AND the segment arriving at it. easeOut on A = slow start. easeIn on B = slow end. bezier on either = both. See `sampleDouble` in `ClipTransform.swift`.
- **Rotation needs PIXEL aspect**, not UV aspect. `layerUniforms` computes `destPixelAspect = fitW / fitH` and ships it in `rotation.z`; shader divides+multiplies the cross-axis by it so a square stays square.
- **Crop does NOT change destRect.** Cropping is purely a "skip this sample region, fall through to the layer below" operation in the shader. destRect = aspect-fit of the FULL source. Auto-feather treats edges with crop == 0 as un-feathered (sentinel large distance).
- **`AVAssetWriter` flow control = `requestMediaDataWhenReady(on:using:)`.** Spin-polling `isReadyForMoreMediaData` from a `Task.sleep` loop stalls at ~65 frames on 4K H.264.
- **Cross-source frame cache prevents 60Hz/24fps mismatch.** `pullFrame` caches the last delivered `PPEDecodedFrame` per source with `[pts, pts+duration)` window check. Without it, a 24 fps source plays at 2.5× even when paused.
- **`CacheFrameReader` seeks lazily on first render.** First `render(at: target)` seeks to `target` (not 0).
- **Aspect handling is two-pass in the realtime compositor.** `composeAsync` composes into a sequence-resolution scratch CVPixelBuffer, then aspect-fits that into the drawable.
- **Never auto-stretch.** Every layer aspect-fits its source into its destRect by default. `Transform.stretchToFill = true` is the only path that allows non-uniform scaling.
- **SwiftUI `HSplitView` / `VSplitView` are unreliable** — use `PreemSplitView`.
- **Polymerge is forked in-tree.** Modify `Sources/Polymerge*` freely.
- **`Task { @MainActor in ... }` vs `MainActor.assumeIsolated { ... }`** — Task hops introduce one-runloop delays. For UI work where you're already on main, use `assumeIsolated`.
- **CVDisplayLink callback `inNow` pointer** is only valid INSIDE the callback. Capture `inNow.pointee.hostTime` before bouncing to MainActor.
- **MediaProber needs `AVURLAssetPreferPreciseDurationAndTimingKey: true`** for B-frame files. Already wired.
- **Pre-render cache invalidated on every sequence mutation.** `WorkspaceModel.updateSequence{,WithoutUndo}` calls `PreRenderCache.clearAll(...)`. There's also a `moveKeyframeLight` path that intentionally bypasses this — it's only used for in-progress drags and the final commit flushes the cache properly.
- **Frame quantization**: transition durations + nudge offsets round to whole frames. `quantizeToFrame(_:)` + `clampHalf(_:neighborDuration:)`.
- **`audio.invalidate()` mirrored to `sourceAudio.invalidate()`** anywhere project / sequence / clip pool changes.
- **PPE realtime path is mostly bypassed.** The dual-PPE program viewer is gone; the realtime host runs the offline compositor. PPE's `AVAssetFrameSource` is still the frame source under the hood; the source viewer still uses `SourcePPEHost`. Don't reintroduce the dual-PPE architecture without a strong reason.
- **`parameterForKeyframe`-style "resolve by keyframe time" is a trap.** Linked params (ScaleX/Y, Position X/Y) share keyframe times — looking up the parameter by matching time returns the wrong row. Always pass the explicit `TransformParameter` from the row context.
- **`applicationShouldTerminateAfterLastWindowClosed` returns `false`.** Closing the window hides it; app keeps running. If you add a new window kind, decide whether its close should also hide or actually close the scene.

## Files to know

**Compositor + render:**
- `PreemRender/OfflineSequenceCompositor.swift` — pull-mode compositor, Metal blend + cross-dissolve shaders, per-source frame cache, sequence-uniforms layout. `sequence` / `mediaPool` are `var` and refreshed each realtime tick.
- `PreemRender/SequenceEncoder.swift` — AVAssetWriter pump with `requestMediaDataWhenReady`. Same compositor under the hood for pre-render and export.
- `PreemMedia/OfflineAudioMixdown.swift` — non-realtime audio mix mirroring `TimelineAudioPipeline`.
- `PreemMedia/PreRenderCache.swift` — cache dir + segment URLs + invalidation.

**Realtime:**
- `PreemAppUI/RealtimeProgramHost.swift` — `RealtimeProgramHostView`, `CacheFrameReader`, `ThinScroller`-friendly drop-detection logic.
- `PreemAppUI/ProgramViewer.swift` — wrapper hosting the realtime view + overlay + fixed-height (28 px) header with the drop chip.
- `PreemAppUI/ProgramTransformOverlay.swift` — direct-manipulation chrome: bounding box (full picture rect), dashed inner crop hint, center grab, 4 corner handles (uniform scale), 4 edge handles (non-uniform scale), top rotation grip.

**Effects + inspector:**
- `PreemCore/ClipTransform.swift` — Transform / Crop schema, `transform(at: clipLocalSeconds)` sampler, keyframe write helpers (`setParameter`, `toggleKeyframing`, `removeKeyframe`, `moveKeyframe`, `setKeyframeInterpolation`), `sampleDouble` (Hermite for ease, smoothstep for bezier).
- `PreemCore/Sequence.swift` — `Interpolation` enum (`hold`, `linear`, `easeIn`, `easeOut`, `bezier`) + `Keyframe` + `ParameterValue.keyframed`.
- `PreemAppUI/EffectControlsPanel.swift` — `EffectControlsContent` (lives as a tab in the Source pane), per-param sliders + stopwatch toggles + reset, lock-X/Y toggle, rotation row, crop section with feather, `KeyframeStripView` with diamond markers + drag/double-click/right-click menu, ThinScrollView for horizontal scroll, +/- zoom controls.
- `PreemAppUI/ViewerPane.swift` — Source pane with tab bar (Source | Effect Controls), hosts `SourcePPEHost` for the source viewer.

**App lifecycle / window:**
- `PreemApp/PreemApp.swift` — `AppDelegate` is the `NSWindowDelegate` for the main window; close-to-hide, dock reopen, ⌘Q save warning, frame autosave (`preem.main.window`).
- `WorkspaceModel.current` (static weak) — read by the AppDelegate for `isDirty` checks.

**Custom chrome:**
- `PreemAppUI/ThinSlider.swift` — SwiftUI-native slim slider.
- `PreemAppUI/ThinScrollView.swift` — NSScrollView wrapper + `ThinScroller` NSScroller subclass.

**Export:**
- `PreemAppUI/ExportSettings.swift` / `ExportPresets.swift` / `ExportSheet.swift`.

**Timeline:**
- `PreemTimelineUI/PreemTimelineView.swift` — drawing + interaction + drag-drop + drag-ghost + tools + In/Out marks + cache bars + transition body / solo-fade body hit-testing.
- `PreemTimelineUI/PreemTimelineUI.swift` — shared selection types: `GapSelection`, `CutSelection`, `ClipEdgeSelection`, `ActiveTool`.

**Audio:**
- `PreemAppUI/TimelineAudioPipeline.swift`, `PreemAppUI/SourceAudioPipeline.swift`.

**Bin + Source viewer (next session's area):**
- `PreemAppUI/BinBrowserView.swift` — bin list; `ClipRow` (~:143) renders a clip and has tap-to-open + drag-to-timeline but NO hover/skim yet; `orderedClips` (~:107). Skim gesture goes here.
- `PreemAppUI/ViewerPane.swift` — Source pane: `ScrubBar` (~:167), `SourcePPEHost` (~:309) wrapping PPE; the source viewer renders whatever `(sourceClip, sourceTimeSeconds)` say.
- `PolymergePlayback/PPE/CustomVideoPlayer.swift` — `update(secondsInVideo:…)` (~:177) is the source seek entry point; renderer pulls the frame.
- Source state in `WorkspaceModel`: `sourceClip` (:16), `sourceTimeSeconds` (:75), `sourceInMark`/`sourceOutMark` (:76–77), `nudgeSourcePlayhead` (:1363), `setSourceIn/Out` (:1373), `insertFromSource`/`overwriteFromSource` (:1394).
- `PreemCore/MediaPool.swift` `ClipSource` (:28) — add rating/favorite/keyword fields here for "selects" (none exist yet; Codable with defaults for back-compat).

**Workspace + brain:**
- `PreemAppUI/WorkspaceModel.swift` — ~3500 lines, well-sectioned. Read top-to-bottom once. `selectedVideoClipIDs`, `setTransformParameterOnSelection`, `moveKeyframeLight`, `setKeyframeInterpolation`, `findPlacedClip` are the keyframe-era additions.
- `PreemAppUI/PreemAppUI.swift` — root view, key monitor (Delete now removes selected cut / edge too), focus border, callback wiring.
- `PreemAppUI/FocusedViewer.swift` — `FocusedViewer` enum + `SourcePaneTab` enum.

**Data model:**
- `PreemCore/Project.swift` + `Sequence.swift` + `MediaPool.swift` + `ClipTransform.swift` — data model.
- `PreemCore/Timecode.swift` — SMPTE formatter.

**Polymerge (forked):**
- `Sources/Polymerge{MediaModel,Ingest,Audio,Playback}/` — fork from 2026-05-27. PPE's `AVAssetFrameSource` is the pull-mode video source the compositor uses.

## State pointer

- **App version**: M2 complete + most of M3 shipped. Playback engine hardened across 2026-05-28/29. **FCP-style filmstrip bin + skimming + favorites shipped 2026-05-29 (second push)** — see that section above; needs interactive footage verification. Remaining backlog: bin follow-ups (proxy-backed skim, persistent skim host, folders/smart collections, reject+keywords), cache↔live boundary micro-hiccup (tightening), multi-track audio export, proxy pipeline, bezier handles, rotated overlay chrome, keymap presets, `.preem` package, render-graph fusion.
- **Git**: `main` holds everything. Worktree clean. Repo created 2026-05-28; `themarket.mp4` gitignored (large test footage).
- **Polymerge**: forked in-tree on 2026-05-27. No external dep.
- **Debug log**: `/tmp/preem-debug.log`. `PreemDebugLog.log(...)` wired into critical paths. Check it first when something behaves weird. Encoder heartbeat is `[Encoder] video N/M audio M/X @ Y fps`. (All the temporary playback telemetry from the 05-29 hunt has been removed.)
- **Build**: `swift build -c release && swift run -c release Preem` for any real footage work. 30 unit tests (`swift test`), all passing.
- **Playback chop**: SOLVED (frame-boundary source sampling + WYSIWYG decoupling). One known polish item left: the cache↔live boundary micro-hiccup.

Good luck. If something feels weird, check the debug log, then re-read `TIMELINE.md` (editing question) or `COMPOSITOR.md` (playback / render question).
