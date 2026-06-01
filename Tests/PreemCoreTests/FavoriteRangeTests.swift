import XCTest
@testable import PreemCore

final class FavoriteRangeTests: XCTestCase {

    private func sampleClip(favorites: [FavoriteRange] = []) -> ClipSource {
        ClipSource(
            url: URL(fileURLWithPath: "/tmp/shot.mov"),
            name: "shot.mov",
            format: MediaFormat(container: "mov", videoCodec: "prores"),
            duration: RationalTime(seconds: 12, scale: 600),
            videoTracks: [VideoTrackInfo(
                resolution: PixelSize(width: 1920, height: 1080),
                frameRate: .twentyFour,
                pixelFormat: "yuv420p",
                colorSpace: .rec709
            )],
            favorites: favorites
        )
    }

    func testSecondsInitRoundsToScale() {
        let t = RationalTime(seconds: 2.5, scale: 600)
        XCTAssertEqual(t.seconds, 2.5, accuracy: 1e-9)
        XCTAssertEqual(t.value, 1500)
    }

    func testFavoritesRoundTrip() throws {
        let fav = FavoriteRange(
            range: TimeRange(start: RationalTime(seconds: 1, scale: 600),
                             duration: RationalTime(seconds: 3, scale: 600)),
            name: "Favorite 1"
        )
        let clip = sampleClip(favorites: [fav])
        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(ClipSource.self, from: data)
        XCTAssertEqual(decoded.favorites.count, 1)
        XCTAssertEqual(decoded.favorites.first?.name, "Favorite 1")
        XCTAssertEqual(decoded.favorites.first?.range.duration.seconds ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(decoded.favorites.first?.rating, .favorite)
    }

    // A project saved before favorites existed has no `favorites` key.
    func testBackCompatMissingFavoritesDecodesEmpty() throws {
        let clip = sampleClip()
        let data = try JSONEncoder().encode(clip)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "favorites")
        XCTAssertNil(obj["favorites"])
        let legacy = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(ClipSource.self, from: legacy)
        XCTAssertEqual(decoded.favorites, [])
        XCTAssertEqual(decoded.name, "shot.mov")
    }
}
