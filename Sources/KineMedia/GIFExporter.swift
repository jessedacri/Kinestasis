import Foundation
import ImageIO
import UniformTypeIdentifiers
import KineCore

/// Animated GIF export: the universal internet recipe - GIF89a, 256-color
/// palette with ImageIO's dithering, per-frame delays derived from the
/// shot's real cadence (one GIF frame per still, not per timeline frame),
/// infinite loop. Small files, plays everywhere.
public enum GIFExporter {

    public enum GIFError: LocalizedError {
        case emptyShot
        case renderFailed(URL)
        case writeFailed(URL)
        public var errorDescription: String? {
            switch self {
            case .emptyShot: return "nothing to export"
            case .renderFailed(let url): return "could not develop \(url.lastPathComponent)"
            case .writeFailed(let url): return "could not write \(url.lastPathComponent)"
            }
        }
    }

    /// One GIF frame per still with its total display time; consecutive
    /// schedule events for the same still merge (ramps produce runs).
    static func consolidatedEntries(schedule: [StillEvent], fps: Double) -> [(index: Int, delay: Double)] {
        var entries: [(index: Int, delay: Double)] = []
        for event in schedule {
            let delay = Double(event.frameCount) / fps
            if let last = entries.last, last.index == event.frameIndex {
                entries[entries.count - 1].delay += delay
            } else {
                entries.append((event.frameIndex, delay))
            }
        }
        return entries
    }

    /// Ping-pong: forward, then back through the interior only (the ends
    /// are not doubled), so the loop point is seamless in both directions.
    static func boomerangEntries(_ entries: [(index: Int, delay: Double)]) -> [(index: Int, delay: Double)] {
        guard entries.count > 2 else { return entries }
        return entries + entries[1..<(entries.count - 1)].reversed()
    }

    /// GIF delays are whole centiseconds; naive rounding of 125.1ms to
    /// 130ms ran every export ~4% slow. Quantize CUMULATIVE time instead,
    /// so per-frame delays dither between neighboring centiseconds and
    /// the loop duration tracks the timeline within 10ms.
    static func quantizedDelays(_ entries: [(index: Int, delay: Double)]) -> [Double] {
        var written = 0.0
        var ideal = 0.0
        return entries.map { entry in
            ideal += entry.delay
            let target = (ideal * 100).rounded() / 100
            let delay = max(0.02, target - written)   // 2cs floor: browsers clamp below it
            written += delay
            return delay
        }
    }

    public static func export(shot: BurstShot, mode: ShotTimingMode, skipDefault: Int,
                              rate: FrameRate, maxPixel: Int, boomerang: Bool = false,
                              to url: URL,
                              isCancelled: @Sendable () -> Bool = { false }) throws {
        let frames = shot.playbackFrames(skipDefault: skipDefault)
        let schedule = ShotTimingEngine.applyRamp(
            ShotTimingEngine.schedule(frames: frames, mode: mode, rate: rate),
            ramp: shot.speedRamp)
        var entries = consolidatedEntries(schedule: schedule, fps: rate.fps)
        if boomerang { entries = boomerangEntries(entries) }
        guard !entries.isEmpty, !frames.isEmpty else { throw GIFError.emptyShot }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, entries.count, nil) else {
            throw GIFError.writeFailed(url)
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)

        let renderer = ShotGradeRenderer()
        let delays = quantizedDelays(entries)
        var rendered: [Int: CGImage] = [:]   // each still develops once; boomerang reuses
        for (position, entry) in entries.enumerated() {
            if isCancelled() { throw CancellationError() }
            guard frames.indices.contains(entry.index) else { continue }
            let source = shot.sourceURL(for: frames[entry.index])
            let image: CGImage
            if let cached = rendered[entry.index] {
                image = cached
            } else if let fresh = renderer.render(url: source, grade: shot.grade,
                                                  maxPixel: maxPixel,
                                                  grainSeed: Int64(entry.index)) {
                rendered[entry.index] = fresh
                image = fresh
            } else {
                throw GIFError.renderFailed(source)
            }
            CGImageDestinationAddImage(dest, image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delays[position],
                    kCGImagePropertyGIFUnclampedDelayTime: delays[position],
                ],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw GIFError.writeFailed(url) }
    }
}
