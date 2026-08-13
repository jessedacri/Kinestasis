# Kinestasis — session handoff

Entry point for a new session in this repo. `WCID.md` (repo root) carries
portfolio status; this file carries the engineering state, footguns, and file
map. Kinestasis is a standalone project (registered with the WCID manager);
Preem (`~/Preem`) is its ancestor and continues separately — do not touch it
from here.

## State (2026-08-11)

Feature-complete v0.1, shipped as a notarized DMG (`build/Kinestasis 0.1.dmg`,
rebuild with `NOTARIZE=1 ./scripts/build-dmg.sh`). 83 tests
(`swift test`; 4 more run with `KINE_REAL_FOOTAGE=1` against
`/Volumes/BLANK 2T/XPro2 Cincinnati`). Jesse is testing the DMG; expect a fix
list next session.

The flow: **Shots workspace** (default) — drag folders in, EXIF-gap grouping
into shots (min-burst threshold splits Singles aside; day sections), per-shot
inspector (player with space/JKL + trim, timing, grade, LUT, texture, ramp,
EXIF), batch export sheet (codec matrix + size estimate + optional fcpxml).
**Assemble mode** — the inherited Preem timeline; shots drag from the bin
straight onto it and play/export with zero pre-render.

## Architecture in one paragraph

Modules `KineCore → KineMedia → KineRender → KineEffects → KineTimelineUI →
KineAppUI → KineApp`, upward deps only, plus PolymergeKit (`../PolymergeKit`)
shared with PolyMerge/Preem — Kit changes must keep `swift test` green in
`../polymerge`. Burst model + timing engine live in KineCore
(`BurstShot.swift`: grouping, three timing modes, trim, ramp, wobble —
all pure and tested). KineMedia holds ingest (`StillsIngest`, parallel EXIF
probe), decode (`StillDecoder`, `ShotGradeRenderer` CI pipeline),
`BurstShotExporter` (windowed multi-core develop → hardware encoder), and
`ShotFrameSource` (stills → `VideoFrameSource`, which is how shots play on
the timeline: the compositor resolves `kine-shot://<uuid>` clip URLs to it).

## Footguns (learned the hard way — don't regress)

- **Never `Bundle.module` on a launch path.** The swift-build-generated
  accessor searches only the .app root and this machine's absolute `.build`
  path, then traps — the packaged app crashed at launch on every other Mac
  (0.1.0, crash/). Use `KineCore.ResourceBundle.locate(named:)`, which
  checks Contents/Resources first and returns nil instead of trapping.
  `scripts/build-dmg.sh` smoke-launches the wrapped app with `.build`
  masked to catch any regression of this class; the manual equivalent is
  `mv .build .build.hidden && build/Kinestasis.app/Contents/MacOS/Kinestasis`.
- **X-Pro2 writes no sub-second EXIF.** Whole-second timestamp runs are
  spread evenly (`BurstGrouper.spreadEqualTimestamps`) or as-shot cadence
  collapses. Subsec fallback chain: Original → Digitized → SubSecTime.
- **RAW+JPEG pairs** collapse to one still (RAW primary, JPEG kept on
  `StillFrame.pairedJpegURL`; per-shot `useJpegSource` toggle). Without this,
  Sony/Canon dual-write cards double every burst.
- **Grid scroll**: `LazyVGrid` is only lazy inside a native SwiftUI
  ScrollView — never move the shot grid back into `ThinScrollView`
  (NSScrollView hosting defeats laziness; 221 cards all lived at once).
  High-frequency transport state stays on `WorkspaceModel.ShotTransport`
  (its own ObservableObject), never `@Published` on the workspace, or the
  whole grid re-renders at 24 Hz. `previewVersion` bumps are coalesced.
- **Export ≡ playback**: grain/wobble animate per output frame in BOTH
  `BurstShotExporter` (per-frame samples when texture is active) and
  `ShotFrameSource`. If you touch one, touch the other.
- **H.264 cannot hold 24 MP** — the codec caps long edge at 3840
  (`Codec.longEdgeLimit`); don't remove the cap.
- **App is force-dark at the NSApp level** (`KineApp`:
  `NSApp.appearance = darkAqua`) — that's what keeps Settings/menus/panels
  readable in system light mode. Root-view `preferredColorScheme` alone is
  not enough.
- **UI copy rules (Jesse):** no em dashes anywhere in UI strings; dialogs
  are on-brand KineTheme sheets, never `NSAlert` in the shots flow; long
  renders must announce destination and be cancellable; settings read as
  always-visible value controls, not dropdown filters.
- **Stale test objects**: after changing a KineCore init signature,
  `touch Tests/*/*.swift` — SPM sometimes links stale test objects and fails
  with phantom missing symbols.

## Next steps (queue as of 2026-08-11)

1. Jesse's DMG test feedback → fixes.
2. Work-order leftovers: fcpxml import into Resolve (note Premiere too);
   30-second screen capture of a real run.
3. Eyeball WB slider mapping + grain defaults on real photos.
4. Perf headroom if wanted: render the CI chain straight into writer pixel
   buffers (skip CGImage readback); disk-backed preview cache for instant
   cold skim on RAF.
5. Product: demand test (X-Pro2 demo video + landing page), then listing on
   the Lemon Squeezy rails (~/WCID/BASELINE.md).

## File map (Kinestasis-specific)

- `Sources/KineCore/BurstShot.swift` — model + grouping + timing engine
- `Sources/KineMedia/StillsIngest.swift` — scan, pairs, parallel EXIF probe
- `Sources/KineMedia/ShotGradeRenderer.swift` — CI develop, grain, LUT, `gradePreview`
- `Sources/KineMedia/BurstShotExporter.swift` — parallel export, codec matrix
- `Sources/KineMedia/ShotFrameSource.swift` — stills as a timeline frame source
- `Sources/KineMedia/ShotBatchXMLSidecar.swift` / `ExifReader.swift`
- `Sources/KineAppUI/ShotsWorkspaceView.swift` — home screen, grid, bar controls
- `Sources/KineAppUI/ShotGradePanel.swift` — inspector/player
- `Sources/KineAppUI/ShotExportSheet.swift` — export dialog + size estimate
- `Sources/KineAppUI/WorkspaceModel.swift` — shots section: ingest, transport,
  preview cache, trim, export, assembly-free timeline bridge (`ensureShotClip`)
- `scripts/build-dmg.sh` — sign + notarize; `scripts/generate-icon-*.swift`
- Inherited engine docs (`docs/*.md` from Preem) describe the compositor/
  timeline machinery and still use Preem-era names; read for mechanism, not
  product scope.
