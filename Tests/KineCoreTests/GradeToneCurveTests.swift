import XCTest
@testable import KineCore

final class GradeToneCurveTests: XCTestCase {

    func testIdentityGradeIsIdentityCurve() {
        for x in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertEqual(GradeToneCurve.evaluate(x, grade: .identity), x, accuracy: 1e-9)
        }
        XCTAssertFalse(GradeToneCurve.isActive(.identity))
    }

    func testPositiveHighlightsBrightenTheTop() {
        let g = ShotGrade(highlights: 60)
        XCTAssertGreaterThan(GradeToneCurve.evaluate(0.8, grade: g), 0.8, "bright region rises")
        XCTAssertEqual(GradeToneCurve.evaluate(0.2, grade: g), 0.2, accuracy: 1e-9, "shadows untouched")
    }

    func testNegativeShadowsDeepenTheBottom() {
        let g = ShotGrade(shadows: -60)
        XCTAssertLessThan(GradeToneCurve.evaluate(0.2, grade: g), 0.2, "dark region sinks")
        XCTAssertEqual(GradeToneCurve.evaluate(0.8, grade: g), 0.8, accuracy: 1e-9, "highlights untouched")
    }

    func testWhitesAndBlacksMoveTheEndZones() {
        XCTAssertGreaterThan(GradeToneCurve.evaluate(0.95, grade: ShotGrade(whites: 80)), 0.95)
        XCTAssertLessThan(GradeToneCurve.evaluate(0.95, grade: ShotGrade(whites: -80)), 0.95)
        XCTAssertGreaterThan(GradeToneCurve.evaluate(0.05, grade: ShotGrade(blacks: 80)), 0.05)
        XCTAssertEqual(GradeToneCurve.evaluate(0.05, grade: ShotGrade(blacks: -80)), 0, accuracy: 0.05)
        XCTAssertEqual(GradeToneCurve.evaluate(0.5, grade: ShotGrade(whites: 80)), 0.5, accuracy: 0.02,
                       "midtones stay put")
    }

    func testContrastIsAnSCurveAroundMiddleGray() {
        let g = ShotGrade(contrast: 70)
        XCTAssertLessThan(GradeToneCurve.evaluate(0.25, grade: g), 0.25)
        XCTAssertGreaterThan(GradeToneCurve.evaluate(0.75, grade: g), 0.75)
        XCTAssertEqual(GradeToneCurve.evaluate(0.5, grade: g), 0.5, accuracy: 1e-6, "pivot holds")
        let flat = ShotGrade(contrast: -70)
        XCTAssertGreaterThan(GradeToneCurve.evaluate(0.25, grade: flat), 0.25)
        XCTAssertLessThan(GradeToneCurve.evaluate(0.75, grade: flat), 0.75)
    }

    func testUserCurveComposesOnTop() {
        var g = ShotGrade()
        g.toneCurve = [CurvePoint(x: 0, y: 0.2), CurvePoint(x: 1, y: 1)]
        XCTAssertEqual(GradeToneCurve.evaluate(0, grade: g), 0.2, accuracy: 0.01)
        XCTAssertTrue(GradeToneCurve.isActive(g))
    }

    func testStaysMonotoneAndBoundedUnderWildCombos() {
        let g = ShotGrade(contrast: 100, highlights: 100, shadows: -100,
                          whites: -100, blacks: 100)
        var last = -0.001
        for i in 0...200 {
            let y = GradeToneCurve.evaluate(Double(i) / 200, grade: g)
            XCTAssertGreaterThanOrEqual(y, 0)
            XCTAssertLessThanOrEqual(y, 1)
            XCTAssertGreaterThanOrEqual(y, last - 0.02, "no hard reversals")
            last = y
        }
    }

    func testContrastWobbleShiftsTheCurve() {
        let still = GradeToneCurve.evaluate(0.75, grade: .identity, contrastWobble: 0)
        let wobbled = GradeToneCurve.evaluate(0.75, grade: .identity, contrastWobble: 0.3)
        XCTAssertGreaterThan(wobbled, still)
        XCTAssertTrue(GradeToneCurve.isActive(.identity, contrastWobble: 0.3))
    }
}
