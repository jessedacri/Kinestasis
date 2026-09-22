# Kinestasis

A macOS app that turns burst-mode photo sets into video clips.

Drag in a folder of stills (JPEG and OEM RAW). Kinestasis groups them into
shots by capture-time gaps, previews them as skimmable filmstrips, and gives
each shot its own cadence, speed ramps, camera-raw-style grade, LUT and film
grain. Export is batched: ProRes, H.264 or HEVC at native resolution, plus
FCPXML for handoff to an NLE. Marked stills ride along, delivered as graded
full-res JPEGs beside the movies.

The look it is built for: 8 to 12 fps stills cadence, silent-film feel.

Video files dropped into a burst folder are ingested too, and share the same
grade and grain pipeline.

## Status

R&D. Current build is 0.1.6; `main` carries unshipped work beyond it.
Not open for contributions.

## Requirements

- macOS 14.0 or later, Apple Silicon
- Swift 5.10 or later
- A checkout of [PolymergeKit](https://github.com/jessedacri/PolymergeKit) in
  a sibling directory

Kinestasis consumes PolymergeKit as a local-path SPM dependency, so the two
repositories have to sit side by side:

```
parent/
├── Kinestasis/
└── PolymergeKit/
```

## Building

```bash
swift build              # compile all targets
swift run Kinestasis     # launch the app
swift test               # run the test suite
```

Use `-c release` for real work with footage. Metal shader compilation and
VideoToolbox are tuned for optimized builds, and debug builds do not keep up.

`scripts/build-dmg.sh` packages a signed, optionally notarized .dmg. It reads
a signing identity and keychain notary profile that only exist on the
maintainer's machine.

Some tests run against a real photo archive and skip when the volume is not
mounted, so a run reporting skipped tests is normal.

## Module layout

```
Sources/
├── KineCore/         # pure data: shots, timing, ramps, project model
├── KineMedia/        # ingest, decode, develop, export, preview caches
├── KineRender/       # Metal compositor, render graph, color pipeline
├── KineEffects/      # transitions, transform, opacity
├── KineTimelineUI/   # AppKit NSView timeline
├── KineAppUI/        # SwiftUI shells: grid, player, inspector, sheets
└── KineApp/          # @main, AppDelegate, window scenes
```

Modules depend upward only. No cycles.

## Docs

- `docs/KINESTASIS-HANDOFF.md` — engineering state, footguns, file map
- `docs/PARALLAX-SPIKE.md` — single-photo parallax investigation
- `docs/COMPOSITOR.md`, `docs/TIMELINE.md`, `docs/COLOR.md` — engine mechanics

Kinestasis was forked from Preem, a macOS NLE, and the inherited engine docs
still use Preem-era names. Read them for how the machinery works, not for what
this product is.

## License

All rights reserved.
