import XCTest
@testable import KineMedia
import KineCore

final class ShotGradeTests: XCTestCase {

    func testCubeLUTParsing() throws {
        let cube = """
        # comment
        TITLE "test"
        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID()).cube")
        try cube.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let lut = try CubeLUT.load(url: url)
        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.rgbaData.count, 2 * 2 * 2 * 4 * MemoryLayout<Float>.size)
        let floats = lut.rgbaData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(Array(floats[0..<4]), [0, 0, 0, 1])
        XCTAssertEqual(Array(floats[4..<8]), [1, 0, 0, 1])
        XCTAssertEqual(floats.last, 1)
    }

    func testCubeLUTRejectsTruncatedData() throws {
        let cube = "LUT_3D_SIZE 2\n0 0 0\n1 1 1\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID()).cube")
        try cube.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try CubeLUT.load(url: url))
    }

    func testGradeIdentityDetection() {
        XCTAssertTrue(ShotGrade.identity.isIdentity)
        var g = ShotGrade.identity
        g.exposure = 0.5
        XCTAssertFalse(g.isIdentity)
        g = .identity
        g.blackAndWhite = true
        XCTAssertFalse(g.isIdentity)
        g = .identity
        g.lutPath = "/tmp/x.cube"
        g.lutIntensity = 0
        XCTAssertTrue(g.isIdentity, "LUT at zero intensity is identity")
    }

    func testShotDecodesWithoutGradeKey() throws {
        let shot = BurstShot(name: "S", frames: [StillFrame(url: URL(fileURLWithPath: "/a.jpg"), captureTime: 1)])
        var dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shot)) as! [String: Any]
        dict["grade"] = nil
        let data = try JSONSerialization.data(withJSONObject: dict)
        let back = try JSONDecoder().decode(BurstShot.self, from: data)
        XCTAssertEqual(back.grade, .identity)
    }

    func testGradeRoundTripsThroughLookJSON() throws {
        let grade = ShotGrade(exposure: 1.2, contrast: 20, temperature: -15, tint: 5,
                              highlights: -30, shadows: 40, saturation: -10,
                              blackAndWhite: false, lutPath: "/tmp/f.cube", lutIntensity: 65)
        let data = try JSONEncoder().encode(grade)
        let back = try JSONDecoder().decode(ShotGrade.self, from: data)
        XCTAssertEqual(back, grade)
    }
}
