import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import KineMedia
import KineCore

/// The full Kinestasis chain on a synthesized burst set: folder → EXIF
/// grouping → per-shot timing/grade/LUT/ramp/wobble → batch ProRes +
/// FCPXML sidecar → AVFoundation verification of every output.
final class EndToEndProofTests: XCTestCase {

    private var folder: URL!
    private var outDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("KinestasisE2E-\(UUID().uuidString)", isDirectory: true)
        folder = base.appendingPathComponent("burst", isDirectory: true)
        outDir = base.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    private func writeStill(name: String, dateTime: String, subsec: String, hue: Double) throws {
        let w = 640, h = 426
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.4 + hue * 0.5, green: 0.4, blue: 0.6 - hue * 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: Int(hue * 500), y: 150, width: 90, height: 90))
        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: dateTime,
            kCGImagePropertyExifSubsecTimeOriginal: subsec,
        ]
        let dest = CGImageDestinationCreateWithURL(
            folder.appendingPathComponent(name) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    func testFullPipelineOnSynthesizedBurstSet() throws {
        // Three bursts: 12 stills @ ~8 fps, 8 stills with a mid-burst
        // buffer slowdown, 6 stills @ 2 fps.
        for i in 0..<12 {
            try writeStill(name: String(format: "DSCF%04d.jpg", i),
                           dateTime: "2026:08:10 10:00:0\(i / 8)",
                           subsec: String(format: "%02d", (i * 125 / 10) % 100),
                           hue: Double(i) / 12)
        }
        for i in 0..<8 {
            let slow = i >= 4 ? 0.4 * Double(i - 3) : 0
            let t = 20.0 + Double(i) * 0.12 + slow
            try writeStill(name: String(format: "DSCF1%03d.jpg", i),
                           dateTime: String(format: "2026:08:10 10:00:%02d", Int(t)),
                           subsec: String(format: "%02d", Int(t.truncatingRemainder(dividingBy: 1) * 100)),
                           hue: Double(i) / 8)
        }
        for i in 0..<6 {
            try writeStill(name: String(format: "DSCF2%03d.jpg", i),
                           dateTime: String(format: "2026:08:10 10:01:%02d", i / 2),
                           subsec: i % 2 == 0 ? "00" : "50",
                           hue: Double(i) / 6)
        }

        // Ingest + group.
        let (shots, videos) = StillsIngest().ingest(folder: folder, gapThreshold: 2.0)
        XCTAssertEqual(shots.map { $0.frames.count }, [12, 8, 6])
        XCTAssertTrue(videos.isEmpty)

        // Shot 1: default fixed timing + a grade with LUT + grain.
        var graded = shots[0]
        let lutURL = folder.appendingPathComponent("warm.cube")
        try "LUT_3D_SIZE 2\n0.05 0 0\n1 0.1 0.1\n0.05 1 0\n1 1 0.1\n0 0 0.9\n1 0.1 1\n0.1 1 1\n1 1 0.95\n"
            .write(to: lutURL, atomically: true, encoding: .utf8)
        graded.grade = ShotGrade(exposure: 0.4, contrast: 15, temperature: 20, tint: -5,
                                 highlights: -20, shadows: 15, saturation: 10,
                                 lutPath: lutURL.path, lutIntensity: 70,
                                 grainAmount: 35, grainSize: 1.4, grainResponse: -30,
                                 wobbleIntensity: 40, wobbleRate: 5)

        // Shot 2: as-shot cadence (the signature) + a speed ramp.
        var cadence = shots[1]
        cadence.timingOverride = .asShot(rate: 1.0)
        cadence.speedRamp = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.4, y: 0.7), CurvePoint(x: 1, y: 1)]

        // Shot 3: frame-skip + B&W.
        var skipped = shots[2]
        skipped.timingOverride = .frameSkip(every: 2, frames: 4)
        skipped.grade = ShotGrade(blackAndWhite: true)

        let finalShots = [graded, cadence, skipped]
        let rate = FrameRate.twentyFour
        let defaults = ShotTimingMode.fixedFramesPerStill(frames: 3)

        // Batch export + sidecar.
        let exporter = BurstShotExporter()
        var entries: [ShotBatchXMLSidecar.Entry] = []
        for shot in finalShots {
            let url = try exporter.export(shot: shot, mode: shot.timing(projectDefault: defaults),
                                          rate: rate, codec: .proRes422HQ, to: outDir)
            let schedule = ShotTimingEngine.schedule(for: shot, projectDefault: defaults, rate: rate)
            entries.append(.init(shot: shot, movieURL: url,
                                 outputFrames: ShotTimingEngine.totalFrames(schedule),
                                 size: PixelSize(width: 640, height: 426)))
        }
        let sidecar = try ShotBatchXMLSidecar().write(entries: entries, rate: rate, to: outDir, batchName: "e2e")

        // Verify: three ProRes movies with the scheduled durations.
        for entry in entries {
            let asset = AVURLAsset(url: entry.movieURL)
            let expected = Double(entry.outputFrames) / rate.fps
            XCTAssertEqual(CMTimeGetSeconds(asset.duration), expected, accuracy: 0.05,
                           "\(entry.shot.name) duration")
            let track = asset.tracks(withMediaType: .video).first
            XCTAssertEqual(track?.mediaFormat.contains("apch"), true, "\(entry.shot.name) is ProRes 422 HQ")
        }
        // Shot 1: 12 stills × 3 frames = 36 frames = 1.5 s.
        XCTAssertEqual(entries[0].outputFrames, 36)
        // Shot 2: as-shot ≈ capture span (~2.44 s) — ramp preserves total.
        XCTAssertGreaterThan(entries[1].outputFrames, 40)
        // Shot 3: every 2nd of 6 stills → 3 kept × 4 frames.
        XCTAssertEqual(entries[2].outputFrames, 12)

        // Sidecar parses and references every movie.
        let doc = try XMLDocument(contentsOf: sidecar)
        XCTAssertEqual(try doc.nodes(forXPath: "//asset").count, 3)
        XCTAssertEqual(try doc.nodes(forXPath: "//spine/asset-clip").count, 3)
    }
}

private extension AVAssetTrack {
    var mediaFormat: String {
        (formatDescriptions as! [CMFormatDescription]).map {
            String(describing: CMFormatDescriptionGetMediaSubType($0).toString())
        }.joined()
    }
}

private extension FourCharCode {
    func toString() -> String {
        let bytes: [CChar] = [
            CChar(truncatingIfNeeded: self >> 24), CChar(truncatingIfNeeded: self >> 16),
            CChar(truncatingIfNeeded: self >> 8), CChar(truncatingIfNeeded: self), 0,
        ]
        return String(cString: bytes.map { UInt8(bitPattern: $0) })
    }
}
