# Preem — Roadmap

Time estimates assume one focused dev driving Claude Code Opus 4.7 agents (typically one primary + parallel sub-agents for isolated work). They count *calendar time*, not agent-hours. The bottleneck at this scale is not typing — it's:

- API design rounds (the user + agent converging on a shape)
- Debugging VideoToolbox / MXF / codec quirks on real footage
- Apple-framework gotchas that don't fail at compile time
- Real-session stability work once people start using it

If those bottlenecks shrink (more parallel agents on isolated work, fewer integration unknowns), these estimates compress. If real-world footage testing surfaces a deep codec bug, they expand.

---

## M1 — Ingest + Viewer (no timeline)

**Goal:** a useful Polymerge-adjacent tool. Drop a folder, get an organized media pool with slate / shot / transcript metadata, scrub clips in a viewer, export an FCPXML the user finishes in Premiere/Resolve.

**Estimate: 2–4 days of agent-driven dev.**

Scope:

- Bin browser with nested bins and smart bins (saved filter queries)
- Drag-and-drop folder ingest
- AVFoundation + MXF metadata read on import (codec, fps, TC, scene/take, camera)
- Source viewer (AVKit placeholder — PPE swap in M2)
- Slate OCR on first/last 5s using Vision `VNRecognizeTextRequest`, fuzzy-match scene/take/roll
- Shot classifier (Core ML) — start with a pretrained-or-fine-tuned wide/medium/close model
- Transcription using Apple `SFSpeechRecognizer` (offline mode) or whisper.cpp Core ML build
- FCPXML 1.10 export

Ships nothing about timelines, edits, or rendering. Already useful.

---

## M2 — Multi-track timeline editor ✓

**Goal:** rough-cut tool. Multi V/A tracks. Cuts, marking, ripple delete, JKL shuttle, save/open, undo, transitions, source viewer audio, FCPXML export.

**Status: functionally complete.** See `docs/TIMELINE.md` and `docs/COMPOSITOR.md` for architecture detail.

✓ Done:

