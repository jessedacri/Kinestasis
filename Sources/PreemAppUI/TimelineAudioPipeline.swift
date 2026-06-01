import Foundation
import AVFoundation
import PreemCore
import PreemMedia
import PolymergeAudio

/// Bridges Preem's timeline data model to Polymerge's
/// `AudioPlaybackEngine`. Owns one engine instance + a transport
/// adapter, builds `TrackBuffer`s on demand from the active sequence's
/// audio clips, and hands them to the engine.
@MainActor
public final class TimelineAudioPipeline {
    public static let sampleRate: Double = 48_000
    public static let channelCount: Int = 2

    private let engine = AudioPlaybackEngine()
    public let transport = EngineTransportAdapter()
    private let loader = ClipAudioLoader(targetSampleRate: TimelineAudioPipeline.sampleRate,
                                         targetChannelCount: TimelineAudioPipeline.channelCount)

    private var isPlaying: Bool = false
    /// Optional sentinel: `nil` = invalidated, must rebuild. A non-nil
    /// value is the signature of the last built buffer set.
    private var lastBuiltSignature: String? = nil

    /// Map from engine TrackBuffer.id → Preem audio track index, so
    /// the UI can pull per-track meter peaks from the engine's
    /// `meters` dictionary (which is keyed by buffer id).
    private var bufferTrackIndex: [UUID: Int] = [:]

    public init() {}

    public var currentAudibleSeconds: Double {
        engine.currentAudibleSeconds()
    }

    public var outputLatencySeconds: Double {
        engine.outputLatencySeconds
    }

    /// Build (or rebuild) the engine's track set from the sequence and
    /// prepare the engine. Call before play. Cheap if `signature(of:)`
    /// hasn't changed and we already have a prepared set.
    public func sync(to sequence: Sequence, mediaPool: MediaPool, startPlayheadSeconds: Double) async {
        let signature = self.signature(of: sequence)
        let initialSample = secondsToSamples(startPlayheadSeconds)

        if signature != lastBuiltSignature {
            let buffers = await buildTrackBuffers(for: sequence, mediaPool: mediaPool)
            let total = secondsToSamples(sequenceDurationSeconds(sequence))
            PreemDebugLog.log("[TimelineAudio] engine.prepare: tracks=\(buffers.count) totalFrames=\(total) (=\(Double(total)/Self.sampleRate)s) initialSample=\(initialSample)")
            transport.setTotalSamples(total)
            transport.playheadSample = initialSample
            engine.prepare(
                tracks: buffers,
                totalFrames: total,
                sampleRate: Self.sampleRate,
                bypassPhaseAlign: true,
                initialPlayheadSample: initialSample
            )
            lastBuiltSignature = signature
        } else {
            // Same edit graph — just sync the start position.
            transport.playheadSample = initialSample
            engine.seek(toSample: initialSample)
        }
    }

    public func play() {
        guard !isPlaying else { return }
        isPlaying = true
        transport.setIsPlaying(true)
        engine.play(transport: transport)
    }

    public func stop() {
        guard isPlaying else { return }
        isPlaying = false
        transport.setIsPlaying(false)
        engine.stop()
    }

    public func teardown() {
        stop()
        engine.teardown()
    }

    /// Force a rebuild on the next sync — e.g. after an edit that
    /// affected the audio track set.
    public func invalidate() {
        lastBuiltSignature = nil
    }

    // MARK: - Build

    private func buildTrackBuffers(for sequence: Sequence, mediaPool: MediaPool) async -> [TrackBuffer] {
        var out: [TrackBuffer] = []
        bufferTrackIndex.removeAll()

        let anySolo = sequence.audioTracks.contains(where: { $0.isSolo })

        for (trackIdx, audioTrack) in sequence.audioTracks.enumerated() {
            // Mute / solo / enabled gating
            if audioTrack.isMuted { continue }
            if anySolo && !audioTrack.isSolo { continue }
            if !audioTrack.isEnabled { continue }

            // Sort so paired-transition lookup can use index ± 1.
            let sorted = audioTrack.clips.sorted {
                $0.timelineRange.start.seconds < $1.timelineRange.start.seconds
            }
            for (i, placed) in sorted.enumerated() {
                guard let source = mediaPool.clips[placed.sourceClipID] else { continue }
                guard !source.audioTracks.isEmpty else { continue }

                // Look for an abutting partner whose own transition pairs
                // with this clip's transition — that's a true cross-fade
                // and the buffers extend into the overlap region so the
                // engine sums them constant-power.
                var pairedExtLeft: Double? = nil
                var pairedExtRight: Double? = nil
                if i > 0 {
                    let prev = sorted[i - 1]
                    if abs(prev.timelineRange.end.seconds - placed.timelineRange.start.seconds) < 0.001,
                       let prevOut = prev.transitionOut, placed.transitionIn != nil {
                        pairedExtLeft = prevOut.duration.seconds
                    }
                }
                if i + 1 < sorted.count {
                    let next = sorted[i + 1]
                    if abs(placed.timelineRange.end.seconds - next.timelineRange.start.seconds) < 0.001,
                       placed.transitionOut != nil, let nextIn = next.transitionIn {
                        pairedExtRight = nextIn.duration.seconds
                    }
                }

                guard let buffer = await buildBuffer(
                    for: placed, source: source,
                    pairedExtLeftSeconds: pairedExtLeft,
                    pairedExtRightSeconds: pairedExtRight
                ) else { continue }
                bufferTrackIndex[buffer.id] = trackIdx
                out.append(buffer)
            }
        }
        return out
    }

