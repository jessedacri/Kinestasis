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
    private var nextFrameIndex: Int = 0

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
                self.nextFrameIndex = targetIdx
                // H.264 bitstreams may require re-submitting SPS/
                // PPS context on a non-keyframe jump. ProRes is
                // intra-only so no flush needed.
                if self.codec == .h264, let session = self.vtSession {
                    VTDecompressionSessionFinishDelayedFrames(session)
                }
                cont.resume()
            }
        }
    }

    public func nextFrame() async throws -> PPEDecodedFrame? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PPEDecodedFrame?, Error>) in
            ioQueue.async {
                do {
                    let frame = try self.decodeNextFrameSync()
                    cont.resume(returning: frame)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func tearDown() {
        ioQueue.async {
            if let s = self.vtSession {
                VTDecompressionSessionInvalidate(s)
                self.vtSession = nil
            }
            try? self.readHandle?.close()
            self.readHandle = nil
        }
    }

    // MARK: - Internals

    /// Must be called on `ioQueue`. Blocks until VT returns
    /// the decoded pixel buffer (synchronous decode — we use
    /// a `DispatchSemaphore` to convert the callback to a
    /// sync wait). Returns nil at EOF.
    private func decodeNextFrameSync() throws -> PPEDecodedFrame? {
        let idx = nextFrameIndex
        if idx >= index.frames.count { return nil }
        let ref = index.frames[idx]

        // Ensure the file handle + VT session are ready.
        if readHandle == nil {
            readHandle = try? FileHandle(forReadingFrom: url)
        }
        guard let handle = readHandle else {
            throw FrameSourceError.readFailed("cannot open \(url.lastPathComponent)")
        }
        if vtSession == nil {
            vtSession = try Self.makeDecompressionSession(
                formatDescription: formatDescription
            )
        }
        guard let session = vtSession else {
            throw FrameSourceError.readerSetupFailed("no VT session")
        }

        // Read the frame's bytes.
        try handle.seek(toOffset: ref.payloadOffset)
        guard let raw = try handle.read(upToCount: Int(ref.payloadLength)),
              raw.count == Int(ref.payloadLength) else {
            throw FrameSourceError.readFailed("short read at frame \(idx)")
        }

        // Build a CMSampleBuffer per codec and submit to VT.
        let pts = CMTime(
            value: Int64(idx) * Int64(frameRateDen),
            timescale: frameRateNum
        )
        let duration = CMTime(
            value: Int64(frameRateDen),
            timescale: frameRateNum
        )
        let sampleBuffer = try buildSampleBuffer(
            for: raw,
            pts: pts,
            duration: duration
        )

        // Synchronous decode via semaphore+callback. VT can
        // operate in async mode but we want one-frame-at-a-
        // time semantics that match the `VideoFrameSource`
        // protocol. Overhead is negligible vs. decode cost.
        let box = DecodeResultBox()
        let sem = DispatchSemaphore(value: 0)
        var flagsOut: VTDecodeInfoFlags = []
        let flagsIn: VTDecodeFrameFlags = [._1xRealTimePlayback]
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: flagsIn,
            infoFlagsOut: &flagsOut,
            outputHandler: { status, _, imageBuffer, _, _ in
                box.status = status
                box.imageBuffer = imageBuffer
                sem.signal()
            }
        )
        if status != noErr {
            throw FrameSourceError.readFailed("VT submit failed \(status) frame \(idx)")
        }
        sem.wait()
        guard box.status == noErr, let image = box.imageBuffer else {
            throw FrameSourceError.readFailed(
                "VT decode failed (\(box.status)) frame \(idx)"
            )
        }

        nextFrameIndex = idx + 1
        return PPEDecodedFrame(
            pts: pts,
            duration: duration,
            pixelBuffer: image
        )
    }

    /// Build a CMSampleBuffer appropriate for the codec. H.264
    /// needs Annex B→AVCC rewriting + slice-only filtering;
    /// ProRes is a raw passthrough.
    private func buildSampleBuffer(
        for data: Data,
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
            formatDescription: formatDescription,
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
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
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

/// Output-handler escape hatch. VT's callback hands us both
/// the status and the pixel buffer; we stash them here and
/// signal a semaphore so the calling thread can continue.
private final class DecodeResultBox {
    var status: OSStatus = -1
    var imageBuffer: CVImageBuffer?
}
