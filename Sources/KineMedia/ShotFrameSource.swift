import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics
import KineCore
import PolymergePlayback

/// Feeds a burst shot straight into the compositor as if it were a video:
/// output frames follow the shot's schedule (timing mode, trim, ramp), and
/// each frame is developed with the shot's grade, grain, and wobble on
/// demand. No intermediate render, no baking — dropping a shot on the
/// timeline just plays.
///
/// `maxPixel` bounds the decode: the realtime program path passes ~2048 so
/// scrubbing/playback stay interactive on 24 MP RAW; export passes native.
public final class ShotFrameSource: VideoFrameSource, @unchecked Sendable {

    public let durationSeconds: Double
    public let nominalFrameRate: Double
    public let pixelDimensions: CGSize

    private let shot: BurstShot
    private let schedule: [StillEvent]
    private let frames: [StillFrame]
    private let totalFrames: Int64
    private let maxPixel: Int
    private let renderer = ShotGradeRenderer()

    private let lock = NSLock()
    private var position: Int64 = 0
    /// Last developed still (they repeat for several output frames; only
    /// grain/wobble change per frame, applied on top of this base).
    private var cachedBase: (index: Int, image: CGImage)?
    private var bufferPool: CVPixelBufferPool?
    private var poolSize: (w: Int, h: Int) = (0, 0)

    public init(shot: BurstShot, defaultTiming: ShotTimingMode, rate: FrameRate, maxPixel: Int) {
        self.shot = shot
        self.frames = shot.playbackFrames
        self.schedule = ShotTimingEngine.schedule(for: shot, projectDefault: defaultTiming, rate: rate)
        self.totalFrames = ShotTimingEngine.totalFrames(schedule)
        self.nominalFrameRate = rate.fps
        self.durationSeconds = Double(totalFrames) / rate.fps
        self.maxPixel = maxPixel

        let native = frames.first?.pixelSize ?? PixelSize(width: 1920, height: 1080)
        let scale = min(1, Double(maxPixel) / Double(max(native.width, native.height)))
        let w = Int(Double(native.width) * scale), h = Int(Double(native.height) * scale)
        self.pixelDimensions = CGSize(width: w - w % 2, height: h - h % 2)
    }

    public func seek(to time: CMTime) async throws {
        let seconds = max(0, CMTimeGetSeconds(time))
        lock.lock()
        position = min(totalFrames, Int64((seconds * nominalFrameRate).rounded()))
        lock.unlock()
    }

    public func nextFrame() async throws -> PPEDecodedFrame? {
        lock.lock()
        let current = position
        lock.unlock()
        guard current < totalFrames,
              let event = ShotTimingEngine.event(at: current, in: schedule),
              frames.indices.contains(event.frameIndex) else { return nil }

        // Base develop only when the still changes; grain/wobble re-apply
        // per output frame so texture animates exactly like the export.
        let base: CGImage
        if let cached = cachedBase, cached.index == event.frameIndex {
            base = cached.image
        } else {
            let url = shot.sourceURL(for: frames[event.frameIndex])
            var develop = shot.grade
            develop.grainAmount = 0   // applied per-frame below
            guard let image = renderer.render(url: url, grade: develop, maxPixel: maxPixel)
                    ?? StillDecoder.decode(url: url, maxPixel: maxPixel) else { return nil }
            base = image
            cachedBase = (event.frameIndex, image)
        }

        var final = base
        if shot.grade.grainAmount > 0 || shot.grade.wobbleIntensity > 0 {
            let ev = ExposureWobble.evOffset(outputFrame: current, fps: nominalFrameRate,
                                             intensity: shot.grade.wobbleIntensity,
                                             rate: shot.grade.wobbleRate)
            var texture = ShotGrade()
            texture.grainAmount = shot.grade.grainAmount
            texture.grainSize = shot.grade.grainSize
            texture.grainResponse = shot.grade.grainResponse
            final = renderer.gradePreview(base, grade: texture, evOffset: ev, grainSeed: current) ?? base
        }

        guard let buffer = makeBuffer(from: final) else { return nil }
        lock.lock()
        position = current + 1
        lock.unlock()
        let scale = CMTimeScale(600)
        return PPEDecodedFrame(
            pts: CMTime(value: CMTimeValue((Double(current) / nominalFrameRate * 600).rounded()), timescale: scale),
            duration: CMTime(value: CMTimeValue((600.0 / nominalFrameRate).rounded()), timescale: scale),
            pixelBuffer: buffer
        )
    }

    public func tearDown() {
        lock.lock()
        cachedBase = nil
        bufferPool = nil
        lock.unlock()
    }

    private func makeBuffer(from image: CGImage) -> CVPixelBuffer? {
        let w = image.width - image.width % 2
        let h = image.height - image.height % 2
        if bufferPool == nil || poolSize.w != w || poolSize.h != h {
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: w,
                kCVPixelBufferHeightKey: h,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ] as CFDictionary, &pool)
            bufferPool = pool
            poolSize = (w, h)
        }
        guard let pool = bufferPool else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let buffer = pb else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer
    }
}