    /// Per-track audio level for the level meter UI. Aggregates the
    /// engine's per-buffer peaks for all buffers we associated with the
    /// given Preem audio track index when last building.
    public func peakLevel(forAudioTrackIndex index: Int) -> Float {
        let meters = engine.meters
        var peak: Float = 0
        for (bufferID, trackIdx) in bufferTrackIndex where trackIdx == index {
            if let m = meters[bufferID] {
                peak = max(peak, m.displayPeak)
            }
        }
        return peak
    }

    /// Build one PCM buffer for a placed audio clip.
    ///
    /// `pairedExtLeftSeconds` / `pairedExtRightSeconds` carry the
    /// partner's transition duration when the clip is one half of a
    /// paired cross-fade. The buffer extends into the partner's space
    /// on that side (using source handles when available, silence
    /// otherwise), and the envelope's fade window grows to cover both
    /// halves — so when the engine sums this buffer with the partner's
    /// (sin/cos curves), the result is a constant-power cross-fade
    /// instead of "fade to silence, then fade in."
    private func buildBuffer(
        for placed: PlacedClip,
        source: ClipSource,
        pairedExtLeftSeconds: Double?,
        pairedExtRightSeconds: Double?
    ) async -> TrackBuffer? {
        let extLeftSec = pairedExtLeftSeconds ?? 0
        let extRightSec = pairedExtRightSeconds ?? 0

        // Buffer length covers the clip's timeline span PLUS the
        // paired extensions on either side. The buffer's timeline
        // start sits at (placed.timelineRange.start - extLeftSec) so
        // the pre-cut dissolve region overlaps with the outgoing
        // clip's tail. The buffer reads source starting at the clip's
        // in-point (extensions just shift the timeline placement, not
        // the source read). Out-of-range source frames fill silence.
        let inFrame = secondsToFrames(placed.sourceRange.start.seconds)
        let sliceLength = secondsToFrames(placed.timelineRange.duration.seconds + extLeftSec + extRightSec)
        guard sliceLength > 0 else { return nil }

        // Decode ONLY this clip's span (zero-padded). For MXF this reads
        // just the covering packets — a trimmed clip from a long source
        // costs ms, not a whole-track decode.
        var rawChannels: [[Float]]
        do {
            rawChannels = try await loader.loadRange(
                clipID: source.id, url: source.url,
                startFrame: inFrame, frameCount: sliceLength
            )
        } catch {
            PreemDebugLog.log("[TimelineAudio] decode failed for \(source.name): \(error)")
            return nil
        }
        guard let firstCh = rawChannels.first, !firstCh.isEmpty else { return nil }
        let channelCount = rawChannels.count

        PreemDebugLog.log("[TimelineAudio] \(source.name): srcStart=\(inFrame) len=\(sliceLength) ch=\(channelCount) timeline=[\(placed.timelineRange.start.seconds - extLeftSec), \(placed.timelineRange.end.seconds + extRightSec))")

        // Compute the fade-in / fade-out windows in samples.
        //   - Paired side: window = own half + partner half (so the cos
        //     and sin curves cover the full overlap, summing constant
        //     power).
        //   - Solo side: window = just own duration.
        let ownIn = placed.transitionIn?.duration.seconds ?? 0
        let ownOut = placed.transitionOut?.duration.seconds ?? 0
        let fadeInWindow = (pairedExtLeftSeconds ?? 0) + ownIn
        let fadeOutWindow = ownOut + (pairedExtRightSeconds ?? 0)

        applyFadeEnvelope(
            channels: &rawChannels,
            fadeInSamples: secondsToFrames(fadeInWindow),
            fadeOutSamples: secondsToFrames(fadeOutWindow)
        )

        // Timeline position shifts left by the left extension so the
        // buffer's first sample lands at the dissolve's start, not at
        // the clip's natural in-point.
        let timelineStartSec = placed.timelineRange.start.seconds - extLeftSec
        let timelineStartSample = secondsToSamples(timelineStartSec)

        return TrackBuffer(
            id: UUID(),
            length: sliceLength,
            channelCount: channelCount,
            fileOffsetSamples: timelineStartSample,
            rawChannels: rawChannels,
            processedChannels: nil,
            phaseDelayInt: 0,
            usedCorrectedSource: false,
            panLeft: 1.0,
            panRight: 1.0
        )
    }

