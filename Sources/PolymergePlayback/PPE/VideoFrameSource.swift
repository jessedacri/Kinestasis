import AVFoundation
import CoreMedia
import CoreVideo

/// One decoded video frame delivered by a `VideoFrameSource`.
/// The `CVPixelBuffer` is suitable for direct upload to a Metal
/// texture via `CVMetalTextureCache`.
///
/// Pixel buffers are reference-counted by Core Video; consumers
/// should release them back into the pool promptly after they've
/// been uploaded / composited to avoid starving the decoder.
public struct PPEDecodedFrame {
    /// Presentation timestamp of this frame, in the source's
    /// native timebase (typically the asset's natural timescale).
    public let pts: CMTime
    /// Frame duration. For constant-frame-rate sources this is
    /// always the same value (1/fps); for VFR this is the actual
    /// inter-frame gap.
    public let duration: CMTime
    /// Decoded pixel data. Format depends on the source's output
    /// settings — the AVAsset-backed source always produces
    /// 32BGRA for easy Metal upload.
    public let pixelBuffer: CVPixelBuffer

    public init(pts: CMTime, duration: CMTime, pixelBuffer: CVPixelBuffer) {
        self.pts = pts
        self.duration = duration
        self.pixelBuffer = pixelBuffer
    }
}

/// Source of decoded video frames for the PolyMerge Playback
/// Engine (PPE). Implementations wrap a specific container /
/// decoder combination: AVAssetReader for MOV/MP4/M4V, our
/// native MXF demuxer for Canon XF-AVC / Sony XAVC / ARRI
/// ProRes-in-MXF, etc.
///
/// **Threading model.** `nextFrame()` and `seek(to:)` are
/// `async` and safe to call from any task; implementations
/// serialize internally. The background decoder in M2 will own
/// one `VideoFrameSource` per active video, pull frames on a
/// dedicated task, and feed the ring buffer.
///
/// **Sequential vs. random access.** The expected access pattern
/// is "seek once to a start position, then pull `nextFrame()`
/// until the consumer (display driver) stops asking." Random
/// access (arbitrary `frame(at:)`) is possible via `seek` +
/// `nextFrame` but is costlier because it flushes decode state.
public protocol VideoFrameSource: AnyObject, Sendable {
    /// Total duration of the source, in seconds. Stable across
    /// the lifetime of the instance.
    var durationSeconds: Double { get }

    /// Nominal frame rate (e.g. 23.976, 29.97, 60). Used by the
    /// display driver to estimate PTS for frame selection.
    var nominalFrameRate: Double { get }

    /// Natural pixel dimensions (before any scaling for display).
    var pixelDimensions: CGSize { get }

    /// Prepare decode state so the next `nextFrame()` call returns
    /// the frame at or just before `time`. Flushes any in-flight
    /// decode. Must be called before the first `nextFrame()` of a
    /// new playback session. Safe to call while `nextFrame()` is
    /// running on another task — the frame source serializes
    /// internally.
    func seek(to time: CMTime) async throws

    /// Return the next frame in sequence. After a `seek(to: t)`,
    /// the first call returns the frame at or just before `t`.
    /// Subsequent calls return successive frames. Returns `nil`
    /// when the source is exhausted (EOF).
    func nextFrame() async throws -> PPEDecodedFrame?

    /// Release any held resources (file handles, decoder
    /// sessions, pixel buffer pools). Safe to call multiple
    /// times.
    func tearDown()
}
