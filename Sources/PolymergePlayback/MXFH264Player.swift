import AVFoundation
import CoreMedia
import VideoToolbox
import PolymergeIngest

/// Native H.264-in-MXF playback engine. Given an `MXFEssenceReader.Index`
/// and the source MXF URL, pulls frame payloads, converts them from
/// Annex B to AVCC format (what VideoToolbox expects), and feeds them
/// to an `AVSampleBufferDisplayLayer` which dispatches to Apple's
/// hardware H.264 decoder. No ffmpeg transcoding, no disk cache,
/// no Pro Video Formats dependency — this is the same path Premiere /
/// Resolve / Avid take internally for MXF playback.
///
/// **Pipeline.**
/// 1. **Once per file**: parse the first frame's NAL units, extract
///    SPS (NAL type 7) and PPS (NAL type 8), build an `avcC` extradata
///    blob, construct a `CMVideoFormatDescription` with that blob.
///    VideoToolbox uses the format description to set up its decoder
///    session.
/// 2. **Per frame**: read the KLV payload from disk, strip AUD (NAL
///    type 9) and SPS/PPS (already in the format description, don't
///    want duplicates in every sample), convert the remaining slice
///    NALs from Annex B (start codes) to AVCC (4-byte big-endian
///    length prefix), wrap in a `CMBlockBuffer` + `CMSampleTimingInfo`,
///    and enqueue on the display layer.
///
/// **What's handled.** Canon XF-AVC (H.264 High 4:2:2 Intra), Sony
/// XAVC-I / XAVC-L, Panasonic AVC-Intra 100 / 200. All three
/// encode to vanilla H.264 bitstreams inside MXF — the container
/// differs but the NAL-stream decoding is identical.
///
/// **What's NOT handled yet (future milestones).**
/// - ProRes-in-MXF (different sample buffer construction — no SPS/PPS,
///   different FourCC)
/// - Audio decoding (MXF audio is typically PCM, trivial to extract
///   but that's a separate pipeline)
/// - Precise frame-rate timing (we use `CMSampleTimingInfo` with a
///   fixed 24000/1001 rate for now; will thread the real rate through)
public final class MXFH264Player {

    // MARK: - Inputs

    private let url: URL
    private let index: MXFEssenceReader.Index
    private let formatDescription: CMVideoFormatDescription

    // MARK: - Outputs

    /// The Core Animation layer to install in the player view.
    /// We own this — the view's `NSView.layer` is set to point at
    /// this instance so `enqueue(_:)` updates are displayed.
    public let displayLayer = AVSampleBufferDisplayLayer()

    /// Pixel dimensions parsed from the H.264 SPS via the
    /// CMVideoFormatDescription we built. Use this to populate UI
    /// metadata panels — AVAsset can't open the MXF so its
    /// AVAssetTrack.naturalSize would throw, and the essence
    /// reader only has byte offsets.
    public var pixelDimensions: CGSize {
        let dims = CMVideoFormatDescriptionGetDimensions(formatDescription)
        return CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
    }

    /// Nominal frame rate as a double — recomputed from the
    /// rational the player was initialized with so UI layers
    /// don't have to guess or re-round.
    public var nominalFrameRate: Double {
        Double(frameRateNum) / Double(frameRateDen)
    }

    /// Duration in seconds from frame count + frame rate. Same
    /// source of truth the playback clock uses.
    public var durationSeconds: Double {
        Double(index.frames.count) / nominalFrameRate
    }

    /// Human-readable codec label for the UI. H.264 for now;
    /// will expand once ProRes-in-MXF is wired.
    public var codecLabel: String { index.codec.displayName }

    // MARK: - Playback state

    /// CMTimebase bound to the display layer's `controlTimebase`.
    /// Drives the playback clock: we set `rate = 1.0` to play,
    /// `rate = 0.0` to pause, and use `CMTimebaseSetTime` to seek.
    /// The display layer renders each enqueued sample at its
    /// `presentationTimeStamp` relative to this timebase — no
    /// manual Timer, no drift, no per-tick jitter.
    private let timebase: CMTimebase

    /// Frame rate as a rational (numerator / denominator) so the
    /// CMTime we build for each frame's PTS is exact. Default is
    /// 24000/1001 (23.976). Future work: read this from the MXF
    /// Picture Essence Descriptor instead of assuming.
    private let frameRateNum: Int32
    private let frameRateDen: Int32

