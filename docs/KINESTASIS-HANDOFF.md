# Kinestasis — session handoff

Entry point for a new session in this repo. `WCID.md` (repo root) carries
portfolio status; this file carries the engineering state, footguns, and file
map. Kinestasis is a standalone project (registered with the WCID manager);
Preem (`~/Preem`) is its ancestor and continues separately — do not touch it
from here.

## State (last worked 2026-08-14)

**Read this first: `main` is ahead of what anyone is running.** The main
user is on 0.1.6 (`build/Kinestasis 0.1.6.dmg`, cut 2026-08-13). Three
things landed after that cut and have never been in a build anyone has
touched:

1. the GIF top-row static fix (their bug, see the Core Image footgun),
2. Record Diagnostics (built *for* them, and useless until they have it),
3. the boomerang preview in the player transport.

So the first substantive question of the next session is whether Jesse
wants 0.1.7 cut. Nothing else in the queue matters as much, because item 2
is the only route to diagnosing their scrub pinwheel and it cannot start
until they have the build. `scripts/build-dmg.sh` still says
`SHORT_VERSION="0.1.6"` — bump it, and update `CHANGELOG.html`.

Rebuild with `NOTARIZE=1 ./scripts/build-dmg.sh` — but do NOT cut DMGs per
revision: build + launch locally for Jesse, he says when to cut. 129 tests
(`swift test`; more with `KINE_REAL_FOOTAGE=1` against
`/Volumes/BLANK 2T/XPro2 Cincinnati` — they skip when the volume is not
mounted, so a "6 skipped" run is normal, not a failure). The main user
actively tests and sends excellent logs (`kinestasis-logs-from-user/`).

**Commit messages carry no `Co-Authored-By` trailer and never will.** Jesse
asked twice, emphatically, and on 2026-08-14 all 110 commits on `main` were
rewritten to strip them. Do not reintroduce one. The only surviving copies
are in `refs/remotes/origin/*`, a vestigial remote pointing at the local
`~/Preem` fork source; `git remote remove origin` clears them if he wants
that, and nothing here has ever been pushed anywhere.

**Loose binaries got committed by accident** on 2026-08-14 (a broad
`git add -A`): `DSC02568.jpeg`, `DSC02568 2.jpeg` at the repo root, and the
same scanline GIF in both `examples/` and `repro/`. About 14 MB, `.git` is
68 MB. Untracking them is one command; purging the blobs is another history
rewrite. Jesse's call, not a silent cleanup.

**Field diagnostics (new):** Kinestasis menu > Record Diagnostics, or
`--diagnostics`, writes one plain-text file to
`~/Library/Logs/Kinestasis` (not Documents - macOS gates that behind a
consent prompt a remote user might dismiss): stalls with the app's
activity at the time, decode queue depth, RAM and disk cache hit rates,
slow decodes, tier changes. Content
is timing, counts, and basenames only, so a user can send it without
sending their pictures. `KineDiagnostics` (KineCore) costs one Bool read
when off; messages are autoclosures, counters aggregate between snapshots.
This exists because the main user pinwheels while scrubbing and this
machine has never reproduced it.

**Debug rig (use it):** `Kinestasis --import <folder>` replays the
drag-a-folder flow; add `--develop` to auto-enter Develop on the biggest
burst and play. A watchdog prints `[lag] main thread stalled Nms + pool
stats` to stderr. Launch with `2>/tmp/kinestasis-stderr.log` and read the
log; `sample <pid>` + `top -stats pid,command,cpu,th` found every stall
this session. NEVER leave a rig instance playing after a test — it eats
Jesse's machine (he works on the same box; his YouTube-and-typing test is
the acceptance bar for background work).

The flow: **VIEW bar (Bin | Develop | Assemble)**. Bin = card grid with
hover skim (player previews hovered shot, selection changes on click),
capture-fps per shot, day sections, singles pruning. Develop (Cmd+F with
native fullscreen) = one specimen at a time: big player, inspector at the
side, skimmable strip below, prev/next via arrows, key-glyph bar. Per-shot
inspector: player (space/JKL + chords: I+O clears trim, K+L / J+K nudge),
trim with visible ranges, timing + orthogonal frame skip, LR-ordered grade
(fixed highlights direction, whites/blacks, tone curve editor, S-curve
contrast), LUT, grain, visible wobble (0.85 EV + contrast flutter), ramps
incl. Hold on This Still (frames + ease in/out + then-skip). M marks stills
as delivery selects. Exits: batch export sheet (codec matrix, stills
selections with originals/RAW, fcpxml, remembers last-used, never
overwrites silently), per-shot GIF export (cadence-true delays, boomerang
toggle in the transport that previews the exact loop the file will play),
drag the player frame out as a full-res graded JPEG (file
promise). **Assemble** — the inherited Preem timeline; shots drag from the
bin straight onto it and play/export with zero pre-render.

