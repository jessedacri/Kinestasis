import AVFoundation
import CoreMedia

/// Shared surface for the native MXF playback engines
/// (`MXFH264Player`, `MXFProResPlayer`). `VideoPlayerController`
/// holds a protocol-typed reference so it can drive play /
/// pause / seek without caring which codec backs the current
/// file.
///
/// **Why a protocol instead of a base class.** Both players
/// manage their own `AVSampleBufferDisplayLayer` +
/// `CMTimebase` + file handle, but the per-frame sample buffer
/// construction is very different: H.264 needs SPS/PPS extracted
/// once + Annex B→AVCC rewriting per frame; ProRes is raw-frame-
/// in, raw-frame-out with no parameter sets. A protocol keeps
/// the shared contract thin and the codec-specific paths
/// cleanly separated.
public protocol MXFNativePlayer: AnyObject {
    /// Core Animation layer that renders decoded frames. Views
    /// install this as a sublayer or backing layer.
    var displayLayer: AVSampleBufferDisplayLayer { get }
    /// Pixel dimensions for the stream (parsed from the codec's
    /// inline metadata or the MXF picture descriptor).
    var pixelDimensions: CGSize { get }
    /// Frame rate as a double (e.g. 23.976 = 24000/1001).
    var nominalFrameRate: Double { get }
    /// Total duration in seconds (frames / rate).
    var durationSeconds: Double { get }
    /// User-facing codec label ("H.264", "ProRes 422 HQ", etc.).
    var codecLabel: String { get }

    func play()
    func pause()
    func seek(toFrame frameIndex: Int)
    func showFirstFrame()
}

extension MXFH264Player: MXFNativePlayer {}
