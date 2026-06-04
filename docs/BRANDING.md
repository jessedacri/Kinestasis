# Preem — Branding (Polymerge sibling)

The visual identity. Last updated 2026-06-04. Lives mostly on the
`feature/branding` branch (see Git below).

## Intent

Preem reads as a **sibling of Polymerge** — same design family, distinct
product. Dark-first, near-black chrome with a slight purple undertone, an
**amber signature accent**, a violet secondary, monospaced data readouts.
The palette is mirrored 1:1 from Polymerge's own theme:
`/Users/jessedacri/polymerge/PolyMerge/Views/Components/Theme.swift`.

## Palette — `PreemTheme` (`Sources/PreemAppUI/PreemTheme.swift`)

Single source of truth. Recolor here, reference tokens elsewhere.

- **Backgrounds:** `#18161B` window · `#1E1C22` panel · `#26232B` card · `#2E2A35` hover · `#332840` selected (violet-tinted)
- **Borders:** `#36323D` · `#443F4D`
- **Text:** `#EDE8F2` · `#9B93A6` muted · `#6B6278` dim
- **Accent (signature):** `#F0A030` amber (`accentDim`/`accentGlow` variants) · **Secondary:** `#C084FC` violet
- **Status:** error `#FF4757` · green `#3FB950` · cyan `#22D3EE` · 8-color `trackColors` cycle
- **Type:** system font; `mono`/`monoSmall`/`monoLarge` (monospaced) for data; `label`/`heading` semibold/bold

`Color(hex:)` extension lives in the same file. Dark-first by construction
(fixed dark values, not system-adaptive).

## How it's applied (Phase 1 + 2, on `feature/branding`)

- **Root** (`PreemAppUI.swift` `PreemRootView`): `.preferredColorScheme(.dark)` + `.tint(PreemTheme.accent)` so every SwiftUI control (buttons, pickers, segmented toggles) goes amber, + `.background(PreemTheme.bg)`.
- **Panels recolored:** bin, source/program viewers, inspectors, Color panel, slim chrome (`ThinSlider`/`ThinScrollView`). All former `Color.accentColor` → `PreemTheme.accent`; window/control backgrounds → theme tiers.
- **Sheets on-brand:** New Sequence + Mismatch get themed backgrounds and amber primary buttons (`.borderedProminent` via the tint); Settings + Export themed.
- **About panel** (`AboutView.swift`): branded sheet that *draws* the mark in SwiftUI (no asset), wired to the app menu via `CommandGroup(replacing: .appInfo)` → `.preemShowAbout` → sheet in `PreemRootView`.
- **App icon:** Polymerge's vertical-waveform icon **rotated 90°** → horizontal amber bars that read as timeline tracks. Set at runtime via `NSApp.applicationIconImage` in `AppDelegate.applicationDidFinishLaunching` (Preem is a plain SPM executable with no bundle/Info.plist icon). Source: `Sources/PreemApp/Resources/PreemIcon.png` (512px). Swap that file to change it.
- **Typography:** bin clip metadata → `PreemTheme.monoSmall`; timecode/value readouts were already monospaced.

## Load-bearing constraint — DO NOT brand the timeline

`PreemTimelineView` (the AppKit timeline, in `PreemTimelineUI`) is kept at
its **exact pre-branding rendering** — system clip colors, white waveforms,
unchanged. Reason: recoloring the audio clip body to a bright brand hue
washed out the white waveform and the user reads that as lost waveform
detail. It was reverted byte-for-byte and `TimelinePalette` removed. See
[[preem_keep_highres_waveforms]].

Two reasons it's also awkward to brand cleanly: (a) `PreemTimelineUI` is a
*lower* module and can't import `PreemTheme` (no back-edges), and (b) the
waveform legibility constraint. If timeline branding is ever wanted, touch
only the non-waveform parts (playhead, In/Out marks, selection outline),
get explicit sign-off, and verify waveform legibility first.

## Git

- `main` has NO branding.
- `feature/branding` holds it: `ea510cf` (palette + dark chrome), `9d40677` (icon/About/sheets/typography), `e96df34`+`bdeb41c` (the waveform regression + revert), `ed9d85c` (timeline fixes — unrelated, rode the branch).
- Merge to `main` when happy. The two timeline bug-fixes in `ed9d85c` are independent of branding if you need them on `main` sooner.

## Backlog (Phase 3+)

- Bespoke app icon (current is the flipped Polymerge mark — placeholder).
- Real `.app` bundle so the icon shows in Finder (not just the Dock) and Preem launches like a packaged app.
- Custom `GroupBox`/section styling in sheets (currently system defaults on a themed background).
- In-app logo in empty states / splash.
- A `BrandComponents` set (primary/secondary buttons, knobs) mirroring Polymerge's `Brand*` views, if the system styles aren't enough.
