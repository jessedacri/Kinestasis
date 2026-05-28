# Preem — Playback + compositor architecture

How frames + samples flow from `Project` data to the user's eyeballs and ears. Editing patterns are in `TIMELINE.md`. **Major refactor 2026-05-27**: the dual-PPE realtime program viewer was replaced by a single unified compositor that runs the same offline-render pipeline at the display rate. Realtime ≡ render by construction.

## Playback state machine

`WorkspaceModel.playbackState: PlaybackState` is the single source of truth for what's playing right now.

```swift
public enum PlaybackState: Equatable, Sendable {
    case stopped
    case program(rate: Double)
    case source(rate: Double)
}
```

`isPlaying`, `sourceIsPlaying`, `playbackRate` are computed from this. All transitions go through `WorkspaceModel.setPlayback(_:)`, which:

1. Bumps `playbackGen: UInt64` (any async work in flight that checks generation will bail).
2. Tears down the current state (both audio engines + playback display link).
3. Starts the new state.

Async tasks (e.g. `audio.sync` awaits) **must** capture `let myGen = playbackGen` before awaiting and check `guard myGen == playbackGen` before doing anything stateful. Otherwise you re-introduce the two-playhead bug.

`program` and `source` are mutually exclusive — only one viewer ever has audio.

## Video pipeline — unified compositor

**The single source of truth: `PreemRender/OfflineSequenceCompositor.swift`.** Same compositor for:
- Realtime program viewer (display-link driven, writes to a `CAMetalLayer` drawable).
- Pre-render cache writes (`Render In to Out` → ProRes 422 LT).
- Export (`SequenceEncoder` → ProRes / H.264 / HEVC via AVAssetWriter).

This guarantees pixels-on-screen match pixels-in-render — Premiere/FCP-style.

### Composition rules

For each frame at time `t`, the compositor enumerates `effectiveLayers(at:)` — bottom-up across `videoTracks`:

- **Single clip on a track**: emits one `LayerContribution.single(frame, uniforms)`. `uniforms` carries the clip's `ClipTransform` translated to a `LayerUniforms` (destRect + cropRect + opacity + rotation). Solo fade-in / fade-out is folded into the opacity.
- **Paired cross-dissolve on a track** (two abutting clips with paired `transitionIn`/`transitionOut` of the same kind): emits one `LayerContribution.crossDissolve(aFrame, aUniforms, bFrame, bUniforms, progress)`. Each clip carries its **own** transform uniforms — so a 4:3 → 16:9 dissolve preserves both aspects through the transition.

Empty regions of any layer fall through to whatever's behind (the accumulator), and ultimately to black. **Aspect is honored by default; nothing auto-stretches** unless a clip's `Transform.stretchToFill` is explicitly true.

### Per-layer transform (the math the shader runs)

`layerUniforms(for:source:fadeAlpha:)` computes the layer's:

- **destRect** in output UV space (where the layer sits in the sequence frame). Aspect-preserving fit by default; the clip's `Transform.positionX/Y` shifts it, `scaleX/Y` scales it, `stretchToFill` forces full-output.
- **cropRect** in source UV space (the source rect that maps into the destRect). `Transform.cropTop/Right/Bottom/Left` controls this; 0..1 fractions to cut from each side.
- **opacity** = `Transform.opacity × fadeAlpha` (where `fadeAlpha` is the solo-fade ramp).
- **rotation** = `(cos θ, sin θ)` precomputed; the shader rotates the source UV around the destRect's center, aspect-corrected.

### Two-pass render-to-drawable

The realtime host writes into a `CAMetalLayer` drawable whose dimensions match the view (so it's pixel-sharp at the user's actual viewer size). But layer destRects are in **sequence UV**, not drawable UV. The fix is two passes:

1. `composeAsync(at:into outputTexture:)` composes all layers into a sequence-resolution scratch CVPixelBuffer via `renderLayersIntoBuffer(_:into:)`.
2. `presentSingleSourceFrame(_ scratch, into: drawable)` aspect-fits the composed scratch into the drawable (letterbox/pillarbox the entire sequence picture into whatever-size drawable the user has).