    /// Frame index we'll enqueue NEXT. Bumped by the background
    /// enqueue loop. Reset by `seek(toFrame:)` which also flushes
    /// the display layer and sets a new timebase time.
    private var nextFrameToEnqueue: Int = 0

    /// Dedicated queue for the background enqueue loop. The
    /// `AVSampleBufferDisplayLayer.requestMediaDataWhenReady`
    /// contract dispatches a block onto this queue each time the
    /// layer is ready for more data. We read from disk + build
    /// sample buffers there, never blocking the main thread.
    private let enqueueQueue = DispatchQueue(label: "polymerge.mxf.h264.enqueue", qos: .userInitiated)

    /// Reusable FileHandle so we don't open/close per frame read.
    /// Owned by the enqueue loop — only touched on `enqueueQueue`.
    private var readHandle: FileHandle?

    /// Latch so we only install the `requestMediaDataWhenReady`
    /// loop once. Subsequent seek/play calls just tweak the
    /// timebase.
    private var enqueueLoopInstalled = false

    // MARK: - Init

    /// Create a player. Throws if the MXF's first frame doesn't
    /// contain usable SPS+PPS (can happen on non-H.264 codecs or
    /// on exotic MXF files where parameter sets live in the
    /// header metadata instead of in-band).
    public init(url: URL, index: MXFEssenceReader.Index, frameRateOverride: Double? = nil) throws {
        self.url = url
        self.index = index
        // Frame rate priority:
        //   1. MXF Picture Essence Descriptor's SampleRate (the
        //      authoritative answer — covers 23.976, 25, 29.97, 30,
        //      50, 59.94, 60 as exact rationals).
        //   2. Caller-provided override (for tests / debugging).
        //   3. 24000/1001 fallback (sensible guess when the
        //      descriptor can't be read on a non-standard MXF).
        var resolvedNum: Int32 = 24000
        var resolvedDen: Int32 = 1001
        // `try?` on a function that returns `Result?` yields
        // `Result??` — flatten and bind to a single optional.
        if let rate = (try? MXFPictureDescriptorReader.read(url: url)).flatMap({ $0 }),
           rate.sampleRateNum > 0, rate.sampleRateDen > 0 {
            resolvedNum = rate.sampleRateNum
            resolvedDen = rate.sampleRateDen
            print("[MXFH264] descriptor rate \(rate.sampleRateNum)/\(rate.sampleRateDen) = \(String(format: "%.3f", rate.frameRate)) fps")
        } else if let fps = frameRateOverride {
            let (n, d) = Self.rationalFrameRate(fps: fps)
            resolvedNum = n
            resolvedDen = d
            print("[MXFH264] descriptor unreadable, using caller-provided \(n)/\(d)")
        } else {
            print("[MXFH264] descriptor unreadable, defaulting to 24000/1001")
        }
        self.frameRateNum = resolvedNum
        self.frameRateDen = resolvedDen

        guard case .h264 = index.codec else {
            throw PlayerError.unsupportedCodec(index.codec.displayName)
        }
        guard let firstFrame = index.frames.first else {
            throw PlayerError.emptyIndex
        }
        let firstFrameData = try MXFEssenceReader.readFrame(url: url, ref: firstFrame)
        let nals = AnnexBParser.parse(firstFrameData)
        let sps = nals.first { $0.nalType == 7 }
        let pps = nals.first { $0.nalType == 8 }
        guard let sps, let pps else {
            throw PlayerError.missingParameterSets(
                "first frame has no SPS/PPS — NAL types seen: \(nals.map { $0.nalType })"
            )
        }
        self.formatDescription = try Self.buildFormatDescription(sps: sps.rawBytes, pps: pps.rawBytes)

        // Build a CMTimebase over the host clock. Rate starts at
        // 0 (paused); time starts at 0.
        var tb: CMTimebase?
        let tbStatus = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb
        )
        guard tbStatus == noErr, let tb else {
            throw PlayerError.formatDescriptionFailed(Int(tbStatus))
        }
        CMTimebaseSetRate(tb, rate: 0.0)
        CMTimebaseSetTime(tb, time: .zero)
        self.timebase = tb
        displayLayer.controlTimebase = tb

