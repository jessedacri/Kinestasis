# Parallax from a single photo — spike

Timeboxed decision input, 2026-08-14. Not a build plan. Jesse's questions
framed it: does Apple reveal its method or API for spatializing photos to
other apps, and if not, what is the pipeline? Written against macOS 26.2
SDK evidence on this machine, not blog posts.

## The short answer

**No. Not on macOS, and not in any form we could use even on visionOS.**

The premise is right that the capability ships on the device. It is not
right that it is available to us. What ships is the Photos app calling
private frameworks. There is exactly one third-party door, and it is the
wrong shape and the wrong platform:

```swift
@available(visionOS 26.0, *)
@available(macOS, unavailable)      // also iOS, tvOS, watchOS, Catalyst
extension ImagePresentationComponent {
  public class Spatial3DImage {
    public init(imageSource: CGImageSource) async throws
    public func generate() async throws
  }
}
```

`RealityFoundation.swiftinterface:3253`, macOS 26.2 SDK. It appears in the
macOS SDK only because RealityKit ships one cross-platform module
description; the availability attributes make it uncompilable here.

Two things kill it beyond the platform gate. `Spatial3DImage` has no
output at all — no depth accessor, no mesh, no stereo pair, only
`generate()` and a hand-off to a RealityKit entity. It is a *display*
component. And the macOS build of the component declares only the `mono`,
`spatialStereo` and `spatialStereoImmersive` viewing modes; the two
generated-scene modes exist only in the visionOS SDK. Apple confirmed the
same in a developer forum thread and again in the WWDC 2026 Camera & Photo
lab: there is no developer API for the Photos reframe capability.

For completeness, the real machinery is on disk and unusable:
`PhotosSpatialMediaCore.framework` (private, `allowable-clients` limited
to Photos and `mediaanalysisd`), writing an MXI scene bundle — a
multi-layer ASTC texture atlas with an infilled backing plane. The
spatialization model itself is not even on disk; it is a CDN-hosted
encrypted asset. Nothing to link, nothing to extract, and App Store fatal
if we tried.

## What we can genuinely do today

Two useful public capabilities, both verified hands-on against this SDK:

- **Write a stereo-pair HEIC that ImageIO recognizes.** The
  `kCGImagePropertyGroups` keys (ImageIO, macOS 12+) with
  `kCGImagePropertyGroupTypeStereoPair`, plus camera extrinsics and
  intrinsics. One trap, verified the hard way: the group dictionary must
  go in the **per-image** properties of `CGImageDestinationAddImage`. Pass
  it to `CGImageDestinationSetProperties` and it writes nothing at all,
  while `Finalize` still returns true.
- **Ship our own depth map as standard auxiliary data.**
  `CGImageDestinationAddAuxiliaryDataInfo` with
  `kCGImageAuxiliaryDataTypeDisparity` round-trips cleanly, and Core Image
  and Photos will pick it up.

What we cannot write is Apple's `.mxibundle` spatial scene. So "export a
photo that Photos treats as spatial the way Apple's own does" is off the
table; "export a stereo pair" is not.

## The do-it-yourself pipeline

1. **Monocular depth.** `apple/coreml-depth-anything-v2-small` — Apache
   2.0, an official Apple Core ML conversion, 24.8 M params, ~50 MB at
   F16. This is the only clean license/quality/speed point. Depth Anything
   V2 Base and larger are CC-BY-NC. Apple's own Depth Pro is sharper and
   metric, but there is no official Core ML export, community conversions
   run ~1.9 GB and seconds per image, and its commercial terms have sat
   unanswered on GitHub since Nov 2024. Not shippable.
2. **Upsample the depth** to full resolution, edge-aligned. A joint
   bilateral upsample in Metal; there is no Core Image guided filter.
3. **Pre-smooth the depth discontinuities.** The highest-leverage step:
   soften depth edges so disocclusion holes never open wide enough to need
   inpainting.
4. **Warp by mesh displacement.** Tessellate a grid, displace by disparity,
   render per view. This is ordinary work for the existing Metal
   compositor.
5. **Fill what tears.** Background stretch is cheap and adequate at
   conservative strength. The good version is layered-depth inpainting, and
   there is no Core ML port of any modern inpainter, so that tier is not an
   on-device Mac path today.

The honest read of step 5 is that quality comes from *not pushing the
parallax*, not from better hole filling.

## Quality on real photos

Measured on this machine against real archive frames. See "Measured" below.

## What it costs on top of KineRender

Everything except the model is machinery this app already has. The warp is
a displaced grid in the Metal compositor, which is the kind of pass
KineRender already runs. The move is keyframed camera parameters over a
static texture. The output is generated frames with cadence-controlled
delays, which is precisely what `GIFExporter` already consumes — a
parallax orbit needs no new export path at all.

The genuinely new parts are: bundling and running a Core ML model (~50 MB
in the app, a first-run develop cost per still), the depth upsample and
smoothing pass, and a quality gate.

That gate is not optional. Apple's own private code is full of them —
`SupportLevel.degraded`/`.none`, occlusion analysis returning
`tooOccluded`, `notOccludedEnough`, `noSalientOverlap`. Apple ships a
classifier that *declines* to spatialize photos that will look bad. Any
version of this that reaches users needs the equivalent, or the feature
will be judged on its worst output.

## Recommendation

**Do not chase spatial photos. Chase the camera move.**

The spatial-photo format is the part Apple has closed, and it is also the
part that needs a Vision Pro to appreciate. The part that is open is the
part that suits this app: a slow parallax move over a still, rendered as
frames, exported as a GIF. Apple's own private vocabulary for this is a
list of camera techniques — dolly, pedestal, horizontal arc, dolly zoom —
over a static scene. That is a motion feature, not a stereo feature, and
it lands directly on the pipeline Kinestasis already has.

It also answers a question the burst format cannot: what this app does
with the thousands of single frames that are not bursts at all. A
one-photo GIF with a three-degree arc is the same product promise as an
8 fps burst clip, made from an archive of ones and twos.

If it gets built, build it in this order: depth on a single still behind a
debug flag, the warp in the compositor, then the move as a ramp-like
generated schedule, then the quality gate. Stop after the first step if
the depth does not hold up on ordinary frames.
