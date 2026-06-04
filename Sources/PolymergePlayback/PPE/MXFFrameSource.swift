import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import PolymergeIngest

/// `VideoFrameSource` implementation for MXF containers —
/// Canon XF-AVC / Sony XAVC / Panasonic AVC-Intra (H.264) and
/// ARRI ProRes-in-MXF. Unifies the two codec-specific
/// `MXFH264Player` / `MXFProResPlayer` classes into the PPE
/// pipeline. Same public surface as `AVAssetFrameSource`: the
/// `CustomVideoPlayer` controller doesn't care which concrete
/// source is running.
///
/// **Why a second frame-source type** instead of reusing
/// `AVAssetFrameSource`. AVFoundation can't open MXF without
/// Apple's Pro Video Formats package (optional download; many
/// users don't have it). The native path reuses the work
/// already done by `MXFEssenceReader` (KLV demux + codec
/// classification), `MXFPictureDescriptorReader` (exact
/// rational frame rate), and `MXFSoundDescriptorReader`
/// (audio for extraction, not needed here), then feeds decoded
/// frames to a `VTDecompressionSession` the same way AVPlayer
/// would internally.
///
/// **Decode model**: one VT session per file, long-lived.
/// `nextFrame()` reads the next frame's bytes from disk, wraps
/// in a `CMSampleBuffer`, submits to VT with a completion
/// continuation, and returns the resulting `CVPixelBuffer` +
/// synthesized PTS (MXF video essence is CBR at the descriptor
/// rate, so PTS = `index * frameRateDen / frameRateNum`).
///
/// **Seek**: binary fast path — compute the target frame index
/// from `time`, set `nextFrameIndex`, and invalidate the VT
/// session on H.264 (the new frame may be an I-frame that
/// requires re-submitting SPS/PPS context). ProRes is intra-
/// only so no flush is needed; we just advance the cursor.
public final class MXFFrameSource: VideoFrameSource, @unchecked Sendable {

    public let durationSeconds: Double
    public let nominalFrameRate: Double
    public let pixelDimensions: CGSize

    private let url: URL
    private let index: MXFEssenceReader.Index
    private let formatDescription: CMVideoFormatDescription
    private let codec: CodecKind
    private let frameRateNum: Int32
    private let frameRateDen: Int32
    private let ioQueue = DispatchQueue(label: "polymerge.mxf.frame-source")
    private var vtSession: VTDecompressionSession?
    private var readHandle: FileHandle?

    // Decode-ahead pipeline (async VT). All-Intra H.264 / ProRes have no
    // frame reordering, so VT outputs are keyed by frame index and consumed
    // in order. Submitting several frames before consuming lets the Media
    // Engine overlap decodes (sync one-at-a-time capped throughput at ~24fps;
    // pipelining pushes well past real-time). All mutated on `ioQueue`.
    private var consumeIndex = 0          // next index the consumer wants
    private var readIndex = 0             // next index to read + submit
    private var inFlight = 0              // submitted, awaiting callback
    private var ready: [Int: PPEDecodedFrame] = [:]
    private let maxAhead = 4
    private var pendingCont: (index: Int, cont: CheckedContinuation<PPEDecodedFrame?, Error>)?
    private var seekGen = 0               // bumped on seek/teardown; stale callbacks no-op

    // H.264 streams can carry IN-BAND parameter sets that change mid-clip —
    // e.g. footage redacted by re-encoding a section with a different SPS/PPS
    // that reuses sps_id/pps_id 0. Decoding such a frame against frame 0's
    // format description yields garbage. So we build a format description from
    // EACH frame's own SPS/PPS (cached by parameter-set bytes) and recreate the
    // VT session whenever it changes. `currentSessionFormat` is the format the
    // live session was built for. All mutated on `ioQueue`.
    private var currentSessionFormat: CMVideoFormatDescription?
    private var formatCache: [Data: CMVideoFormatDescription] = [:]

    enum CodecKind {
        case h264
        case prores
    }

    // MARK: - Load