        print("[MXFH264] initialized — \(index.frames.count) frames, format \(CMVideoFormatDescriptionGetDimensions(formatDescription)), rate \(resolvedNum)/\(resolvedDen)")
    }

    private static func rationalFrameRate(fps: Double) -> (Int32, Int32) {
        // Snap common broadcast rates to their exact rationals.
        let epsilon = 0.01
        let table: [(Double, Int32, Int32)] = [
            (23.976023976, 24000, 1001),
            (24.0, 24, 1),
            (25.0, 25, 1),
            (29.970029970, 30000, 1001),
            (30.0, 30, 1),
            (50.0, 50, 1),
            (59.940059940, 60000, 1001),
            (60.0, 60, 1),
        ]
        for (target, num, den) in table where abs(fps - target) < epsilon {
            return (num, den)
        }
        // Uncommon rate — approximate with timescale 90000 (an
        // MPEG-friendly value that divides evenly by most
        // broadcast rates).
        let timescale: Int32 = 90000
        let duration = Int32((Double(timescale) / fps).rounded())
        return (timescale, duration)
    }

    // MARK: - Playback control

    /// Start playback from the current timebase position. The
    /// display layer's timebase drives frame presentation — we
    /// just make sure the enqueue loop is running and bump the
    /// rate to 1.0.
    public func play() {
        installEnqueueLoopIfNeeded()
        CMTimebaseSetRate(timebase, rate: 1.0)
    }

    public func pause() {
        CMTimebaseSetRate(timebase, rate: 0.0)
    }

    /// Seek to the given frame. Stops playback, flushes the
    /// display layer's queue, resets the timebase, and restarts
    /// the enqueue loop from the target frame.
    public func seek(toFrame frameIndex: Int) {
        let target = max(0, min(frameIndex, index.frames.count - 1))
        pause()
        displayLayer.flushAndRemoveImage()
        enqueueQueue.sync {
            self.nextFrameToEnqueue = target
        }
        let targetTime = CMTime(
            value: Int64(target) * Int64(frameRateDen),
            timescale: frameRateNum
        )
        CMTimebaseSetTime(timebase, time: targetTime)
        installEnqueueLoopIfNeeded()
    }

    /// Show the first frame as a still. Hooks up the enqueue loop
    /// in paused mode so the one frame renders and then the
    /// loop idles waiting for play().
    public func showFirstFrame() {
        seek(toFrame: 0)
    }

    // MARK: - Enqueue loop

    /// Install the `requestMediaDataWhenReady` loop on our
    /// dedicated queue. AVSampleBufferDisplayLayer calls back
    /// whenever its internal ready-queue drops below the high-
    /// water mark, which is exactly when we should decode +
    /// enqueue the next frame. The system handles the pacing —
    /// we just keep supplying frames as long as
    /// `isReadyForMoreMediaData` is true.
    private func installEnqueueLoopIfNeeded() {
        guard !enqueueLoopInstalled else { return }
        enqueueLoopInstalled = true
        displayLayer.requestMediaDataWhenReady(on: enqueueQueue) { [weak self] in
            guard let self else { return }
            while self.displayLayer.isReadyForMoreMediaData {
                let idx = self.nextFrameToEnqueue
                if idx >= self.index.frames.count {
                    // Reached the end. Stop the request loop so
                    // we're not burning CPU polling. Caller can
                    // seek back to restart.
                    self.displayLayer.stopRequestingMediaData()
                    self.enqueueLoopInstalled = false
                    return
                }
                do {
                    let sb = try self.buildSampleBufferForFrame(at: idx)
                    self.displayLayer.enqueue(sb)
                    self.nextFrameToEnqueue = idx + 1
                } catch {
                    print("[MXFH264] enqueue failed at frame \(idx): \(error.localizedDescription)")
                    self.nextFrameToEnqueue = idx + 1
                }
            }
        }
    }

    /// Build a `CMSampleBuffer` for a specific frame index. Uses
    /// the cached `readHandle` so we avoid open/close cost
    /// between frames.
    private func buildSampleBufferForFrame(at idx: Int) throws -> CMSampleBuffer {
        let ref = index.frames[idx]
        if readHandle == nil {
            readHandle = try? FileHandle(forReadingFrom: url)
        }
        guard let handle = readHandle else {
            throw PlayerError.sampleBufferFailed(-1)
        }
        try handle.seek(toOffset: ref.payloadOffset)
        guard let raw = try handle.read(upToCount: Int(ref.payloadLength)),
              raw.count == Int(ref.payloadLength) else {
            throw PlayerError.sampleBufferFailed(-2)
        }
        // Exact PTS = idx * (1/fps). With rational frame rate
        // (24000/1001) this gives sample-accurate presentation
        // timestamps that the timebase can match to host time.
        let pts = CMTime(
            value: Int64(idx) * Int64(frameRateDen),
            timescale: frameRateNum
        )
        return try buildSampleBuffer(for: raw, presentationTime: pts)
    }

    // MARK: - Format description (SPS + PPS → avcC)

    /// Build a `CMVideoFormatDescription` for H.264 decoding from
    /// Annex-B-formatted SPS and PPS NAL unit bytes (the raw NAL
    /// including the 1-byte NAL header, without start codes).
    private static func buildFormatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        let spsPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: sps.count)
        sps.copyBytes(to: spsPtr, count: sps.count)
        defer { spsPtr.deallocate() }
        let ppsPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: pps.count)
        pps.copyBytes(to: ppsPtr, count: pps.count)
        defer { ppsPtr.deallocate() }

        let pointers: [UnsafePointer<UInt8>] = [
            UnsafePointer(spsPtr),
            UnsafePointer(ppsPtr)
        ]
        let sizes: [Int] = [sps.count, pps.count]

        var fmt: CMVideoFormatDescription?
        let status = pointers.withUnsafeBufferPointer { ptrBuf in
            sizes.withUnsafeBufferPointer { sizeBuf in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: ptrBuf.baseAddress!,
                    parameterSetSizes: sizeBuf.baseAddress!,
                    nalUnitHeaderLength: 4, // AVCC uses 4-byte length prefix
                    formatDescriptionOut: &fmt
                )
            }
        }
        guard status == noErr, let fmt else {
            throw PlayerError.formatDescriptionFailed(Int(status))
        }
        return fmt
    }

    // MARK: - Sample buffer construction

    /// Convert one Annex-B frame payload to a `CMSampleBuffer`
    /// that VideoToolbox can decode + display. Strips AUD / SPS /
    /// PPS (they're already in the format description — including
    /// them in every sample causes some decoders to choke), and
    /// rewrites slice NALs from Annex B start codes to 4-byte
    /// big-endian length prefixes (AVCC format).
    private func buildSampleBuffer(
        for annexBData: Data,
        presentationTime: CMTime
    ) throws -> CMSampleBuffer {
        let nals = AnnexBParser.parse(annexBData)
        // Keep only picture slice NALs. Discard AUD (9), SPS (7),
        // PPS (8), Filler (12), End of Stream/Sequence (10,11).
        // Keep SEI (6) since it can carry timing / color info the
        // decoder may use.
        let sliceNALs = nals.filter { nal in
            switch nal.nalType {
            case 1, 5, 6, 19, 20: return true
            default: return false
            }
        }
        guard !sliceNALs.isEmpty else {
            throw PlayerError.noSliceNAL(
                "frame has no slice NAL — types: \(nals.map { $0.nalType })"
            )
        }
        // Build AVCC payload: for each NAL, 4-byte big-endian
        // length followed by the NAL bytes.
        var avcc = Data()
        avcc.reserveCapacity(annexBData.count)
        for nal in sliceNALs {
            let n = UInt32(nal.rawBytes.count)
            let bytes: [UInt8] = [
                UInt8((n >> 24) & 0xFF),
                UInt8((n >> 16) & 0xFF),
                UInt8((n >> 8) & 0xFF),
                UInt8(n & 0xFF)
            ]
            avcc.append(contentsOf: bytes)
            avcc.append(nal.rawBytes)
        }

        // Allocate a CMBlockBuffer and copy the AVCC bytes in.
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw PlayerError.blockBufferFailed(Int(blockStatus))
        }
        let copyStatus = avcc.withUnsafeBytes { bufPtr -> OSStatus in
            guard let base = bufPtr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw PlayerError.blockBufferFailed(Int(copyStatus))
        }

        // Exact frame duration as a rational so the timebase can
        // schedule each sample precisely. For 23.976 fps the
        // duration is 1001/24000 sec per frame.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: Int64(frameRateDen), timescale: frameRateNum),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSizes: [Int] = [avcc.count]
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizes,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else {
            throw PlayerError.sampleBufferFailed(Int(sbStatus))
        }
        // Deliberately NOT setting `kCMSampleAttachmentKey_
        // DisplayImmediately`. The whole point of the control
        // timebase is that samples render at their PTS relative
        // to the timebase's clock — display-immediately would
        // render frames as fast as we enqueue, which is exactly
        // the drift we're trying to avoid.
        //
        // **But DO mark every frame as a key frame / independent.**
        // Canon XF-AVC + Sony XAVC-Intra + Panasonic AVC-Intra
        // are ALL intra-only H.264 (no P/B frames), so each NAL
        // slice can decode without the previous one. Without
        // these attachments VT assumes a mixed-GOP bitstream and
        // serializes decode, which gates throughput to single-
        // threaded speed on 4K Intra streams. IsDependedOnBy-
        // Others=false lets VT drop stale frames when the play
        // rate pushes past the decoder's throughput instead of
        // stacking up latency.
        if let attach = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attach) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attach, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanFalse).toOpaque()
            )
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanFalse).toOpaque()
            )
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_IsDependedOnByOthers).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanFalse).toOpaque()
            )
        }
        return sampleBuffer
    }

    // MARK: - Errors

    public enum PlayerError: LocalizedError {
        case unsupportedCodec(String)
        case emptyIndex
        case missingParameterSets(String)
        case formatDescriptionFailed(Int)
        case blockBufferFailed(Int)
        case sampleBufferFailed(Int)
        case noSliceNAL(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedCodec(let s):
                return "MXFH264Player only handles H.264; got \(s)"
            case .emptyIndex:
                return "MXF has no video frames"
            case .missingParameterSets(let why):
                return "No SPS/PPS in first frame. \(why)"
            case .formatDescriptionFailed(let code):
                return "CMVideoFormatDescriptionCreateFromH264ParameterSets failed (\(code))"
            case .blockBufferFailed(let code):
                return "CMBlockBufferCreate failed (\(code))"
            case .sampleBufferFailed(let code):
                return "CMSampleBufferCreate failed (\(code))"
            case .noSliceNAL(let why):
                return "Frame has no slice NAL. \(why)"
            }
        }
    }
}

