import XCTest
@testable import KineMedia
import KineCore

/// The player's boomerang loop is only a preview if it matches the file.
/// These pin the two together.
final class BoomerangParityTests: XCTestCase {

    /// Frames the exported GIF actually plays for, at `fps`.
    private func gifLoopFrames(_ schedule: [StillEvent], fps: Double) -> Double {
        let entries = GIFExporter.consolidatedEntries(schedule: schedule, fps: fps)
        return GIFExporter.boomerangEntries(entries).reduce(0) { $0 + $1.delay } * fps
    }

    private func schedule(_ spans: [(still: Int, frames: Int64)]) -> [StillEvent] {
        var start: Int64 = 0
        return spans.map { span in
            defer { start += span.frames }
            return StillEvent(frameIndex: span.still, startFrame: start, frameCount: span.frames)
        }
    }

    func testLoopLengthMatchesTheExportedGIF() {
        let even = schedule((0..<6).map { (still: $0, frames: Int64(3)) })
        let loop = BoomerangLoop(schedule: even)
        XCTAssertNotNil(loop)
        XCTAssertEqual(Double(loop!.totalFrames), gifLoopFrames(even, fps: 24), accuracy: 0.001)
    }

    func testRampHeldStillsCountAsOneStillAtEachEnd() {
        // A hold ramp emits several events for the same still. The opening
        // and closing stills are runs, and the whole run is what the return
        // pass skips.
        let ramped = schedule([
            (0, 4), (0, 4), (0, 4),   // opening hold, one still
            (1, 3), (2, 3), (3, 3),
            (4, 5), (4, 5),           // closing hold, one still
        ])
        let loop = BoomerangLoop(schedule: ramped)
        XCTAssertNotNil(loop)
        XCTAssertEqual(loop!.firstStillEnd, 12, "the whole opening hold is the first still")
        XCTAssertEqual(loop!.lastStillStart, 21, "the closing hold starts where its first event does")
        XCTAssertEqual(Double(loop!.totalFrames), gifLoopFrames(ramped, fps: 24), accuracy: 0.001)
    }

    func testTooFewStillsHaveNoInteriorToMirror() {
        // GIFExporter leaves 2-entry shots alone; the player must too.
        for count in 1...2 {
            let short = schedule((0..<count).map { (still: $0, frames: Int64(3)) })
            XCTAssertNil(BoomerangLoop(schedule: short), "\(count) stills")
            let entries = GIFExporter.consolidatedEntries(schedule: short, fps: 24)
            XCTAssertEqual(GIFExporter.boomerangEntries(entries).count, entries.count)
        }
    }

    func testReturnPassSkipsBothEndsExactlyOnce() {
        let s = schedule((0..<4).map { (still: $0, frames: Int64(2)) })
        let entries = GIFExporter.consolidatedEntries(schedule: s, fps: 24)
        XCTAssertEqual(GIFExporter.boomerangEntries(entries).map(\.index), [0, 1, 2, 3, 2, 1])
        let loop = BoomerangLoop(schedule: s)!
        XCTAssertEqual(loop.firstStillEnd, 2)
        XCTAssertEqual(loop.lastStillStart, 6)
        XCTAssertEqual(loop.totalFrames, 12, "8 forward, 4 back through the interior")
    }
}
