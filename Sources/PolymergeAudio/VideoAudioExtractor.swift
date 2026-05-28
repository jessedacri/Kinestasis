import AVFoundation
import Accelerate
import PolymergeMediaModel
import PolymergeIngest

/// Aggregates per-track progress across a parallel-decode
/// TaskGroup so the caller gets a single monotonically-
/// increasing progress fraction without jitter. Each task
/// reports its own fraction (0...1); the aggregator averages
/// them so the overall bar advances smoothly as all tracks
/// decode in parallel.
///
/// `Sendable` final class + NSLock so the non-isolated callers
/// from concurrent TaskGroup tasks can bump their slot safely.
/// A more idiomatic option would be an `actor` but calls into
/// the `onProgress` closure from an actor require the callers
/// to await, and the decode inner loop doesn't naturally sit
/// inside an async context.
final class ExtractionProgressAggregator: @unchecked Sendable {
    private let lock = NSLock()
    private var perTrack: [Double]

    init(trackCount: Int) {
        self.perTrack = Array(repeating: 0, count: max(1, trackCount))
    }

    /// Update one track's fraction and return the aggregate
    /// (mean across all tracks) so the caller can emit an
    /// overall progress value. Clamped to `[0, 1]`.
    func reportTrackProgress(trackIndex: Int, trackFraction: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let clamped = min(1.0, max(0.0, trackFraction))
        if trackIndex >= 0 && trackIndex < perTrack.count {
            if clamped > perTrack[trackIndex] {
                perTrack[trackIndex] = clamped
            }
        }
        let sum = perTrack.reduce(0, +)
        return sum / Double(perTrack.count)
    }
}