// MARK: - Annex B parser

/// Split an Annex B bitstream into individual NAL units. Start
/// codes are `00 00 00 01` (4-byte) or `00 00 01` (3-byte). Each
/// NAL's raw bytes include the 1-byte NAL header but NOT the
/// start code.
enum AnnexBParser {
    struct NALUnit {
        let rawBytes: Data   // excluding start code; first byte is NAL header
        var nalType: UInt8 { rawBytes.first.map { $0 & 0x1F } ?? 0 }
    }

    static func parse(_ data: Data) -> [NALUnit] {
        var units: [NALUnit] = []
        var i = 0
        let n = data.count
        var nalStart: Int? = nil

        func consumeStartCode(at pos: Int) -> Int? {
            if pos + 3 < n,
               data[pos] == 0x00, data[pos + 1] == 0x00,
               data[pos + 2] == 0x00, data[pos + 3] == 0x01 {
                return pos + 4
            }
            if pos + 2 < n,
               data[pos] == 0x00, data[pos + 1] == 0x00, data[pos + 2] == 0x01 {
                return pos + 3
            }
            return nil
        }

        while i < n {
            if let next = consumeStartCode(at: i) {
                if let start = nalStart {
                    // NAL ends at i (start of the next start code).
                    let nalData = data.subdata(in: start..<i)
                    if !nalData.isEmpty {
                        units.append(NALUnit(rawBytes: nalData))
                    }
                }
                nalStart = next
                i = next
                continue
            }
            i += 1
        }
        // Final NAL extends to end of buffer.
        if let start = nalStart, start < n {
            let nalData = data.subdata(in: start..<n)
            if !nalData.isEmpty {
                units.append(NALUnit(rawBytes: nalData))
            }
        }
        return units
    }
}
