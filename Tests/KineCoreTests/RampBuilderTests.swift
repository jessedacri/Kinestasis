import XCTest
@testable import KineCore

final class RampBuilderTests: XCTestCase {

    private func assertMonotone(_ points: [CurvePoint]) {
        for i in 1..<points.count {
            XCTAssertGreaterThan(points[i].x, points[i - 1].x - 1e-9)
            XCTAssertGreaterThanOrEqual(points[i].y, points[i - 1].y - 1e-9)
        }
    }

    func testDwellRampEndpointsAndMonotonicity() {
        let points = RampBuilder.ramp(fromDwells: [1, 1, 5, 1, 1])
        XCTAssertEqual(points.first?.x, 0)
        XCTAssertEqual(points.first?.y, 0)
        XCTAssertEqual(points.last?.x ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(points.last?.y ?? 0, 1, accuracy: 1e-9)
        assertMonotone(points)
    }

    func testHeavyDwellFlattensItsSpan() {
        // Still 2 of 5 gets 5x weight: its output span is 5/9 wide but
        // only 1/5 of the source advances across it.
        let points = RampBuilder.ramp(fromDwells: [1, 1, 5, 1, 1])
        let curve = ToneCurve(points)
        let before = curve.evaluate(2.0 / 9.0)
        let after = curve.evaluate(7.0 / 9.0)
        XCTAssertEqual(before, 0.4, accuracy: 0.05, "two stills done as the hold begins")
        XCTAssertEqual(after, 0.6, accuracy: 0.05, "hold ends with three stills done")
    }

    func testHoldRampGivesHeldStillItsShare() {
        let points = RampBuilder.holdRamp(stillIndex: 10, stillCount: 21,
                                          holdShare: 0.4, easeIn: 0, easeOut: 0, ease: 0)
        assertMonotone(points)
        let curve = ToneCurve(points)
        // The held still spans source [10/21, 11/21]; find its output width.
        var enter = 0.0, exit = 1.0
        for t in stride(from: 0.0, through: 1.0, by: 0.001) {
            let y = curve.evaluate(t)
            if y <= 10.0 / 21.0 + 1e-6 { enter = t }
            if y >= 11.0 / 21.0 - 1e-6 { exit = min(exit, t) }
        }
        XCTAssertEqual(exit - enter, 0.4, accuracy: 0.08)
    }

    func testHoldRampClampsAndDegenerates() {
        XCTAssertTrue(RampBuilder.holdRamp(stillIndex: 0, stillCount: 1, holdShare: 0.5, easeIn: 2, easeOut: 2, ease: 0.5).isEmpty)
        XCTAssertTrue(RampBuilder.holdRamp(stillIndex: 9, stillCount: 5, holdShare: 0.5, easeIn: 2, easeOut: 2, ease: 0.5).isEmpty)
        let extreme = RampBuilder.holdRamp(stillIndex: 2, stillCount: 10, holdShare: 5.0, easeIn: 3, easeOut: 3, ease: 1)
        assertMonotone(extreme)
    }

    func testSkipAfterHoldDropsFollowingStills() {
        var shot = BurstShot(name: "S", frames: (0..<20).map {
            StillFrame(url: URL(fileURLWithPath: "/s/\($0).jpg"), captureTime: Double($0) * 0.125)
        })
        shot.timingOverride = .fixedFramesPerStill(frames: 2)
        shot.speedRamp = RampBuilder.holdRamp(stillIndex: 8, stillCount: 20,
                                              holdShare: 0.3, easeIn: 0, easeOut: 0,
                                              ease: 0, skipAfter: 3)
        let events = ShotTimingEngine.schedule(for: shot, projectDefault: .default, rate: .twentyFour)
        let played = Set(events.map(\.frameIndex))
        XCTAssertTrue(played.contains(8), "held still plays")
        XCTAssertFalse(played.contains(9), "stills right after the hold are skipped")
        XCTAssertFalse(played.contains(10))
        XCTAssertFalse(played.contains(11))
        XCTAssertTrue(played.contains(12), "cadence resumes past the skip")
    }

    func testDownsampleCapsHandleCount() {
        let dwells = (0..<200).map { i in 1.0 + (i == 100 ? 30.0 : 0) + Double(i % 7) * 0.01 }
        let points = RampBuilder.ramp(fromDwells: dwells)
        XCTAssertLessThanOrEqual(points.count, 16)
        assertMonotone(points)
    }

    func testRampPreservesScheduleDuration() {
        var shot = BurstShot(name: "S", frames: (0..<24).map {
            StillFrame(url: URL(fileURLWithPath: "/s/\($0).jpg"), captureTime: Double($0) * 0.125)
        })
        shot.timingOverride = .fixedFramesPerStill(frames: 3)
        let flat = ShotTimingEngine.schedule(for: shot, projectDefault: .default, rate: .twentyFour)
        shot.speedRamp = RampBuilder.holdRamp(stillIndex: 12, stillCount: 24,
                                              holdShare: 0.5, easeIn: 3, easeOut: 3, ease: 0.5)
        let ramped = ShotTimingEngine.schedule(for: shot, projectDefault: .default, rate: .twentyFour)
        XCTAssertEqual(ShotTimingEngine.totalFrames(ramped), ShotTimingEngine.totalFrames(flat))
    }

    func testMarkedStillsSurviveCodableRoundTrip() throws {
        let frames = (0..<4).map {
            StillFrame(url: URL(fileURLWithPath: "/s/\($0).jpg"), captureTime: Double($0))
        }
        var shot = BurstShot(name: "S", frames: frames)
        shot.markedStillIDs = [frames[1].id, frames[3].id]
        let back = try JSONDecoder().decode(BurstShot.self, from: JSONEncoder().encode(shot))
        XCTAssertEqual(back.markedStillIDs, shot.markedStillIDs)
    }
}
