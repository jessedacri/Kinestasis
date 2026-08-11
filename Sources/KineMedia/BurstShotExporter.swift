import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
import KineCore

/// Batch-exports burst shots to ProRes movies — one file per shot, native
/// input resolution, frame timing from `ShotTimingEngine`.
public struct BurstShotExporter: Sendable {

    public enum Codec: String, CaseIterable, Sendable {
        case proRes422HQ
        case proRes4444

        var avCodec: AVVideoCodecType {
            switch self {
            case .proRes422HQ: return .proRes422HQ
            case .proRes4444:  return .proRes4444
            }
        }

        public var fileSuffix: String {
            switch self {
            case .proRes422HQ: return "422HQ"
            case .proRes4444:  return "4444"
            }
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
        isCancelled: @Sendable () -> Bool = { false },
        progress: @Sendable (Double) -> Void = { _ in }
    ) throws -> URL {
        let gradeRenderer = shot.grade.isIdentity ? nil : ShotGradeRenderer()
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
        let width = nativeSize.width - (nativeSize.width % 2)
        let height = nativeSize.height - (nativeSize.height % 2)

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

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
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

        for (i, event) in schedule.enumerated() {
            if isCancelled() {
                input.markAsFinished()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                return outputURL
            }
            let stillURL = shot.sourceURL(for: frames[event.frameIndex])
            let maxEdge = max(nativeSize.width, nativeSize.height)
            let ev = ExposureWobble.evOffset(
                outputFrame: event.startFrame, fps: rate.fps,
                intensity: shot.grade.wobbleIntensity, rate: shot.grade.wobbleRate)
            let decoded = gradeRenderer?.render(url: stillURL, grade: shot.grade, maxPixel: maxEdge,
                                                evOffset: ev, grainSeed: event.startFrame)
                ?? StillDecoder.decode(url: stillURL, maxPixel: maxEdge)
            guard let image = decoded else {
                input.markAsFinished()
                writer.cancelWriting()
                throw ExportError.stillDecodeFailed(stillURL)
            }
            guard let pool = adaptor.pixelBufferPool,
                  let buffer = Self.render(image: image, width: width, height: height, pool: pool) else {
                input.markAsFinished()
                writer.cancelWriting()
                throw ExportError.pixelBufferAllocFailed
            }
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            let pts = CMTime(value: event.startFrame * frameTicks, timescale: timescale)
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                let reason = writer.error?.localizedDescription ?? "append failed"
                input.markAsFinished()
                writer.cancelWriting()
                throw ExportError.writerFailed(reason)
            }
            progress(Double(i + 1) / Double(schedule.count))
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
