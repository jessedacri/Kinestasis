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

    func testBoomerangMirrorsInteriorOnly() {
        let entries: [(index: Int, delay: Double)] = [(0, 0.1), (1, 0.2), (2, 0.3), (3, 0.4)]
        let pingPong = GIFExporter.boomerangEntries(entries)
        XCTAssertEqual(pingPong.map(\.index), [0, 1, 2, 3, 2, 1],
                       "ends are not doubled, so the loop is seamless")
        XCTAssertEqual(pingPong.map(\.delay), [0.1, 0.2, 0.3, 0.4, 0.3, 0.2])
    }

    func testBoomerangOfTinySequencesIsUnchanged() {
        let two: [(index: Int, delay: Double)] = [(0, 0.1), (1, 0.2)]
        XCTAssertEqual(GIFExporter.boomerangEntries(two).map(\.index), [0, 1])
    }

    func testDelayQuantizationTracksCumulativeTime() {
        // 10 stills at 125.1ms: naive rounding writes 1.30s; dithered
        // quantization must land within one centisecond of 1.251s.
        let entries = (0..<10).map { (index: $0, delay: 3.0 / 23.976) }
        let delays = GIFExporter.quantizedDelays(entries)
        let total = delays.reduce(0, +)
        XCTAssertEqual(total, 10 * 3.0 / 23.976, accuracy: 0.011)
        for d in delays {
            XCTAssertEqual((d * 100).rounded() / 100, d, accuracy: 1e-9, "whole centiseconds")
            XCTAssertGreaterThanOrEqual(d, 0.02, "browser clamp floor")
        }
        XCTAssertTrue(Set(delays.map { Int(($0 * 100).rounded()) }).count > 1, "dithers between 12 and 13cs")
    }
}
