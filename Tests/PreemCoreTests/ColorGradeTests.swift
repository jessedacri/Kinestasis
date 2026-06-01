import XCTest
@testable import PreemCore

final class ColorGradeTests: XCTestCase {

    private func clip() -> PlacedClip {
        PlacedClip(
            sourceClipID: ClipID(),
            sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 5)),
            timelineRange: TimeRange(start: .zero, duration: RationalTime(seconds: 5))
        )
    }

    func testIdentityGrade() {
        XCTAssertTrue(ColorGrade.identity.isIdentity)
        XCTAssertTrue(clip().colorGrade(at: 0).isIdentity)
    }

    func testReadBackScalar() {
        var c = clip()
        c.setColorParameter(.exposure, value: 1.5)
        c.setColorParameter(.saturation, value: -40)
        let g = c.colorGrade(at: 0)
        XCTAssertEqual(g.exposure, 1.5, accuracy: 1e-9)
        XCTAssertEqual(g.saturation, -40, accuracy: 1e-9)
        XCTAssertFalse(g.isIdentity)
    }

    func testKeyframedScalarInterpolates() {
        var c = clip()
        c.toggleColorKeyframing(.exposure, at: 0)
        c.setColorParameter(.exposure, value: 0, at: 0)
        c.setColorParameter(.exposure, value: 2, at: 4)
        XCTAssertTrue(c.hasKeyframes(for: .exposure))
        XCTAssertEqual(c.colorGrade(at: 0).exposure, 0, accuracy: 1e-6)
        XCTAssertEqual(c.colorGrade(at: 2).exposure, 1, accuracy: 1e-6)
        XCTAssertEqual(c.colorGrade(at: 4).exposure, 2, accuracy: 1e-6)
    }

    func testCurveReadBack() {
        var c = clip()
        let pts = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.7), CurvePoint(x: 1, y: 1)]
        c.setColorCurve("curveMaster", pts)
        XCTAssertEqual(c.colorGrade(at: 0).curveMaster.count, 3)
    }

    func testToneCurveIdentityAndEndpoints() {
        XCTAssertTrue(ToneCurve([]).isIdentity)
        let lift = ToneCurve([CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)])
        XCTAssertEqual(lift.evaluate(0), 0.1, accuracy: 1e-9)
        XCTAssertEqual(lift.evaluate(1), 1.0, accuracy: 1e-9)
        XCTAssertEqual(lift.evaluate(-1), 0.1, accuracy: 1e-9)   // clamps below
        XCTAssertEqual(lift.evaluate(2), 1.0, accuracy: 1e-9)    // clamps above
    }

    func testToneCurveMonotone() {
        // An S-curve should stay monotonically non-decreasing (no overshoot).
        let s = ToneCurve([
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.15),
            CurvePoint(x: 0.75, y: 0.85), CurvePoint(x: 1, y: 1)
        ])
        var prev = -1.0
        for i in 0...100 {
            let y = s.evaluate(Double(i) / 100)
            XCTAssertGreaterThanOrEqual(y + 1e-9, prev)
            prev = y
        }
    }

    func testBakeLength() {
        let lut = ToneCurve([CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]).bake(256)
        XCTAssertEqual(lut.count, 256)
        XCTAssertEqual(lut.first!, 0, accuracy: 1e-6)
        XCTAssertEqual(lut.last!, 1, accuracy: 1e-6)
    }
}
