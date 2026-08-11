import XCTest
@testable import KineMedia
import KineCore

final class ShotBatchXMLSidecarTests: XCTestCase {

    private func entry(_ name: String, frames: Int64, w: Int = 6000, h: Int = 4000) -> ShotBatchXMLSidecar.Entry {
        let shot = BurstShot(name: name, frames: [StillFrame(url: URL(fileURLWithPath: "/s/\(name).jpg"), captureTime: 0)])
        return ShotBatchXMLSidecar.Entry(
            shot: shot, movieURL: URL(fileURLWithPath: "/out/\(name)_422HQ.mov"),
            outputFrames: frames, size: PixelSize(width: w, height: h))
    }

    func testSidecarIsWellFormedAndComplete() throws {
        let xml = ShotBatchXMLSidecar().xml(
            entries: [entry("A_S001", frames: 24), entry("A_S002", frames: 48)],
            rate: .twentyFour, batchName: "Batch")
        let doc = try XMLDocument(xmlString: xml)
        let assets = try doc.nodes(forXPath: "//asset")
        XCTAssertEqual(assets.count, 2)
        let spineClips = try doc.nodes(forXPath: "//spine/asset-clip")
        XCTAssertEqual(spineClips.count, 2)
        // Second spine clip offset = first duration (24 frames @ 24 = 1s).
        let second = spineClips[1] as! XMLElement
        XCTAssertEqual(second.attribute(forName: "offset")?.stringValue, "24/24s")
        XCTAssertEqual(second.attribute(forName: "duration")?.stringValue, "48/24s")
        let formats = try doc.nodes(forXPath: "//format")
        XCTAssertEqual(formats.count, 1, "same pixel size shares one format")
    }

    func testSidecarFractionalRateAndEscaping() throws {
        let xml = ShotBatchXMLSidecar().xml(
            entries: [entry("A&B <S1>", frames: 24)],
            rate: .twentyThree976, batchName: "Fuji & Co")
        let doc = try XMLDocument(xmlString: xml)
        let fmt = try doc.nodes(forXPath: "//format").first as! XMLElement
        XCTAssertEqual(fmt.attribute(forName: "frameDuration")?.stringValue, "1001/24000s")
        let asset = try doc.nodes(forXPath: "//asset").first as! XMLElement
        XCTAssertEqual(asset.attribute(forName: "name")?.stringValue, "A&B <S1>")
    }
}
