import XCTest
@testable import KineMedia
import KineCore
import CoreImage
import ImageIO
import CoreGraphics

/// A source whose scaled height is fractional (4240x2832 → 960x641.207)
/// used to render one row the image only partly covered, which the GIF
/// encoder turned into a line of static across the top of every frame.
final class GIFTopRowTests: XCTestCase {

    /// Flat mid-gray source, so any variation in the output is the defect.
    private func writeSource(_ w: Int, _ h: Int, to url: URL) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        else { throw XCTSkip("could not build source") }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// Top-left-origin RGBA bytes of one GIF frame.
    private func frameRGBA(_ url: URL, index: Int) throws -> (w: Int, h: Int, bytes: [UInt8]) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, index, nil)
        else { throw XCTSkip("could not read GIF frame \(index)") }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, bytes)
    }

    func testFractionalAspectGIFHasNoStaticAtTheTop() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("giftoprow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A7S III proportions: 960 / 4240 * 2832 = 641.207, a fractional row.
        let sources = try (0..<3).map { i -> URL in
            let url = dir.appendingPathComponent("still-\(i).jpg")
            try writeSource(4240, 2832, to: url)
            return url
        }
        var grade = ShotGrade()
        grade.contrast = 12          // non-identity, so the graded path runs
        grade.grainAmount = 20       // grain writes into every row it is given
        let shot = BurstShot(
            name: "S",
            frames: sources.enumerated().map { StillFrame(url: $1, captureTime: Double($0) * 0.1) },
            grade: grade)

        let gif = dir.appendingPathComponent("out.gif")
        try GIFExporter.export(shot: shot, mode: .fixedFramesPerStill(frames: 2), skipDefault: 1,
                               rate: .twentyFour, maxPixel: 960, to: gif)

        let (w, h, bytes) = try frameRGBA(gif, index: 0)
        XCTAssertEqual(w, 960)
        XCTAssertEqual(h, 641, "the partly covered row must not be emitted")

        func row(_ y: Int) -> [(r: UInt8, a: UInt8)] {
            (0..<w).map { (bytes[(y * w + $0) * 4], bytes[(y * w + $0) * 4 + 3]) }
        }
        // The source is flat, so the top rows must match the body of the
        // image in both coverage and value.
        let reference = row(h / 2).map { Int($0.r) }
        let refMin = reference.min()!, refMax = reference.max()!
        for y in [0, 1, 2] {
            let r = row(y)
            XCTAssertTrue(r.allSatisfy { $0.a == 255 },
                          "row \(y) has transparent pixels: the uncovered-row defect")
            let lum = r.map { Int($0.r) }
            XCTAssertGreaterThanOrEqual(lum.min()!, refMin - 24,
                                        "row \(y) is darker than the image body")
            XCTAssertLessThanOrEqual(lum.max()!, refMax + 24,
                                     "row \(y) is brighter than the image body")
        }
    }

    func testEvenAspectStillExportsEveryRow() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("giftoprow-even-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // X-Pro2 proportions: 960 / 6000 * 4000 = 640 exactly. Nothing to crop.
        let url = dir.appendingPathComponent("still.jpg")
        try writeSource(6000, 4000, to: url)
        var grade = ShotGrade()
        grade.contrast = 12
        let shot = BurstShot(name: "S", frames: [StillFrame(url: url, captureTime: 0)], grade: grade)

        let gif = dir.appendingPathComponent("out.gif")
        try GIFExporter.export(shot: shot, mode: .fixedFramesPerStill(frames: 2), skipDefault: 1,
                               rate: .twentyFour, maxPixel: 960, to: gif)
        let (w, h, _) = try frameRGBA(gif, index: 0)
        XCTAssertEqual([w, h], [960, 640])
    }
}
