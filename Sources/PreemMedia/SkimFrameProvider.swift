import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import PreemCore
import PolymergePlayback

/// Fast still-frame source for skimming / scrubbing / paused display.
///
/// Uses a single reused `AVAssetImageGenerator` (random-access friendly,
/// async, and cancelable — unlike the PPE playback decoder, which is built
/// for *sequential* decode and pays a cold-reader rebuild on every scrub
/// seek). Requests are coalesced (only the latest matters) and results are
/// cached so re-visiting a position is instant. The playback decoder is
/// reserved for actual playback.
///
/// `bestAvailable` always returns *something* to draw immediately — exact
/// cached frame, nearest cached frame, or the nearest low-res thumbnail —
/// so the viewer is never black while a sharper frame decodes.
@MainActor
public final class SkimFrameProvider {
    public init() {}

    // One generator at a time — skim is single-clip. Frames stay cached
    // per clip so switching back is still instant.
    private var curID: ClipID?
    private var curURL: URL?
    private var curGen: AVAssetImageGenerator?

    // Frame cache: clipID -> (timeBucket -> image), bounded by `cap`.
    private var cache: [ClipID: [Int: CGImage]] = [:]
    private var order: [(ClipID, Int)] = []
    private let cap = 256

    private var token: Int = 0
    private let bucketStep = 0.05   // cache granularity, seconds

    // MXF still path: AVAssetImageGenerator can't open MXF, so decode
    // stills with the native demuxer (one source at a time, serialized,
    // latest-request-wins) and convert to CGImage via Core Image.
    private var mxfSrc: MXFFrameSource?
    private var mxfID: ClipID?
    private var mxfBusy = false
    private var mxfPending: (clip: ClipSource, seconds: Double, bucket: Int, token: Int, completion: (CGImage) -> Void)?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private func bucket(_ s: Double) -> Int { Int((max(0, s) / bucketStep).rounded()) }

    private func generator(for clip: ClipSource) -> AVAssetImageGenerator {
        if curID == clip.id, curURL == clip.url, let g = curGen { return g }
        curGen?.cancelAllCGImageGeneration()
        let asset = AVURLAsset(url: clip.url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 0, height: 720)
        // Modest tolerance keeps generation snappy for skimming; the cache
        // + thumbnail seed cover the rest.
        g.requestedTimeToleranceBefore = CMTime(seconds: 0.12, preferredTimescale: 600)
        g.requestedTimeToleranceAfter  = CMTime(seconds: 0.12, preferredTimescale: 600)
        curGen = g; curID = clip.id; curURL = clip.url
        return g
    }

    private func cached(_ id: ClipID, _ b: Int) -> CGImage? { cache[id]?[b] }

    private func store(_ id: ClipID, _ b: Int, _ img: CGImage) {
        if cache[id] == nil { cache[id] = [:] }
        if cache[id]![b] == nil { order.append((id, b)) }
        cache[id]![b] = img
        while order.count > cap {
            let (oid, ob) = order.removeFirst()
            cache[oid]?[ob] = nil
        }
    }

    /// Synchronous best guess so the viewer can draw immediately:
    /// exact cached bucket → nearest cached bucket (within ~0.4s) →
    /// nearest of the supplied low-res thumbnails. Never returns nil
    /// when thumbnails are present.
    public func bestAvailable(clip: ClipSource, seconds: Double, thumbnails: [CGImage]) -> CGImage? {
        let b = bucket(seconds)
        if let img = cached(clip.id, b) { return img }
        if let buckets = cache[clip.id], !buckets.isEmpty,
           let nearest = buckets.keys.min(by: { abs($0 - b) < abs($1 - b) }),
           abs(nearest - b) <= 8 {
            return buckets[nearest]
        }
        if !thumbnails.isEmpty {
            let dur = max(0.001, clip.duration.seconds)
            let frac = max(0, min(1, seconds / dur))
            let idx = min(thumbnails.count - 1, Int((frac * Double(thumbnails.count - 1)).rounded()))
            return thumbnails[idx]
        }
        return nil
    }

    /// Decode a sharp frame asynchronously. Coalesced: an in-flight decode
    /// for the same clip is canceled, and only the latest request's result
    /// is delivered (`completion` fires on the main actor). Cached for
    /// instant re-visits.
    public func requestSharp(clip: ClipSource, seconds: Double, completion: @escaping (CGImage) -> Void) {
        let b = bucket(seconds)
        if let img = cached(clip.id, b) { completion(img); return }
        token &+= 1
        let myToken = token
        if clip.url.pathExtension.lowercased() == "mxf" {
            requestMXF(clip: clip, seconds: seconds, bucket: b, token: myToken, completion: completion)
            return
        }
        let gen = generator(for: clip)
        gen.cancelAllCGImageGeneration()
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: t)]) { [weak self] _, image, _, result, _ in
            guard let image, result == .succeeded else { return }
            Task { @MainActor in
                guard let self else { return }
                self.store(clip.id, b, image)
                if myToken == self.token { completion(image) }
            }
        }
    }

    // MARK: - MXF still decode

    private func requestMXF(clip: ClipSource, seconds: Double, bucket b: Int, token myToken: Int,
                            completion: @escaping (CGImage) -> Void) {
        // One decode at a time; keep only the latest pending request.
        if mxfBusy {
            mxfPending = (clip, seconds, b, myToken, completion)
            return
        }
        mxfBusy = true
        Task { @MainActor in
            await self.decodeMXF(clip: clip, seconds: seconds, bucket: b, token: myToken, completion: completion)
            self.mxfBusy = false
            if let p = self.mxfPending {
                self.mxfPending = nil
                self.requestMXF(clip: p.clip, seconds: p.seconds, bucket: p.bucket, token: p.token, completion: p.completion)
            }
        }
    }

    private func decodeMXF(clip: ClipSource, seconds: Double, bucket b: Int, token myToken: Int,
                           completion: @escaping (CGImage) -> Void) async {
        guard let src = await ensureMXF(clip) else { return }
        do {
            try await src.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
            if let f = try await src.nextFrame(), let img = cgImage(from: f.pixelBuffer) {
                store(clip.id, b, img)
                if myToken == token { completion(img) }
            }
        } catch { /* skip — best effort */ }
    }

    private func ensureMXF(_ clip: ClipSource) async -> MXFFrameSource? {
        if mxfID == clip.id, let s = mxfSrc { return s }
        mxfSrc?.tearDown()
        mxfSrc = nil; mxfID = nil
        if let s = try? await MXFFrameSource.load(url: clip.url) {
            mxfSrc = s; mxfID = clip.id
            return s
        }
        return nil
    }

    private func cgImage(from pb: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pb)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    public func clear() {
        curGen?.cancelAllCGImageGeneration()
        curGen = nil; curID = nil; curURL = nil
        mxfSrc?.tearDown(); mxfSrc = nil; mxfID = nil; mxfPending = nil
        cache.removeAll(); order.removeAll()
    }
}
