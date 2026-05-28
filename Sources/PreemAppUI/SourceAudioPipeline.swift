import Foundation
import AVFoundation
import PreemCore
import PreemMedia
import PolymergeAudio

/// Audio pipeline scoped to the SOURCE viewer — plays a single clip's
/// audio while the user previews it before edits. Mirrors
/// `TimelineAudioPipeline` but the engine is loaded with one buffer
/// (the whole source clip) instead of a sequence's per-track set.
///
/// Mutex with the timeline engine is enforced upstream by
/// `WorkspaceModel.PlaybackState`: only `.program` OR `.source` is
/// active at a time, never both. `tearDownCurrentPlayback` stops
/// whichever pipeline is running before starting the other.
@MainActor
public final class SourceAudioPipeline {
    public static let sampleRate: Double = 48_000
    public static let channelCount: Int = 2

    private let engine = AudioPlaybackEngine()
    public let transport = EngineTransportAdapter()
    private let loader = ClipAudioLoader(
        targetSampleRate: SourceAudioPipeline.sampleRate,
        targetChannelCount: SourceAudioPipeline.channelCount
    )

    /// Identity of the clip currently prepared on the engine. nil means
    /// the engine has nothing loaded (or was invalidated). Used to skip
    /// rebuild when re-syncing the same clip after a seek.
    private var preparedClipID: ClipID?
    private var preparedTotalFrames: Int64 = 0

    public init() {}

    public var currentAudibleSeconds: Double {
        engine.currentAudibleSeconds()
    }

    public var outputLatencySeconds: Double {
        engine.outputLatencySeconds
    }

    /// Build (or reuse) the buffer for `clip` and seek to
    /// `startSeconds`. Cheap if the same clip is already prepared —
    /// just seeks. Call before `play()`.
    public func sync(to clip: ClipSource, startSeconds: Double) async {
        let initialSample = secondsToSamples(startSeconds)

        if preparedClipID != clip.id {
            guard let buffer = await buildBuffer(for: clip) else {
                preparedClipID = nil
                return
            }
            let total = secondsToSamples(clip.duration.seconds)
            preparedTotalFrames = total
            transport.setTotalSamples(total)
            transport.playheadSample = initialSample
            engine.prepare(
                tracks: [buffer],
                totalFrames: total,
                sampleRate: Self.sampleRate,
                bypassPhaseAlign: true,
                initialPlayheadSample: initialSample
            )
            preparedClipID = clip.id
        } else {
            transport.playheadSample = initialSample
            engine.seek(toSample: initialSample)
        }
    }

    public func play() {
        transport.setIsPlaying(true)
        engine.play(transport: transport)
    }

    public func stop() {
        transport.setIsPlaying(false)
        engine.stop()
    }

    public func teardown() {
        stop()
        engine.teardown()
    }

    /// Force the buffer to be rebuilt on next `sync` — call when the
    /// source clip's audio is no longer valid (clip removed, project
    /// closed, etc.).
    public func invalidate() {
        preparedClipID = nil
    }

    // MARK: - Helpers

    private func buildBuffer(for clip: ClipSource) async -> TrackBuffer? {
        guard !clip.audioTracks.isEmpty else { return nil }
        let decoded: ClipAudioLoader.DecodedAudio
        do {
            decoded = try await loader.load(clipID: clip.id, url: clip.url)
        } catch {
            PreemDebugLog.log("[SourceAudio] decode failed for \(clip.name): \(error)")
            return nil
        }
        guard decoded.channels.count >= 1 else { return nil }
        let totalFrames = decoded.channels[0].count
        return TrackBuffer(
            id: UUID(),
            length: totalFrames,
            channelCount: decoded.channels.count,
            fileOffsetSamples: 0,
            rawChannels: decoded.channels,
            processedChannels: nil,
            phaseDelayInt: 0,
            usedCorrectedSource: false,
            panLeft: 1.0,
            panRight: 1.0
        )
    }

    private func secondsToSamples(_ seconds: Double) -> Int64 {
        Int64(seconds * Self.sampleRate)
    }
}
