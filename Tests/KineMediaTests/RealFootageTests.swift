import XCTest
import AVFoundation
@testable import KineMedia
import KineCore

/// Verification against real camera archives. Gated: runs only with
/// KINE_REAL_FOOTAGE=1 and the volume mounted, so the default suite
/// stays fast and machine-independent.
///
///   KINE_REAL_FOOTAGE=1 swift test --filter RealFootageTests
final class RealFootageTests: XCTestCase {

    private static let root = URL(fileURLWithPath: "/Volumes/BLANK 2T/XPro2 Cincinnati")

    private func requireFootage() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KINE_REAL_FOOTAGE"] == "1",
                          "set KINE_REAL_FOOTAGE=1 to run against the real archive")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.root.path),
                          "X-Pro2 volume not mounted")
    }

    func testFujiRAFProbeAndDecode() throws {
        try requireFootage()
        let raf = Self.root.appendingPathComponent("C1/DCIM/177_FUJI/DSCF7171.RAF")
        let frame = StillsIngest().probeStill(raf)
        XCTAssertGreaterThan(frame.captureTime, 1_400_000_000, "EXIF DateTimeOriginal read from RAF")
        XCTAssertEqual(frame.pixelSize?.width, 6000)
        XCTAssertEqual(frame.pixelSize?.height, 4000)

        let preview = StillDecoder.preview(url: raf, maxPixel: 720)
        XCTAssertNotNil(preview, "embedded RAF preview decodes (fast skim path)")
        let graded = ShotGradeRenderer().render(
            url: raf, grade: ShotGrade(exposure: 0.5, temperature: 15, grainAmount: 20), maxPixel: 720)
        XCTAssertNotNil(graded, "CIRAWFilter develop works on X-Pro2 RAF")
    }

    func testSonyARWProbeAndDecode() throws {
        try requireFootage()
        let arw = Self.root.appendingPathComponent("C2/DCIM/100MSDCF/DSC02273.ARW")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: arw.path), "ARW sample missing")
        let frame = StillsIngest().probeStill(arw)
        XCTAssertNotNil(frame.pixelSize, "ARW dimensions probe")
        XCTAssertNotNil(StillDecoder.preview(url: arw, maxPixel: 720), "ARW preview decodes")
        XCTAssertNotNil(ShotGradeRenderer().render(url: arw, grade: ShotGrade(exposure: 0.3), maxPixel: 720),
                        "CIRAWFilter develop works on Sony ARW")
    }

    func testRealCardIngestGroupsAndExports() throws {
        try requireFootage()
        let card = Self.root.appendingPathComponent("C1/DCIM/176_FUJI")
        let started = Date()
        let result = StillsIngest().ingest(folder: card, gapThreshold: 2.0, minBurstCount: 3)
        let probeSeconds = Date().timeIntervalSince(started)

        let stillCount = result.shots.reduce(0) { $0 + $1.frames.count } + result.singles.count
        print("[RealFootage] 176_FUJI: \(stillCount) stills → \(result.shots.count) shots + \(result.singles.count) singles in \(String(format: "%.1f", probeSeconds))s")
        for shot in result.shots.prefix(12) {
            print(String(format: "[RealFootage]   %@ — %d stills over %.2fs", shot.name, shot.frames.count, shot.captureSpan))
        }
        XCTAssertGreaterThan(result.shots.count, 0, "real card contains bursts")
        XCTAssertLessThan(probeSeconds, 30, "metadata-only probe stays fast")

        // Capture spans must be days apart across the archive folders —
        // day sectioning has real material. (171 vs 177 differ by months.)
        let other = StillsIngest().probeStill(Self.root.appendingPathComponent("C1/DCIM/171_FUJI/DSCF1079.JPG"))
        if let firstShotTime = result.shots.first?.frames.first?.captureTime {
            XCTAssertGreaterThan(abs(firstShotTime - other.captureTime), 86_400, "different capture days present")
        }

        // Export the smallest real burst (grade + as-shot cadence) at
        // native res to the scratchpad and verify the movie.
        guard let smallest = result.shots.filter({ $0.frames.count >= 3 }).min(by: { $0.frames.count < $1.frames.count }) else {
            XCTFail("no exportable shot"); return
        }
        var shot = smallest
        shot.timingOverride = .asShot(rate: 1.0)
        shot.grade = ShotGrade(exposure: 0.2, contrast: 10, grainAmount: 15)
        let outDir = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-jessedacri-Preem/f043db8e-68dd-4668-b674-bc449c66ad51/scratchpad/real-export", isDirectory: true)
        let exportStart = Date()
        let movie = try BurstShotExporter().export(shot: shot, mode: shot.timing(projectDefault: .default),
                                                   rate: .twentyFour, codec: .proRes422HQ, to: outDir)
        let exportSeconds = Date().timeIntervalSince(exportStart)
        let asset = AVURLAsset(url: movie)
        let schedule = ShotTimingEngine.schedule(for: shot, projectDefault: .default, rate: .twentyFour)
        print(String(format: "[RealFootage] exported %@ (%d stills → %.2fs movie) in %.1fs → %@",
                     shot.name, shot.frames.count, Double(ShotTimingEngine.totalFrames(schedule)) / 24.0,
                     exportSeconds, movie.path))
        XCTAssertEqual(CMTimeGetSeconds(asset.duration),
                       Double(ShotTimingEngine.totalFrames(schedule)) / 24.0, accuracy: 0.05)
        let size = asset.tracks(withMediaType: .video).first?.naturalSize ?? .zero
        XCTAssertGreaterThanOrEqual(Int(size.width), 4000, "native-res export from real RAF/JPG")
    }
}
