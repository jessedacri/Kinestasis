import XCTest
@testable import PreemCore

/// Guards the keyframe sampler that BOTH the realtime preview and the
/// renderer share (`sampleDouble` → `transform(at:)`). If these pass,
/// the rendered file honors eases identically to the live preview.
final class KeyframeInterpolationTests: XCTestCase {
    private func kf(_ t: Double, _ v: Double, _ interp: Interpolation) -> Keyframe {
        Keyframe(
            time: RationalTime(value: Int64(t * 1000), scale: 1000),
            value: .double(v),
            interpolation: interp
        )
    }

    /// Linear is the straight-line baseline.
    func testLinearMidpoint() {
        let p = ParameterValue.keyframed([kf(0, 1.0, .linear), kf(1, 0.0, .linear)])
        XCTAssertEqual(sampleDouble(p, at: 0.5, default: 1), 0.5, accuracy: 1e-9)
    }

    /// easeIn on the END keyframe decelerates INTO it: at the midpoint the
    /// value is further along than linear (0.375 < 0.5 for a 1→0 ramp).
    func testEaseInEndDeceleratesIntoKeyframe() {
        let p = ParameterValue.keyframed([kf(0, 1.0, .linear), kf(1, 0.0, .easeIn)])
        let mid = sampleDouble(p, at: 0.5, default: 1)
        XCTAssertEqual(mid, 0.375, accuracy: 1e-6)
        XCTAssertNotEqual(mid, 0.5, accuracy: 1e-3, "easeIn must not be linear")
    }

    /// easeOut on the START keyframe eases out of it: slow start, so at the
    /// midpoint the value has moved LESS than linear (0.625 > 0.5).
    func testEaseOutStartEasesOut() {
        let p = ParameterValue.keyframed([kf(0, 1.0, .easeOut), kf(1, 0.0, .linear)])
        let mid = sampleDouble(p, at: 0.5, default: 1)
        XCTAssertEqual(mid, 0.625, accuracy: 1e-6)
    }

    /// bezier eases both ends — symmetric smoothstep through the midpoint.
    func testBezierSymmetricMidpoint() {
        let p = ParameterValue.keyframed([kf(0, 1.0, .bezier), kf(1, 0.0, .bezier)])
        let mid = sampleDouble(p, at: 0.5, default: 1)
        XCTAssertEqual(mid, 0.5, accuracy: 1e-9)        // symmetric at center
        // ...but quarter point is pulled toward the start (slow start).
        let quarter = sampleDouble(p, at: 0.25, default: 1)
        XCTAssertGreaterThan(quarter, 0.75, "bezier slow-start holds value high early")
    }

    /// hold on the leading keyframe is a step: value stays at A across the
    /// whole segment, snapping to B only at the boundary.
    func testHoldStaysAtLeadingValue() {
        let p = ParameterValue.keyframed([kf(0, 1.0, .hold), kf(1, 0.0, .linear)])
        XCTAssertEqual(sampleDouble(p, at: 0.5, default: 1), 1.0, accuracy: 1e-9)
        XCTAssertEqual(sampleDouble(p, at: 0.99, default: 1), 1.0, accuracy: 1e-9)
    }

    /// Before the first / after the last keyframe clamps to the endpoints.
    func testClampsOutsideRange() {
        let p = ParameterValue.keyframed([kf(1, 0.2, .linear), kf(2, 0.8, .linear)])
        XCTAssertEqual(sampleDouble(p, at: 0.0, default: 0), 0.2, accuracy: 1e-9)
        XCTAssertEqual(sampleDouble(p, at: 9.0, default: 0), 0.8, accuracy: 1e-9)
    }
}
