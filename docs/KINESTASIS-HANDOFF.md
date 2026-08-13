# Kinestasis — session handoff

Entry point for a new session in this repo. `WCID.md` (repo root) carries
portfolio status; this file carries the engineering state, footguns, and file
map. Kinestasis is a standalone project (registered with the WCID manager);
Preem (`~/Preem`) is its ancestor and continues separately — do not touch it
from here.

## State (2026-08-13)

Current release 0.1.3 build 68 (`build/Kinestasis 0.1.3.dmg`, notarized;
rebuild with `NOTARIZE=1 ./scripts/build-dmg.sh` — but do NOT cut DMGs per
revision: build + launch locally for Jesse, he says when to cut). 103 tests
(`swift test`; 4 more run with `KINE_REAL_FOOTAGE=1` against
`/Volumes/BLANK 2T/XPro2 Cincinnati`). The 0.1.0 launch crash is fixed and
confirmed by the main user, who is now actively testing and feeding back.

The flow: **Shots workspace** (default) — drag folders in, EXIF-gap grouping
into shots (min-burst threshold splits Singles aside; day sections; capture
fps measured and shown per shot), FCPX-style hover skim (player previews the
hovered shot, selection changes only on click), per-shot inspector (player
with space/JKL + chords, trim with visible ranges, timing, orthogonal frame
skip, grade, LUT, texture, ramp incl. Hold on This Still, EXIF), M marks
stills as delivery selects, batch export sheet (codec matrix + size estimate
+ stills selections + optional fcpxml, remembers last-used, never overwrites
silently). **Assemble mode** — the inherited Preem timeline; shots drag from
the bin straight onto it and play/export with zero pre-render.

## Architecture in one paragraph

Modules `KineCore → KineMedia → KineRender → KineEffects → KineTimelineUI →
KineAppUI → KineApp`, upward deps only, plus PolymergeKit (`../PolymergeKit`)
shared with PolyMerge/Preem — Kit changes must keep `swift test` green in
`../polymerge`. Burst model + timing engine live in KineCore
(`BurstShot.swift`: grouping, timing modes, trim, orthogonal frame skip with
default+override, marked stills, ramp — all pure and tested; `RampBuilder`
generates hold ramps from dwell weights). KineMedia holds ingest
(`StillsIngest`, worker-capped parallel EXIF probe), decode (`StillDecoder`,
`ShotGradeRenderer` CI pipeline), `BurstShotExporter` (windowed multi-core
develop → hardware encoder), `StillExporter` (graded JPEG + originals/RAW
delivery), and `ShotFrameSource` (stills → `VideoFrameSource`, which is how
shots play on the timeline: the compositor resolves `kine-shot://<uuid>`
clip URLs to it). Playback/export consume `playbackFrames(skipDefault:)`
(trim, then skip); the project-default skip threads through the compositor
and encoder as `burstSkip`.

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
- **Never fan out unbounded high-QoS work.** Unbounded `.userInitiated`
  decode tasks (160 per hovered shot) and an all-cores probe at interactive
  priority brought a full M3 Max to a crawl on the 4k-still archive. Ingest
  probing runs at utility with cores-2 workers; thumbnails drain through a
  3-wide queue; preview decodes go through a 4-wide LIFO pool
  (`pumpPreviewDecodes`, newest-first so the frame under the cursor wins).
  New bulk work must join one of these pools, not spawn free tasks.
- **Skim never touches the selection.** Hover sets `skimShotID`; the player
  and transport follow `previewShot` (skim wins, else selection), the
  inspector reads `selectedShot`, and `endSkim()` restores the selected
  playhead. Do not route hover through `selectShot` again (the pre-0.1.2
  jank the user complained about).
- **Frame skip is orthogonal to timing** (`frameSkipOverride` per shot,
  `BurstDefaults.frameSkip` project-wide). `.frameSkip` stays in
  `ShotTimingMode` only as a decode-migration target; never offer it in UI.
- **Jesse's writing style for user-facing docs** (changelog etc.): short,
  flat bullets, no taglines, no flourish. He called the ornate version
  "annoying claude speak".

## Next steps (queue as of 2026-08-13)

1. Main-user feedback on 0.1.3 (stills selection + hold ramps are new).
2. Record Ramp round two: trackpad scrub recording with haptic ticks was
   built and pulled same day ("doesnt work right"); `RampBuilder.ramp(
   fromDwells:)` and its tests remain as the foundation. Get the scroll
   feel + direction right before reintroducing.
3. Stills pipeline extensions Jesse floated: RAW delivery with development
   settings applied but still editable (XMP sidecar).
4. Work-order leftovers: fcpxml import into Resolve (note Premiere too);
   30-second screen capture of a real run.
5. Eyeball WB slider mapping + grain defaults on real photos.
6. Perf headroom if wanted: render the CI chain straight into writer pixel
   buffers (skip CGImage readback); disk-backed preview cache for instant
   cold skim on RAF.
7. Product: demand test (X-Pro2 demo video + landing page), then listing on
   the Lemon Squeezy rails (~/WCID/BASELINE.md).

## File map (Kinestasis-specific)

- `Sources/KineCore/BurstShot.swift` — model + grouping + timing engine +
  frame skip + marked stills
- `Sources/KineCore/RampBuilder.swift` — hold/dwell ramp generation
- `Sources/KineCore/ResourceBundle.swift` — safe bundle lookup (launch crash)
- `Sources/KineMedia/StillsIngest.swift` — scan, pairs, capped parallel probe
- `Sources/KineMedia/ShotGradeRenderer.swift` — CI develop, grain, LUT, `gradePreview`
- `Sources/KineMedia/BurstShotExporter.swift` — parallel export, codec matrix
- `Sources/KineMedia/StillExporter.swift` — marked-stills delivery (JPEG/originals/RAW)
- `Sources/KineMedia/ShotFrameSource.swift` — stills as a timeline frame source
- `Sources/KineMedia/ShotBatchXMLSidecar.swift` / `ExifReader.swift`
- `Sources/KineAppUI/ShotsWorkspaceView.swift` — home screen, grid, bar controls
  (Rate / Timing / Skip / Split gap / Min burst)
- `Sources/KineAppUI/ShotGradePanel.swift` — inspector/player, hold-ramp controls
- `Sources/KineAppUI/ShotExportSheet.swift` — export dialog, stills toggles,
  overwrite question, last-used persistence
- `Sources/KineAppUI/WorkspaceModel.swift` — shots section: ingest, transport +
  skim state, bounded decode pools, trim, marks, export, timeline bridge
  (`ensureShotClip`)
- `Sources/KineAppUI/KineAppUI.swift` — key monitor incl. chord handling
- `CHANGELOG.html` — user-facing changelog (keep flat and plain)
- `scripts/build-dmg.sh` — sign + notarize + masked-`.build` launch smoke test
- Inherited engine docs (`docs/*.md` from Preem) describe the compositor/
  timeline machinery and still use Preem-era names; read for mechanism, not
  product scope.
