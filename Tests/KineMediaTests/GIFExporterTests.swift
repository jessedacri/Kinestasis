import XCTest
@testable import KineMedia
import KineCore

final class GIFExporterTests: XCTestCase {
    func testConsolidationMergesRunsAndDerivesDelays() {
        let schedule = [
            StillEvent(frameIndex: 0, startFrame: 0, frameCount: 3),
            StillEvent(frameIndex: 1, startFrame: 3, frameCount: 3),
            StillEvent(frameIndex: 1, startFrame: 6, frameCount: 2),   // ramp continuation
            StillEvent(frameIndex: 2, startFrame: 8, frameCount: 6),
        ]
        let entries = GIFExporter.consolidatedEntries(schedule: schedule, fps: 24)
        XCTAssertEqual(entries.map(\.index), [0, 1, 2])
        XCTAssertEqual(entries[0].delay, 3.0 / 24, accuracy: 1e-9)
        XCTAssertEqual(entries[1].delay, 5.0 / 24, accuracy: 1e-9, "merged run")
        XCTAssertEqual(entries[2].delay, 6.0 / 24, accuracy: 1e-9)
    }
}
