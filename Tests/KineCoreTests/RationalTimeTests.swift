import XCTest
@testable import KineCore

final class RationalTimeTests: XCTestCase {
    func testZeroIsZero() {
        XCTAssertEqual(RationalTime.zero.seconds, 0)
    }

    func test23976FrameIsOneOverTwentyFour() {
        let oneFrame = RationalTime(value: 1001, scale: 24000)
        XCTAssertEqual(oneFrame.seconds, 1001.0 / 24000.0, accuracy: 1e-9)
    }

    func testRescale() {
        let oneSecAt24 = RationalTime(value: 24, scale: 24)
        let rescaled = oneSecAt24.rescaled(to: 48_000)
        XCTAssertEqual(rescaled.seconds, 1.0, accuracy: 1e-9)
    }

    func testAdditionSameScale() {
        let a = RationalTime(value: 24, scale: 24)
        let b = RationalTime(value: 12, scale: 24)
        XCTAssertEqual((a + b).seconds, 1.5, accuracy: 1e-9)
    }

    func testAdditionMixedScale() {
        let a = RationalTime(value: 24000, scale: 24000)   // 1 s
        let b = RationalTime(value: 1001,  scale: 24000)   // 1 frame at 23.976
        let sum = a + b
        XCTAssertEqual(sum.seconds, 1.0 + 1001.0 / 24000.0, accuracy: 1e-9)
    }

    func testRangeContainsAndOverlap() {
        let r1 = TimeRange(start: RationalTime(value: 0, scale: 24), duration: RationalTime(value: 48, scale: 24))   // 0..2
        let r2 = TimeRange(start: RationalTime(value: 24, scale: 24), duration: RationalTime(value: 48, scale: 24))  // 1..3
        XCTAssertTrue(r1.contains(RationalTime(value: 24, scale: 24)))
        XCTAssertFalse(r1.contains(RationalTime(value: 48, scale: 24)))
        XCTAssertTrue(r1.overlaps(r2))
    }
}
