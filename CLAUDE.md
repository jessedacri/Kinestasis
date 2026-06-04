# Preem — Developer Guide

## What This Is

Preem is a macOS-native non-linear video editor targeting eventual Adobe Premiere Pro feature parity, with a differentiator on ingest-time organization (slate OCR, shot-type detection, transcription) and tight integration with the Polymerge audio engine.

**Target users:** Independent filmmakers, documentary editors, production sound mixers who edit, anyone who values metadata-driven org over chasing Hollywood-tier color/VFX.
**Reference NLEs:** Premiere Pro, DaVinci Resolve, Final Cut Pro.

## Tech Stack

- **Language:** Swift 5.10+ (moving to Swift 6 strict concurrency as targets stabilize)
- **UI:** SwiftUI for inspectors / bins / viewers; AppKit `NSView` + Metal for the timeline (SwiftUI can't hit the data density an NLE timeline needs)
- **Build:** Swift Package Manager monorepo (`Package.swift`, no `.xcodeproj`)
- **Frameworks:** Metal / MetalKit / MetalFX / MetalPerformanceShaders, VideoToolbox, AVFoundation, Vision, Core ML, Speech, Accelerate (vDSP / vImage), Core Audio
- **Platform:** macOS 14.0+ (Apple Silicon first-class; Intel best-effort)

## Building & Running

```bash
swift build          # compile all targets
swift run Preem      # launch the app
swift test           # run test suite
```

Release builds (`swift build -c release` / `swift run -c release Preem`) are required for any real footage work — Metal shader compile + VideoToolbox sessions are tuned for optimized builds.

## Module Layout

```
Sources/
├── PreemCore/         # pure data: Project, Sequence, Track, Clip, TimeRange, IDs
├── PreemMedia/        # AVFoundation/VideoToolbox wrappers, VT session pool, proxy mgr
├── PreemRender/       # Metal compositor, render graph, color pipeline
├── PreemEffects/      # starter effect arsenal: xfade, HPF/LPF, transform, opacity, …
├── PreemML/           # Vision (slate OCR), Core ML (shot classifier), Speech (transcription)
├── PreemTimelineUI/   # AppKit NSView timeline + tools (select, blade, pen, slip)
├── PreemAppUI/        # SwiftUI shells: bin browser, source viewer, program viewer, inspector
└── PreemApp/          # @main, AppDelegate, window scenes
```

Dependency rule: modules depend **upward only**. PreemCore depends on nothing. PreemApp depends on everything. No cycles. If you find yourself wanting a back-edge, the abstraction is in the wrong place.

## Apple Silicon — what runs where

| Subsystem | Path | Notes |
|---|---|---|
| H.264/HEVC decode/encode | VideoToolbox Media Engine | Parallel sessions across multiple engines on Pro/Max/Ultra |
| ProRes decode/encode | VideoToolbox ProRes Engine | M1 Pro+; primary export codec |
| Compositor + effects | Metal (custom shaders) | Zero-copy `CVPixelBuffer` → `MTLTexture` via `CVMetalTextureCache` |
| Color / scopes | MPSGraph + custom shaders | Waveform, vectorscope, parade |
| Proxy ↔ full-res scaling | MetalFX (spatial + temporal) | |
| Slate OCR / shot / transcription | Core ML on ANE | `MLComputeUnits.all` |
| Audio DSP | Accelerate vDSP | Re-use Polymerge primitives |

See `docs/APPLE-SILICON.md` for the deep dive.

## Polymerge — forked in-tree (2026-05-27)

Polymerge's four Preem-relevant modules were forked into Preem's source tree on 2026-05-27 from Polymerge's `feature/spm-library-targets` working tree. The fork severed the cross-product dependency so PPE, audio, and ingest can be modified freely for NLE-specific needs (pull-mode rendering, offline composition for pre-render + export) without touching the Polymerge product.

Forked modules now living under `Sources/`:

- `PolymergeMediaModel` — `AudioFile`, `VideoFile`, `TimecodeValue`, DSP primitives (`HighPassFilter`, `PhaseTrajectory`, `LTCDecoder`, etc.)
- `PolymergeIngest` — WAV/BEXT/iXML parsers, MXF essence/picture/sound/timecode readers
- `PolymergeAudio` — `AudioPlaybackEngine`, `TrackBuffer`, `TrackBufferBuilder`, `LoudnessAnalyzer`, `MixLoudnessMeasurer`, `SampleRateConverter`, `SincInterpolator`, `TimecodeAligner`, `WaveformTCInferrer`, `VideoAudioExtractor`, `GCCPHATAnalyzer`
- `PolymergePlayback` — PPE (`CustomVideoPlayer`, `PPEMetalRenderer`, `PPEFrameQueue`, `PPEBackgroundDecoder`, `AVAssetFrameSource`, `MXFFrameSource`, `PPELUTLoader`, `VideoFrameSource`) + legacy video players + `VideoFileParser`

`PolymergePhaseAlign` (phase alignment / STFT) is not used by Preem and was not forked.

Module names kept the `Polymerge` prefix to minimize import churn — Preem source files still `import PolymergePlayback`, etc. Dependency direction is strictly downward: Polymerge* modules have no Preem deps; Preem* modules consume Polymerge* freely. Upstream Polymerge improvements no longer flow in automatically — that's the cost of severing the coupling, and it's a deliberate trade for autonomy on the playback path.

## Conventions

- One feature per PR. Small surface area beats heroic megacommits.
- Test what's deterministic (data model, time math, project file). Don't test what depends on a GPU or codec — those go through manual smoke runs.
- No multi-paragraph docstrings. One short line if absolutely needed; let names carry the meaning.
- No `// added for X` / `// removed in Y` comments. The git log is the changelog.
- Performance is a feature. Any code on the render path that allocates per-frame is a bug.

## Where to look next

- **`docs/HANDOFF.md`** — entry point for a new session. State pointer, what's next, footguns, file map.
- `docs/USER-GUIDE.md` — the user-facing manual: import, editing, transforms, render, export, troubleshooting.
- `docs/ARCHITECTURE.md` — load-bearing design decisions, module dependency graph, data model, render-graph philosophy, project file format.
- `docs/TIMELINE.md` — every user-facing editing pattern: tools, keymap, focus model, drag/drop, snapping, selection types, V/A linking, no-overlap invariant, undo batching, frame quantization, zoom, preview cache, In/Out marks, target-tracks, splits, sequence settings.
- `docs/BROWSER.md` — FCP-style media browser: filmstrip skimming, the still-vs-PPE source-viewer state machine, `SkimFrameProvider`, favorites (subclips) + filter, transport/marks routing.
- `docs/COLOR.md` — Lumetri-style grading: Basic Correction + Curves, the color-managed per-layer pipeline (input/log transforms → linear → display), `ColorGrade` model, and the color-management roadmap.
- `docs/BRANDING.md` — the Polymerge-sibling theme: `PreemTheme` palette, dark amber chrome, Dock icon, About panel, and the "don't brand the timeline waveforms" constraint.
- `docs/COMPOSITOR.md` — runtime architecture: playback state machine, audio pipelines (timeline + source), **unified compositor** (realtime + render share one path), pre-render cache, transform/crop, transitions, timecode, Polymerge fork state.
- `docs/ROADMAP.md` — milestones M1 → M6+.
- `docs/APPLE-SILICON.md` — which API for which job, and why.

## Quick state pointer

M1 (ingest + viewer + ML pipelines + FCPXML media-pool export) and M2 (timeline editor + audio engine + transitions + FCPXML timeline export) are **functionally complete**. Most of M3 shipped across 2026-05-26 → 2026-05-28: pre-render cache + Export (ProRes 422 Proxy/LT/422/HQ/4444, H.264, HEVC, audio-only WAV/AIFF/AAC), unified realtime compositor (realtime ≡ render by construction), per-clip Transform + Crop, **keyframes with linear / hold / easeIn / easeOut / bezier interpolation** (Premiere-style — easing on the end keyframe decelerates INTO it), **Effect Controls inspector as a tab in the Source pane** with stopwatch toggles + keyframe strip (drag/double-click/right-click), **on-canvas direct manipulation** (center drag, corner uniform scale, edge non-uniform scale, top rotation grip), aspect-aware compositing with crop decoupled from aspect-fit + auto-feather, Final Cut–style **app lifecycle** (close-to-hide, dock reopen, save-warn on ⌘Q, frame autosave), foolproof transition delete (click body + Delete key), **custom slim chrome** (`ThinSlider` + `ThinScrollView` ignore macOS system scrollbar prefs). The app is a real NLE: import → cut → trim → blade → ripple-delete → drag-between-tracks → fade → cross-dissolve → animate transforms with keyframes → render In to Out → export to ProRes/H.264/HEVC. Across 2026-05-28/29 the project went under git and the **playback engine was hardened**: a full cleanliness/perf audit, then the playback-chop hunt — root cause was **frame-boundary source sampling** (sample 4 ms into the frame), plus frame-accurate WYSIWYG preview (playhead off `@Published`, CALayer playhead, wall-clock compose time), overlap-aware decoder keying (layer a clip over itself without thrash; seamless same-source cuts), cache-reader stall fix, and cache↔live frame-grid alignment. See `HANDOFF.md` (top) and `COMPOSITOR.md` ("Frame-exact playback invariants") — those invariants are load-bearing, don't regress them. The **FCP-style filmstrip bin** shipped 2026-05-29 (skimmable thumbnail filmstrips, In/Out on the skimmer, **F** favorites a `FavoriteRange` subclip, Favorites filter) — see `BROWSER.md`. **2026-05-30 → 06-04 shipped:** **Lumetri-style color grading** (Basic Correction + RGB curves + `.cube` LUT, color-managed per-layer compositor — `COLOR.md`); **native MXF** import + playback (video via pipelined async VT decode, native PCM audio with ranged/windowed decode + shared KLV index — `HANDOFF.md` MXF section); **Polymerge-sibling branding** (`PreemTheme` dark amber chrome, flipped Dock icon, About — `BRANDING.md`; the timeline rendering is deliberately left unbranded to preserve waveform legibility); and two timeline fixes (multi-select drag, ⌘F program fullscreen — `TIMELINE.md`); and **multi-track audio export** (export-sheet Audio→Tracks: Single mixdown / Separate Tracks / Separate Tracks preserving source channels; MOV only — `HANDOFF.md` multi-track section). **Git:** branding merged to `main` (`cb8e117`) on 2026-06-04; multi-track audio export is on `feature/multitrack-audio-export` — merge when happy. Remaining backlog in `HANDOFF.md`: merge multi-track audio + verify with real multicam footage; bin follow-ups; color (linear-light compositing, HDR, wheels/HSL secondary, scopes); MXF (Long-GOP seek, batched reads); cache↔live micro-hiccup; proxy pipeline; bezier handles; keymap presets; `.preem` package; render-graph fusion.
