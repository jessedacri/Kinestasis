import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import KineMedia
import KineCore

final class StillsIngestTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StillsIngestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Write a tiny JPEG with EXIF DateTimeOriginal/SubSecTimeOriginal.
    private func writeJPEG(name: String, dateTime: String, subsec: String?, width: Int = 64, height: Int = 48) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.3, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        var exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: dateTime]
        if let subsec { exif[kCGImagePropertyExifSubsecTimeOriginal] = subsec }
        let props: [CFString: Any] = [kCGImagePropertyExifDictionary: exif]
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testProbeReadsExifWithSubseconds() throws {
        let url = try writeJPEG(name: "a.jpg", dateTime: "2026:08:10 12:00:05", subsec: "25")
        let frame = StillsIngest().probeStill(url)
        let base = StillsIngestTests.parse("2026:08:10 12:00:05")
        XCTAssertEqual(frame.captureTime, base + 0.25, accuracy: 0.001)
        XCTAssertEqual(frame.pixelSize, PixelSize(width: 64, height: 48))
    }

    func testProbeFallsBackToFileDateWithoutExif() throws {
        let url = dir.appendingPathComponent("plain.jpg")
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        let frame = StillsIngest().probeStill(url)
        XCTAssertGreaterThan(frame.captureTime, 0)
    }

    func testIngestGroupsByGapAndNamesShots() throws {
        // Burst 1: three stills 0.25s apart. Burst 2: two stills 5s later
        // (below the default min-burst of 3 → singles, not a shot).
        _ = try writeJPEG(name: "b1.jpg", dateTime: "2026:08:10 12:00:00", subsec: "00")
        _ = try writeJPEG(name: "b2.jpg", dateTime: "2026:08:10 12:00:00", subsec: "25")
        _ = try writeJPEG(name: "b3.jpg", dateTime: "2026:08:10 12:00:00", subsec: "50")
        _ = try writeJPEG(name: "c1.jpg", dateTime: "2026:08:10 12:00:06", subsec: "00")
        _ = try writeJPEG(name: "c2.jpg", dateTime: "2026:08:10 12:00:06", subsec: "40")
        let result = StillsIngest().ingest(folder: dir, gapThreshold: 2.0)
        XCTAssertEqual(result.shots.map { $0.frames.count }, [3])
        XCTAssertEqual(result.singles.count, 2)
        XCTAssertTrue(result.videos.isEmpty)
        XCTAssertTrue(result.shots[0].name.hasSuffix("_S001"))
    }

    func testMinBurstCountAdjustsSinglesSplit() throws {
        _ = try writeJPEG(name: "b1.jpg", dateTime: "2026:08:10 12:00:00", subsec: "00")
        _ = try writeJPEG(name: "b2.jpg", dateTime: "2026:08:10 12:00:00", subsec: "25")
        _ = try writeJPEG(name: "lone.jpg", dateTime: "2026:08:10 12:00:30", subsec: "00")
        let relaxed = StillsIngest().ingest(folder: dir, gapThreshold: 2.0, minBurstCount: 2)
        XCTAssertEqual(relaxed.shots.map { $0.frames.count }, [2])
        XCTAssertEqual(relaxed.singles.count, 1)
        let strict = StillsIngest().ingest(folder: dir, gapThreshold: 2.0, minBurstCount: 3)
        XCTAssertTrue(strict.shots.isEmpty)
        XCTAssertEqual(strict.singles.count, 3)
    }

    func testRawJpegPairsCollapseToOneStillPreferringRaw() {
        let urls = [
            URL(fileURLWithPath: "/card/DSC001.JPG"),
            URL(fileURLWithPath: "/card/DSC001.ARW"),
            URL(fileURLWithPath: "/card/DSC002.ARW"),
            URL(fileURLWithPath: "/card/DSC003.JPG"),
            URL(fileURLWithPath: "/other/DSC001.JPG"),   // different dir — distinct still
        ]
        let (primaries, pairs) = StillsIngest.pairRawJpeg(urls)
        XCTAssertEqual(primaries.map(\.path), [
            "/card/DSC001.ARW", "/card/DSC002.ARW", "/card/DSC003.JPG", "/other/DSC001.JPG",
        ])
        XCTAssertEqual(pairs[URL(fileURLWithPath: "/card/DSC001.ARW")]?.path, "/card/DSC001.JPG")
        XCTAssertNil(pairs[URL(fileURLWithPath: "/card/DSC002.ARW")], "no JPEG twin")
    }

    func testSourceToggleSwitchesEffectiveURL() {
        let frame = StillFrame(url: URL(fileURLWithPath: "/c/A.ARW"),
                               pairedJpegURL: URL(fileURLWithPath: "/c/A.JPG"), captureTime: 0)
        var shot = BurstShot(name: "S", frames: [frame])
        XCTAssertEqual(shot.sourceURL(for: frame).path, "/c/A.ARW")
        XCTAssertEqual(shot.fileTypeLabel, "Sony ARW (+JPEG)")
        shot.useJpegSource = true
        XCTAssertEqual(shot.sourceURL(for: frame).path, "/c/A.JPG")
        XCTAssertTrue(shot.hasRawJpegPairs)
    }

    func testScanSeparatesVideosAndIgnoresJunk() throws {
        _ = try writeJPEG(name: "s.jpg", dateTime: "2026:08:10 12:00:00", subsec: nil)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("v.mov").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("notes.txt").path, contents: Data())
        let scan = StillsIngest().scan(dir)
        XCTAssertEqual(scan.stills.count, 1)
        XCTAssertEqual(scan.videos.count, 1)
    }

    func testBatchExportWritesProResWithScheduledDuration() throws {
        var urls: [URL] = []
        for i in 0..<6 {
            urls.append(try writeJPEG(name: String(format: "e%02d.jpg", i),
                                      dateTime: "2026:08:10 12:00:00",
                                      subsec: String(format: "%02d", i * 10)))
        }
        let shots = StillsIngest().ingest(folder: dir, gapThreshold: 2.0).shots
        XCTAssertEqual(shots.count, 1)

        let out = dir.appendingPathComponent("out", isDirectory: true)
        let exporter = BurstShotExporter()
        let url = try exporter.export(shot: shots[0], mode: .fixedFramesPerStill(frames: 4),
                                      rate: .twentyFour, codec: .proRes422HQ, to: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(url.lastPathComponent.hasSuffix("_422HQ.mov"))

        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        // 6 stills × 4 frames @ 24 fps = 1.0 s
        XCTAssertEqual(duration, 1.0, accuracy: 0.05)
        let track = asset.tracks(withMediaType: .video).first
        XCTAssertNotNil(track)
        XCTAssertEqual(Int(track!.naturalSize.width), 64)
        XCTAssertEqual(Int(track!.naturalSize.height), 48)
    }

    private static func parse(_ s: String) -> TimeInterval {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)!.timeIntervalSince1970
    }
}