/// Extracts the audio track of a video file (MOV / MP4 / M4V / MXF)
/// into per-channel `[Float]` arrays at a target sample rate.
///
/// **Why this exists**: Stage 4 of the video file roadmap is TC-less
/// audio-to-video sync. For cameras that don't stamp TC into their
/// files (phones, GoPros, drones, consumer cameras, action cams), we
/// recover the start TC by cross-correlating the camera's guide
/// audio against the bin's reference audio file — the same envelope
/// approach `WaveformTCInferrer` already uses for audio-only TC
/// recovery. The only new piece is getting the audio OUT of the
/// video container, which is what this extractor does.
///
/// **Implementation**: `AVAssetReader` + `AVAssetReaderTrackOutput`
/// configured for 32-bit float interleaved PCM at the target rate.
/// `AVSampleRateKey` in the output settings lets us tell AVFoundation
/// to resample on-the-fly so the caller doesn't have to run a
/// separate SRC pass — VideoToolbox / AudioConverter handle it
/// transparently. Output is de-interleaved into `[[Float]]` (one
/// array per channel) to match the format `WaveformTCInferrer` and
/// `TrackBufferBuilder` already work with.
///
/// **AVAssetReader vs TMCD**: unlike pitfall #51 (where AVAssetReader
/// returns empty buffers for QuickTime timecode tracks), the audio
/// path is the standard documented use of AVAssetReader and works
/// reliably for every codec AVFoundation supports — AAC, ALAC,
/// LinearPCM in MOV/MP4/MXF, etc.
///
/// **Async**: uses the modern `AVAsset.loadTracks(withMediaType:)`
/// API which is the post-iOS 16 / macOS 13 way. The synchronous
/// `asset.tracks(withMediaType:)` is deprecated.
public struct VideoAudioExtractor {
    public enum ExtractionError: LocalizedError {
        case noAudioTrack
        case readerSetupFailed(String)
        case readFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                return "Video file has no audio track to sync against"
            case .readerSetupFailed(let msg):
                return "Could not set up audio reader: \(msg)"
            case .readFailed(let msg):
                return "Failed to read audio: \(msg)"
            }
        }
    }

    /// Result of an extraction.
    public struct Result {
        /// Per-channel audio at the target sample rate. The first
        /// `Int(channelCount)` arrays are valid; channel order
        /// matches the source's track layout (typically L, R, then
        /// any extra channels for surround / multi-mic).
        public let channels: [[Float]]
        /// Number of channels actually extracted.
        public let channelCount: Int
        /// Sample rate of the extracted data (== `targetSampleRate`
        /// the caller passed in, since AVAssetReader resamples on
        /// the fly).
        public let sampleRate: Int

        public init(channels: [[Float]], channelCount: Int, sampleRate: Int) {
            self.channels = channels
            self.channelCount = channelCount
            self.sampleRate = sampleRate
        }
    }

    /// Extract the first audio track from a video file. Resamples
    /// to `targetSampleRate` on the fly via AVAssetReader's built-in
    /// AudioConverter. Returns per-channel `[Float]` arrays.
    ///
    /// - Parameters:
    ///   - url: file URL of the video container
    ///   - targetSampleRate: desired output sample rate. The reader
    ///     will resample as needed.
    public static func extract(url: URL, targetSampleRate: Int) async throws -> Result {
        let asset = AVURLAsset(url: url)

        // Find the first audio track. Modern async API — the
        // synchronous `asset.tracks(withMediaType:)` is deprecated
        // as of macOS 13.
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ExtractionError.readerSetupFailed(error.localizedDescription)
        }
        guard let audioTrack = audioTracks.first else {
            throw ExtractionError.noAudioTrack
        }

        // Build the reader with PCM Float output settings. Setting
        // AVSampleRateKey here tells AVFoundation to resample on
        // the fly via AudioConverter — saves us a separate SRC
        // pass downstream.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ExtractionError.readerSetupFailed(error.localizedDescription)
        }

        let trackOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: outputSettings
        )
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            throw ExtractionError.readerSetupFailed("Reader rejected the track output")
        }
        reader.add(trackOutput)

        guard reader.startReading() else {
            let msg = reader.error?.localizedDescription ?? "Unknown reader error"
            throw ExtractionError.readFailed(msg)
        }

        // Pull sample buffers and accumulate the interleaved float
        // data. We need the channel count from the first buffer's
        // format description before we can de-interleave, so we
        // collect everything into a single flat buffer first and
        // de-interleave at the end.
        var interleaved: [Float] = []
        interleaved.reserveCapacity(targetSampleRate * 60 * 2)  // ~1 min stereo
        var channelCount = 0

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            // Pull channel count from the first buffer (it doesn't
            // change across buffers within a single track).
            if channelCount == 0,
               let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                channelCount = Int(asbd.pointee.mChannelsPerFrame)
            }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let dataPointer else {
                continue
            }

            // Reinterpret the byte buffer as Float samples.
            let sampleCount = totalLength / MemoryLayout<Float>.size
            dataPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { floatPtr in
                let buf = UnsafeBufferPointer(start: floatPtr, count: sampleCount)
                interleaved.append(contentsOf: buf)
            }
        }

        if reader.status == .failed {
            let msg = reader.error?.localizedDescription ?? "Reader failed mid-read"
            throw ExtractionError.readFailed(msg)
        }

        guard channelCount > 0 else {
            throw ExtractionError.readFailed("Could not determine channel count from any sample buffer")
        }
        guard !interleaved.isEmpty else {
            throw ExtractionError.readFailed("No audio samples returned")
        }

        // De-interleave LRLRLR... into [[L], [R]].
        let frameCount = interleaved.count / channelCount
        var channels = [[Float]](repeating: [], count: channelCount)
        for c in 0..<channelCount {
            channels[c].reserveCapacity(frameCount)
        }
        interleaved.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for frame in 0..<frameCount {
                let frameStart = base + frame * channelCount
                for c in 0..<channelCount {
                    channels[c].append(frameStart[c])
                }
            }
        }

        return Result(
            channels: channels,
            channelCount: channelCount,
            sampleRate: targetSampleRate
        )
    }

    /// Result of `extractAndWriteWAV`. The caller feeds
    /// `outputURL` into `AudioFile.parse(url:...)` to get a full-
    /// featured AudioFile tied to the extracted audio.
    public struct WriteResult {
        public let outputURL: URL
        public let channelCount: Int
        public let sampleRate: Int
        public let totalSamples: UInt64

        public init(outputURL: URL, channelCount: Int, sampleRate: Int, totalSamples: UInt64) {
            self.outputURL = outputURL
            self.channelCount = channelCount
            self.sampleRate = sampleRate
            self.totalSamples = totalSamples
        }
    }

    /// Progress callback for `extractAndWriteWAV`. Stage names are
    /// user-facing so the UI can display them verbatim.
    public typealias WriteProgressCallback = @Sendable (_ stage: String, _ fraction: Double) -> Void

    /// Extract the first audio track from a video file and write
    /// the result to disk as a 24-bit PCM WAV. Used by the camera-
    /// audio-inclusion flow: when the user flips a video to
    /// `.reference` or `.production`, we extract its embedded audio
    /// to a sibling WAV that then lives in the session as a first-
    /// class AudioFile (with CHANNELS panel, sync ref candidacy,
    /// merger participation, timeline waveform, everything).
    ///
    /// Resamples on the fly to the video's NATIVE sample rate
    /// (no downstream SRC work), produces 24-bit PCM to match the
    /// production-audio convention, de-interleaved to per-channel
    /// arrays before writing (matches `AudioFile.parse`'s
    /// expectation).
    ///
    /// - Parameters:
    ///   - url: Source video file URL.
    ///   - outputURL: Destination for the extracted WAV. Parent
    ///     directory must exist; the file is created if needed and
    ///     overwritten if it already does.
    ///   - onProgress: Invoked as extraction progresses. Fraction
    ///     is `[0, 1]` against the video's total audio sample count.
    ///     Stages: "Loading track", "Decoding (N%)", "Writing WAV".
    ///   - isCancelled: Closure queried between sample buffers;
    ///     when it returns true, the extraction aborts cleanly,
    ///     the partial file is deleted, and `CancellationError` is
    ///     thrown.
    public static func extractAndWriteWAV(
        url: URL,
        outputURL: URL,
        onProgress: WriteProgressCallback? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async throws -> WriteResult {
        // MXF route: AVAssetReader can't open MXF unless the
        // user has Apple's Pro Video Formats installed, and we
        // don't want to shell out to ffmpeg for something we
        // can do ourselves. `MXFAudioExtractor` walks the
        // essence stream directly, decodes PCM to Float, and
        // we hand the result to `writePCM24WAV` like every
        // other path.
        if url.pathExtension.lowercased() == "mxf" {
            return try await extractMXFAndWriteWAV(
                url: url,
                outputURL: outputURL,
                onProgress: onProgress,
                isCancelled: isCancelled
            )
        }
        onProgress?("Loading track", 0)
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw ExtractionError.noAudioTrack
        }

        // Many cameras (ARRI / RED / Blackmagic / Atomos) lay
        // down 4 audio channels as 4 SEPARATE mono tracks in the
        // container instead of one 4-channel track. The simple
        // `audioTracks.first` path would see just channel 1 and
        // produce a mono WAV. Real fix: read EVERY audio track,
        // interleave them into one combined buffer in track
        // order, and write the resulting multi-channel WAV.
        //
        // Within a single track we still honor its native channel
        // count (stereo track → 2 channels), so a 4-channel
        // stereo-pair layout (e.g. L/R + lav-L/lav-R in two
        // separate stereo tracks) also works.
        //
        // Sample rate is pulled from the FIRST track's format
        // description; all tracks in a single container share a
        // clock, and re-sampling per track would just waste
        // cycles. `AVNumberOfChannelsKey` is set to the PER-TRACK
        // channel count so each reader preserves its own layout.
        var nativeSampleRate = 48000
        var perTrackChannelCounts: [Int] = []
        for track in audioTracks {
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            var trackCh = 0
            for fd in formats {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
                    let sr = Int(asbd.pointee.mSampleRate)
                    if sr > 0 { nativeSampleRate = sr }
                    let ch = Int(asbd.pointee.mChannelsPerFrame)
                    if ch > 0 {
                        trackCh = ch
                        break
                    }
                }
            }
            perTrackChannelCounts.append(max(1, trackCh))
        }
        let sourceChannelCount = perTrackChannelCounts.reduce(0, +)

        print("[VideoAudioExtractor] source=\(url.lastPathComponent) tracks=\(audioTracks.count) perTrack=\(perTrackChannelCounts) totalChannels=\(sourceChannelCount) sr=\(nativeSampleRate)")

        // Total sample count estimate for progress reporting. Use
        // the first track's duration (all audio tracks in one
        // container share a duration to within a sample or two).
        let trackTimeRange = (try? await audioTracks[0].load(.timeRange)) ?? CMTimeRange()
        let rawDuration = CMTimeGetSeconds(trackTimeRange.duration)
        let durationSeconds = (rawDuration.isFinite && rawDuration > 0) ? rawDuration : 0.0
        let estimatedTotalFrames = max(1, Int(durationSeconds * Double(nativeSampleRate)))

        // Decode every audio track in PARALLEL via TaskGroup. One
        // AVAssetReader per task so each track honors its own
        // channel layout. On a 4-track camera (ARRI / RED /
        // Blackmagic / Atomos proxies that split 4 channels
        // across 4 mono tracks), parallel decode cuts the
        // wall-clock extraction time roughly by the track count
        // up to the CPU's available cores. Serial was the
        // previous approach and quadrupled the user-visible
        // extraction latency for those camera formats.
        //
        // Progress is aggregated across tasks: each reports its
        // own fraction, we sum and divide by total tracks. The
        // bar advances smoothly as all tracks decode together
        // instead of jumping in per-track chunks.
        let trackCount = audioTracks.count
        var perTrackChannels: [[[Float]]] = Array(
            repeating: [],
            count: trackCount
        )
        let progressAggregator = ExtractionProgressAggregator(trackCount: trackCount)
        try await withThrowingTaskGroup(of: (Int, [[Float]]).self) { group in
            for (trackIdx, track) in audioTracks.enumerated() {
                let trackCh = max(1, perTrackChannelCounts[trackIdx])
                group.addTask {
                    let channels = try decodeTrackChannels(
                        asset: asset,
                        track: track,
                        trackIndex: trackIdx,
                        trackCount: trackCount,
                        channelCount: trackCh,
                        sampleRate: nativeSampleRate,
                        estimatedTotalFrames: estimatedTotalFrames,
                        outputURL: outputURL,
                        onProgress: { _, trackFraction in
                            let aggregated = progressAggregator.reportTrackProgress(
                                trackIndex: trackIdx,
                                trackFraction: trackFraction
                            )
                            let global = aggregated * 0.85
                            onProgress?("Decoding (\(Int(aggregated * 100))%)", global)
                        },
                        isCancelled: isCancelled
                    )
                    return (trackIdx, channels)
                }
            }
            for try await (trackIdx, channels) in group {
                perTrackChannels[trackIdx] = channels
            }
        }

        // Flatten the per-track channel arrays into a single
        // contiguous interleaved buffer. Take the MIN frame count
        // across every channel of every track so uneven codec
        // tails don't produce silent gaps on one channel while
        // others have samples.
        let totalChannels = perTrackChannels.reduce(0) { $0 + $1.count }
        var minFrames = Int.max
        for track in perTrackChannels {
            for ch in track where ch.count < minFrames {
                minFrames = ch.count
            }
        }
        guard totalChannels > 0, minFrames > 0, minFrames != Int.max else {
            throw ExtractionError.readFailed("No audio samples returned from any track")
        }

        var interleaved = [Float](repeating: 0, count: minFrames * totalChannels)
        var outCh = 0
        for track in perTrackChannels {
            for ch in track {
                for frame in 0..<minFrames {
                    interleaved[frame * totalChannels + outCh] = ch[frame]
                }
                outCh += 1
            }
        }
        let channelCount = totalChannels
        let totalFrames = UInt64(minFrames)
        print("[VideoAudioExtractor] merged \(audioTracks.count) track(s) → \(channelCount)ch × \(minFrames) frames")

        // Write the WAV file. 24-bit PCM matches the production
        // audio convention and saves ~33% disk vs 32-bit float for
        // an imperceptible precision loss (6 dB of noise floor vs
        // >140 dB for 24-bit). No BEXT; the caller assigns the TC
        // on the resulting AudioFile after parse. Progress is
        // reported chunk-by-chunk during the float-to-int
        // conversion (the slow part) so the bar doesn't stall
        // at 90% for the last few seconds of a multi-channel
        // extraction.
        try writePCM24WAV(
            interleavedFloat: interleaved,
            channelCount: channelCount,
            sampleRate: nativeSampleRate,
            outputURL: outputURL,
            onProgress: { fraction in
                // Writing phase covers the last 15% of the overall
                // progress bar (85% → 100%).
                let global = 0.85 + fraction * 0.15
                onProgress?("Writing WAV \(Int(fraction * 100))%", global)
            }
        )
        onProgress?("Ready", 1.0)

        return WriteResult(
            outputURL: outputURL,
            channelCount: channelCount,
            sampleRate: nativeSampleRate,
            totalSamples: totalFrames
        )
    }

    /// MXF-specific path: native essence decode → interleave →
    /// `writePCM24WAV`. Runs the decode on a detached task so
    /// the synchronous `MXFAudioExtractor.extract` doesn't block
    /// the caller's actor.
    private static func extractMXFAndWriteWAV(
        url: URL,
        outputURL: URL,
        onProgress: WriteProgressCallback?,
        isCancelled: (@Sendable () -> Bool)?
    ) async throws -> WriteResult {
        onProgress?("Scanning MXF essence", 0)
        let result: MXFAudioExtractor.Result = try await Task.detached(priority: .userInitiated) {
            try MXFAudioExtractor.extract(
                url: url,
                onProgress: { frac in
                    // Decode dominates the total work; attribute
                    // it 85% of the overall progress bar.
                    let global = frac * 0.85
                    onProgress?("Decoding (\(Int(frac * 100))%)", global)
                },
                isCancelled: isCancelled
            )
        }.value
        print("[VideoAudioExtractor/MXF] \(url.lastPathComponent) → \(result.channels.count)ch × \(result.frameCount) frames @ \(result.sampleRate) Hz")

        let channelCount = result.channels.count
        guard channelCount > 0, result.frameCount > 0 else {
            throw ExtractionError.readFailed("MXF decoded empty audio")
        }
        // Interleave per-channel arrays LRLRLR…
        var interleaved = [Float](repeating: 0, count: result.frameCount * channelCount)
        for c in 0..<channelCount {
            let src = result.channels[c]
            for frame in 0..<result.frameCount {
                interleaved[frame * channelCount + c] = src[frame]
            }
        }

        try writePCM24WAV(
            interleavedFloat: interleaved,
            channelCount: channelCount,
            sampleRate: result.sampleRate,
            outputURL: outputURL,
            onProgress: { fraction in
                let global = 0.85 + fraction * 0.15
                onProgress?("Writing WAV \(Int(fraction * 100))%", global)
            }
        )
        onProgress?("Ready", 1.0)

        return WriteResult(
            outputURL: outputURL,
            channelCount: channelCount,
            sampleRate: result.sampleRate,
            totalSamples: UInt64(result.frameCount)
        )
    }

    /// Minimal RIFF/WAVE writer for the cache path. Writes a
    /// standard 24-bit PCM WAV (fmt + data chunks). No BEXT — the
    /// TC flows from the source video onto the parsed AudioFile
    /// in the session layer, not via the on-disk metadata.
    ///
    /// Floats are clamped to `[-1, 1]` and multiplied by 2^23 - 1
    /// before truncation. Saturates on clipping. Progress is
    /// reported during the conversion loop so a multi-channel
    /// ~15 min extract (the float→24bit pass dominates the
    /// writing time) doesn't stall the UI progress bar at 90%.
    private static func writePCM24WAV(
        interleavedFloat: [Float],
        channelCount: Int,
        sampleRate: Int,
        outputURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        let bytesPerSample = 3
        let dataByteCount = interleavedFloat.count * bytesPerSample
        // Convert Float [-1,1] → 24-bit signed little-endian int.
        // Pre-allocate the full buffer then write into it via
        // direct index access: ~10x faster than repeated
        // `Data.append(UInt8)` on a multi-million-sample file.
        var pcmBytes = Data(count: dataByteCount)
        let maxInt: Int32 = (1 << 23) - 1
        let minInt: Int32 = -(1 << 23)
        let total = interleavedFloat.count
        // Progress ticks: once per ~1% of samples. For a 15 min
        // stereo 48 kHz file (~86 M samples), that's ~860k
        // samples between reports, roughly a tick every 10 ms.
        let tickEvery = max(1, total / 100)
        pcmBytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<total {
                let sample = interleavedFloat[i]
                let clamped = max(Float(-1), min(Float(1), sample))
                var value = Int32(clamped * Float(maxInt))
                value = max(minInt, min(maxInt, value))
                let byteOffset = i * bytesPerSample
                base[byteOffset]     = UInt8(value & 0xFF)
                base[byteOffset + 1] = UInt8((value >> 8) & 0xFF)
                base[byteOffset + 2] = UInt8((value >> 16) & 0xFF)
                if (i % tickEvery) == 0 {
                    onProgress?(Double(i) / Double(total))
                }
            }
        }
        onProgress?(1.0)

        // WAV header: RIFF chunk wrapping fmt + data.
        let fmtChunkSize: UInt32 = 16        // standard PCM
        let dataChunkSize = UInt32(dataByteCount)
        let riffSize: UInt32 = 4 + (8 + fmtChunkSize) + (8 + dataChunkSize)
        let channels = UInt16(channelCount)
        let sampleRateU32 = UInt32(sampleRate)
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bytesPerSample)
        let blockAlign = UInt16(channelCount * bytesPerSample)
        let bitsPerSample: UInt16 = 24

        var header = Data(capacity: 44)
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(le32(riffSize))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(le32(fmtChunkSize))
        header.append(le16(1))                 // PCM
        header.append(le16(channels))
        header.append(le32(sampleRateU32))
        header.append(le32(byteRate))
        header.append(le16(blockAlign))
        header.append(le16(bitsPerSample))
        header.append(contentsOf: Array("data".utf8))
        header.append(le32(dataChunkSize))

        // Write atomically via a single combined Data.
        var out = header
        out.append(pcmBytes)
        try out.write(to: outputURL, options: .atomic)
    }

    /// Decode a single audio track's samples into per-channel
    /// Float arrays. Used by `extractAndWriteWAV` when the source
    /// has multiple audio tracks (e.g. a camera that records 4
    /// channels as 4 separate mono tracks). Each track gets its
    /// own AVAssetReader so the per-track channel layout is
    /// preserved — the caller concatenates the results into one
    /// multi-channel WAV.
    private static func decodeTrackChannels(
        asset: AVURLAsset,
        track: AVAssetTrack,
        trackIndex: Int,
        trackCount: Int,
        channelCount: Int,
        sampleRate: Int,
        estimatedTotalFrames: Int,
        outputURL: URL,
        onProgress: WriteProgressCallback?,
        isCancelled: (@Sendable () -> Bool)?
    ) throws -> [[Float]] {
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: outputSettings
        )
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else {
            throw ExtractionError.readerSetupFailed("Reader rejected output for track \(trackIndex + 1)")
        }
        reader.add(trackOutput)
        guard reader.startReading() else {
            let msg = reader.error?.localizedDescription ?? "Unknown reader error"
            throw ExtractionError.readFailed(msg)
        }

        var interleaved: [Float] = []
        interleaved.reserveCapacity(estimatedTotalFrames * channelCount)
        var observedChannels = 0

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            if isCancelled?() == true {
                reader.cancelReading()
                try? FileManager.default.removeItem(at: outputURL)
                throw CancellationError()
            }
            if observedChannels == 0,
               let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
                observedChannels = Int(asbd.pointee.mChannelsPerFrame)
                if observedChannels != channelCount {
                    print("[VideoAudioExtractor] track \(trackIndex + 1): buffer reports \(observedChannels)ch, expected \(channelCount)ch")
                }
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let dataPointer else { continue }
            let sampleCount = totalLength / MemoryLayout<Float>.size
            dataPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { floatPtr in
                let buf = UnsafeBufferPointer(start: floatPtr, count: sampleCount)
                interleaved.append(contentsOf: buf)
            }
            // Progress: attribute each track a slice of the
            // overall progress bar. Track i of N advances from
            // `i/N` to `(i+1)/N` as it decodes.
            let framesDecoded = interleaved.count / max(1, channelCount)
            let trackFrac = min(1.0, Double(framesDecoded) / Double(estimatedTotalFrames))
            // Invoke the caller's progress callback with the stage
            // string + the per-track fraction. The caller (the
            // TaskGroup coordinator in `extractAndWriteWAV`) is
            // responsible for aggregating across tracks and emitting
            // an overall progress number.
            onProgress?("Decoding track \(trackIndex + 1)/\(trackCount)", trackFrac)
        }

        if reader.status == .failed {
            let msg = reader.error?.localizedDescription ?? "Reader failed mid-read"
            throw ExtractionError.readFailed(msg)
        }
        guard !interleaved.isEmpty else {
            throw ExtractionError.readFailed("Track \(trackIndex + 1) returned no samples")
        }

        // De-interleave into per-channel arrays.
        let actualChannels = max(1, observedChannels > 0 ? observedChannels : channelCount)
        let frameCount = interleaved.count / actualChannels
        var channels = [[Float]](repeating: [], count: actualChannels)
        for c in 0..<actualChannels {
            channels[c].reserveCapacity(frameCount)
        }
        interleaved.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for frame in 0..<frameCount {
                let frameStart = base + frame * actualChannels
                for c in 0..<actualChannels {
                    channels[c].append(frameStart[c])
                }
            }
        }
        return channels
    }

    private static func le16(_ value: UInt16) -> Data {
        var v = value.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }

    private static func le32(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
}