- AppKit `NSView` timeline with Quartz drawing (Metal-swap deferred to when clip counts matter)
- Pointer / blade / cut-at-playhead tools (A / B / V) with custom blade cursor
- Click/drag clip placement, snap-to-playhead, snap-to-edit-points (N toggles snapping)
- Drag-to-select rubber-band in empty timeline space
- Source viewer with I/O marks, 3-point insert (`,`) / overwrite (`.`)
- Source viewer audio playback (mutex'd with timeline audio via PlaybackState)
- Multi-track V/A with mute / solo / lock per track and peak-level meters
- Drop-overwrite (underlying clips get sliced at the new clip's edges)
- Vertical drag between tracks with deferred commit (no mid-drag wipeout)
- Auto-create sequence on first drop when none exists; mismatch dialog otherwise
- Drag-ghost preview from bin AND source viewer (with optional in/out range)
- Drag above V_top auto-creates V_n+1; drag below A_last auto-creates A_n+1 (both for bin drops AND existing-clip drags)
- V/A linking with ⌘L toggle and right-click menu
- Single playback state machine — program OR source plays, never both
- JKL transport with 1×–4× shuttle (1× audio engine, faster/reverse silent)
- Polymerge `AudioPlaybackEngine` driving timeline audio + per-clip fade envelopes (sin/cos constant-power)
- Dual-PPE compositor in the program viewer with `presentsWithTransaction = true` for CA alpha blending
- Cross-dissolve transitions (⌘D add, ⇧⌘D remove, drag wedge edges to resize asymmetrically)
- Solo fade-in / fade-out via right-click on clip edges; fades into underlying clip when one exists
- Always-on dual-PPE for solo fades over underlying — neither PPE swaps clips during the fade
- Audio cross-fade extends source buffers into the dissolve overlap
- Sequence settings dialog + transition defaults in PreemSettings (Settings scene)
- `.preem` save / open / autosave (JSON, bundle structure deferred to M3)
- Undo / redo (⌘Z / ⇧⌘Z) with drag/trim grouped into single steps
- No same-track overlap invariant: `finalizeOverlapsForClip` runs at end of drag/trim
- Nudge selection ±1 frame with `<` / `>` (frame-precise, preserves selection IDs)
- Timeline zoom: ⌘+/⌘-, slider, trackpad pinch (range 4–800 px/s)
- Forced dark UI globally
- SMPTE timecode display (program viewer + ruler): non-drop-frame + true drop-frame for 29.97 / 59.94
- Sequence spec readout next to TC (`3840x2160 23.976 | HH:MM:SS:FF`)
- Waveforms on audio clips + thumbnails on video clips (preview cache, async generated)
- FCPXML 1.10 timeline export: `<project>/<sequence>/<spine>` with V1 on spine + V2+/audio on lanes; media-pool catalog at event level
- Gap selection + ripple-delete (click empty space on a track, ⌫ closes the gap across all tracks)
- Cut selection + right-click "Add Transition" between abutting clips

**Remaining M2 polish — all shipped:**

- ~~Target tracks UI~~ ✓ Lane-header click sets exclusive target per V/A; chip displays which track is active.
- ~~Timeline In/Out marks~~ ✓ Per-sequence, persisted, drawn in ruler, drives Render In to Out + export range.
- ~~Pre-render cache~~ ✓ Render In to Out → ProRes 422 LT under `~/Library/Caches/Preem/projects/<id>/prerender/`, realtime substitution via cache fast-path, green bar overlay on the ruler.

Still deferred:
- Customizable keymap presets (current keymap is hard-coded)
- Drop-frame TC for 23.976 (currently uses nominal 24 fps)

---

## M3 — Multi-track + transitions + keyframes + proxies + ProRes export

**Estimate: 3–6 weeks.** **Significant portion shipped 2026-05-27.**

Scope (✓ = shipped, ◐ = partial, ◯ = pending):

- ✓ Multiple V/A tracks with target-track routing
- ✓ Transitions: cross dissolve, solo fade-in / fade-out (audio xfade variants deferred)
- ✓ Per-clip transform (position / scale X+Y / opacity / rotation / crop) via `ClipTransform`. Direct manipulation in the program viewer (drag/corner-scale) + Effect Controls inspector (`⇧⌘5`).
- ◯ Keyframes on transform / opacity — schema supports `ParameterValue.keyframed([Keyframe])`, but the compositor's reader uses static values today. Needs temporal interpolation + keyframe-editing UI.
- ◯ Audio HPF/LPF/EQ primitives — Polymerge biquad code is in the fork; not yet exposed as Preem effects.
- ◯ Proxy pipeline: ProRes 422 LT background transcode on import. Cache infrastructure is in place; needs the per-clip proxy-generation pump + a proxy-aware decode path.
- ✓ VideoToolbox-driven ProRes / H.264 / HEVC export — via `SequenceEncoder` using `AVAssetWriter` + `requestMediaDataWhenReady`. Sheet with preset rail (YouTube/Vimeo/Apple Devices/ProRes/Audio-Only) covers most common targets.
- ✓ Aspect-aware compositing — letterbox/pillarbox by default; never auto-stretch unless user explicitly sets `stretchToFill`.
- ✓ Alpha-aware cross-dissolve shader — handles different source aspects with correct `(1-p)*A + p*B` math + V_below show-through where only one clip covers.
- ✓ Realtime compositor refactor — single `OfflineSequenceCompositor` instance drives both realtime + render; realtime ≡ render by construction.
- ✓ Frame-drop indicator — subtle orange chip suggests Render In to Out when realtime can't keep up.
- ◐ Render graph fusion — currently the compositor runs one blend pass per layer; multi-effect-per-clip is supported by the data model (`PlacedClip.effects: [EffectInstance]`) but only Transform + Crop are wired today. Fusing N effects into a single Metal pass per layer comes when the effect arsenal grows.
- ◯ Multi-track audio export preservation — currently always mixes to stereo. Needs `ClipAudioLoader` → `AVAssetReader`-per-track + per-track `AVAssetWriterInput`.

End of M3: this is the first version someone could realistically cut a short film in and not feel hobbled. We're most of the way there.

---

## M4 — Pen tool, masks, effect arsenal, edit-graph undo, autosave hardening

**Estimate: 3–5 weeks.**

Scope:

- Pen tool: bezier path drawing
- Shape masks per effect (rectangle, ellipse, bezier, with feather)
- Tracking points (manual; auto-tracking deferred to M5+)
- Expanded effect arsenal: gaussian blur, sharpen, color matrix, curves, vignette, levels
- Audio effects: compressor, limiter, de-esser, noise gate (vDSP-backed)
- Edit-graph undo (instead of snapshot undo) so "delete 50 clips" is one Cmd+Z
- Autosave hardening: incremental writes, crash recovery
- Source/program viewer scopes (waveform, vectorscope, parade) via MPSGraph

---

## M5 — Plugin host, color page, advanced trim, nested sequences, scopes

**Estimate: 2–3 months.**

Scope:

- FxPlug 4 host (Mac-native, Metal-friendly)
- OFX bridge research + prototype
- Color page: node-based grading UI, primary wheels, curves, qualifier, color match
- Nested sequences (compound clips)
- Advanced trim modes: slip, slide, ripple, roll, asymmetric trim, JKL trim
- Multicam editing (sync by TC / waveform — Polymerge phase-align primitive)
- Advanced scopes: histogram per channel, false color, focus assist

---

## M6+ — Premiere contention

**Estimate: ongoing.** Not a milestone, a phase.

What lands here:

- Speed ramps + time remapping
- Title designer
- AAF / OMF round-trip (post audio handoff)
- Collaboration / shared project model (deferred research)
- VR / 360 (deferred research)
- Color management with ACES + CDL
- Format compatibility: long-tail codecs (RED R3D via decoder SDK, BRAW via Blackmagic SDK)

The honest assessment: M5 is where Preem is *good for some workflows*; M6+ is where it actually contests Premiere on broad professional use. That phase is gated by real-user testing more than code throughput.

---

## What's deliberately *not* on the roadmap

- Cross-platform (Windows/Linux). Mac-only is a constraint we use, not a limitation we apologize for.
- Cloud rendering. Possible later; not a v1 concern.
- AI-driven auto-edit. The slate/shot/transcription work is *organizational* AI, not creative AI. We don't have an opinion on creative AI yet.
- A subscription model. Distribution / business model is a separate conversation.
