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
        // Burst 1: three stills 0.25s apart. Burst 2: two stills 5s later.
        _ = try writeJPEG(name: "b1.jpg", dateTime: "2026:08:10 12:00:00", subsec: "00")
        _ = try writeJPEG(name: "b2.jpg", dateTime: "2026:08:10 12:00:00", subsec: "25")
        _ = try writeJPEG(name: "b3.jpg", dateTime: "2026:08:10 12:00:00", subsec: "50")
        _ = try writeJPEG(name: "c1.jpg", dateTime: "2026:08:10 12:00:06", subsec: "00")
        _ = try writeJPEG(name: "c2.jpg", dateTime: "2026:08:10 12:00:06", subsec: "40")
        let (shots, videos) = StillsIngest().ingest(folder: dir, gapThreshold: 2.0)
        XCTAssertEqual(shots.map { $0.frames.count }, [3, 2])
        XCTAssertTrue(videos.isEmpty)
        XCTAssertTrue(shots[0].name.hasSuffix("_S001"))
        XCTAssertTrue(shots[1].name.hasSuffix("_S002"))
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
        let (shots, _) = StillsIngest().ingest(folder: dir, gapThreshold: 2.0)
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
