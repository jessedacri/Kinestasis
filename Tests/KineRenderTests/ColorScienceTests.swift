import XCTest
import simd
import KineCore
@testable import KineRender

final class ColorScienceTests: XCTestCase {

    func testRec709IsIdentity() {
        let m = ColorScience.cameraToRec709(.rec709)
        let id = matrix_identity_float3x3
        for c in 0..<3 {
            for r in 0..<3 {
                XCTAssertEqual(m[c][r], id[c][r], accuracy: 1e-5)
            }
        }
    }

    /// All supported gamuts share a D65 white point, so neutral camera RGB
    /// (1,1,1) must map to neutral Rec.709 (1,1,1) — the white is preserved.
    func testWhitePreservedAcrossGamuts() {
        for space in [ColorTransferSpace.sonySLog3, .canonCLog2, .canonCLog3, .arriLogC3, .panasonicVLog, .rec2020] {
            let m = ColorScience.cameraToRec709(space)
            let white = m * SIMD3<Float>(1, 1, 1)
            XCTAssertEqual(white.x, 1, accuracy: 1e-3, "\(space) R")
            XCTAssertEqual(white.y, 1, accuracy: 1e-3, "\(space) G")
            XCTAssertEqual(white.z, 1, accuracy: 1e-3, "\(space) B")
        }
    }

    /// Wide-gamut → Rec.709 desaturates a pure primary (the camera's red is
    /// more saturated than 709 red), so off-diagonal terms appear.
    func testWideGamutHasOffDiagonal() {
        let m = ColorScience.cameraToRec709(.sonySLog3)
        // Pure camera red has some negative green/blue after conversion.
        let red = m * SIMD3<Float>(1, 0, 0)
        XCTAssertGreaterThan(red.x, 1.0)          // 709 red channel pushed past 1
        XCTAssertLessThan(red.y, 0.0)             // green goes negative (out of 709 gamut)
    }
}
