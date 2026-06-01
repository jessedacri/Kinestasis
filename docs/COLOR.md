# Preem — Color (Lumetri-style grading)

Color grading + color management. Last updated 2026-05-29. Pairs with `COMPOSITOR.md` (render runtime), `BROWSER.md` (bin), `HANDOFF.md` (state).

## What this is

A Lumetri-style color grader: a **Color** tab in the Source pane that edits the `preem.color` effect on the selected timeline clip(s). Because the offline compositor is the same path used for the program viewer AND export, grading is **WYSIWYG by construction** (preview ≡ render). Built color-managed from the foundation: per-layer input transform (log/gamma → linear) → grade → display transform.

## Controls (current)

**Basic Correction** (all keyframable via the per-row stopwatch):
- **Input** color space (per clip): Rec.709 / sRGB / Linear / Rec.2020 / ARRI LogC3 / Sony S-Log3 / Canon C-Log3 / Canon C-Log2 / Panasonic V-Log.
- **White Balance:** Temperature, Tint.
- **Tone:** Exposure (stops), Contrast, Highlights, Shadows, Whites, Blacks.
- **Saturation, Vibrance.**

**Creative:** `.cube` LUT (Load… / clear) + **LUT Intensity** (keyframable).

**Curves:** interactive RGB tone curves — Master / Red / Green / Blue. Drag points, click empty curve to add a point, double-click a point to remove it (endpoints stay), Reset. Monotone cubic (no overshoot).

Reset (header) strips the whole grade.

## Input transforms — sources & accuracy

Each input space applies a **transfer function** (log/gamma → scene-linear) AND a **gamut matrix** (camera primaries → Rec.709 working primaries). Both matter — the transfer function alone gives correct tonality but wrong saturation/hue.

- **Transfer functions** are from the authoritative [`colour-science`](https://colour.readthedocs.io) library / manufacturer specs:
  - Canon **C-Log2** and **C-Log3** — colour-science constants (C-Log3 was corrected from an earlier wrong set; see `cLog2ToLin` / `cLog3ToLin`).
  - Sony **S-Log3**, Panasonic **V-Log**, ARRI **LogC3** (EI 800), Rec.709/2020 (2.4), sRGB (piecewise).
- **Gamut matrices** are computed in `ColorScience.swift` from each gamut's published **chromaticity primaries** (Cinema Gamut, S-Gamut3.Cine, ARRI Wide Gamut 3, V-Gamut, Rec.2020) via the standard primaries→XYZ→Rec.709 derivation. All share D65, so no chromatic adaptation is needed. Validated by `ColorScienceTests` (Rec.709 = identity; white preserved; wide-gamut desaturates).

**Known caveats to verify on real footage:**
- **Legal vs. full range:** the decode assumes the source pixels arrive normalized full-range (0–1). If a clip is tagged video/legal-range and the decoder hands us legal levels, mid-gray/black could sit slightly off. If C-Log2/S-Log3 footage looks a touch milky or crushed at the extremes, this is the first thing to check (may need a legal→full expand before the transfer function).
- **Mid-gray scaling:** the Canon decode returns scene-linear without the optional ×0.9 "reflection" scaling; exposure-neutrality across formats should be eyeballed (the Exposure slider compensates).
- ARRI LogC3 is the EI 800 curve only (other EIs differ slightly).

## Pipeline (per-layer, in the compositor shader)

`applyColorGrade` runs on each layer's source pixels before compositing:

1. **Input transform → scene-linear**: transfer function (log/gamma decode) then **camera-gamut → Rec.709 matrix** (identity for Rec.709 inputs). See "Input transforms" below.
2. **Scene-linear:** white balance (channel gains) + exposure (×2^stops).
3. **Linear → display-referred Rec.709** for the creative/tonal ops.
4. **Tonal zones:** shadows/highlights/blacks/whites via smooth luminance masks.
5. **Contrast** about 0.5 pivot.
6. **Saturation + Vibrance** (vibrance protects already-saturated pixels).
7. **Curves:** per-channel R/G/B, then master — sampled from a 4×32 LUT passed as a `constant float*` buffer.
8. **Creative `.cube` LUT** (blend path only): 3D LUT sampled in display Rec.709, mixed by LUT Intensity. Identity 3D LUT bound when none.

Identity grades (neutral sliders + Rec.709 input + no curves) short-circuit (`ColorGrade.isIdentity` → `ColorUniforms.disabled`), so untouched clips pay no cost.

## Data model (`PreemCore`)

- `ColorGrade` — typed view of the `preem.color` effect (scalars + 4 curves + input space + LUT path/intensity). All scalars neutral at 0 (identity = all-zeros), keyed like Lumetri.
- `ColorGradeParameter` — keyframable scalars; reuses the Transform keyframe infrastructure (`sampleDouble`, stopwatch, strip).
- `ColorTransferSpace` / `OutputColorSpace` — color-management tags (shader IDs).
- `CurvePoint` + `ParameterValue.curve` (schema addition) — curves stored on the same effect, not keyframed in v1.
- `ToneCurve` — monotone cubic (Fritsch–Carlson) eval + `bake(N)` → LUT. Used by the shader LUT builder and the editor.
- Tests: `ColorGradeTests` (data + curve), `CompositorShaderTests` (MSL compiles).

## Key files

- `PreemCore/ColorGrade.swift` — model, params, ToneCurve, `colorGrade(at:)` + keyframe helpers.
- `PreemCore/Sequence.swift` — `ParameterValue.curve` + `CurvePoint`.
- `PreemRender/OfflineSequenceCompositor.swift` — `ColorUniforms`, `colorUniforms`/`curveLUT`, the grade threaded through blend + cross-dissolve, and the MSL color science (`applyColorGrade`, transfer functions, `sampleCurve`).
- `PreemAppUI/ColorPanelContent.swift` — the Color tab (Basic Correction + slider rows).
- `PreemAppUI/CurveEditorView.swift` — interactive curve editor.
- `PreemAppUI/WorkspaceModel.swift` — `clipColorGrade`, `setColorParameterOnSelection(+Light)`, curve/input/LUT setters, `resetColorOnSelection`.

## Architecture note — grading space

v1 grades **per-layer** (input → linear → grade → display Rec.709) and composites the graded display-referred layers in the existing pipeline. For a single graded clip over black this is identical to a full linear pipeline. The remaining color-management work:

- **Linear-light compositing** — move the accumulator chain to float16 and composite in linear so multi-layer blends + cross-dissolves mix in linear (more correct highlight roll-off). Currently composites in display space.
- **HDR output** — `OutputColorSpace` has PQ/HLG cases; the output transform + `CAMetalLayer` EDR wiring are not yet built (Rec.709 SDR only).
- **LUT in cross-dissolve** — the `.cube` LUT applies in the blend path only; a clip mid-cross-dissolve gets scalar+curve grade but not its LUT.

## Backlog (toward full Lumetri)

- Creative section (faded film, sharpen, tint wheels), Color Wheels (3-way), HSL Secondary qualifier, Vignette.
- Hue/Sat curves (Hue×Hue/Sat/Luma, Luma×Sat, Sat×Sat).
- Scopes (waveform / RGB parade / vectorscope) — MPSGraph, planned.
- Source-viewer grading (currently grading shows in the Program/timeline path; the PPE source viewer has its own exposure+LUT prep that isn't wired to `preem.color`).
- Keyframable curves; curve LUT caching (rebuilt per frame when curves are present — cheap, but cacheable).
