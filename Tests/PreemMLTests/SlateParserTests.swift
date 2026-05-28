import XCTest
@testable import PreemML
import CoreGraphics
import PreemCore

final class SlateParserTests: XCTestCase {

    private func obs(_ text: String, _ confidence: Float = 0.9) -> SlateParser.Observation {
        SlateParser.Observation(text: text, confidence: confidence, boundingBox: .init(x: 0, y: 0, width: 1, height: 1))
    }

    func testLabeledFullSlate() {
        let result = SlateParser.parse([
            obs("Scene 12B"),
            obs("Take 4"),
            obs("Roll 03"),
            obs("PRODUCTION: Test Shoot"),
        ])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.scene, "12B")
        XCTAssertEqual(result?.take, "4")
        XCTAssertEqual(result?.roll, "03")
    }

    func testAbbreviatedLabels() {
        let result = SlateParser.parse([
            obs("Sc. 7"),
            obs("TK 2"),
            obs("Roll A4"),
        ])
        XCTAssertEqual(result?.scene, "7")
        XCTAssertEqual(result?.take, "2")
        XCTAssertEqual(result?.roll, "A4")
    }

    func testShortLetterCooccurrence() {
        let result = SlateParser.parse([
            obs("S 12"),
            obs("T 3"),
            obs("R 02"),
        ])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.scene, "12")
        XCTAssertEqual(result?.take, "3")
        XCTAssertEqual(result?.roll, "02")
    }

    func testShortLettersAloneRejected() {
        let result = SlateParser.parse([
            obs("S 12"),
        ])
        XCTAssertNil(result, "Single short letter should not match without co-occurrence")
    }

    func testTakeOnlyFallback() {
        let result = SlateParser.parse([
            obs("Take 7"),
            obs("misc text"),
        ])
        XCTAssertEqual(result?.take, "7")
        XCTAssertNil(result?.scene)
        XCTAssertNil(result?.roll)
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(SlateParser.parse([]))
    }

    func testNoMatchingPatternReturnsNil() {
        let result = SlateParser.parse([
            obs("random words"),
            obs("hello world"),
        ])
        XCTAssertNil(result)
    }

    func testCaseInsensitive() {
        let result = SlateParser.parse([
            obs("scene 5a"),
            obs("take 1"),
        ])
        XCTAssertEqual(result?.scene, "5A")
        XCTAssertEqual(result?.take, "1")
    }

    func testFilledFieldsBeatsTakeOnly() {
        // A confident take-only parse must lose to a labeled full match
        // when both are findable in the same corpus.
        let result = SlateParser.parse([
            obs("Scene 1"),
            obs("Take 2"),
            obs("Roll 3"),
        ])
        XCTAssertEqual(result?.scene, "1")
        XCTAssertEqual(result?.take, "2")
        XCTAssertEqual(result?.roll, "3")
    }
}
