# Apple Silicon — which API for which job

The premise: Apple Silicon is not a CPU you happen to be running on, it's a coordinated set of accelerators with a unified memory model. Code that doesn't exploit that leaves 5–20× on the table. This doc says which accelerator each subsystem uses and why.

## The accelerators we actually use

| Block | What it does | How we reach it |
|---|---|---|
| **CPU performance cores** | Swift code, project model, scheduling | Swift Concurrency, GCD when needed |
| **CPU efficiency cores** | Background indexing, ML thumbnailing | QoS `.utility` or `.background` |
| **GPU** | Compositor, effects, scopes, scaling | Metal directly |
| **Media Engine (H.264/HEVC)** | Decode + encode | VideoToolbox |
| **ProRes Engine** (M1 Pro+) | ProRes decode + encode at high throughput | VideoToolbox |
| **Apple Neural Engine** | Slate OCR, shot class, transcription | Core ML w/ `MLComputeUnits.all` |
| **AMX / matrix coprocessor** | Heavy DSP, batch matrix ops | Accelerate vDSP / vImage / BNNS |

On an M3 Pro: 1 ProRes engine, 2 Media engines, 16-core ANE, GPU shared. On an M3 Max: 2 ProRes engines, 2 Media engines. On an M3 Ultra: 4 ProRes engines, 4 Media engines. Our export pipeline parallelizes across these — see "Export" below.

## Render pipeline rules

**Rule 1: Zero-copy or you've lost.** Decoded frames are `IOSurface`-backed `CVPixelBuffer`s. They flow:

```
VTDecompressionSession → CVPixelBuffer (IOSurface)
                       → CVMetalTextureCache → MTLTexture       (no copy)
                       → Metal compositor passes               (GPU-resident)
                       → MTLDrawable.present                    (preview)
                       OR
                       → AVAssetWriter via CVPixelBufferPool   (export)
                       → VTCompressionSession                  (encode)
```

The CPU never touches the pixels. `CVPixelBufferLockBaseAddress` on the hot path is a bug; it's only acceptable for thumbnail-export and snapshot operations.

**Rule 2: One Metal device per process.** We don't multi-device on Apple Silicon (there's only one GPU; UMA makes "transfer to GPU" meaningless).

**Rule 3: Texture cache, not texture creation.** Build a single `CVMetalTextureCacheCreate` at session start, reuse it for the lifetime. Creating `MTLTexture` per frame is wasteful and pessimizes against the cache.

**Rule 4: Display link, not timer.** Preview animation runs off `CADisplayLink` (or `CVDisplayLink` on macOS pre-14 for non-Retina) — anything else fights ProMotion variable refresh.

**Rule 5: Effects fuse.** A render graph that produces 5 sequential fragment passes for transform + opacity + color matrix + LUT + vignette is GPU-bandwidth-bound. We fuse fusable nodes into a single shader at graph-finalize time. Non-fusable boundaries: anything that reads neighbor pixels (blur, sharpen, mask edges).

## Decode

`VTDecompressionSession` per (codec, format) combination, pooled in `VTSessionPool`. We never recreate a session for a seek; we issue a flush + a fresh `decodeFrame` with `_DoNotOutputFrame` to seek without decode.

Per codec:

| Codec | Path |
|---|---|
| H.264 / HEVC | VideoToolbox via Media Engine |
| ProRes 422/4444 | VideoToolbox via ProRes Engine (M1 Pro+) or VideoToolbox software path |
| MXF-wrapped H.264 / ProRes / XAVC / DNxHD | Custom KLV walker (port from Polymerge `MXFEssenceReader`) → VTDecompressionSession |
| ARRI RAW (.ari, .arx) | Phase-deferred. Likely Atomos/ARRI SDK. |
| RED R3D | Phase-deferred. REDline / R3D SDK. |
| BRAW | Phase-deferred. Blackmagic SDK. |

The deferred codecs aren't in M1–M4. They become important when contesting Premiere for actual broadcast/feature jobs.

## Encode (export)

Parallel `VTCompressionSession`s, one per available engine. We probe `VTIsHardwareEncoderSupported` and the engine count at startup. Export divides the timeline into N segments (one per engine), encodes them in parallel, and stitches via `AVAssetWriter` concat (proven; same pattern Compressor uses internally).

ProRes 422 LT for proxies. ProRes 422 HQ or 4444 for delivery, depending on user choice.

## Color pipeline

```
linearize (γ 2.2 → linear) → exposure (multiply by 2^stops)
                          → color matrix (CDL / primary wheels at M5)
                          → 3D LUT sample (Polymerge PPE pattern)
                          → tonemap (per output space)
                          → re-encode to display γ
```

The whole thing is one fragment shader when no neighborhood-touching nodes are active (M3+). LUT loading from .cube files is borrowed from Polymerge `PPELUTLoader`.

ACES is a M6+ research item; for M1–M5 we operate in BT.709 / sRGB with optional Rec.2020 for HDR previews.

## Audio

We use Polymerge primitives end-to-end:

- `AudioPlaybackEngine` for timeline playback (multi-track mixer)
- `TrackBufferBuilder` for per-clip prep
- `HighPassFilter` (vDSP.Biquad) for HPF/LPF
- `LoudnessAnalyzer` for BS.1770 metering
- `PhaseAligner` for sync-by-waveform multicam (M5)

Polymerge's audio engine already uses Accelerate and the AMX-friendly biquad APIs. We inherit that.

## ML — slate, shot, transcription

All three target the Neural Engine. We use `MLComputeUnits.all` and let CoreML schedule.

| Feature | Model | Input |
|---|---|---|
| Slate OCR | Vision `VNRecognizeTextRequest` (`.accurate`) | First 5s + last 5s sampled at 2 fps |
| Shot type (wide / med / close / etc.) | Fine-tuned MobileNetV3 or Apple's built-in image classifier | One frame per shot |
| Transcription | Apple `SFSpeechRecognizer` offline OR whisper.cpp Core ML | Extracted dialogue track |

All three run on a `.utility`-QoS background queue, results cached in `MyProject.preem/ml/`. Re-running is cheap; we always start with the cache.

## What we explicitly *don't* do

- We don't use OpenGL. Deprecated on macOS.
- We don't use Core Image for hot-path rendering. (We may use it for export-time stills.)
- We don't ship CPU-only fallbacks for things VideoToolbox can do. If the user is on hardware that can't accelerate ProRes, they get a slower software path *via VideoToolbox itself* — we don't write a competing software decoder.
- We don't roll our own H.264/HEVC/ProRes decoder. We use VideoToolbox even when annoying.
- We don't use Combine for engine code (only in UI layer). Engine uses Swift Concurrency.