    public static func load(url: URL) async throws -> MXFFrameSource {
        // Essence scan runs on a detached task — KLV header
        // walk is fast (< 100 ms typical) but ARRI OP1a takes
        // with huge essence bodies can run longer; don't block
        // the caller's thread.
        let index: MXFEssenceReader.Index = try await Task.detached(priority: .userInitiated) {
            try MXFEssenceReader.scanIndex(url: url)
        }.value

        guard !index.frames.isEmpty else {
            throw FrameSourceError.noVideoTrack
        }

        let codec: CodecKind
        var fmt: CMVideoFormatDescription
        var resolvedDims: CMVideoDimensions? = nil

        switch index.codec {
        case .h264:
            codec = .h264
            let firstFrameData = try MXFEssenceReader.readFrame(url: url, ref: index.frames[0])
            let nals = AnnexBParser.parse(firstFrameData)
            guard let sps = nals.first(where: { $0.nalType == 7 }),
                  let pps = nals.first(where: { $0.nalType == 8 }) else {
                throw FrameSourceError.readerSetupFailed(
                    "no SPS/PPS in first frame — NAL types seen: \(nals.map { $0.nalType })"
                )
            }
            fmt = try Self.buildH264FormatDescription(sps: sps.rawBytes, pps: pps.rawBytes)
        case .prores:
            codec = .prores
            let firstFrameData = (try? MXFEssenceReader.readFrame(url: url, ref: index.frames[0])) ?? Data()
            let fourCC = Self.inferProResFourCC(firstFrameData: firstFrameData)
                ?? kCMVideoCodecType_AppleProRes422HQ
            let (fd, dims) = try Self.buildProResFormatDescription(
                fourCC: fourCC,
                firstFrameData: firstFrameData,
                descriptorURL: url
            )
            fmt = fd
            resolvedDims = dims
        case .unknown(let bytes):
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            throw FrameSourceError.readerSetupFailed("unsupported MXF codec (\(hex))")
        }

        // Rational frame rate from the MXF Picture Essence
        // Descriptor. Fall back to 24000/1001 if the
        // descriptor can't be read (rare but not impossible on
        // non-standard MXFs).
        var num: Int32 = 24000
        var den: Int32 = 1001
        if let rate = (try? MXFPictureDescriptorReader.read(url: url)).flatMap({ $0 }),
           rate.sampleRateNum > 0, rate.sampleRateDen > 0 {
            num = rate.sampleRateNum
            den = rate.sampleRateDen
        }
        let fps = Double(num) / Double(den)
        let duration = Double(index.frames.count) / fps

        let dims = resolvedDims ?? CMVideoFormatDescriptionGetDimensions(fmt)
        return MXFFrameSource(
            url: url,
            index: index,
            formatDescription: fmt,
            codec: codec,
            frameRateNum: num,
            frameRateDen: den,
            durationSeconds: duration,
            nominalFrameRate: fps,
            pixelDimensions: CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        )
    }

    private init(
        url: URL,
        index: MXFEssenceReader.Index,
        formatDescription: CMVideoFormatDescription,
        codec: CodecKind,
        frameRateNum: Int32,
        frameRateDen: Int32,
        durationSeconds: Double,
        nominalFrameRate: Double,
        pixelDimensions: CGSize
    ) {
        self.url = url
        self.index = index
        self.formatDescription = formatDescription
        self.codec = codec
        self.frameRateNum = frameRateNum
        self.frameRateDen = frameRateDen
        self.durationSeconds = durationSeconds
        self.nominalFrameRate = nominalFrameRate
        self.pixelDimensions = pixelDimensions
    }

    // MARK: - API