The cache fast-path uses the same `presentSingleSourceFrame` so paths look identical at cache boundaries.

### Cross-dissolve shader (alpha-aware)

`compositorCrossDissolveFragment` in the inline shader source. Per-fragment:

```
wA = (uv ∈ A.destRect) ? A_opacity * (1-progress) : 0
wB = (uv ∈ B.destRect) ? B_opacity * progress     : 0
wAcc = max(0, 1 - wA - wB)
result = wAcc * acc + wA * A_sample + wB * B_sample
```

This produces:
- Inside both destRects: `(1-p)*A + p*B` — true cross-dissolve.
- Inside A only: `p*acc + (1-p)*A` — underlying shows through where A is fading and B doesn't reach.
- Inside B only: `(1-p)*acc + p*B`.
- Outside both: `acc` unchanged.

Single render pass with three input textures (acc, A, B).

### Per-source frame cache

`pullFrame(source:atSourceTime:)` is the critical correctness fix for cross-rate playback. The realtime host calls `compose(at:)` 60–120 times per second, but a 24fps source has frames spaced ~41 ms apart. Without caching, every tick advanced the source via `nextFrame()` — playback ran at 60+ fps.

The cache stores the last delivered `PPEDecodedFrame` per source with `[pts, pts+duration)` window. If the requested target falls in the window, return the cached buffer without touching the source. Otherwise walk forward via `nextFrame` (one frame at a time, never overshooting — the break condition is "target inside this frame's window," not "PTS ≥ target"). Backward jump or large forward gap invalidates the cache.

### Realtime host: `RealtimeProgramHost.swift`

- `RealtimeProgramHostView` (SwiftUI `NSViewRepresentable`) — wraps `RealtimeMetalView` (an `NSView` with `CAMetalLayer` backing).
- `Coordinator` (@MainActor) owns the `OfflineSequenceCompositor`, a `CVDisplayLink`, and an `inFlight: Bool` flag.
- Display link → main actor → `renderTick()`:
  1. **Snapshot** workspace state (playhead seconds, cache segment at playhead) on main.
  2. Update `layer.drawableSize = view.bounds × backingScale`.
  3. Acquire `layer.nextDrawable()`.
  4. Set `inFlight = true` and detach a `Task.detached(priority: .userInitiated)`.
- Background task → `composeAsync` (uncached path) OR `CacheFrameReader.render` (cached path) → `drawable.present()` → bumps `inFlight = false` back on main.

If the previous tick's compose is still in flight when the next display tick fires, the new tick is dropped. Bounds the GPU queue to 1 frame and keeps main from accumulating pending render tasks.

### Cache fast-path

`WorkspaceModel.cacheSegmentAtPlayhead()` returns the on-disk segment URL covering the current playhead (or nil). When non-nil, the realtime host uses `CacheFrameReader` instead of the compositor — direct `AVAssetReader` → `CVPixelBuffer` → `compositor.presentSingleSourceFrame(into: drawable.texture)`.

