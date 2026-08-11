import Foundation
import AVFoundation
import CoreMedia
import KineCore

/// Decodes a clip's audio track to non-interleaved 32-bit Float arrays
/// (one `[Float]` per channel) resampled to a common rate. AVFoundation
/// handles the resampling via `AVAssetReaderAudioMixOutput`'s output
/// settings.
///
/// The result is cached in memory by `ClipID` so re-decoding doesn't
/// happen when the user moves / trims / cuts clips. Cache is bounded by
/// `maxCacheBytes`; least-recently-used clips are dropped when the cap
/// is reached.
public actor ClipAudioLoader {

    public struct DecodedAudio: Sendable {
        public let channels: [[Float]]           // [channel][sample]
        public let sampleRate: Double
        public let originalChannelCount: Int
        public init(channels: [[Float]], sampleRate: Double, originalChannelCount: Int) {
            self.channels = channels; self.sampleRate = sampleRate
            self.originalChannelCount = originalChannelCount
        }
    }

    public enum LoadError: Error {
        case noAudioTrack
        case readerFailed(String)
    }

    public let targetSampleRate: Double
    public let targetChannelCount: Int
    public let maxCacheBytes: Int

    private var cache: [ClipID: DecodedAudio] = [:]
    private var cacheOrder: [ClipID] = []
    private var cacheBytes: Int = 0

    /// Separate cache for native-channel decodes (`loadNative`). Kept apart
    /// from `cache` because the same `ClipID` can be decoded both
    /// downmixed (`load`) and at native channel count (`loadNative`), and
    /// the two results must not collide.
    private var nativeCache: [ClipID: DecodedAudio] = [:]
    private var nativeOrder: [ClipID] = []
    private var nativeBytes: Int = 0

    public init(targetSampleRate: Double = 48_000, targetChannelCount: Int = 2, maxCacheBytes: Int = 500 * 1024 * 1024) {
        self.targetSampleRate = targetSampleRate
        self.targetChannelCount = targetChannelCount
        self.maxCacheBytes = maxCacheBytes
    }

    public func load(clipID: ClipID, url: URL) async throws -> DecodedAudio {
        if let cached = cache[clipID] {
            touchLRU(clipID)
            return cached
        }
        let decoded = try await decode(url: url)
        insert(clipID: clipID, decoded: decoded)
        return decoded
    }

    /// Load exactly `frameCount` samples per channel starting at
    /// `startFrame` (zero-padded out of range), sliced from the whole-file
    /// cached decode. Channels are the source's native channel layout.
    public func loadRange(clipID: ClipID, url: URL, startFrame: Int, frameCount: Int) async throws -> [[Float]] {
        let decoded = try await load(clipID: clipID, url: url)
        return Self.slice(decoded.channels, start: startFrame, count: frameCount)
    }

    /// Decode preserving the source's native channel layout (no downmix),
    /// resampled only if the native rate differs from `targetSampleRate`.
    /// Used by `separateTracksPreserveChannels` export. Files with several
    /// discrete audio tracks (e.g. multicam camera audio) are concatenated
    /// channel-wise into one N-channel result.
    public func loadNative(clipID: ClipID, url: URL) async throws -> DecodedAudio {
        if let cached = nativeCache[clipID] {
            touchNative(clipID)
            return cached
        }
        let decoded = try await decodeNative(url: url)
        insertNative(clipID: clipID, decoded: decoded)
        return decoded
    }

    private static func slice(_ channels: [[Float]], start: Int, count: Int) -> [[Float]] {
        guard count > 0 else { return channels.map { _ in [] } }
        let total = channels.first?.count ?? 0
        return channels.map { ch in
            var out = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let s = start + i
                if s >= 0 && s < total { out[i] = ch[s] }
            }
            return out
        }
    }

    public func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
        cacheBytes = 0
        nativeCache.removeAll()
        nativeOrder.removeAll()
        nativeBytes = 0
    }

    // MARK: - Decode

    private func decode(url: URL) async throws -> DecodedAudio {
        // AVAudioFile + AVAudioConverter — more robust across the long
        // tail of codec/container combos than AVAssetReader with
        // explicit float32 output settings (which fails with a vague
        // "operation could not be completed" for files like PCM-in-
        // ProRes-MOV).
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw LoadError.readerFailed("AVAudioFile open failed: \(error.localizedDescription)")
        }

        let sourceFormat = audioFile.processingFormat   // PCM float32, deinterleaved, at file's native rate
        let originalChannelCount = Int(sourceFormat.channelCount)
        let totalSourceFrames = Int(audioFile.length)
        guard totalSourceFrames > 0 else {
            return DecodedAudio(
                channels: Array(repeating: [], count: targetChannelCount),
                sampleRate: targetSampleRate,
                originalChannelCount: originalChannelCount
            )
        }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(totalSourceFrames)
        ) else {
            throw LoadError.readerFailed("could not allocate source PCM buffer (\(totalSourceFrames) frames)")
        }
        do {
            try audioFile.read(into: sourceBuffer)
        } catch {
            throw LoadError.readerFailed("AVAudioFile read failed: \(error.localizedDescription)")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: AVAudioChannelCount(targetChannelCount),
            interleaved: false
        ) else {
            throw LoadError.readerFailed("could not construct target AVAudioFormat")
        }

        // Fast path: source already matches target — no conversion needed.
        let resultBuffer: AVAudioPCMBuffer
        if abs(sourceFormat.sampleRate - targetSampleRate) < 0.5
            && Int(sourceFormat.channelCount) == targetChannelCount
            && !sourceFormat.isInterleaved {
            resultBuffer = sourceBuffer
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw LoadError.readerFailed("AVAudioConverter init failed (\(sourceFormat) → \(targetFormat))")
            }
            let outRatio = targetSampleRate / sourceFormat.sampleRate
            let outFrames = AVAudioFrameCount(Double(sourceBuffer.frameLength) * outRatio + 1)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else {
                throw LoadError.readerFailed("could not allocate converted PCM buffer (\(outFrames) frames)")
            }
            var error: NSError?
            var done = false
            converter.convert(to: converted, error: &error) { _, status in
                if done {
                    status.pointee = .endOfStream
                    return nil
                }
                done = true
                status.pointee = .haveData
                return sourceBuffer
            }
            if let error {
                throw LoadError.readerFailed("AVAudioConverter.convert: \(error.localizedDescription)")
            }
            resultBuffer = converted
        }

        let frameCount = Int(resultBuffer.frameLength)
        guard let channelData = resultBuffer.floatChannelData else {
            return DecodedAudio(
                channels: Array(repeating: [Float](repeating: 0, count: frameCount), count: targetChannelCount),
                sampleRate: targetSampleRate,
                originalChannelCount: originalChannelCount
            )
        }
        var channels: [[Float]] = Array(repeating: [], count: targetChannelCount)
        for ch in 0..<targetChannelCount {
            let ptr = channelData[ch]
            channels[ch] = Array(UnsafeBufferPointer(start: ptr, count: frameCount))
        }

        return DecodedAudio(
            channels: channels,
            sampleRate: targetSampleRate,
            originalChannelCount: originalChannelCount
        )
    }

    /// Native-channel decode via `AVAssetReader`, one track output per
    /// audio `AVAssetTrack`, resampled to `targetSampleRate`. Tracks are
    /// concatenated channel-wise (track 0's channels first, then track 1,
    /// …) and zero-padded to a common length. Runs off the actor.
    private func decodeNative(url: URL) async throws -> DecodedAudio {
        let rate = targetSampleRate
        return try await Task.detached(priority: .userInitiated) {
            try Self.readNative(url: url, targetSampleRate: rate)
        }.value
    }

    private nonisolated static func readNative(url: URL, targetSampleRate: Double) throws -> DecodedAudio {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw LoadError.noAudioTrack }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw LoadError.readerFailed("AVAssetReader init: \(error.localizedDescription)")
        }

        // Native channel count per track (no AVNumberOfChannelsKey → keep
        // source channels); resample to the engine rate; interleaved float.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: targetSampleRate,
        ]

        var outputs: [AVAssetReaderTrackOutput] = []
        for track in audioTracks {
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) { reader.add(out); outputs.append(out) }
        }
        guard !outputs.isEmpty, reader.startReading() else {
            throw LoadError.readerFailed("AVAssetReader could not start (\(reader.error?.localizedDescription ?? "unknown"))")
        }

        // Drain each track output into per-track deinterleaved channels.
        var perTrack: [[[Float]]] = []
        perTrack.reserveCapacity(outputs.count)
        for out in outputs {
            perTrack.append(Self.drainTrack(out))
        }

        if reader.status == .failed {
            throw LoadError.readerFailed("AVAssetReader failed: \(reader.error?.localizedDescription ?? "unknown")")
        }

        // Concatenate tracks channel-wise, padding to the longest.
        let maxFrames = perTrack.flatMap { $0 }.map(\.count).max() ?? 0
        var channels: [[Float]] = []
        for trackChannels in perTrack {
            for var ch in trackChannels {
                if ch.count < maxFrames { ch.append(contentsOf: repeatElement(0, count: maxFrames - ch.count)) }
                channels.append(ch)
            }
        }
        if channels.isEmpty { channels = [[]] }
        return DecodedAudio(channels: channels, sampleRate: targetSampleRate, originalChannelCount: channels.count)
    }

    /// Read every sample buffer from one track output and return its
    /// deinterleaved float channels. Channel count is read from the
    /// delivered format description (native, since we didn't force it).
    private nonisolated static func drainTrack(_ output: AVAssetReaderTrackOutput) -> [[Float]] {
        var channels: [[Float]] = []
        var channelCount = 0
        while let sb = output.copyNextSampleBuffer() {
            defer { /* sb released by ARC */ }
            if channelCount == 0,
               let fmt = CMSampleBufferGetFormatDescription(sb),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
                channelCount = Int(asbd.pointee.mChannelsPerFrame)
                channels = Array(repeating: [Float](), count: max(1, channelCount))
            }
            guard channelCount > 0, let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var lengthAtOffset = 0
            var totalLength = 0
            var dataPtr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                              totalLengthOut: &totalLength, dataPointerOut: &dataPtr) == kCMBlockBufferNoErr,
                  let base = dataPtr else { continue }
            let floatCount = totalLength / MemoryLayout<Float>.size
            let frames = floatCount / channelCount
            base.withMemoryRebound(to: Float.self, capacity: floatCount) { fp in
                for ch in 0..<channelCount {
                    channels[ch].reserveCapacity(channels[ch].count + frames)
                    for f in 0..<frames {
                        channels[ch].append(fp[f * channelCount + ch])
                    }
                }
            }
        }
        return channels.isEmpty ? [[]] : channels
    }

    private func insertNative(clipID: ClipID, decoded: DecodedAudio) {
        let bytes = decoded.channels.reduce(0) { $0 + $1.count * MemoryLayout<Float>.stride }
        while nativeBytes + bytes > maxCacheBytes, let oldest = nativeOrder.first {
            nativeOrder.removeFirst()
            if let dropped = nativeCache.removeValue(forKey: oldest) {
                nativeBytes -= dropped.channels.reduce(0) { $0 + $1.count * MemoryLayout<Float>.stride }
            }
        }
        nativeCache[clipID] = decoded
        nativeOrder.append(clipID)
        nativeBytes += bytes
    }

    private func touchNative(_ clipID: ClipID) {
        if let idx = nativeOrder.firstIndex(of: clipID) {
            nativeOrder.remove(at: idx)
            nativeOrder.append(clipID)
        }
    }

    // MARK: - LRU cache

    private func insert(clipID: ClipID, decoded: DecodedAudio) {
        let bytes = decoded.channels.reduce(0) { $0 + $1.count * MemoryLayout<Float>.stride }
        evictUntilFits(adding: bytes)
        cache[clipID] = decoded
        cacheOrder.append(clipID)
        cacheBytes += bytes
    }

    private func touchLRU(_ clipID: ClipID) {
        if let idx = cacheOrder.firstIndex(of: clipID) {
            cacheOrder.remove(at: idx)
            cacheOrder.append(clipID)
        }
    }

    private func evictUntilFits(adding newBytes: Int) {
        while cacheBytes + newBytes > maxCacheBytes, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            if let decoded = cache.removeValue(forKey: oldest) {
                cacheBytes -= decoded.channels.reduce(0) { $0 + $1.count * MemoryLayout<Float>.stride }
            }
        }
    }
}
