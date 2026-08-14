import XCTest
import CoreGraphics
@testable import KineMedia

final class PreviewDiskCacheTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDC-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeSourceFile(_ name: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try Data(repeating: 7, count: 1000).write(to: url)
        return url
    }

    private func makeImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.6, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func testRoundTripAndTierSeparation() throws {
        let source = try makeSourceFile("a.jpg")
        XCTAssertNil(PreviewDiskCache.load(url: source, maxPixel: 960))
        PreviewDiskCache.store(makeImage(width: 960, height: 640), url: source, maxPixel: 960)
        let hit = try XCTUnwrap(PreviewDiskCache.load(url: source, maxPixel: 960))
        XCTAssertEqual(hit.width, 960)
        XCTAssertNil(PreviewDiskCache.load(url: source, maxPixel: 2560), "tiers are separate keys")
    }

    func testEditedSourceMissesCleanly() throws {
        let source = try makeSourceFile("b.jpg")
        PreviewDiskCache.store(makeImage(width: 448, height: 300), url: source, maxPixel: 448)
        XCTAssertNotNil(PreviewDiskCache.load(url: source, maxPixel: 448))
        // Change size + mtime: identity changes, cache must miss.
        try Data(repeating: 9, count: 2000).write(to: source)
        XCTAssertNil(PreviewDiskCache.load(url: source, maxPixel: 448))
    }
}
