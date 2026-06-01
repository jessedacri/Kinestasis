import Foundation
import AVFoundation
import CoreMedia
import PreemCore
import PolymergeIngest

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

    /// Cached native MXF readers (one index/file-handle per URL) so the
    /// expensive packet-index scan is paid once, then ranged decodes are
    /// cheap. Keyed by file path.
    private var mxfReaders: [String: MXFAudioReader] = [:]
    /// Cache of decoded MXF sample ranges so repeated timeline syncs of the
    /// same trimmed clip don't re-read packets. Keyed by "path|start|count".
    private var rangeCache: [String: [[Float]]] = [:]
    private var rangeOrder: [String] = []
    private var rangeBytes: Int = 0

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
    /// `startFrame` (zero-padded out of range). For MXF this decodes ONLY
    /// the covering packets (fast for trimmed clips); other formats fall
    /// back to the whole-file cached decode + slice (unchanged behavior).
    /// Channels are the source's native channel layout.
    public func loadRange(clipID: ClipID, url: URL, startFrame: Int, frameCount: Int) async throws -> [[Float]] {
        if url.pathExtension.lowercased() == "mxf" {
            let reader = try await mxfReader(for: url)
            // Ranged decode only when the file's native rate already matches
            // the engine rate (Canon/most pro MXF = 48 kHz). Otherwise fall
            // back to whole-file decode + resample, then slice.
            if reader.sampleRate == Int(targetSampleRate.rounded()) {
                let key = "\(url.path)|\(startFrame)|\(frameCount)"
                if let cached = rangeCache[key] { touchRange(key); return cached }
                let r = reader
                let channels = await Task.detached(priority: .userInitiated) {
                    r.decodeRange(startFrame: startFrame, frameCount: frameCount)
                }.value
                insertRange(key: key, channels: channels)
                return channels
            }
            let decoded = try await load(clipID: clipID, url: url)
            return Self.slice(decoded.channels, start: startFrame, count: frameCount)
        }
        let decoded = try await load(clipID: clipID, url: url)
        return Self.slice(decoded.channels, start: startFrame, count: frameCount)
    }

    private func mxfReader(for url: URL) async throws -> MXFAudioReader {
        let key = url.path
        if let r = mxfReaders[key] { return r }
        let reader = try await Task.detached(priority: .userInitiated) {
            try MXFAudioReader.open(url: url)
        }.value
        mxfReaders[key] = reader
        return reader
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
        mxfReaders.removeAll()
        rangeCache.removeAll()
        rangeOrder.removeAll()
        rangeBytes = 0
    }

    // MARK: - Decode

    private func decode(url: URL) async throws -> DecodedAudio {
        // MXF carries uncompressed PCM sound essence that AVFoundation
        // can't open — read it natively (KLV demux → per-channel Float),
        // preserving the source's native channels (e.g. 4 discrete mono on
        // a Canon clip). No transcode / temp WAV.
        if url.pathExtension.lowercased() == "mxf" {
            return try await decodeMXF(url: url)
        }
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

    /// Native MXF audio: demux the PCM sound essence directly to
    /// per-channel Float arrays (all source channels preserved), then
    /// conform only the sample rate to the engine's rate if it differs
    /// (Canon/most pro MXF is already 48 kHz → pass-through). The heavy
    /// essence read runs off the actor.
    private func decodeMXF(url: URL) async throws -> DecodedAudio {
        let reader: MXFAudioReader
        do {
            reader = try await mxfReader(for: url)
        } catch {
            throw LoadError.readerFailed("MXF audio: \(error.localizedDescription)")
        }
        let srcRate = Double(reader.sampleRate)
        let r = reader
        var channels = await Task.detached(priority: .userInitiated) {
            r.decodeRange(startFrame: 0, frameCount: r.totalFrames)
        }.value
        if srcRate > 0, abs(srcRate - targetSampleRate) > 0.5 {
            channels = Self.conform(channels: channels, srcRate: srcRate, toRate: targetSampleRate)
        }
        return DecodedAudio(
            channels: channels,
            sampleRate: srcRate > 0 && abs(srcRate - targetSampleRate) > 0.5 ? targetSampleRate : srcRate,
            originalChannelCount: channels.count
        )
    }

    private func insertRange(key: String, channels: [[Float]]) {
        let bytes = channels.reduce(0) { $0 + $1.count * MemoryLayout<Float>.stride }
        // Bound the range cache to a fraction of the overall budget.
        let cap = maxCacheBytes / 4
        while rangeBytes + bytes > cap, let oldest = rangeOrder.first {
            rangeOrder.removeFirst()
            if let dropped = rangeCache.removeValue(forKey: oldest) {
                rangeBytes -= dropped.reduce(0) { $0 + $1.count * MemoryLayout<Float>.stride }
            }
        }
        rangeCache[key] = channels
        rangeOrder.append(key)
        rangeBytes += bytes
    }

    private func touchRange(_ key: String) {
        if let idx = rangeOrder.firstIndex(of: key) {
            rangeOrder.remove(at: idx)
            rangeOrder.append(key)
        }
    }

    /// Resample per-channel Float arrays from `srcRate` to `toRate`,
    /// preserving channel count. Used only when an MXF's native rate
    /// isn't the engine rate. Returns the input unchanged on failure.
    private nonisolated static func conform(channels: [[Float]], srcRate: Double, toRate: Double) -> [[Float]] {
        guard let n = channels.first?.count, n > 0,
              let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: srcRate,
                                         channels: AVAudioChannelCount(channels.count), interleaved: false),
              let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: toRate,
                                         channels: AVAudioChannelCount(channels.count), interleaved: false),
              let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(n)),
              let conv = AVAudioConverter(from: srcFmt, to: dstFmt)
        else { return channels }
        srcBuf.frameLength = AVAudioFrameCount(n)
        if let cd = srcBuf.floatChannelData {
            for ch in 0..<channels.count {
                channels[ch].withUnsafeBufferPointer { cd[ch].update(from: $0.baseAddress!, count: n) }
            }
        }
        let outCap = AVAudioFrameCount(Double(n) * toRate / srcRate + 1)
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: outCap) else { return channels }
        var done = false
        var err: NSError?
        conv.convert(to: dstBuf, error: &err) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            done = true; status.pointee = .haveData; return srcBuf
        }
        guard err == nil, let cd = dstBuf.floatChannelData else { return channels }
        let outN = Int(dstBuf.frameLength)
        return (0..<channels.count).map { Array(UnsafeBufferPointer(start: cd[$0], count: outN)) }
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