**Preview pipeline (rebuilt this session; understand before touching):**
three tiers (Draft 448 / Balanced 960 / High 2560-real-develop) in device
pixels; a paused playhead refines to a 2560 develop. Every decode goes
through `PreviewDiskCache` (~/Library/Caches, keyed path+size+mtime+tier,
20GB sweep): a frame develops once per tier EVER. In RAM, an epoch-tagged
byte-budget cache (stale frames keep serving and re-decode lazily on tier
change; eviction pins the previewed shot). Decode pool: LIFO user requests
at utility, priming strictly-serial-ish behind them (2 slots, released on
ALL skip paths - a leak here froze generation once). Generation phases
serialize: probe -> thumbnails (2-wide) -> priming; skeleton cards reveal
in ~10-shot batches; playback pauses priming and feeds its own lookahead.
Video clip previews (thumbs/waveforms) run STRICTLY one clip at a time.

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
- **Core Image rounds a scaled extent OUTWARD.** Scaling 4240x2832 (A7S III)
  to 960 wide gives 641.207 rows, and CI reports the extent as 642 - one
  row the image covers a fifth of. Rendered, that row has partial alpha,
  and ImageIO dithered it into a line of static across the top of every
  GIF the main user made. Aspects that divide evenly (X-Pro2 6000x4000 to
  960x640) never show it, which is why it never reproduced here.
  `ShotGradeRenderer.downscale` crops to `extent.applying(transform)
  .containedIntegral` - the pixels the image actually fills. Cropping to
  the extent CI reports is a no-op, because it has already rounded.
  Any new scale-then-render path needs the same crop.
- **Boomerang lives in `KineCore.BoomerangLoop`**, read by both the player
  transport and `GIFExporter`. The return pass skips the first and last
  STILL, not the first and last frame, and a ramp holds one still across
  several schedule events - so the ends are runs to measure, not single
  events. Change the loop shape in one place only, or the preview stops
  being a preview.
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
- **The whole-machine-hitching postmortem (days of Jesse pain — learn it):**
  the villain was measured, not guessed: unbounded per-video thumbnail +
  waveform jobs exploded the SHARED VTDecoderXPCService to 2,740 threads
  (our process 1,559) — Safari video and system input died with it. Video
  preview jobs are strictly serial now. Also convicted along the way, each
  real: per-frame previewTicker bumps redrew the whole grid at 7 Hz
  (WindowServer storm — bump only when the landed frame is on-screen);
  CALayer implicit contents-fade animations at playback rate; per-tick
  SwiftUI @State image swaps dragging full-window AppKit layout (frame
  pipeline now lives OUTSIDE SwiftUI: RenderPump + FrameSurfaceView);
  autosave JSON-encoding the project on main; a new CIContext per slider
  tick (share renderers); disk reads per view body (cache the Looks list).
  QoS classes do NOT throttle memory bandwidth or shared XPC services —
  serialize and pace instead. `.background` QoS starves work to uselessness
  on Apple Silicon; don't use it for anything the user waits on.
- **Publish-storm rule (violated three times before it stuck):** anything
  ticking faster than ~1 Hz must live on its own ObservableObject (see
  ShotTransport, PreviewTicker, PrimeProgress, KeyGlyphState) with the
  smallest possible observer, or on no publisher at all (RenderPump uses
  Combine sinks straight to a CALayer).
- **Pool accounting:** every skip/continue path in pumpPreviewDecodes must
  release the slot it claimed (primeInFlight leak = frozen generation) and
  completion paths must call maybeFinishGenerating or the skeleton reveal
  deadlocks.
- **JPEG embedded thumbnails are 160x120.** StillDecoder.preview falls
  through to a real scaled decode when the embedded image is far below the
  request — without that, JPEG bursts render garbage at every tier
  (PreviewSizeGuardTests pins it against the real archive).
- **In-camera RAW conversions** carry the ORIGINAL capture time on a new
  file number; BurstGrouper.isolateRedeveloped ejects them to Singles or
  they splice into their source burst as duplicate frames.
- **Odd-height videos** can fail VT conversion forever (err -536870206);
  ClipPreviewCache negative-caches failures and even-aligns thumb sizes.
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

## Next steps (queue as of 2026-08-14)

1. **Cut 0.1.7 when Jesse says.** Carries the scanline fix, Record
   Diagnostics, and the boomerang preview. Everything below item 2 is
   blocked behind it in practice.
2. **Then relay the diagnostics instruction to the main user**, verbatim:
   "In the Kinestasis menu choose Record Diagnostics, scrub the burst that
   pinwheels until it stalls, then choose Record Diagnostics again and send
   me the file it reveals in the Finder." When the log arrives: read the
   STALL lines and the counters around them, name the cause in `WCID.md`,
   fix it if small, scope it in a work order if not. The open hypothesis
   space is decode queue depth, a cache miss storm at the High tier, or
   something outside the preview pipeline entirely — the log exists
   precisely because guessing has not worked.
3. One question for the main user, not blocking (the fix is
   aspect-independent): confirm the scanline GIFs came from Sony files.
   The 960x642 geometry says A7S III, and confirming closes the loop.