    // MARK: - Helpers

    /// Constant-power fade envelope (sin/cos curves). For complementary
    /// fade-out + fade-in pairs (paired audio dissolves), sin² + cos²
    /// = 1 → perceived loudness stays roughly constant across the
    /// dissolve, instead of the audible dip a linear ramp creates.
    /// For solo fades the curve sounds gentler than linear too.
    private func applyFadeEnvelope(channels: inout [[Float]], fadeInSamples: Int, fadeOutSamples: Int) {
        guard fadeInSamples > 0 || fadeOutSamples > 0 else { return }
        let halfPi: Float = .pi / 2
        for ch in channels.indices {
            let length = channels[ch].count
            if fadeInSamples > 0 {
                let n = min(fadeInSamples, length)
                if n > 1 {
                    let denom = Float(n - 1)
                    for i in 0..<n {
                        let p = Float(i) / denom
                        channels[ch][i] *= sin(p * halfPi)
                    }
                } else {
                    channels[ch][0] = 0
                }
            }
            if fadeOutSamples > 0 {
                let n = min(fadeOutSamples, length)
                if n > 1 {
                    let start = length - n
                    let denom = Float(n - 1)
                    for i in 0..<n {
                        let p = Float(i) / denom
                        channels[ch][start + i] *= cos(p * halfPi)
                    }
                } else {
                    channels[ch][length - 1] = 0
                }
            }
        }
    }

    private func secondsToSamples(_ seconds: Double) -> Int64 {
        Int64(seconds * Self.sampleRate)
    }

    private func secondsToFrames(_ seconds: Double) -> Int {
        Int(seconds * Self.sampleRate)
    }

    private func sequenceDurationSeconds(_ sequence: Sequence) -> Double {
        let all = sequence.videoTracks.flatMap(\.clips) + sequence.audioTracks.flatMap(\.clips)
        return all.map { $0.timelineRange.end.seconds }.max() ?? 0
    }

    /// A stable string fingerprint of every audio clip's
    /// (sourceClipID, sourceRange, timelineRange). Used to skip rebuilds
    /// when nothing audio-relevant changed.
    private func signature(of sequence: Sequence) -> String {
        var parts: [String] = []
        for track in sequence.audioTracks {
            for placed in track.clips {
                let fadeIn = placed.transitionIn?.duration.seconds ?? 0
                let fadeOut = placed.transitionOut?.duration.seconds ?? 0
                parts.append("\(placed.sourceClipID.rawValue.uuidString):\(placed.sourceRange.start.seconds):\(placed.sourceRange.end.seconds):\(placed.timelineRange.start.seconds):\(fadeIn):\(fadeOut)")
            }
        }
        return parts.joined(separator: "|")
    }
}

/// A small `EnginePlaybackTransport` implementation that can be safely
/// mutated from `@MainActor` and read from the audio render thread.
public final class EngineTransportAdapter: EnginePlaybackTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _playheadSample: Int64 = 0
    private var _isPlaying: Bool = false
    private var _shuttleSpeed: Double = 1.0
    private var _totalSamples: UInt64 = 0

    public var playheadSample: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return _playheadSample }
        set { lock.lock(); _playheadSample = newValue; lock.unlock() }
    }

    public var totalSamples: UInt64 {
        get { lock.lock(); defer { lock.unlock() }; return _totalSamples }
    }

    public var shuttleSpeed: Double {
        get { lock.lock(); defer { lock.unlock() }; return _shuttleSpeed }
    }

    public var isPlaying: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isPlaying }
    }

    public func stop() {
        lock.lock(); _isPlaying = false; lock.unlock()
    }

    public func setIsPlaying(_ value: Bool) {
        lock.lock(); _isPlaying = value; lock.unlock()
    }

    public func setTotalSamples(_ value: Int64) {
        lock.lock(); _totalSamples = UInt64(max(0, value)); lock.unlock()
    }

    public func setShuttleSpeed(_ value: Double) {
        lock.lock(); _shuttleSpeed = value; lock.unlock()
    }
}
