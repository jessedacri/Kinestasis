import Foundation
import KineCore

/// Offline (non-realtime) audio mixdown for a `Sequence`. Mirrors the
/// realtime `TimelineAudioPipeline` mixing rules — mute / solo gating,
/// paired-cross-fade buffer extensions, sin/cos fade envelopes — but
/// produces a single non-interleaved float buffer instead of feeding the
/// realtime engine.
///
/// Designed to feed `SequenceEncoder`'s audio input alongside the video
/// frames the offline compositor produces. Same Sequence → same output
/// audio, frame for frame, in both realtime playback and offline render.
public final class OfflineAudioMixdown {

    public static let defaultSampleRate: Double = 48_000
    public static let defaultChannelCount: Int = 2

    public let sampleRate: Double
    public let channelCount: Int
    public let sequence: Sequence
    public let mediaPool: MediaPool

    private let loader: ClipAudioLoader

    public init(
        sequence: Sequence,
        mediaPool: MediaPool,
        sampleRate: Double = OfflineAudioMixdown.defaultSampleRate,
        channelCount: Int = OfflineAudioMixdown.defaultChannelCount
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.sequence = sequence
        self.mediaPool = mediaPool
        self.loader = ClipAudioLoader(
            targetSampleRate: sampleRate,
            targetChannelCount: channelCount
        )
    }

    /// One output audio track's mixed buffer plus the label/channel count
    /// it should be written with. Returned by `renderPerTrack`.
    public struct TrackMix: Sendable {
        public let channels: [[Float]]   // [channel][frame]
        public let channelCount: Int
        public let label: String         // e.g. "A1"
        public init(channels: [[Float]], channelCount: Int, label: String) {
            self.channels = channels; self.channelCount = channelCount; self.label = label
        }
    }

    /// Render `[startSeconds, endSeconds)` of the sequence audio to a
    /// single non-interleaved float buffer (`channels[ch][frame]`),
    /// summing every audible timeline track. All clips that overlap the
    /// range contribute; clips outside it are skipped.
    public func render(startSeconds: Double, endSeconds: Double) async -> [[Float]] {
        let frameCount = max(0, Int((endSeconds - startSeconds) * sampleRate))
        guard frameCount > 0 else {
            return Array(repeating: [Float](), count: channelCount)
        }
        var output: [[Float]] = Array(
            repeating: [Float](repeating: 0, count: frameCount),
            count: channelCount
        )

        let anySolo = sequence.audioTracks.contains(where: { $0.isSolo })
        for track in sequence.audioTracks where isAudible(track, anySolo: anySolo) {
            await mixTrack(
                track, into: &output, outChannelCount: channelCount,
                startSeconds: startSeconds, frameCount: frameCount,
                preserveSourceChannels: false
            )
        }
        return output
    }

    /// Render one mixed buffer per audible timeline audio track (instead
    /// of summing them). Empty / fully-inaudible tracks are skipped.
    ///
    /// - `preserveSourceChannels`: when true each output track keeps its
    ///   clips' native channel count (the widest among its clips); when
    ///   false each track is downmixed to `channelCount`.
    public func renderPerTrack(
        startSeconds: Double, endSeconds: Double,
        preserveSourceChannels: Bool
    ) async -> [TrackMix] {
        let frameCount = max(0, Int((endSeconds - startSeconds) * sampleRate))
        guard frameCount > 0 else { return [] }

        let anySolo = sequence.audioTracks.contains(where: { $0.isSolo })
        var mixes: [TrackMix] = []
        for (idx, track) in sequence.audioTracks.enumerated() {
            guard isAudible(track, anySolo: anySolo) else { continue }
            // Skip tracks with no usable audio clips entirely.
            let hasAudio = track.clips.contains { placed in
                guard let s = mediaPool.clips[placed.sourceClipID] else { return false }
                return !s.audioTracks.isEmpty
            }
            guard hasAudio else { continue }

            let outCh = preserveSourceChannels ? sourceChannelCount(for: track) : channelCount
            var output: [[Float]] = Array(
                repeating: [Float](repeating: 0, count: frameCount),
                count: outCh
            )
            await mixTrack(
                track, into: &output, outChannelCount: outCh,
                startSeconds: startSeconds, frameCount: frameCount,
                preserveSourceChannels: preserveSourceChannels
            )
            let label = track.name.isEmpty ? "A\(idx + 1)" : track.name
            mixes.append(TrackMix(channels: output, channelCount: outCh, label: label))
        }
        return mixes
    }

    // MARK: - Per-track mixing

    private func isAudible(_ track: AudioTrack, anySolo: Bool) -> Bool {
        if track.isMuted { return false }
        if anySolo && !track.isSolo { return false }
        if !track.isEnabled { return false }
        return true
    }

    /// Widest native source channel count among a track's clips (for the
    /// preserve-channels layout). Defaults to 1 if nothing is placed.
    private func sourceChannelCount(for track: AudioTrack) -> Int {
        var maxCh = 1
        for placed in track.clips {
            guard let s = mediaPool.clips[placed.sourceClipID] else { continue }
            let c = s.audioTracks.reduce(0) { $0 + $1.channelCount }
            if c > maxCh { maxCh = c }
        }
        return max(1, maxCh)
    }