4. **Parallax, if Jesse wants it** (`docs/PARALLAX-SPIKE.md` is the
   decision input; Apple's spatialization is closed to us, the camera-move
   route is open). Build order: depth on a single still behind a debug
   flag, warp in the compositor, the move as a generated schedule, the
   disocclusion fill, then the quality gate. Stop after step one if depth
   fails on his own frames.
5. Record Ramp round two: built and pulled ("doesnt work right");
   RampBuilder.ramp(fromDwells:) + tests remain. Get scroll feel +
   direction right before reintroducing.
6. Remaining GIF-first candidates Jesse did NOT pick on 2026-08-14, kept
   because they may come back: GIF button on the shot card and player,
   drag a GIF out the way stills drag out, per-shot GIF settings that
   persist. He chose only the loop preview; do not build these unasked.
7. Drag-out from filmstrip cards / marked stills (player-frame drag
   shipped; same file-promise machinery extends naturally).
8. Stills RAW delivery with editable develop settings (XMP sidecar).
9. Long-open verification: fcpxml import into Resolve (note Premiere too);
   30-second screen capture of a real run; eyeball WB slider mapping and
   grain defaults on real photos.
10. NOTE (possible revert): GIF delay dithering landed in `0101312` (was
   fcab6b0 before the history rewrite) - delays alternate 120/130ms so
   loops track the timeline instead of a flat 130ms (~4% slow). Jesse was
   fine with the old behavior and only asked out of curiosity; if the
   dither ever reads as judder, reverting that commit restores flat naive
   rounding cleanly.

Product note: the demand test, landing page, and listing are
**owner-deferred**. Kinestasis is in a deliberate R&D phase and Jesse will
call it. Do not raise it.

## File map (Kinestasis-specific)

- `Sources/KineCore/BurstShot.swift` — model + grouping + timing engine +
  frame skip + marked stills
- `Sources/KineCore/RampBuilder.swift` — hold/dwell ramp generation
- `Sources/KineCore/BoomerangLoop.swift` — where a ping-pong loop turns
  around; shared by the player transport and `GIFExporter`
- `Sources/KineCore/KineDiagnostics.swift` — opt-in field recorder
  (Record Diagnostics); free when off, aggregates counters when on
- `Sources/KineCore/ResourceBundle.swift` — safe bundle lookup (launch crash)
- `Sources/KineMedia/StillsIngest.swift` — scan, pairs, capped parallel probe
- `Sources/KineMedia/ShotGradeRenderer.swift` — CI develop, grain, LUT, `gradePreview`
- `Sources/KineMedia/BurstShotExporter.swift` — parallel export, codec matrix
- `Sources/KineMedia/StillExporter.swift` — marked-stills delivery (JPEG/originals/RAW)
- `Sources/KineMedia/PreviewDiskCache.swift` — decode-once-ever disk cache
- `Sources/KineMedia/GIFExporter.swift` — cadence-true GIFs + boomerang
- `Sources/KineMedia/ClipPreviewCache.swift` — video thumbs/waveforms, STRICTLY serial
- `Sources/KineMedia/ShotFrameSource.swift` — stills as a timeline frame source
- `Sources/KineMedia/ShotBatchXMLSidecar.swift` / `ExifReader.swift`
- `Sources/KineAppUI/ShotsWorkspaceView.swift` — home screen, grid, bar controls
  (Rate / Timing / Skip / Split gap / Min burst)
- `Sources/KineAppUI/ShotPlayerView.swift` — player + RenderPump + FrameSurfaceView
  (Combine-to-CALayer frame pipeline, drag-out file promise, transport leaves)
- `Sources/KineAppUI/ShotDevelopView.swift` — Develop View + key glyph bar
- `Sources/KineAppUI/GIFExportSheet.swift` — GIF sheet (size, boomerang)
- `Sources/KineAppUI/ShotGradePanel.swift` — inspector sections, hold-ramp controls
- `Sources/KineAppUI/ShotExportSheet.swift` — export dialog, stills toggles,
  overwrite question, last-used persistence
- `Sources/KineAppUI/WorkspaceModel.swift` — shots section: ingest, transport +
  skim state, bounded decode pools, trim, marks, export, timeline bridge
  (`ensureShotClip`)
- `Sources/KineAppUI/KineAppUI.swift` — key monitor incl. chord handling
- `CHANGELOG.html` — user-facing changelog (keep flat and plain)
- `scripts/build-dmg.sh` — sign + notarize + masked-`.build` launch smoke test
- `docs/PARALLAX-SPIKE.md` — the single-photo parallax decision input
  (2026-08-14): Apple's spatialization is closed to third parties, the DIY
  camera-move route is open and measured
- `repro/scanline_glitch_example.gif` — the main user's GIF with the top
  line of static, kept as the artifact behind the Core Image footgun
- Inherited engine docs (`docs/*.md` from Preem) describe the compositor/
  timeline machinery and still use Preem-era names; read for mechanism, not
  product scope.
