import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
import KineCore

/// Batch-exports burst shots to ProRes movies — one file per shot, native
/// input resolution, frame timing from `ShotTimingEngine`.
public struct BurstShotExporter: Sendable {

    public enum Codec: String, CaseIterable, Sendable {
        case proRes422
        case proRes422HQ
        case proRes4444
        case h264
        case hevc

        var avCodec: AVVideoCodecType {
            switch self {
            case .proRes422:   return .proRes422
            case .proRes422HQ: return .proRes422HQ
            case .proRes4444:  return .proRes4444
            case .h264:        return .h264
            case .hevc:        return .hevc
            }
        }

        public var fileSuffix: String {
            switch self {
            case .proRes422:   return "422"
            case .proRes422HQ: return "422HQ"
            case .proRes4444:  return "4444"
            case .h264:        return "H264"
            case .hevc:        return "HEVC"
            }
        }

        public var displayName: String {
            switch self {
            case .proRes422:   return "ProRes 422"
            case .proRes422HQ: return "ProRes 422 HQ"
            case .proRes4444:  return "ProRes 4444"
            case .h264:        return "H.264"
            case .hevc:        return "HEVC"
            }
        }

        /// Compact label for tight segmented controls.
        public var shortName: String {
            switch self {
            case .proRes422:   return "422"
            case .proRes422HQ: return "422 HQ"
            case .proRes4444:  return "4444"
            case .h264:        return "H.264"
            case .hevc:        return "HEVC"
            }
        }

        public var usesBitrate: Bool { self == .h264 || self == .hevc }
        public var defaultBitrateMbps: Int { self == .h264 ? 50 : 30 }

        /// Hardware encoder dimension ceiling; native 24 MP stills exceed
        /// what H.264 levels allow.
        public var longEdgeLimit: Int? {
            switch self {
            case .h264: return 3840
            case .hevc: return 8192
            default: return nil
            }
        }

        func videoSettings(width: Int, height: Int, bitrateMbps: Int?) -> [String: Any] {
            var settings: [String: Any] = [
                AVVideoCodecKey: avCodec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
            if usesBitrate {
                var compression: [String: Any] = [
                    AVVideoAverageBitRateKey: (bitrateMbps ?? defaultBitrateMbps) * 1_000_000,
                    AVVideoMaxKeyFrameIntervalKey: 48,
                ]
                if self == .h264 {
                    compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
                }
                settings[AVVideoCompressionPropertiesKey] = compression
            }
            return settings
        }
    }

    public enum ExportError: Error, LocalizedError {
        case emptyShot
        case stillDecodeFailed(URL)
        case pixelBufferAllocFailed
        case writerFailed(String)

        public var errorDescription: String? {
            switch self {
            case .emptyShot: return "Shot has no frames."
            case .stillDecodeFailed(let url): return "Could not decode \(url.lastPathComponent)."
            case .pixelBufferAllocFailed: return "Could not allocate a pixel buffer."
            case .writerFailed(let s): return "Export failed: \(s)"
            }
        }
    }

    public init() {}

    /// Deterministic output name: `<shotname>_<codec>.mov`.
    public static func outputURL(for shot: BurstShot, codec: Codec, in directory: URL) -> URL {
        directory.appendingPathComponent("\(shot.name)_\(codec.fileSuffix).mov")
    }

    /// Export one shot. Blocking; run off the main actor. `progress` gets
    /// the fraction of stills written. Returns the written file URL.
    @discardableResult
    public func export(
        shot: BurstShot,
        mode: ShotTimingMode,
        rate: FrameRate,
        codec: Codec,
        to directory: URL,
        filename: String? = nil,
        maxLongEdge: Int? = nil,
        bitrateMbps: Int? = nil,
        isCancelled: @Sendable () -> Bool = { false },
        progress: @Sendable (Double) -> Void = { _ in }
    ) throws -> URL {
        let frames = shot.effectiveFrames
        let schedule = ShotTimingEngine.applyRamp(
            ShotTimingEngine.schedule(frames: frames, mode: mode, rate: rate),
            ramp: shot.speedRamp)
        guard !schedule.isEmpty, !frames.isEmpty else { throw ExportError.emptyShot }

        // Native input resolution from the first still (probe if the
        // ingest pass didn't record it). Even dimensions for the encoder.
        let nativeSize: PixelSize
        if let s = frames[schedule[0].frameIndex].pixelSize ?? frames.first?.pixelSize {
            nativeSize = s
        } else if let img = StillDecoder.decode(url: shot.sourceURL(for: frames[0]), maxPixel: 100_000) {
            nativeSize = PixelSize(width: img.width, height: img.height)
        } else {
            throw ExportError.stillDecodeFailed(frames[0].url)
        }
        // Optional long-edge cap from the export sheet (nil = native),
        // tightened to the codec's hardware ceiling (H.264 tops out well
        // below 24 MP stills).
        var effectiveCap = maxLongEdge
        if let limit = codec.longEdgeLimit {
            effectiveCap = min(effectiveCap ?? limit, limit)
        }
        let outputSize: PixelSize
        if let cap = effectiveCap, cap < max(nativeSize.width, nativeSize.height) {
            let scale = Double(cap) / Double(max(nativeSize.width, nativeSize.height))
            outputSize = PixelSize(width: Int(Double(nativeSize.width) * scale),
                                   height: Int(Double(nativeSize.height) * scale))
        } else {
            outputSize = nativeSize
        }
        let width = outputSize.width - (outputSize.width % 2)
        let height = outputSize.height - (outputSize.height % 2)

        let outputURL = filename.map { directory.appendingPathComponent($0) }
            ?? Self.outputURL(for: shot, codec: codec, in: directory)
        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw ExportError.writerFailed(error.localizedDescription)
        }

