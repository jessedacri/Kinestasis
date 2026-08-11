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
    /// Identity grades short-circuit to the plain decoder.
    public func render(url: URL, grade: ShotGrade, maxPixel: Int) -> CGImage? {
        guard !grade.isIdentity else {
            return StillDecoder.decode(url: url, maxPixel: maxPixel)
        }
        guard var image = developed(url: url, grade: grade, maxPixel: maxPixel) else { return nil }
        image = applyToneAndLook(image, grade: grade, isRAW: Self.rawExtensions.contains(url.pathExtension.lowercased()))
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0 else { return nil }
        return context.createCGImage(image, from: extent)
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

    /// Shared downstream stages: highlights/shadows, contrast, saturation
    /// or B&W, then the LUT mixed at intensity.
    private func applyToneAndLook(_ input: CIImage, grade: ShotGrade, isRAW: Bool) -> CIImage {
        var image = input
        if grade.highlights != 0 || grade.shadows != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 - grade.highlights / 100 * 0.7,
                "inputShadowAmount": grade.shadows / 100,
            ])
        }
        let saturation = grade.blackAndWhite ? 0 : 1 + grade.saturation / 100
        let contrast = 1 + grade.contrast / 100 * 0.35
        if saturation != 1 || contrast != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: saturation,
                kCIInputContrastKey: contrast,
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
