import AVFoundation
import CoreMedia
import CoreVideo

/// `VideoFrameSource` implementation for anything AVFoundation's
/// AVAssetReader can open: MOV, MP4, M4V, HEIC sequences, etc.
/// That covers ProRes-in-MOV (the DEMI session case), H.264 MP4
/// from phones / consumer cameras, HEVC from modern iPhones, and
/// everything in between.
///
/// **Why AVAssetReader and not our own VTDecompressionSession.**
/// AVAssetReader wraps a VTDecompressionSession internally and
/// delivers decoded `CVPixelBuffer`s at the output settings we
/// specify. Doing it this way:
///   - Gets us the hardware decode path automatically (same one
///     AVPlayer uses; it's how QuickTime Player plays MOVs
///     smoothly).
///   - Handles format description, parameter set extraction,
///     track reordering, and all the other AVFoundation
///     bookkeeping that our MXF readers had to do by hand.
///   - Lets us request a specific output pixel format so the
///     Metal renderer can skip color-space conversion in the
///     shader. `kCVPixelFormatType_32BGRA` is universally
///     supported + zero-copy into an `MTLTexture` via
///     `CVMetalTextureCache`.
///
/// We keep `MXFH264Player` / `MXFProResPlayer` as their own path
/// because AVAssetReader can't open MXF without Apple's Pro
/// Video Formats package (which is the whole reason we built the
/// native MXF demuxer). In M5 we'll consolidate the MXF path
/// into this same protocol.
///
/// **Threading.** Internal state (reader, output, current PTS)
/// is protected by a serial `DispatchQueue`. `nextFrame()` and
/// `seek(to:)` both dispatch onto it, so concurrent calls from
/// multiple tasks are serialized safely.
public final class AVAssetFrameSource: VideoFrameSource, @unchecked Sendable {

    // MARK: - Immutable metadata

    public let durationSeconds: Double
    public let nominalFrameRate: Double
    public let pixelDimensions: CGSize

    // MARK: - Internal state

    private let url: URL
    private let asset: AVURLAsset
    private let videoTrack: AVAssetTrack
    /// Serial queue for all mutations of `reader` / `output` /
    /// `lastDeliveredPTS`. `nextFrame` and `seek` both hop onto
    /// it via async continuations so we never see torn state.
    private let ioQueue = DispatchQueue(label: "polymerge.ppe.avasset.frame-source")
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// The PTS of the last frame we returned from `nextFrame`.
    /// Used only for diagnostic logging at seek-time; the
    /// reader's internal cursor is the authoritative position.
    private var lastDeliveredPTS: CMTime = .invalid

    // MARK: - Init

    /// Synchronous initializer. Loads track metadata via the
    /// deprecated-but-still-functional sync APIs so that a
    /// non-async caller (e.g. the M4 `CustomVideoPlayer` ctor)
    /// can build one without await. Throws on unreadable files.
    ///
    /// For the common path we load everything async (`loadTracks`,
    /// `load(.duration)`, etc.) via the `async` overload below.
    public static func load(url: URL) async throws -> AVAssetFrameSource {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw FrameSourceError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let naturalSize = try await track.load(.naturalSize)
        let nominalFrameRateValue = try await track.load(.nominalFrameRate)
        return AVAssetFrameSource(
            url: url,
            asset: asset,
            videoTrack: track,
            durationSeconds: CMTimeGetSeconds(duration),
            nominalFrameRate: Double(nominalFrameRateValue),
            pixelDimensions: naturalSize
        )
    }

    private init(
        url: URL,
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        durationSeconds: Double,
        nominalFrameRate: Double,
        pixelDimensions: CGSize
    ) {
        self.url = url
        self.asset = asset
        self.videoTrack = videoTrack
        self.durationSeconds = durationSeconds
        self.nominalFrameRate = nominalFrameRate > 0 ? nominalFrameRate : 24
        self.pixelDimensions = pixelDimensions
    }

    // MARK: - Public API

    /// Configure the reader to start at (or just before) the
    /// given time. Any existing reader/output are torn down and
    /// replaced — AVAssetReader is one-shot per time range, so a
    /// new time range means a new reader.
    public func seek(to time: CMTime) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ioQueue.async {
                do {
                    self.reader?.cancelReading()
                    self.output = nil
                    self.lastDeliveredPTS = .invalid
                    try self.startReader(from: time)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Pull the next frame from the reader. Returns nil at EOF.
    public func nextFrame() async throws -> PPEDecodedFrame? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PPEDecodedFrame?, Error>) in
            ioQueue.async {
                // Lazy-init reader at time 0 for callers that
                // skip the initial seek.
                if self.reader == nil {
                    do {
                        try self.startReader(from: .zero)
                    } catch {
                        cont.resume(throwing: error)
                        return
                    }
                }
                guard let output = self.output else {
                    cont.resume(returning: nil)
                    return
                }
                guard let sb = output.copyNextSampleBuffer() else {
                    // Distinguish EOF from reader-failure. EOF
                    // leaves the reader in `.completed` status;
                    // failure sets `.failed`.
                    if let reader = self.reader, reader.status == .failed {
                        cont.resume(throwing: FrameSourceError.readFailed(
                            reader.error?.localizedDescription ?? "unknown"
                        ))
                        return
                    }
                    cont.resume(returning: nil)
                    return
                }
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sb) else {
                    cont.resume(throwing: FrameSourceError.readFailed("no image buffer in sample"))
                    return
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                let duration = CMSampleBufferGetDuration(sb)
                self.lastDeliveredPTS = pts
                cont.resume(returning: PPEDecodedFrame(
                    pts: pts,
                    duration: duration,
                    pixelBuffer: pixelBuffer
                ))
            }
        }
    }

    public func tearDown() {
        ioQueue.async {
            self.reader?.cancelReading()
            self.reader = nil
            self.output = nil
            self.lastDeliveredPTS = .invalid
        }
    }

    // MARK: - Internals

    /// Build a fresh AVAssetReader starting at `time`. Always
    /// called on `ioQueue`. The time range stretches from `time`
    /// to `.positiveInfinity` so sequential `copyNextSampleBuffer`
    /// delivers every frame from that point until EOF.
    private func startReader(from time: CMTime) throws {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: time,
            duration: .positiveInfinity
        )
        // 32BGRA is the natural pixel format for Metal texture
        // upload via `CVMetalTextureCache` — no color-space
        // conversion in the shader, and it's hardware-accelerated
        // by VT's output pipeline. We deliberately don't cap
        // resolution here; the Metal renderer downscales via GPU
        // at draw time.
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: outputSettings
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw FrameSourceError.readerSetupFailed("reader rejected output")
        }
        reader.add(output)
        guard reader.startReading() else {
            let msg = reader.error?.localizedDescription ?? "unknown reader error"
            throw FrameSourceError.readerSetupFailed(msg)
        }
        self.reader = reader
        self.output = output
    }

    // MARK: - Errors

    public enum FrameSourceError: LocalizedError {
        case noVideoTrack
        case readerSetupFailed(String)
        case readFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "File has no video track"
            case .readerSetupFailed(let s): return "Could not set up video reader: \(s)"
            case .readFailed(let s): return "Video read failed: \(s)"
            }
        }
    }
}