    public func seek(to time: CMTime) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ioQueue.async {
                let seconds = CMTimeGetSeconds(time)
                let targetIdx = max(0, min(
                    self.index.frames.count - 1,
                    Int((seconds * self.nominalFrameRate).rounded())
                ))
                // Invalidate in-flight async decodes (their callbacks become
                // no-ops via the generation check), drain VT, and reset the
                // pipeline to the new position.
                self.seekGen += 1
                if let session = self.vtSession {
                    VTDecompressionSessionWaitForAsynchronousFrames(session)
                }
                self.ready.removeAll()
                self.inFlight = 0
                self.consumeIndex = targetIdx
                self.readIndex = targetIdx
                if let p = self.pendingCont { self.pendingCont = nil; p.cont.resume(returning: nil) }
                cont.resume()
            }
        }
    }

    public func nextFrame() async throws -> PPEDecodedFrame? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PPEDecodedFrame?, Error>) in
            ioQueue.async {
                guard self.pendingCont == nil else {
                    cont.resume(throwing: FrameSourceError.readFailed("concurrent nextFrame"))
                    return
                }
                self.pendingCont = (index: self.consumeIndex, cont)
                self.pump()
                self.serviceWaiter()
            }
        }
    }

    public func tearDown() {
        ioQueue.async {
            self.seekGen += 1
            if let s = self.vtSession {
                VTDecompressionSessionWaitForAsynchronousFrames(s)
                VTDecompressionSessionInvalidate(s)
                self.vtSession = nil
                self.currentSessionFormat = nil
            }
            try? self.readHandle?.close()
            self.readHandle = nil
            self.ready.removeAll()
            self.inFlight = 0
            if let p = self.pendingCont { self.pendingCont = nil; p.cont.resume(returning: nil) }
        }
    }

    // MARK: - Internals (decode-ahead pipeline; all on `ioQueue`)

    private func ensureResources() {
        if readHandle == nil { readHandle = try? FileHandle(forReadingFrom: url) }
        if vtSession == nil {
            vtSession = try? Self.makeDecompressionSession(formatDescription: formatDescription)
            currentSessionFormat = vtSession != nil ? formatDescription : nil
        }
    }

    /// Keep the VT pipeline filled up to `maxAhead` frames in flight +
    /// decoded-but-unconsumed, reading + submitting frames asynchronously
    /// so the Media Engine can overlap decodes.
    private func pump() {
        ensureResources()
        guard vtSession != nil, readHandle != nil else { return }
        while inFlight + ready.count < maxAhead && readIndex < index.frames.count {
            // submitFrame returns false when it needs to switch the VT
            // session to a new parameter set but frames are still in flight —
            // leave readIndex put and retry once the pipeline drains.
            if submitFrame(readIndex) {
                readIndex += 1
            } else {
                break
            }
        }
    }

    /// Read frame `idx` off disk and submit it to VT for async decode.
    /// Returns `false` when the frame needs a different VT session (its
    /// parameter set changed) but frames are still in flight — the caller
    /// must not advance and should retry after the pipeline drains. Returns
    /// `true` once the frame is submitted (or skipped on a recoverable read
    /// error), i.e. the cursor may advance.
    @discardableResult
    private func submitFrame(_ idx: Int) -> Bool {
        guard idx < index.frames.count, let handle = readHandle else { return true }
        let ref = index.frames[idx]
        let gen = seekGen
        do {
            try handle.seek(toOffset: ref.payloadOffset)
            let len = Int(ref.payloadLength)
            guard let raw = try handle.read(upToCount: len), raw.count == len else { return true }
            let pts = CMTime(value: Int64(idx) * Int64(frameRateDen), timescale: frameRateNum)
            let duration = CMTime(value: Int64(frameRateDen), timescale: frameRateNum)

            // Resolve THIS frame's format from its own in-band SPS/PPS. If it
            // differs from the live session's, the session must be rebuilt —
            // but only once all in-flight frames (decoded against the old
            // format) have drained, so defer when inFlight > 0.
            let frameFormat = formatForFrame(raw)
            if let frameFormat,
               !(currentSessionFormat.map { CMFormatDescriptionEqual($0, otherFormatDescription: frameFormat) } ?? false) {
                if inFlight > 0 { return false }   // drain first, then retry
                if let s = vtSession {
                    VTDecompressionSessionWaitForAsynchronousFrames(s)
                    VTDecompressionSessionInvalidate(s)
                }
                vtSession = try? Self.makeDecompressionSession(formatDescription: frameFormat)
                currentSessionFormat = vtSession != nil ? frameFormat : nil
            }
            guard let session = vtSession else { return true }
            let sampleBuffer = try buildSampleBuffer(
                for: raw,
                format: frameFormat ?? currentSessionFormat ?? formatDescription,
                pts: pts, duration: duration
            )

            inFlight += 1
            var infoFlags: VTDecodeInfoFlags = []
            let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression, ._1xRealTimePlayback]
            let status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: flags,
                infoFlagsOut: &infoFlags,
                outputHandler: { [weak self] status, _, imageBuffer, _, _ in
                    guard let self else { return }
                    self.ioQueue.async {
                        guard gen == self.seekGen else { return }   // superseded by a seek/teardown
                        self.inFlight -= 1
                        if status == noErr, let image = imageBuffer {
                            self.ready[idx] = PPEDecodedFrame(pts: pts, duration: duration, pixelBuffer: image)
                        }
                        self.serviceWaiter()
                        self.pump()
                    }
                }
            )
            if status != noErr { inFlight -= 1 }
            return true
        } catch {
            // I/O or sample-buffer error on this frame — skip it (advance).
            return true
        }
    }

    /// Build (and cache) the H.264 format description for a frame from its
    /// own in-band SPS/PPS. Returns nil when the frame carries no parameter
    /// sets (caller falls back to the current/base format) or for ProRes.
    private func formatForFrame(_ frameData: Data) -> CMVideoFormatDescription? {
        guard codec == .h264 else { return nil }
        let nals = AnnexBParser.parse(frameData)
        guard let sps = nals.first(where: { $0.nalType == 7 }),
              let pps = nals.first(where: { $0.nalType == 8 }) else { return nil }
        var key = Data()
        key.append(sps.rawBytes)
        key.append(pps.rawBytes)
        if let cached = formatCache[key] { return cached }
        guard let fmt = try? Self.buildH264FormatDescription(sps: sps.rawBytes, pps: pps.rawBytes) else { return nil }
        formatCache[key] = fmt
        return fmt
    }

    /// Deliver the consumer's awaited frame once it's decoded, or nil at EOF
    /// / on an unrecoverable miss.
    private func serviceWaiter() {
        guard let p = pendingCont else { return }
        if let frame = ready.removeValue(forKey: p.index) {
            consumeIndex = p.index + 1
            pendingCont = nil
            p.cont.resume(returning: frame)
            return
        }
        if p.index >= index.frames.count {
            pendingCont = nil
            p.cont.resume(returning: nil)               // genuine EOF
            return
        }
        if inFlight == 0 && readIndex > p.index {
            // Submitted but never produced (decode failure) and nothing else
            // in flight → don't hang the consumer.
            pendingCont = nil
            p.cont.resume(returning: nil)
            return
        }
        // Otherwise keep waiting — a callback or pump will make progress.
    }

    /// Build a CMSampleBuffer appropriate for the codec. H.264
    /// needs Annex B→AVCC rewriting + slice-only filtering;
    /// ProRes is a raw passthrough.
    private func buildSampleBuffer(
        for data: Data,
        format: CMVideoFormatDescription,
        pts: CMTime,
        duration: CMTime
    ) throws -> CMSampleBuffer {
        let payload: Data
        switch codec {
        case .h264:
            let nals = AnnexBParser.parse(data)
            let slices = nals.filter { n in
                switch n.nalType { case 1, 5, 6, 19, 20: return true; default: return false }
            }
            guard !slices.isEmpty else {
                throw FrameSourceError.readFailed("no slice NAL in frame")
            }
            var avcc = Data()
            avcc.reserveCapacity(data.count)
            for n in slices {
                let len = UInt32(n.rawBytes.count)
                avcc.append(contentsOf: [
                    UInt8((len >> 24) & 0xFF),
                    UInt8((len >> 16) & 0xFF),
                    UInt8((len >> 8) & 0xFF),
                    UInt8(len & 0xFF),
                ])
                avcc.append(n.rawBytes)
            }
            payload = avcc
        case .prores:
            payload = data
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let bb = blockBuffer else {
            throw FrameSourceError.readFailed("block buffer create \(status)")
        }
        status = payload.withUnsafeBytes { buf -> OSStatus in
            guard let base = buf.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw FrameSourceError.readFailed("block buffer copy \(status)")
        }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sizes: [Int] = [payload.count]
        var sb: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sizes,
            sampleBufferOut: &sb
        )
        guard sbStatus == noErr, let buffer = sb else {
            throw FrameSourceError.readFailed("sample buffer create \(sbStatus)")
        }
        // Mark every frame as a keyframe / independent.
        // Canon XF-AVC and Sony XAVC-Intra are all-I H.264;
        // ProRes is intra-only by design. VT can decode in
        // parallel when it knows frames don't depend on each
        // other.
        if let attach = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
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
        return buffer
    }

    // MARK: - Format description builders

    private static func buildH264FormatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        let spsPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: sps.count)
        sps.copyBytes(to: spsPtr, count: sps.count)
        defer { spsPtr.deallocate() }
        let ppsPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: pps.count)
        pps.copyBytes(to: ppsPtr, count: pps.count)
        defer { ppsPtr.deallocate() }

        let pointers: [UnsafePointer<UInt8>] = [UnsafePointer(spsPtr), UnsafePointer(ppsPtr)]
        let sizes: [Int] = [sps.count, pps.count]

        var fmt: CMVideoFormatDescription?
        let status = pointers.withUnsafeBufferPointer { ptrBuf in
            sizes.withUnsafeBufferPointer { szBuf in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: ptrBuf.baseAddress!,
                    parameterSetSizes: szBuf.baseAddress!,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &fmt
                )
            }
        }
        guard status == noErr, let fmt else {
            throw FrameSourceError.readerSetupFailed("H.264 format description (\(status))")
        }
        return fmt
    }

    private static func buildProResFormatDescription(
        fourCC: FourCharCode,
        firstFrameData: Data,
        descriptorURL: URL
    ) throws -> (CMVideoFormatDescription, CMVideoDimensions) {
        // Dimensions: prefer the MXF picture descriptor's
        // StoredWidth / StoredHeight; fall back to parsing the
        // ProRes frame header at bytes 16-19. Default to 1920×
        // 1080 if neither works (shouldn't happen in practice).
        var width: Int32 = 1920
        var height: Int32 = 1080
        if let desc = (try? MXFPictureDescriptorReader.read(url: descriptorURL)).flatMap({ $0 }),
           let w = desc.storedWidth, let h = desc.storedHeight, w > 0, h > 0 {
            width = w
            height = h
        } else if firstFrameData.count >= 20 {
            let w = (Int32(firstFrameData[16]) << 8) | Int32(firstFrameData[17])
            let h = (Int32(firstFrameData[18]) << 8) | Int32(firstFrameData[19])
            if w > 0, h > 0 { width = w; height = h }
        }
        var fmt: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: fourCC,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &fmt
        )
        guard status == noErr, let fmt else {
            throw FrameSourceError.readerSetupFailed("ProRes format description (\(status))")
        }
        return (fmt, CMVideoDimensions(width: width, height: height))
    }

    private static func inferProResFourCC(firstFrameData: Data) -> FourCharCode? {
        guard firstFrameData.count >= 22 else { return nil }
        let chroma = (firstFrameData[20] >> 6) & 0x03
        if chroma == 0x03 { return kCMVideoCodecType_AppleProRes4444 }
        return kCMVideoCodecType_AppleProRes422HQ
    }

    // MARK: - VT session

    private static func makeDecompressionSession(
        formatDescription: CMVideoFormatDescription
    ) throws -> VTDecompressionSession {
        // Request 32BGRA output so frames flow into the PPE
        // renderer with the same pixel format as
        // AVAssetFrameSource — no downstream branching needed.
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        // Explicitly request the hardware decoder (Apple Silicon Media
        // Engine). Without this, 4K All-Intra H.264 can fall back to / pick
        // a slower path that can't sustain 24 fps.
        let decoderSpec: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true,
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let s = session else {
            throw FrameSourceError.readerSetupFailed("VT session create (\(status))")
        }
        return s
    }

    // MARK: - Errors

    public enum FrameSourceError: LocalizedError {
        case noVideoTrack
        case readerSetupFailed(String)
        case readFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "MXF has no video essence"
            case .readerSetupFailed(let s): return "MXF frame source setup: \(s)"
            case .readFailed(let s): return "MXF frame read failed: \(s)"
            }
        }
    }
}

