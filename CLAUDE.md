# Kinestasis — Developer Guide

## What This Is

Kinestasis is a macOS app that turns burst-mode photo sets into video clips. Drag in a folder of stills (JPEG + OEM RAW); the app groups them into shots by capture-time gaps, previews them as draggable filmstrips, applies per-clip cadence (frames-per-still / as-shot timing / frame-skip), camera-raw-style grades, LUTs, film grain, and batch-exports ProRes clips at native resolution plus XML for NLE handoff. The signature aesthetic: 8–12 fps stills cadence, silent-film feel.

Forked from Preem (the macOS NLE, `~/Preem`) on 2026-08-10 per `WCID-WORKORDER.md` — same layered engine, pointed at a different product. The NLE ambition stays parked in Preem.

**Video compatibility (Jesse, 2026-08-10):** users may drop video files into a burst folder and expect them interpreted with the same look/feel as stills. AVFoundation video ingest (MOV/MP4/M4V — probe, thumbnails, skim, audio, playback) is retained; a video file becomes a shot alongside still-groups and shares the grade/grain pipeline. Only Preem's MXF-specific native demuxer path and the ML module (slate OCR / shot classifier / transcription) were pruned.

## Tech Stack

- **Language:** Swift 5.10+ • **UI:** SwiftUI panels; AppKit `NSView` + Metal for the timeline
- **Build:** SPM monorepo (`Package.swift`, no `.xcodeproj`)
- **Frameworks:** Metal/MetalKit, VideoToolbox, AVFoundation, ImageIO + CIRAWFilter (RAW decode), Core Image, Accelerate, Core Audio
- **Platform:** macOS 14.0+, Apple Silicon first-class

## Building & Running

```bash
swift build              # compile all targets
swift run Kinestasis     # launch the app
swift test               # run test suite
```

Release builds (`-c release`) required for real-footage work — Metal shader compile + VideoToolbox are tuned for optimized builds.

## Module Layout

```
Sources/
├── KineCore/         # pure data: Project, Sequence, Track, Clip, TimeRange, IDs
├── KineMedia/        # AVFoundation wrappers, probing, preview cache, project store
├── KineRender/       # Metal compositor, render graph, color pipeline
├── KineEffects/      # effect arsenal: xfade, transform, opacity, …
├── KineTimelineUI/   # AppKit NSView timeline + tools
├── KineAppUI/        # SwiftUI shells: bin browser, viewers, inspector, theme
└── KineApp/          # @main, AppDelegate, window scenes
```

Dependency rule: modules depend **upward only**; no cycles.

## PolymergeKit

Shared media-engine package at `../PolymergeKit` (own git repo), consumed via local-path SPM dep by PolyMerge, Preem, and Kinestasis. Products used: `PolymergeMediaModel`, `PolymergeIngest`, `PolymergeAudio`, `PolymergePlayback`. Library changes are committed in the Kit repo — after changing the Kit, build this app AND run `swift test` in `../polymerge` so a change never breaks another consumer silently. No PolymergeKit API breaks; Kinestasis-specific needs go in the Kit as additive public API or in a Kine module on top.

## Conventions

- One feature per PR. Small surface area beats heroic megacommits.
- Test what's deterministic (data model, time math, grouping, project file). GPU/codec paths go through manual smoke runs.
- No multi-paragraph docstrings; let names carry the meaning.
- No `// added for X` comments — git log is the changelog.
- Performance is a feature. Per-frame allocation on the render path is a bug.

## Inherited docs

`docs/` is inherited from Preem and still uses Preem-era names (Preem*, MXF, ML). Engine explanations (COMPOSITOR.md render invariants, TIMELINE.md editing model, COLOR.md pipeline) remain accurate for the shared machinery — read them for how things work, not for product scope. `docs/HANDOFF.md` state pointers describe Preem, not Kinestasis.

## Work order & status

`WCID-WORKORDER.md` (repo root) is the build plan: K1 ingest/grouping/timing/export → K2 grade → K3 motion/texture → K4 XML/assembly/DMG. Mark checkboxes there as tasks complete.

## WCID
After substantive work in this project, update `WCID.md` in this directory — it is how the WCID portfolio manager (~/WCID) tracks this project without crawling it.
