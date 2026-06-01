import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import PreemCore
import PolymergePlayback

/// In-memory cache of per-clip preview data drawn into the timeline:
/// downsampled audio peaks for audio clips, evenly-spaced still frames
/// for video clips. Generation runs on detached background tasks;
/// results are committed on the main actor and `onChange` fires so the
/// timeline can re-render. One entry per source `ClipID` — every
/// `PlacedClip` that references the same source shares the underlying
/// data and slices into it via `sourceRange`.
@MainActor
public final class ClipPreviewCache {

    public struct Waveform: Sendable {
        /// Per-bucket peak amplitude in [0, 1]. Bucket `i` covers the
        /// `i`-th equally-sized slice of the source's full duration.
        public let peaks: [Float]
        public init(peaks: [Float]) { self.peaks = peaks }
    }

    public struct ThumbStrip: @unchecked Sendable {
        /// Evenly-spaced still frames across the source's full duration.
        /// `images.count` is the requested count (or fewer if some
        /// requests failed).
        public let images: [CGImage]
        public init(images: [CGImage]) { self.images = images }
    }

    private var waveforms: [ClipID: Waveform] = [:]
    private var thumbs: [ClipID: ThumbStrip] = [:]
    private var inFlightWaveforms: Set<ClipID> = []
    private var inFlightThumbs: Set<ClipID> = []

    /// Bumped each time a new preview is committed. Observers re-read
    /// the cache (or call `snapshot()`) when this changes.
    public private(set) var version: Int = 0

    /// Called on the main actor after every commit. The workspace
    /// uses this to nudge SwiftUI into a re-render so the timeline
    /// view picks up the new data.
    public var onChange: (() -> Void)?

    public init() {}

    public func waveform(for id: ClipID) -> Waveform? { waveforms[id] }
    public func thumbnails(for id: ClipID) -> ThumbStrip? { thumbs[id] }

    /// Snapshot the current caches. Cheap — both dictionaries are
    /// shallow copies of value types / immutable refs.
    public func snapshot() -> (waveforms: [ClipID: Waveform], thumbs: [ClipID: ThumbStrip]) {
        (waveforms, thumbs)
    }

    public func ensureWaveform(clipID: ClipID, url: URL, buckets: Int = 2000) {
        if waveforms[clipID] != nil || inFlightWaveforms.contains(clipID) { return }
        inFlightWaveforms.insert(clipID)
        Task.detached(priority: .utility) {
            let result = Self.generateWaveform(url: url, buckets: buckets)
            await MainActor.run {
                self.inFlightWaveforms.remove(clipID)
                if let result {
                    self.waveforms[clipID] = result
                    self.version &+= 1
                    self.onChange?()
                }
            }
        }
    }

    public func ensureThumbnails(clipID: ClipID, url: URL, count: Int = 24, heightPx: Int = 80) {
        if thumbs[clipID] != nil || inFlightThumbs.contains(clipID) { return }
        inFlightThumbs.insert(clipID)
        Task.detached(priority: .utility) {
            let result = await Self.generateThumbnails(url: url, count: count, heightPx: heightPx)
            await MainActor.run {
                self.inFlightThumbs.remove(clipID)
                if let result {
                    self.thumbs[clipID] = result
                    self.version &+= 1
                    self.onChange?()
                }
            }
        }
    }

    public func clear() {
        waveforms.removeAll()
        thumbs.removeAll()
        inFlightWaveforms.removeAll()
        inFlightThumbs.removeAll()
        version &+= 1
        onChange?()
    }

    // MARK: - Audio waveform

    private nonisolated static func generateWaveform(url: URL, buckets: Int) -> Waveform? {
        guard buckets > 0 else { return nil }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            return nil
        }
        let format = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0 else {
            return Waveform(peaks: [Float](repeating: 0, count: buckets))
        }
        // Read in chunks; track the max absolute sample per bucket.
        let chunkFrames: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            return nil
        }
        var peaks = [Float](repeating: 0, count: buckets)
        let bucketSize = Double(totalFrames) / Double(buckets)
        var consumed: Int64 = 0
        while consumed < totalFrames {
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                break
            }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let channelData = buffer.floatChannelData else { break }
            let channelCount = Int(buffer.format.channelCount)
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<channelCount {
                    let v = abs(channelData[c][i])
                    if v > s { s = v }
                }
                let absFrame = Double(consumed + Int64(i))
                let bucket = min(buckets - 1, Int(absFrame / bucketSize))
                if s > peaks[bucket] { peaks[bucket] = s }
            }
            consumed += Int64(n)
        }
        // Clamp to [0, 1].
        for i in 0..<peaks.count {
            if peaks[i] > 1 { peaks[i] = 1 }
            if peaks[i] < 0 { peaks[i] = 0 }
        }
        return Waveform(peaks: peaks)
    }

    // MARK: - Video thumbnails

    private nonisolated static func generateThumbnails(url: URL, count: Int, heightPx: Int) async -> ThumbStrip? {
        // AVFoundation can't open MXF — decode filmstrip frames with the
        // native demuxer instead.
        if url.pathExtension.lowercased() == "mxf" {
            return await generateMXFThumbnails(url: url, count: count, heightPx: heightPx)
        }
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            return nil
        }
        let totalSeconds = duration.seconds
        guard totalSeconds.isFinite, totalSeconds > 0, count > 0 else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 0, height: CGFloat(heightPx) * 2)
        // Loose tolerance — quality-of-life over frame-exact accuracy
        // when scrubbing a timeline strip.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 0.25, preferredTimescale: 600)

        var times: [CMTime] = []
        if count == 1 {
            times.append(CMTime(seconds: totalSeconds / 2, preferredTimescale: 600))
        } else {
            for i in 0..<count {
                let f = Double(i) / Double(count - 1)
                let t = min(max(0, totalSeconds * f), totalSeconds)
                times.append(CMTime(seconds: t, preferredTimescale: 600))
            }
        }

        var images: [CGImage] = []
        images.reserveCapacity(count)
        for time in times {
            do {
                let result = try await generator.image(at: time)
                images.append(result.image)
            } catch {
                continue
            }
        }
        guard !images.isEmpty else { return nil }
        return ThumbStrip(images: images)
    }

    /// MXF filmstrip thumbnails via the native demuxer — N evenly-spaced
    /// decoded frames scaled to `heightPx`. Runs on a background task; the
    /// per-frame seek+decode is fine off the playback path.
    private nonisolated static func generateMXFThumbnails(url: URL, count: Int, heightPx: Int) async -> ThumbStrip? {
        guard count > 0, let src = try? await MXFFrameSource.load(url: url) else { return nil }
        defer { src.tearDown() }
        let dur = src.durationSeconds
        guard dur > 0 else { return nil }
        let ci = CIContext(options: [.cacheIntermediates: false])
        var images: [CGImage] = []
        images.reserveCapacity(count)
        for i in 0..<count {
            let f = count == 1 ? 0.5 : Double(i) / Double(count - 1)
            let t = min(max(0, dur * f), dur)
            do {
                try await src.seek(to: CMTime(seconds: t, preferredTimescale: 600))
                guard let frame = try await src.nextFrame() else { continue }
                let full = CIImage(cvPixelBuffer: frame.pixelBuffer)
                let scale = full.extent.height > 0 ? CGFloat(heightPx * 2) / full.extent.height : 1
                let scaled = full.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                if let cg = ci.createCGImage(scaled, from: scaled.extent) { images.append(cg) }
            } catch { continue }
        }
        return images.isEmpty ? nil : ThumbStrip(images: images)
    }
}
