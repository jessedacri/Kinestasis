import XCTest
@testable import PreemMedia
import PreemCore

final class FCPXMLExporterTests: XCTestCase {

    private func sampleProject() -> Project {
        var project = Project(name: "Demo")

        let clipA = ClipSource(
            url: URL(fileURLWithPath: "/tmp/take1.mov"),
            name: "take1",
            format: MediaFormat(container: "mov", videoCodec: "h264", audioCodec: "pcm_s24le"),
            duration: RationalTime(value: 5_000, scale: 1000),
            videoTracks: [VideoTrackInfo(resolution: PixelSize(width: 1920, height: 1080), frameRate: .twentyFour, pixelFormat: "yuv420p", colorSpace: .rec709)],
            audioTracks: [AudioTrackInfo(sampleRate: 48_000, channelCount: 2, bitDepth: 24)],
            scene: "12B",
            take: "4",
            roll: "03"
        )

        var clipB = ClipSource(
            url: URL(fileURLWithPath: "/tmp/take2.mov"),
            name: "take2",
            format: MediaFormat(container: "mov", videoCodec: "prores"),
            duration: RationalTime(value: 7_500, scale: 1000),
            videoTracks: [VideoTrackInfo(resolution: PixelSize(width: 3840, height: 2160), frameRate: .twentyThree976, pixelFormat: "yuv422p10", colorSpace: .rec2020)]
        )
        clipB.ml.shotType = .closeUp

        project.mediaPool.clips[clipA.id] = clipA
        project.mediaPool.clips[clipB.id] = clipB
        project.mediaPool.rootBin.children = [.clip(clipA.id), .clip(clipB.id)]
        return project
    }

    func testEmitsValidWellFormedXML() throws {
        let xml = FCPXMLExporter().export(project: sampleProject())
        XCTAssertTrue(xml.hasPrefix("<?xml"))
        XCTAssertTrue(xml.contains("<fcpxml version=\"1.10\">"))
        XCTAssertTrue(xml.contains("</fcpxml>"))

        // Parse with XMLDocument — fails if structurally invalid.
        _ = try XMLDocument(xmlString: xml)
    }

    func testIncludesEachClipAsAsset() {
        let xml = FCPXMLExporter().export(project: sampleProject())
        XCTAssertTrue(xml.contains("name=\"take1\""))
        XCTAssertTrue(xml.contains("name=\"take2\""))
        XCTAssertEqual(xml.components(separatedBy: "<asset ").count - 1, 2)
    }

    func testIncludesSlateAndShotKeywords() {
        let xml = FCPXMLExporter().export(project: sampleProject())
        XCTAssertTrue(xml.contains("value=\"Scene 12B\""))
        XCTAssertTrue(xml.contains("value=\"Take 4\""))
        XCTAssertTrue(xml.contains("value=\"Roll 03\""))
        XCTAssertTrue(xml.contains("value=\"Close-Up\""))
    }

    func testFormatsAreDeduped() {
        // Two clips with the same 1920×1080@24 format should share a single <format>.
        var project = Project(name: "Dup")
        let v = [VideoTrackInfo(resolution: PixelSize(width: 1920, height: 1080), frameRate: .twentyFour, pixelFormat: "yuv420p", colorSpace: .rec709)]
        let c1 = ClipSource(url: URL(fileURLWithPath: "/tmp/a.mov"), name: "a",
                            format: MediaFormat(container: "mov"),
                            duration: RationalTime(value: 1000, scale: 1000),
                            videoTracks: v)
        let c2 = ClipSource(url: URL(fileURLWithPath: "/tmp/b.mov"), name: "b",
                            format: MediaFormat(container: "mov"),
                            duration: RationalTime(value: 1000, scale: 1000),
                            videoTracks: v)
        project.mediaPool.clips[c1.id] = c1
        project.mediaPool.clips[c2.id] = c2
        project.mediaPool.rootBin.children = [.clip(c1.id), .clip(c2.id)]

        let xml = FCPXMLExporter().export(project: project)
        XCTAssertEqual(xml.components(separatedBy: "<format ").count - 1, 1)
    }

    func testXMLEscapesUnsafeChars() {
        var project = Project(name: "Has & in name")
        let clip = ClipSource(
            url: URL(fileURLWithPath: "/tmp/quote\"file.mov"),
            name: "with <tag> & quote",
            format: MediaFormat(container: "mov"),
            duration: RationalTime(value: 1000, scale: 1000),
            videoTracks: [VideoTrackInfo(resolution: PixelSize(width: 1920, height: 1080), frameRate: .twentyFour, pixelFormat: "yuv420p", colorSpace: .rec709)]
        )
        project.mediaPool.clips[clip.id] = clip
        project.mediaPool.rootBin.children = [.clip(clip.id)]

        let xml = FCPXMLExporter().export(project: project)
        XCTAssertTrue(xml.contains("&lt;tag&gt;"))
        XCTAssertTrue(xml.contains("&amp;"))
        XCTAssertFalse(xml.contains("<tag>"))
        XCTAssertNoThrow(try XMLDocument(xmlString: xml))
    }

    func testEmptyProjectStillEmitsValidXML() throws {
        let project = Project(name: "Empty")
        let xml = FCPXMLExporter().export(project: project)
        XCTAssertNoThrow(try XMLDocument(xmlString: xml))
        XCTAssertTrue(xml.contains("<event name=\"Empty\">"))
    }
}
