import Foundation
import CoreImage
import CoreGraphics
import KineCore

/// Renders a still through a `ShotGrade`. RAW files develop through
/// CIRAWFilter (exposure + white balance in the RAW domain); JPEG/HEIF get
/// an equivalent Core Image chain. Both share the downstream tone /
/// saturation / LUT stages so the look matches across sources.
public final class ShotGradeRenderer: @unchecked Sendable {

    /// Extensions routed through CIRAWFilter. DNG + the OEM RAW list.
    private static let rawExtensions: Set<String> = StillsIngest.stillExtensions
        .subtracting(["jpg", "jpeg", "heic", "heif", "tif", "tiff", "png"])

    private let context: CIContext
    private var lutCache: (path: String, filter: CIFilter)?

    public init() {
        context = CIContext(options: [.cacheIntermediates: false])
    }

    /// Decode + grade + downscale to `maxPixel` on the longest edge.
    /// Identity grades short-circuit to the plain decoder. `evOffset` adds
    /// exposure wobble for this frame; `grainSeed` shifts the grain field
    /// so it animates frame to frame.
    public func render(url: URL, grade: ShotGrade, maxPixel: Int, evOffset: Double = 0, grainSeed: Int64 = 0) -> CGImage? {
        guard !grade.isIdentity || evOffset != 0 else {
            return StillDecoder.decode(url: url, maxPixel: maxPixel)
        }
        var effective = grade
        effective.exposure += evOffset
        guard var image = developed(url: url, grade: effective, maxPixel: maxPixel) else { return nil }
        image = applyToneAndLook(image, grade: effective, isRAW: Self.rawExtensions.contains(url.pathExtension.lowercased()), wobbleEV: evOffset)
        if grade.grainAmount > 0 {
            image = applyGrain(image, grade: grade, seed: grainSeed)
        }
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0 else { return nil }
        return context.createCGImage(image, from: extent)
    }