        let input = AVAssetWriterInput(mediaType: .video,
            outputSettings: codec.videoSettings(width: width, height: height, bitrateMbps: bitrateMbps))
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else { throw ExportError.writerFailed("input rejected") }
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        let timescale = CMTimeScale(rate.rationalRate)
        let frameTicks = Int64(rate.rationalScale)
        let maxEdge = max(width, height)

        // ── Sample plan ─────────────────────────────────────────────
        // Static texture: one sample per schedule event (a still held for
        // k frames is one appended frame with a k-frame duration). Grain
        // or wobble animate per output frame, so those shots emit one
        // sample per frame with the texture re-applied on top of a
        // once-developed base (matches timeline playback exactly).
        struct Sample { let stillIndex: Int; let outputFrame: Int64 }
        let animatedTexture = shot.grade.grainAmount > 0 || shot.grade.wobbleIntensity > 0
        var samples: [Sample] = []
        if animatedTexture {
            for event in schedule {
                for f in 0..<event.frameCount {
                    samples.append(Sample(stillIndex: event.frameIndex, outputFrame: event.startFrame + f))
                }
            }
        } else {
            samples = schedule.map { Sample(stillIndex: $0.frameIndex, outputFrame: $0.startFrame) }
        }

        // ── Parallel develop, ordered append ────────────────────────
        // Decode/develop dominates export time and each still is
        // independent, so windows of samples develop concurrently across
        // cores while appends stay strictly ordered. The hardware ProRes /
        // H.264 / HEVC encoder then stays fed instead of starving behind a
        // single-core decode loop.
        var developGrade = shot.grade
        developGrade.grainAmount = 0
        let renderer = ShotGradeRenderer()
        let baseLock = NSLock()
        var baseCache: [Int: CGImage] = [:]
        let window = max(4, min(12, ProcessInfo.processInfo.activeProcessorCount))
        var appended = 0

        func developBase(_ stillIndex: Int) -> CGImage? {
            baseLock.lock()
            if let hit = baseCache[stillIndex] { baseLock.unlock(); return hit }
            baseLock.unlock()
            let url = shot.sourceURL(for: frames[stillIndex])
            let image = renderer.render(url: url, grade: developGrade, maxPixel: maxEdge)
                ?? StillDecoder.decode(url: url, maxPixel: maxEdge)
            if let image {
                baseLock.lock()
                baseCache[stillIndex] = image
                // Stills are consumed in order; keep only a small tail.
                if baseCache.count > window * 2 {
                    let minLive = stillIndex - window * 2
                    baseCache = baseCache.filter { $0.key >= minLive }
                }
                baseLock.unlock()
            }
            return image
        }

        func produce(_ sample: Sample) -> CVPixelBuffer? {
            guard var image = developBase(sample.stillIndex) else { return nil }
            if animatedTexture {
                let ev = ExposureWobble.evOffset(outputFrame: sample.outputFrame, fps: rate.fps,
                                                 intensity: shot.grade.wobbleIntensity,
                                                 rate: shot.grade.wobbleRate)
                var texture = ShotGrade()
                texture.grainAmount = shot.grade.grainAmount
                texture.grainSize = shot.grade.grainSize
                texture.grainResponse = shot.grade.grainResponse
                image = renderer.gradePreview(image, grade: texture, evOffset: ev, grainSeed: sample.outputFrame) ?? image
            }
            guard let pool = adaptor.pixelBufferPool else { return nil }
            return Self.render(image: image, width: width, height: height, pool: pool)
        }

        var index = 0
        while index < samples.count {
            if isCancelled() {
                input.markAsFinished()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                return outputURL
            }
            let upper = min(index + window, samples.count)
            let windowSamples = Array(samples[index..<upper])
            var buffers = [CVPixelBuffer?](repeating: nil, count: windowSamples.count)
            buffers.withUnsafeMutableBufferPointer { out in
                let base = out.baseAddress!
                let resultLock = NSLock()
                DispatchQueue.concurrentPerform(iterations: windowSamples.count) { i in
                    let buffer = produce(windowSamples[i])
                    resultLock.lock(); base[i] = buffer; resultLock.unlock()
                }
            }
            for (i, sample) in windowSamples.enumerated() {
                guard let buffer = buffers[i] else {
                    input.markAsFinished()
                    writer.cancelWriting()
                    throw ExportError.stillDecodeFailed(shot.sourceURL(for: frames[sample.stillIndex]))
                }
                while !input.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.002)
                }
                let pts = CMTime(value: sample.outputFrame * frameTicks, timescale: timescale)
                guard adaptor.append(buffer, withPresentationTime: pts) else {
                    let reason = writer.error?.localizedDescription ?? "append failed"
                    input.markAsFinished()
                    writer.cancelWriting()
                    throw ExportError.writerFailed(reason)
                }
                appended += 1
                progress(Double(appended) / Double(samples.count))
            }
            index = upper
        }

        // End the session at the schedule's end boundary so the last still
        // keeps its full display span (a writer otherwise ends the movie
        // at the final sample's PTS).
        let endFrame = ShotTimingEngine.totalFrames(schedule)
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.endSession(atSourceTime: CMTime(value: endFrame * frameTicks, timescale: timescale))
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status == .failed {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        return outputURL
    }

    /// Draw a CGImage into a pooled BGRA buffer, aspect-fit on black in the
    /// (rare) case a burst mixes pixel sizes.
    private static func render(image: CGImage, width: Int, height: Int, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let buffer = pb else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let w = CGFloat(image.width) * scale
        let h = CGFloat(image.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
        return buffer
    }
}
