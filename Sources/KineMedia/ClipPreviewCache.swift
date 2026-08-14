import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import KineCore
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

    private var waveformQueue: [(ClipID, URL, Int)] = []
    private var waveformJobRunning = false

    public func ensureWaveform(clipID: ClipID, url: URL, buckets: Int = 2000) {
        if waveforms[clipID] != nil || inFlightWaveforms.contains(clipID) { return }
        inFlightWaveforms.insert(clipID)
        waveformQueue.append((clipID, url, buckets))
        pumpWaveformQueue()
    }

    private func pumpWaveformQueue() {
        guard !waveformJobRunning, !waveformQueue.isEmpty else { return }
        waveformJobRunning = true
        let (clipID, url, buckets) = waveformQueue.removeFirst()
        Task.detached(priority: .utility) {
            let result = Self.generateWaveform(url: url, buckets: buckets)
            await MainActor.run {
                self.inFlightWaveforms.remove(clipID)
                if let result { self.waveforms[clipID] = result }
                self.version &+= 1
                self.onChange?()
                self.waveformJobRunning = false
                self.pumpWaveformQueue()
            }
        }
    }

    /// Clips whose generation failed. Without this, every UI pass retried
    /// the same failing clip forever - an odd-height video whose frames
    /// cannot convert (VT/IOSurface err -536870206) burned CPU until the
    /// app hung (user report, 0.1.4).
    private var failedThumbs: Set<ClipID> = []

    /// Strictly one clip generating at a time. A folder with dozens of
    /// videos used to launch every thumbnail+waveform job at once - each
    /// spins VideoToolbox sessions, and the shared VTDecoderXPCService
    /// ballooned to thousands of threads, hitching video playback in
    /// EVERY app on the machine (Safari included).
    private var thumbQueue: [(ClipID, URL, Int, Int)] = []
    private var thumbJobRunning = false

    public func ensureThumbnails(clipID: ClipID, url: URL, count: Int = 24, heightPx: Int = 80) {
        if thumbs[clipID] != nil || inFlightThumbs.contains(clipID) || failedThumbs.contains(clipID) { return }
        inFlightThumbs.insert(clipID)
        thumbQueue.append((clipID, url, count, heightPx))
        pumpThumbQueue()
    }

    private func pumpThumbQueue() {
        guard !thumbJobRunning, !thumbQueue.isEmpty else { return }
        thumbJobRunning = true
        let (clipID, url, count, heightPx) = thumbQueue.removeFirst()
        Task.detached(priority: .utility) {
            let result = await Self.generateThumbnails(url: url, count: count, heightPx: heightPx)
            await MainActor.run {
                self.inFlightThumbs.remove(clipID)
                if let result {
                    self.thumbs[clipID] = result
                } else {
                    self.failedThumbs.insert(clipID)
                }
                self.version &+= 1
                self.onChange?()
                self.thumbJobRunning = false
                self.pumpThumbQueue()
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
        // Even dimensions only: odd-height outputs hit a VT/IOSurface
        // conversion bug on some sources ('422f' 202x135 -> RGBA 202x136).
        generator.maximumSize = CGSize(width: 0, height: CGFloat((heightPx * 2) & ~1))
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
}
