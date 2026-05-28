# Preem — Handoff Notes

Snapshot for the next session. Last updated 2026-05-28. Pairs with `CLAUDE.md` (developer guide), `ARCHITECTURE.md` (load-bearing decisions), `TIMELINE.md` (editing patterns), `COMPOSITOR.md` (playback + render runtime), `ROADMAP.md` (milestones), `APPLE-SILICON.md` (API matrix).

## Where things stand

**M1 + M2 are functionally complete.** Big M3 chunks landed across the 2026-05-26 → 2026-05-28 push: pre-render + Export, unified realtime compositor, Transform/Crop, alpha-aware cross-dissolves — see prior HANDOFF entries (in git) for the May 26/27 details.

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
4. `COMPOSITOR.md` — runtime architecture: playback state machine, audio pipelines, **realtime compositor**, transitions (cross-dissolve + solo fade), pre-render cache, transform/crop, keyframe sampling, timecode.
5. `ROADMAP.md` — what's in M1 → M6+.
6. `APPLE-SILICON.md` — which Apple API for which job, and why.

## What I'd do next (recommended order)

1. **Multi-track audio export** — clips with multi-cam camera audio still collapse to one stream on export. Needs: `ClipAudioLoader` rewrite on `AVAssetReader` with one output per source `AVAssetTrack` (current `AVAudioFile` path collapses to one stream); per-track `AVAssetWriterInput` in `SequenceEncoder`; `ExportSettings.audio.tracksMode = .mixdown | .preserveSource`.
2. **Bezier handles for keyframes** — today `.bezier` / `.easeIn` / `.easeOut` use cubic Hermite with fixed zero tangents at the eased ends. After Effects–style draggable Bezier handles would need: schema additions (`Keyframe.inHandle`, `Keyframe.outHandle`), updated `sampleDouble`, and per-handle drag UI in the strip.
3. **Rotated chrome in the program viewer overlay.** The bounding box + handles stay axis-aligned today (AABB of the rotated picture). Rotating the chrome to follow the picture requires applying inverse rotation to cursor deltas in the corner/edge gesture math — `ProgramTransformOverlay.cornerScaleGesture` and friends.
4. **Customizable keymap presets** — `PreemSettings`-backed save/load for the keymap. User flagged this when the V/B/A keymap landed.
5. **Proxy pipeline** — ProRes 422 LT background transcode on import for heavy source codecs. Realtime drop chip already prompts the user; proxies are the next-level fix.
6. **`.preem` package format** — currently a flat JSON file. Waveform / thumbnail / proxy caches will want to live inside the project bundle. Pre-render cache lives at `~/Library/Caches/Preem/projects/<id>/prerender/` and survives renames; not urgent.
7. **Render-graph fusion** — multiple `effects` on a clip iterate one Metal pass each. Fusing into one pass per layer would matter as the effect arsenal grows.

## Open mystery — overnight playback choppiness

User reported that after leaving Preem open overnight, actual playback (not just the chip) got choppy. The chip false-positive was diagnosed and fixed (nil drawables + cap + hysteresis), but the real choppiness root cause is **not found**. Code reading didn't turn it up:
- `OfflineSequenceCompositor.frameSources` / `lastSourceTime` caches are bounded (one entry per source clip).
- `AVAssetFrameSource.seek` tears down the previous reader cleanly.
- Compose path doesn't allocate per-frame outside the bounded scratch pool.

If the user reports it again, add telemetry to the realtime tick first: rolling p50/p99 of ms-per-tick, `CVPixelBufferPool` allocate failures, and the `frameSources` dictionary size. The most likely real causes (no evidence yet):
- macOS swapping the working set after extended idle (first wake = slow).
- A `@Published` storm somewhere else that's flooding SwiftUI re-renders.

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

- **App version**: M2 complete + most of M3 shipped. Remaining: multi-track audio mux on export, bezier handles, proxy pipeline, render-graph fusion, customizable keymap presets, `.preem` package format.
- **Polymerge**: forked in-tree on 2026-05-27. No external dep.
- **Debug log**: `/tmp/preem-debug.log`. `PreemDebugLog.log(...)` wired into critical paths. Check it first when something behaves weird. Encoder heartbeat is `[Encoder] video N/M audio M/X @ Y fps`.
- **Build**: `swift build -c release && swift run -c release Preem` for any real footage work.
- **Open mystery**: overnight playback choppiness (see section above). Add telemetry if it reproduces.

Good luck. If something feels weird, check the debug log, then re-read `TIMELINE.md` (editing question) or `COMPOSITOR.md` (playback / render question).