    /// Fast preview path: apply the grade to an ALREADY-DECODED small
    /// frame (the preview cache's base image) using the JPEG chain for
    /// every source. Skips the CIRAWFilter develop — WB/exposure are
    /// approximated on display pixels, exact on export — which is what
    /// lets sliders and playback stay live at frame rate.
    public func gradePreview(_ image: CGImage, grade: ShotGrade, evOffset: Double = 0, grainSeed: Int64 = 0) -> CGImage? {
        if grade.isIdentity && evOffset == 0 { return image }
        var ci = CIImage(cgImage: image)
        var effective = grade
        effective.exposure += evOffset
        if effective.exposure != 0 {
            ci = ci.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: effective.exposure])
        }
        if effective.temperature != 0 || effective.tint != 0 {
            ci = ci.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + effective.temperature * 25, y: effective.tint * 0.5),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        ci = applyToneAndLook(ci, grade: effective, isRAW: false, wobbleEV: evOffset)
        if grade.grainAmount > 0 {
            ci = applyGrain(ci, grade: grade, seed: grainSeed)
        }
        let extent = ci.extent
        guard !extent.isInfinite, extent.width > 0 else { return nil }
        return context.createCGImage(ci, from: extent)
    }

    /// Film grain: luma noise soft-lit over the image, sized by
    /// `grainSize`, weighted toward shadows or highlights by
    /// `grainResponse`. The infinite CIRandomGenerator field is translated
    /// per frame so grain animates instead of sitting static.
    private func applyGrain(_ input: CIImage, grade: ShotGrade, seed: Int64) -> CIImage {
        guard let noiseSource = CIFilter(name: "CIRandomGenerator")?.outputImage else { return input }
        let extent = input.extent
        let size = max(0.5, grade.grainSize)
        let offsetX = CGFloat((seed &* 73) % 4096) + 2048
        let offsetY = CGFloat((seed &* 149) % 4096) + 2048

        // Monochrome noise centered on mid-gray, amplitude from amount.
        let amplitude = grade.grainAmount / 100 * 0.5
        var noise = noiseSource
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY)
                .scaledBy(x: size, y: size))
            .cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(amplitude), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: CGFloat(amplitude), y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: CGFloat(amplitude), y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: CGFloat(0.5 - amplitude / 2), y: CGFloat(0.5 - amplitude / 2), z: CGFloat(0.5 - amplitude / 2), w: 0),
            ])
        noise = noise.applyingFilter("CISoftLightBlendMode", parameters: [
            kCIInputBackgroundImageKey: input,
        ])

        let response = grade.grainResponse
        guard response != 0 else { return noise }

        // Bias: mask from image luminance (or its inverse) selects where
        // the grained version shows through.
        var luma = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        if response < 0 {
            luma = luma.applyingFilter("CIColorInvert")
        }
        let strength = min(1, abs(response) / 100)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
        let mask = strength >= 1 ? luma : luma.applyingFilter("CIMix", parameters: [
            "inputBackgroundImage": white,
            "inputAmount": strength,
        ])
        return noise.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: input,
            kCIInputMaskImageKey: mask,
        ])
    }

    /// The developed (but ungraded-downstream) base image. RAW: CIRAWFilter
    /// with exposure/WB baked into the develop. JPEG: plain CIImage —
    /// exposure/WB applied later as filters.
    private func developed(url: URL, grade: ShotGrade, maxPixel: Int) -> CIImage? {
        let ext = url.pathExtension.lowercased()
        if Self.rawExtensions.contains(ext), let raw = CIRAWFilter(imageURL: url) {
            raw.exposure = Float(grade.exposure)
            // Temperature slider (−100…+100) sweeps ±2500 K around the
            // as-shot neutral; tint sweeps ±50.
            raw.neutralTemperature += Float(grade.temperature * 25)
            raw.neutralTint += Float(grade.tint * 0.5)
            // Ask the develop for roughly the target size — dramatically
            // faster than a full-res develop for previews.
            raw.scaleFactor = 1.0
            if let full = raw.outputImage {
                return downscale(full, maxPixel: maxPixel)
            }
            return nil
        }
        guard var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        image = downscale(image, maxPixel: maxPixel)
        if grade.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: grade.exposure])
        }
        if grade.temperature != 0 || grade.tint != 0 {
            // Warmer = treat the scene neutral as bluer than 6500 K so the
            // correction pulls toward warm; same idea for tint.
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + grade.temperature * 25, y: grade.tint * 0.5),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        return image
    }

    /// Shared downstream stages, Lightroom-ordered: local highlight
    /// recovery / shadow lift, then the parametric tone curve (contrast,
    /// blacks/whites, the global halves of highlights/shadows, the user
    /// curve), then saturation or B&W, then the LUT mixed at intensity.
    /// `wobbleEV` also drives a per-frame contrast flutter so wobble reads
    /// as projector breathing, not just brightness.
    private func applyToneAndLook(_ input: CIImage, grade: ShotGrade, isRAW: Bool, wobbleEV: Double = 0) -> CIImage {
        var image = input
        // The radius-aware halves: -highlights recovers blown areas,
        // +shadows lifts blocked ones (CIHighlightShadowAdjust can only
        // recover/lift; the opposite directions run through the curve).
        let recovery = min(0, grade.highlights) / 100
        let lift = max(0, grade.shadows) / 100
        if recovery != 0 || lift != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + recovery * 0.85,
                "inputShadowAmount": lift,
            ])
        }
        let contrastWobble = wobbleEV * 0.5
        if GradeToneCurve.isActive(grade, contrastWobble: contrastWobble) {
            let samples = GradeToneCurve.samples(grade: grade, contrastWobble: contrastWobble)
            var data = Data(capacity: samples.count * 3 * MemoryLayout<Float>.size)
            for s in samples {
                withUnsafeBytes(of: s) { bytes in
                    data.append(contentsOf: bytes)
                    data.append(contentsOf: bytes)
                    data.append(contentsOf: bytes)
                }
            }
            image = image.applyingFilter("CIColorCurves", parameters: [
                "inputCurvesData": data,
                "inputCurvesDomain": CIVector(x: 0, y: 1),
                "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB) as Any,
            ])
        }
        let saturation = grade.blackAndWhite ? 0 : 1 + grade.saturation / 100
        if saturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: saturation,
            ])
        }
        if let path = grade.lutPath, grade.lutIntensity > 0,
           let cube = lutFilter(path: path) {
            cube.setValue(image, forKey: kCIInputImageKey)
            if let graded = cube.outputImage {
                let amount = min(1, max(0, grade.lutIntensity / 100))
                image = amount >= 1 ? graded : graded.applyingFilter("CIMix", parameters: [
                    "inputBackgroundImage": image,
                    "inputAmount": amount,
                ])
            }
        }
        return image
    }

    private func lutFilter(path: String) -> CIFilter? {
        if let cached = lutCache, cached.path == path { return cached.filter }
        guard let lut = try? CubeLUT.load(url: URL(fileURLWithPath: path)),
              let filter = CIFilter(name: "CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": lut.size,
                "inputCubeData": lut.rgbaData,
                "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB) as Any,
              ]) else { return nil }
        lutCache = (path, filter)
        return filter
    }

    private func downscale(_ image: CIImage, maxPixel: Int) -> CIImage {
        let longest = max(image.extent.width, image.extent.height)
        guard longest > CGFloat(maxPixel), longest > 0 else { return image }
        let scale = CGFloat(maxPixel) / longest
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}

// MARK: - .cube parsing

/// Minimal Adobe/Resolve `.cube` 3D LUT parser → RGBA float data for
/// CIColorCube (alpha 1, red fastest-varying, matching the .cube layout).
public struct CubeLUT {
    public let size: Int
    public let rgbaData: Data

    public enum ParseError: Error, LocalizedError {
        case notA3DLUT
        case badEntryCount(expected: Int, got: Int)

        public var errorDescription: String? {
            switch self {
            case .notA3DLUT: return "Not a 3D .cube LUT (missing LUT_3D_SIZE)."
            case .badEntryCount(let e, let g): return "Cube data incomplete: expected \(e) entries, got \(g)."
            }
        }
    }

    public static func load(url: URL) throws -> CubeLUT {
        let text = try String(contentsOf: url, encoding: .utf8)
        var size = 0
        var floats: [Float] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.uppercased().hasPrefix("LUT_3D_SIZE") {
                size = Int(line.split(separator: " ").last.map(String.init) ?? "") ?? 0
                floats.reserveCapacity(size * size * size * 4)
                continue
            }
            if line.uppercased().hasPrefix("TITLE") || line.uppercased().hasPrefix("DOMAIN_")
                || line.uppercased().hasPrefix("LUT_1D") { continue }
            let parts = line.split(separator: " ")
            if parts.count >= 3,
               let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) {
                floats.append(contentsOf: [r, g, b, 1])
            }
        }
        guard size > 1 else { throw ParseError.notA3DLUT }
        let expected = size * size * size * 4
        guard floats.count == expected else {
            throw ParseError.badEntryCount(expected: expected / 4, got: floats.count / 4)
        }
        return CubeLUT(size: size, rgbaData: floats.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}
