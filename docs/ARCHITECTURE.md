# Preem — Architecture

This document captures the load-bearing decisions. If you change one of these without updating this doc, the next agent that reads the code will make a wrong assumption and break something.

## Module dependency graph

```
                ┌─────────────────────┐
                │     PreemApp        │  @main, AppDelegate
                └──────────┬──────────┘
                           │
                ┌──────────▼──────────┐
                │    PreemAppUI       │  SwiftUI: bins, viewers, inspector
                └─┬───┬───┬───┬────┬──┘
                  │   │   │   │    │
   ┌──────────────┘   │   │   │    └────────────────┐
   │                  │   │   │                     │
┌──▼─────────────┐ ┌──▼───┴─▼──┐ ┌──────▼─────┐ ┌──▼────────┐
│ PreemTimelineUI│ │ PreemML   │ │PreemEffects│ │PreemRender│
└──┬─────────────┘ └──┬────────┘ └──┬─────────┘ └──┬────────┘
   │                  │             │              │
   │                  │             │              │
   │                  └────┐        │              │
   │                       │        │              │
   │                ┌──────▼────────▼──────────────▼──┐
   │                │           PreemMedia            │
   │                └──────────────┬──────────────────┘
   │                               │
   │                ┌──────────────▼──────────────────┐
   └───────────────►│           PreemCore             │
                    └─────────────────────────────────┘
```

Rule: arrows point downward only. Never upward, never sideways.

## PreemCore — the data model

The project is a value type all the way down. Mutating an edit means producing a new `Project` value (with structural sharing through reference-typed media pool entries, since those are large). This is what gives us free undo/redo: every snapshot is a `Project` ref.

```
Project
├── mediaPool: MediaPool
│   ├── bins: [Bin]
│   │   └── items: [BinItem]            (Clip or nested Bin)
│   └── clips: [Clip.ID: ClipSource]    (large; reference-counted)
├── sequences: [Sequence]
└── settings: ProjectSettings
```

```
Sequence
├── id, name, settings (timebase, frameRate, resolution, colorSpace)
├── videoTracks: [VideoTrack]
├── audioTracks: [AudioTrack]
└── markers: [Marker]
```

```
Track
├── id, name, enabled, locked, height
└── clips: [PlacedClip]                 (sparse, sorted by .timelineRange.start)
```

```
PlacedClip
├── id
├── sourceClipID                        (reference into MediaPool)
├── sourceRange: TimeRange               (in:out within the source)
├── timelineRange: TimeRange             (in:out on the sequence timeline)
├── enabled
├── effects: [EffectInstance]
└── transitions: (in: Transition?, out: Transition?)
```

All times are `RationalTime` (numerator/denominator) to avoid float drift. A 23.976 timeline uses 24000/1001; we never store seconds-as-Double in the project file.

## Render graph

```
Sequence ──► RenderGraph ──► MTLCommandBuffer per frame

RenderGraph nodes:
  SourceNode(clipID, time)         leaf; emits MTLTexture (decoded frame)
  EffectNode(effect, [inputs])     applies effect; one MTL pass per *non-fusable* effect
  TransitionNode(a, b, t)          dissolve / wipe; one MTL pass
  TrackBlendNode([layers])         alpha composite, top-to-bottom
  OutputNode                       writes to drawable (preview) or VT encoder (export)
```

Hot rule: nodes that can fuse (transform + opacity, color matrix chains) compile to a single fragment shader at graph-finalize time. This is the only way real-time playback with 4+ stacked effects works without dropping frames.

## Project file format

`.preem` is a directory bundle:

```
MyProject.preem/
├── project.json           # versioned, sequences + media pool refs
├── thumbnails/            # per-clip thumbnail caches
├── waveforms/             # per-clip mono PCM thumbnails
├── proxies/               # per-clip ProRes 422 LT (or H.264) proxy files
├── ml/                    # cached slate OCR / transcription / shot results
└── autosaves/             # rotating last-N autosaves
```

`project.json` is forward-compatible: every node has a `schema` field; unknown fields are preserved on round-trip. We use a CBOR variant only if we hit a real size problem; JSON wins for diffability while the format is still churning.

## Playback path

```
Display Link tick (≈60 Hz)
  → TimelineCursor.currentTime
  → RenderGraph.evaluate(at: time)
     → SourceNode pulls decoded frame from VTSessionPool
     → EffectNodes composite via Metal
  → MTLDrawable.present()
```

VTSessionPool keeps decoders warm across seeks. We never recreate a `VTDecompressionSession` for a clip we played 200ms ago.

Audio runs through Polymerge's `AudioPlaybackEngine` (post-M2 integration). Until then, M1 uses AVKit and audio rides along with the AVPlayer.

## Apple Silicon constraints baked into the architecture

1. **Unified memory zero-copy.** Decoded frames are `IOSurface`-backed `CVPixelBuffer`s. They flow VideoToolbox → Metal → AVAssetWriter without ever touching CPU memory. Any code that calls `CVPixelBufferLockBaseAddress` on the hot path is a bug.
2. **One Metal device.** Apple Silicon has one GPU. We don't multi-device. (Intel branch: skip.)
3. **Display link not timers.** All preview animation runs off `CADisplayLink`. No `Timer.scheduledTimer`.
4. **Actor-isolated project model.** `Project` lives on a project actor. UI reads through `@MainActor`-isolated view models that snapshot the project. No shared-mutable on the project itself.
5. **Proxy-first.** Native footage gets a proxy transcode on import (ProRes 422 LT). The timeline always plays proxies; export reads originals. This is what makes Preem run well on an M3, not just an M3 Max.

## Cross-cutting concerns

- **Undo** is at the project-snapshot granularity for M1–M2. M3+ introduces a coarser edit-graph undo so multi-edit operations collapse to single undo steps.
- **Autosave** writes a fresh `autosaves/N.json` every 60s of dirty editing. Recovery on launch reads the freshest one with a "you crashed; recover?" prompt.
- **Logging** uses `os.Logger`. No `print` in shipped code.
- **Error model**: `throw` for recoverable, `assertionFailure` for impossible-in-correct-code, never `fatalError` outside `@main`.

## Testing strategy

Three tiers:

1. **Unit tests** (in `Tests/PreemCoreTests/`): time math, sequence mutations, project codable round-trip, edit operations. Deterministic, fast, no GPU/codec.
2. **Integration smoke runs** (manual until M3, scripted after): drop a folder of footage, build a sequence, render, compare hash.
3. **Real-session debugging**: the only thing that catches the actual VideoToolbox/MXF quirks. Have a corpus of test footage (a few takes from a real shoot, varied codecs) and run them through the app every milestone.
