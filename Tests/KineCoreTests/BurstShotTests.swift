import XCTest
@testable import KineCore

final class BurstShotTests: XCTestCase {

    private func frame(_ t: TimeInterval, name: String = "IMG") -> StillFrame {
        StillFrame(url: URL(fileURLWithPath: "/stills/\(name)_\(t).jpg"), captureTime: t)
    }

    // MARK: - Grouping

    func testGroupSplitsOnGap() {
        let frames = [0.0, 0.1, 0.2, 5.0, 5.1, 20.0].map { frame($0) }
        let shots = BurstGrouper.group(frames, gapThreshold: 2.0)
        XCTAssertEqual(shots.map(\.count), [3, 2, 1])
    }

    func testGroupSortsUnorderedInput() {
        let frames = [5.1, 0.2, 0.0, 5.0, 0.1].map { frame($0) }
        let shots = BurstGrouper.group(frames, gapThreshold: 2.0)
        XCTAssertEqual(shots.map(\.count), [3, 2])
        XCTAssertEqual(shots[0].map(\.captureTime), [0.0, 0.1, 0.2])
    }

    func testGroupEmptyAndSingle() {
        XCTAssertTrue(BurstGrouper.group([], gapThreshold: 2).isEmpty)
        XCTAssertEqual(BurstGrouper.group([frame(1)], gapThreshold: 2).map(\.count), [1])
    }

    func testGapExactlyAtThresholdDoesNotSplit() {
        let shots = BurstGrouper.group([frame(0), frame(2.0)], gapThreshold: 2.0)
        XCTAssertEqual(shots.count, 1)
    }

    // MARK: - Fixed frames-per-still

