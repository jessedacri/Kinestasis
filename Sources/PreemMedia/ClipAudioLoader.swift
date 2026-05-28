import Foundation
import AVFoundation
import CoreMedia
import PreemCore

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

    public func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
        cacheBytes = 0
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