`CacheFrameReader`:
- Lazily opens the `AVAssetReader` on the first `render(at:)` call, seeking to the actual target time (NOT to 0 — that's what caused the post-render fast-motion sweep).
- Maintains the same `[pts, pts+duration)` frame cache as the compositor.
- Backward jump or large forward gap (> 0.5 s) → reseek; otherwise walk forward via `copyNextSampleBuffer`.
- Reuses the compositor's blend pipeline (via `presentSingleSourceFrame`) so the cache picture aspect-fits into the drawable identically to the live path.

### Frame-drop indicator

`Coordinator.noteDuration(started:)` times each compose+present roundtrip. After 4 consecutive sustained drops, `workspace.realtimeIsDropping = true` — surfaced as a subtle orange chip in the program viewer header: *"Dropping frames · Render In to Out for smooth playback"*. Clears when frames stop dropping.

### Transition data model

- `Transition.kind: String` — `"crossDissolve"` is the only one rendered today. Other kinds round-trip in the data model + Settings catalog for future work.
- `Transition.duration: RationalTime` — for paired transitions, this is the HALF-DURATION on this clip's side. `transitionOut.duration` on outgoing = left half; `transitionIn.duration` on incoming = right half.
- For solo fades (no paired neighbor), `transitionIn.duration` is the full fade-in length; `transitionOut.duration` is the full fade-out length.

Defaults from `PreemSettings.shared.defaultTransitionKind` + `defaultTransitionFrames`.

### Paired-fade-in source shift

For incoming clip B with a paired transitionIn, B's source playback maps from `B.sourceRange.start` starting at the dissolve's pre-cut boundary (not at `cutT`). User loses `leftHalf` seconds of B's content (the "no handles" Premiere compromise) but B has real motion during the dissolve. `WorkspaceModel.playbackShiftForPairedFadeIn(_:in:)` computes the shift; the compositor's `effectiveLayers` applies it.

## Direct manipulation overlay

`PreemAppUI/ProgramTransformOverlay.swift` — a SwiftUI overlay on top of `RealtimeProgramHostView`. When a clip is selected and visible at the playhead:

- Bounding box stroked in accent color, sized via the same math `layerUniforms` uses (so the box always matches what's on screen).
- Center drag area: drag updates `Transform.positionX/Y` (delta normalized by sequence width/height).
- Corner handles (4): drag scales `Transform.scaleX/Y` uniformly around the destRect's center.
- Gestures are undo-batched (`beginUndoBatch` on first drag tick, `endUndoBatch` on release) so one drag = one Cmd+Z.

Per-edge scale + a rotation grip are TBD.

## Effect Controls inspector

`PreemAppUI/EffectControlsPanel.swift`, opened via `⇧⌘5` (or Clip menu → "Effect Controls…"). Shows the selected clip's `ClipTransform`:

- Transform: positionX/Y, scaleX/Y (with reset), opacity (slider + %), rotation (degrees), fill mode (Aspect Fit / Stretch to Fill).
- Crop: top / right / bottom / left sliders with %.
- Multi-select aware: edits apply to all selected clips.
- Routes through `WorkspaceModel.setClipTransform(_:_:)` which uses `updateSequence` so undo + cache invalidation work normally.

## Audio pipelines

Two `AudioPlaybackEngine` instances. Mutex via `PlaybackState`.

### `WorkspaceModel.audio: TimelineAudioPipeline`

Drives the timeline. Each `PlacedClip` on an audio track becomes one `TrackBuffer` with `fileOffsetSamples` set to the clip's timeline-start in samples.

- Mute / solo respected at buffer-build time.
- Cache key: `lastBuiltSignature: String?`. `nil` = rebuild on next sync.
- Output latency subtracted when computing the visible playhead.
- Audio fade envelopes: `applyFadeEnvelope` — sin curve fade-in, cos curve fade-out. Constant-power: `sin² + cos² = 1`, perceived loudness stays flat across paired audio cross-fades.
- Paired audio dissolves extend each buffer into the overlap region so the engine sums them.

### `WorkspaceModel.sourceAudio: SourceAudioPipeline`

Drives the source viewer. Same engine type, single `TrackBuffer` scoped to the loaded source clip.

### Offline audio mixdown — `PreemMedia/OfflineAudioMixdown.swift`

For pre-render + export. Mirrors `TimelineAudioPipeline.buildTrackBuffers` byte-for-byte (mute/solo/enabled gating, paired-cross-fade extensions, sin/cos envelopes) and produces non-interleaved `[[Float]]` ready for `AVAssetWriter` (which transcodes to PCM 16/24-bit or AAC depending on the export's `audioOutputSettings`).

Current limitation: stereo (or mono) mixdown only. Multi-track preservation (a 4-camera source's discrete audio tracks staying separate in the output) is on the next-session backlog — needs an `AVAssetReader`-per-track loader path.

## Source viewer playback path

`ViewerPane` still renders source video via `SourcePPEHost` (a separate single-PPE host that hasn't been compositor-refactored — source has no multi-layer needs). Source audio plays through `WorkspaceModel.sourceAudio`.

`startSourcePlayback`:
- For 1× with audio tracks: `sourceAudio.sync(to: clip, startSeconds:)` → `sourceAudio.play()` → start display link. The visible playhead follows wall-clock minus `sourceAudio.outputLatencySeconds`.
- For non-1× shuttle (J / L) or audio-less clips: plain wall-clock display link, no audio engine.

`sourceTick` checks `sourceAudio.transport.isPlaying` to detect natural end-of-clip; clamps to `[0, clip.duration.seconds]` for shuttle.

## Timecode

`PreemCore/Timecode.swift` — central SMPTE formatter for both program viewer header and timeline ruler.

- 23.976 / 24 / 25 / 30 / 50 / 60 → non-drop-frame `HH:MM:SS:FF`. 23.976 displays as 24-fps timecode.
- 29.97 / 59.94 → true SMPTE drop-frame `HH:MM:SS;FF`.

Program viewer header: `"WxH FPS | TC"` — e.g. `"3840x2160 23.976 | 00:00:12:14"`.

## Preview cache (waveforms + thumbnails)

`PreemMedia.ClipPreviewCache` generates downsampled audio peaks + evenly-spaced video thumbnails on background tasks. Cached per source `ClipID`. `previewVersion` is `@Published` so SwiftUI re-renders push fresh snapshots into the timeline NSView.

## Pre-render cache

`PreemMedia/PreRenderCache.swift` — file layout for baked sequence segments.

- Files at `~/Library/Caches/Preem/projects/<projectID>/prerender/<sequenceID>_<startMs>_<endMs>.mov`.
- Keyed by project UUID so the cache survives renames / moves.
- `clearAll(forProjectID:sequenceID:)` is called by `WorkspaceModel.updateSequence{,WithoutUndo}` and `applyRestoredProject` — any edit invalidates the entire sequence's cache.
- `segmentContaining(timelineSeconds:...)` is the realtime host's lookup; returns the URL + range or nil.
- The encoder's `Render In to Out` writes here; freshness is guaranteed by the unconditional invalidate on every edit.

## Compositor uniforms layout (Metal interop)

```swift
public struct LayerUniforms {           // 64 bytes
    var destRect: SIMD4<Float>          // (minU, minV, maxU, maxV) in output UV
    var cropRect: SIMD4<Float>          // (minU, minV, maxU, maxV) in source UV
    var opacity:  SIMD4<Float>          // .x = opacity; rest reserved
    var rotation: SIMD4<Float>          // .x = cos θ, .y = sin θ
}

public struct CrossDissolveUniforms {   // 112 bytes
    var aDestRect, aCropRect, aRotation: SIMD4<Float>
    var bDestRect, bCropRect, bRotation: SIMD4<Float>
    var weights: SIMD4<Float>           // .x = wA, .y = wB
}
```

Every field is `float4` to keep MSL and Swift alignment unambiguous. Shaders mirror the structs verbatim — see the inline `shaderSource` string at the bottom of `OfflineSequenceCompositor.swift`.

## Polymerge (forked in-tree)

Preem owns `Sources/Polymerge{MediaModel,Ingest,Audio,Playback}/` as of 2026-05-27. PPE's `AVAssetFrameSource` (in `PolymergePlayback`) is the pull-mode video source the compositor uses — it abstracts AVAssetReader-with-IOSurface decode for MOV/MP4/M4V/HEIC. MXF support via `MXFFrameSource` lives in the same module. Modify these freely; no upstream coupling.

The original dual-PPE realtime path (PPE's `CAMetalLayer` driving the program viewer's display directly) is **gone** as of the 2026-05-27 refactor. PPE-as-display-driver still appears in `SourcePPEHost` for the source viewer, where the realtime compositor isn't needed.
