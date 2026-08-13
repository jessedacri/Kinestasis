import XCTest
@testable import KineMedia

final class PreviewSizeGuardTests: XCTestCase {
    /// The 160x120 EXIF thumbnail must never satisfy a preview request:
    /// JPEG bursts rendered as garbage at every tier because of it.
    func testJPEGPreviewHonorsRequestedSize() throws {
        let jpg = URL(fileURLWithPath: "/Volumes/BLANK 2T/XPro2 Cincinnati/C1/DCIM/171_FUJI/DSCF1491.JPG")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: jpg.path))
        for px in [448, 960, 1920] {
            let img = try XCTUnwrap(StillDecoder.preview(url: jpg, maxPixel: px))
            XCTAssertGreaterThanOrEqual(max(img.width, img.height) * 10, px * 7,
                                        "preview(\(px)) returned \(img.width)x\(img.height)")
        }
    }

    /// RAWs keep the fast embedded-preview path when it is big enough.
    func testRAFPreviewStillUsesEmbedded() throws {
        let raf = URL(fileURLWithPath: "/Volumes/BLANK 2T/XPro2 Cincinnati/C1/DCIM/177_FUJI/DSCF7171.RAF")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: raf.path))
        let img = try XCTUnwrap(StillDecoder.preview(url: raf, maxPixel: 960))
        XCTAssertEqual(max(img.width, img.height), 960)
    }
}
