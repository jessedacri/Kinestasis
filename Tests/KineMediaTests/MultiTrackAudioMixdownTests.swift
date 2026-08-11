import XCTest
import AVFoundation
import KineCore
@testable import KineMedia

/// Exercises the per-track export mixdown (`OfflineAudioMixdown`) with
/// small synthetic WAV files. PCM decode is deterministic, so the
/// track-selection + channel-mapping logic that drives multi-track audio
/// export can be unit-tested without footage.
final class MultiTrackAudioMixdownTests: XCTestCase {

    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        super.tearDown()
    }

    // MARK: - Fixtures

    private let rate: Double = 48_000
    private let dur: Double = 0.5   // 24k frames

    /// Write a constant-DC float WAV with `channels` channels.
    private func makeWAV(channels: Int, value: Float) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kine-mt-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(dur * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<channels {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(frames) { p[i] = value }
        }
        try file.write(from: buf)
        tempFiles.append(url)
        return url
    }

    private func source(url: URL, channels: Int) -> ClipSource {
        ClipSource(
            url: url, name: url.lastPathComponent,
            format: MediaFormat(container: "wav", audioCodec: "pcm_f32le"),
            duration: RationalTime(seconds: dur),
            audioTracks: [AudioTrackInfo(sampleRate: Int(rate), channelCount: channels, bitDepth: 32)]
        )
    }

    private func clip(_ src: ClipSource) -> PlacedClip {
        PlacedClip(
            sourceClipID: src.id,
            sourceRange: TimeRange(start: RationalTime(seconds: 0), duration: RationalTime(seconds: dur)),
            timelineRange: TimeRange(start: RationalTime(seconds: 0), duration: RationalTime(seconds: dur))
        )
    }

    /// A1 = stereo clip @ 0.5, A2 = mono clip @ 0.25.
    private func makeFixture(muteA2: Bool = false) throws -> (Sequence, MediaPool) {
        let stereo = source(url: try makeWAV(channels: 2, value: 0.5), channels: 2)
        let mono = source(url: try makeWAV(channels: 1, value: 0.25), channels: 1)
        let pool = MediaPool(clips: [stereo.id: stereo, mono.id: mono])
        let a1 = AudioTrack(name: "A1", clips: [clip(stereo)])
        let a2 = AudioTrack(name: "A2", isMuted: muteA2, clips: [clip(mono)])
        let seq = Sequence(
            name: "T",
            settings: SequenceSettings(frameRate: .twentyFour, resolution: PixelSize(width: 1920, height: 1080)),
            videoTracks: [], audioTracks: [a1, a2]
        )
        return (seq, pool)
    }

    private func mixer(_ seq: Sequence, _ pool: MediaPool) -> OfflineAudioMixdown {
        OfflineAudioMixdown(sequence: seq, mediaPool: pool, sampleRate: rate, channelCount: 2)
    }

    // MARK: - Tests

    func testMixdownSumsAllTracks() async throws {
        let (seq, pool) = try makeFixture()
        let out = await mixer(seq, pool).render(startSeconds: 0, endSeconds: dur)
        XCTAssertEqual(out.count, 2)                       // stereo
        // ch0 = stereo(0.5) + mono→both(0.25) = 0.75
        XCTAssertEqual(out[0][1000], 0.75, accuracy: 0.02)
        XCTAssertEqual(out[1][1000], 0.75, accuracy: 0.02)
    }

    func testPerTrackEmitsOneBufferPerAudibleTrack() async throws {
        let (seq, pool) = try makeFixture()
        let mixes = await mixer(seq, pool).renderPerTrack(
            startSeconds: 0, endSeconds: dur, preserveSourceChannels: false
        )
        XCTAssertEqual(mixes.count, 2)
        XCTAssertEqual(mixes.map(\.label), ["A1", "A2"])
        // Each downmixed to the export channel count (stereo).
        XCTAssertTrue(mixes.allSatisfy { $0.channelCount == 2 })
        XCTAssertEqual(mixes[0].channels[0][1000], 0.5, accuracy: 0.02)
        // Mono source maps onto both output channels.
        XCTAssertEqual(mixes[1].channels[0][1000], 0.25, accuracy: 0.02)
        XCTAssertEqual(mixes[1].channels[1][1000], 0.25, accuracy: 0.02)
    }

    func testMutedTrackSkipped() async throws {
        let (seq, pool) = try makeFixture(muteA2: true)
        let mixes = await mixer(seq, pool).renderPerTrack(
            startSeconds: 0, endSeconds: dur, preserveSourceChannels: false
        )
        XCTAssertEqual(mixes.count, 1)
        XCTAssertEqual(mixes[0].label, "A1")
    }

    func testPreserveChannelsKeepsSourceLayout() async throws {
        let (seq, pool) = try makeFixture()
        let mixes = await mixer(seq, pool).renderPerTrack(
            startSeconds: 0, endSeconds: dur, preserveSourceChannels: true
        )
        XCTAssertEqual(mixes.count, 2)
        XCTAssertEqual(mixes[0].channelCount, 2)           // stereo source stays stereo
        XCTAssertEqual(mixes[1].channelCount, 1)           // mono source stays mono
        XCTAssertEqual(mixes[1].channels[0][1000], 0.25, accuracy: 0.02)
    }
}