    func testFixedFramesPerStill() {
        let frames = (0..<4).map { frame(Double($0)) }
        let events = ShotTimingEngine.schedule(frames: frames, mode: .fixedFramesPerStill(frames: 3), rate: .twentyFour)
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events.map(\.startFrame), [0, 3, 6, 9])
        XCTAssertEqual(events.map(\.frameCount), [3, 3, 3, 3])
        XCTAssertEqual(ShotTimingEngine.totalFrames(events), 12)
    }

    func testFixedClampsToOneFrameMinimum() {
        let events = ShotTimingEngine.schedule(frames: [frame(0)], mode: .fixedFramesPerStill(frames: 0), rate: .twentyFour)
        XCTAssertEqual(events, [StillEvent(frameIndex: 0, startFrame: 0, frameCount: 1)])
    }

    // MARK: - Frame skip

    func testFrameSkipKeepsEveryNth() {
        let frames = (0..<10).map { frame(Double($0)) }
        let events = ShotTimingEngine.schedule(frames: frames, mode: .frameSkip(every: 4, frames: 2), rate: .twentyFour)
        XCTAssertEqual(events.map(\.frameIndex), [0, 4, 8])
        XCTAssertEqual(events.map(\.startFrame), [0, 2, 4])
        XCTAssertEqual(events.map(\.frameCount), [2, 2, 2])
    }

    // MARK: - As-shot cadence

    func testAsShotRealTimeCadence() {
        // 2 fps burst at 24 fps timeline, real time → 12 frames per still.
        let frames = [0.0, 0.5, 1.0, 1.5].map { frame($0) }
        let events = ShotTimingEngine.schedule(frames: frames, mode: .asShot(rate: 1.0), rate: .twentyFour)
        XCTAssertEqual(events.map(\.startFrame), [0, 12, 24, 36])
        XCTAssertEqual(events.map(\.frameCount), [12, 12, 12, 12])
    }

    func testAsShotPreservesBufferSlowdown() {
        // Burst slows mid-way (camera buffer): 0.1s gaps then a 0.5s gap.
        let frames = [0.0, 0.1, 0.2, 0.7, 0.8].map { frame($0) }
        let events = ShotTimingEngine.schedule(frames: frames, mode: .asShot(rate: 1.0), rate: .thirty)
        XCTAssertEqual(events.map(\.frameCount), [3, 3, 15, 3, 3])
    }

    func testAsShotRateScalesDurations() {
        let frames = [0.0, 1.0, 2.0].map { frame($0) }
        let events = ShotTimingEngine.schedule(frames: frames, mode: .asShot(rate: 2.0), rate: .twentyFour)
        XCTAssertEqual(events.map(\.frameCount), [12, 12, 12])
    }

    func testAsShotDropsSubFrameStills() {
        // 120 fps burst on a 24 fps timeline: ~1 kept still per 5 captured.
        let frames = (0..<20).map { frame(Double($0) / 120.0) }
        let events = ShotTimingEngine.schedule(frames: frames, mode: .asShot(rate: 1.0), rate: .twentyFour)
        XCTAssertFalse(events.isEmpty)
        XCTAssertLessThan(events.count, 20)
        // Contiguity: no gaps or overlaps after drops.
        for (a, b) in zip(events, events.dropFirst()) {
            XCTAssertEqual(a.startFrame + a.frameCount, b.startFrame)
        }
        // Total ≈ real-time span (20 stills / 120 fps ≈ 0.17 s ≈ 4 frames).
        XCTAssertEqual(ShotTimingEngine.totalFrames(events), 4, accuracy: 1)
    }

    func testAsShotSingleStill() {
        let events = ShotTimingEngine.schedule(frames: [frame(3.0)], mode: .asShot(rate: 1.0), rate: .twentyFour)
        XCTAssertEqual(events, [StillEvent(frameIndex: 0, startFrame: 0, frameCount: 1)])
    }

    // MARK: - Lookup

    func testEventAtFrameBinarySearch() {
        let frames = (0..<5).map { frame(Double($0)) }
        let events = ShotTimingEngine.schedule(frames: frames, mode: .fixedFramesPerStill(frames: 3), rate: .twentyFour)
        XCTAssertEqual(ShotTimingEngine.event(at: 0, in: events)?.frameIndex, 0)
        XCTAssertEqual(ShotTimingEngine.event(at: 2, in: events)?.frameIndex, 0)
        XCTAssertEqual(ShotTimingEngine.event(at: 3, in: events)?.frameIndex, 1)
        XCTAssertEqual(ShotTimingEngine.event(at: 14, in: events)?.frameIndex, 4)
        XCTAssertEqual(ShotTimingEngine.event(at: 99, in: events)?.frameIndex, 4)
        XCTAssertEqual(ShotTimingEngine.event(at: -1, in: events)?.frameIndex, 0)
        XCTAssertNil(ShotTimingEngine.event(at: 0, in: []))
    }

    // MARK: - Model

    func testTimingOverridePrecedence() {
        var shot = BurstShot(name: "S1", frames: [frame(0)])
        XCTAssertEqual(shot.timing(projectDefault: .default), .default)
        shot.timingOverride = .asShot(rate: 1)
        XCTAssertEqual(shot.timing(projectDefault: .default), .asShot(rate: 1))
    }

    func testBurstShotCodableRoundTrip() throws {
        let shot = BurstShot(name: "S1", frames: [frame(0), frame(0.25)], timingOverride: .frameSkip(every: 2, frames: 3))
        let data = try JSONEncoder().encode(shot)
        let back = try JSONDecoder().decode(BurstShot.self, from: data)
        XCTAssertEqual(back.name, shot.name)
        XCTAssertEqual(back.frames.map(\.captureTime), shot.frames.map(\.captureTime))
        XCTAssertEqual(back.timingOverride, shot.timingOverride)
    }

    func testProjectSettingsDecodeWithoutBurstKeyFallsBack() throws {
        let json = """
        {"defaultFrameRate":"24","defaultResolution":{"width":1920,"height":1080},"defaultColorSpace":"rec709"}
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(ProjectSettings.self, from: json)
        XCTAssertEqual(settings.burst, .default)
    }

    // MARK: - Speed ramp

    func testRampEmptyIsUnchanged() {
        let frames = (0..<4).map { frame(Double($0)) }
        let base = ShotTimingEngine.schedule(frames: frames, mode: .fixedFramesPerStill(frames: 3), rate: .twentyFour)
        XCTAssertEqual(ShotTimingEngine.applyRamp(base, ramp: []), base)
    }

    func testRampPreservesTotalDuration() {
        let frames = (0..<6).map { frame(Double($0)) }
        let base = ShotTimingEngine.schedule(frames: frames, mode: .fixedFramesPerStill(frames: 4), rate: .twentyFour)
        let ramp = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.85), CurvePoint(x: 1, y: 1)]
        let out = ShotTimingEngine.applyRamp(base, ramp: ramp)
        XCTAssertEqual(ShotTimingEngine.totalFrames(out), ShotTimingEngine.totalFrames(base))
        // Contiguous, monotone still order.
        for (a, b) in zip(out, out.dropFirst()) {
            XCTAssertEqual(a.startFrame + a.frameCount, b.startFrame)
            XCTAssertLessThan(a.frameIndex, b.frameIndex)
        }
    }

    func testRampRedistributesScreenTime() {
        // Fast first half (steep), lingering second half (flat): early
        // stills get less screen time than late ones.
        let frames = (0..<8).map { frame(Double($0)) }
        let base = ShotTimingEngine.schedule(frames: frames, mode: .fixedFramesPerStill(frames: 6), rate: .twentyFour)
        let ramp = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.3, y: 0.8), CurvePoint(x: 1, y: 1)]
        let out = ShotTimingEngine.applyRamp(base, ramp: ramp)
        XCTAssertLessThan(out.first!.frameCount, out.last!.frameCount)
    }

    // MARK: - Exposure wobble

    func testWobbleDeterministicAndBounded() {
        let a = ExposureWobble.evOffset(outputFrame: 7, fps: 24, intensity: 100, rate: 4)
        let b = ExposureWobble.evOffset(outputFrame: 7, fps: 24, intensity: 100, rate: 4)
        XCTAssertEqual(a, b)
        for f in 0..<200 {
            let ev = ExposureWobble.evOffset(outputFrame: Int64(f), fps: 24, intensity: 100, rate: 4)
            XCTAssertLessThanOrEqual(abs(ev), ExposureWobble.maxEV + 1e-9)
        }
    }

    func testWobbleZeroIntensityIsZero() {
        XCTAssertEqual(ExposureWobble.evOffset(outputFrame: 3, fps: 24, intensity: 0, rate: 4), 0)
    }

    func testWobbleScalesWithIntensity() {
        let full = ExposureWobble.evOffset(outputFrame: 13, fps: 24, intensity: 100, rate: 4)
        let half = ExposureWobble.evOffset(outputFrame: 13, fps: 24, intensity: 50, rate: 4)
        XCTAssertEqual(half, full / 2, accuracy: 1e-12)
    }

    // MARK: - Whole-second timestamp spreading

    func testEqualTimestampsSpreadEvenlyAcrossTheSecond() {
        let frames = [10.0, 10.0, 10.0, 10.0, 11.0, 11.0].map { frame($0) }
        let spread = BurstGrouper.spreadEqualTimestamps(frames)
        XCTAssertEqual(spread.map(\.captureTime), [10.0, 10.25, 10.5, 10.75, 11.0, 11.5])
    }

    func testWholeSecondBurstKeepsAsShotCadenceAlive() {
        // X-Pro2 style: 8 stills across 2 whole-second stamps. After the
        // grouping spread, as-shot at 24 fps must keep every still visible.
        let raw = (0..<8).map { frame(Double($0 / 4)) }
        let grouped = BurstGrouper.group(raw, gapThreshold: 2.0)
        XCTAssertEqual(grouped.count, 1)
        let events = ShotTimingEngine.schedule(frames: grouped[0], mode: .asShot(rate: 1.0), rate: .twentyFour)
        XCTAssertEqual(events.count, 8, "no stills collapsed by whole-second timestamps")
        XCTAssertEqual(events.map(\.frameCount), [6, 6, 6, 6, 6, 6, 6, 6])
    }
}