    /// Mix one timeline audio track's clips into `output` (pre-sized to
    /// `outChannelCount`), applying the same paired-cross-fade extensions
    /// and constant-power envelopes as `TimelineAudioPipeline`.
    private func mixTrack(
        _ track: AudioTrack,
        into output: inout [[Float]],
        outChannelCount: Int,
        startSeconds: Double,
        frameCount: Int,
        preserveSourceChannels: Bool
    ) async {
        let sorted = track.clips.sorted {
            $0.timelineRange.start.seconds < $1.timelineRange.start.seconds
        }

        for (i, placed) in sorted.enumerated() {
            guard let source = mediaPool.clips[placed.sourceClipID] else { continue }
            guard !source.audioTracks.isEmpty else { continue }

            // Paired-extension lookup — same rules as TimelineAudioPipeline.
            var extLeft: Double = 0
            var extRight: Double = 0
            if i > 0 {
                let prev = sorted[i - 1]
                if abs(prev.timelineRange.end.seconds - placed.timelineRange.start.seconds) < 0.001,
                   let prevOut = prev.transitionOut, placed.transitionIn != nil {
                    extLeft = prevOut.duration.seconds
                }
            }
            if i + 1 < sorted.count {
                let next = sorted[i + 1]
                if abs(placed.timelineRange.end.seconds - next.timelineRange.start.seconds) < 0.001,
                   placed.transitionOut != nil, let nextIn = next.transitionIn {
                    extRight = nextIn.duration.seconds
                }
            }

            let clipTimelineStart = placed.timelineRange.start.seconds - extLeft
            let clipTimelineEnd   = placed.timelineRange.end.seconds + extRight
            // The output range is [startSeconds, startSeconds + frameCount/rate).
            let endSeconds = startSeconds + Double(frameCount) / sampleRate
            if clipTimelineEnd <= startSeconds || clipTimelineStart >= endSeconds { continue }

            let decoded: ClipAudioLoader.DecodedAudio
            do {
                decoded = preserveSourceChannels
                    ? try await loader.loadNative(clipID: source.id, url: source.url)
                    : try await loader.load(clipID: source.id, url: source.url)
            } catch {
                KineDebugLog.log("[OfflineAudio] decode failed for \(source.name): \(error)")
                continue
            }
            guard !decoded.channels.isEmpty else { continue }

            let bufferLength = max(0, Int((placed.timelineRange.duration.seconds + extLeft + extRight) * sampleRate))
            guard bufferLength > 0 else { continue }

            let sourceFrameIn = Int(placed.sourceRange.start.seconds * sampleRate)
            let totalSourceFrames = decoded.channels[0].count
            let srcChannelCount = decoded.channels.count

            // Build the clip's per-channel buffer aligned to its
            // (extended) timeline start. Reads from the clip's source
            // in-point forward — paired LEFT extensions use source frames
            // at-the-in-point onward (matching TimelineAudioPipeline).
            var bufChannels: [[Float]] = []
            bufChannels.reserveCapacity(srcChannelCount)
            for ch in 0..<srcChannelCount {
                var slice = [Float](repeating: 0, count: bufferLength)
                let srcArray = decoded.channels[ch]
                for j in 0..<bufferLength {
                    let srcIdx = sourceFrameIn + j
                    if srcIdx >= 0, srcIdx < totalSourceFrames {
                        slice[j] = srcArray[srcIdx]
                    }
                }
                bufChannels.append(slice)
            }

            // Fade envelope. Paired side: own half + partner half so the
            // curves cover the full overlap; solo side: own only.
            let ownIn = placed.transitionIn?.duration.seconds ?? 0
            let ownOut = placed.transitionOut?.duration.seconds ?? 0
            let fadeInWindow = extLeft + ownIn
            let fadeOutWindow = ownOut + extRight
            applyFadeEnvelope(
                channels: &bufChannels,
                fadeInSamples: Int(fadeInWindow * sampleRate),
                fadeOutSamples: Int(fadeOutWindow * sampleRate)
            )

            // Sum into the output buffer at the clip's offset.
            let dstStartFrame = Int((clipTimelineStart - startSeconds) * sampleRate)
            for outCh in 0..<outChannelCount {
                let srcCh: Int
                if preserveSourceChannels {
                    // Discrete preservation: source channel i → output
                    // channel i. Output channels beyond this clip's
                    // channel count get nothing from it.
                    if outCh >= srcChannelCount { continue }
                    srcCh = outCh
                } else if srcChannelCount == 1 {
                    srcCh = 0              // mono → all output channels
                } else if outCh < srcChannelCount {
                    srcCh = outCh          // direct map for stereo+
                } else {
                    srcCh = srcChannelCount - 1
                }
                let src = bufChannels[srcCh]
                let srcLen = src.count
                for j in 0..<srcLen {
                    let dstIdx = dstStartFrame + j
                    if dstIdx < 0 || dstIdx >= frameCount { continue }
                    output[outCh][dstIdx] += src[j]
                }
            }
        }
    }

    // MARK: - Constant-power fade envelope (matches TimelineAudioPipeline)

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
}
