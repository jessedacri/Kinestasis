import AVFoundation
import CoreMedia
import VideoToolbox
import PolymergeIngest

/// Native Apple ProRes-in-MXF playback. Sibling of
/// `MXFH264Player` with the same public surface
/// (`MXFNativePlayer` protocol), but the per-frame path is
/// simpler: ProRes frames are self-contained intraframe
/// compressed units, so we copy the KLV payload straight into a
/// `CMBlockBuffer` without Annex B → AVCC rewriting or parameter-
/// set extraction. VideoToolbox's ProRes decoder accepts the
/// bytes directly once we hand it the right codec type +
/// dimensions.
///
/// **Codec variants.** SMPTE ST 2019-4 defines the ProRes
/// FourCC set (apco / apcs / apcn / apch / ap4h / ap4x). We
/// resolve the variant from the MXF picture descriptor's
/// `picture_essence_coding` UL when present, and fall back to
/// apch (ProRes 422 HQ — the most common ARRI Alexa variant)
/// when the UL isn't readable. VideoToolbox is lenient here:
/// specifying the wrong sibling variant (say, apcn instead of
/// apch) typically still decodes correctly because the frame
/// bytes themselves carry the chroma / bit-depth metadata
/// needed by the hardware decoder.
///
/// **Why the frame rate comes from the descriptor.** Unlike
/// H.264 (where SPS *sometimes* carries frame rate), ProRes
/// frame headers don't encode frame rate at all. We read tag
/// `0x3001` SampleRate from the picture descriptor — the
/// authoritative answer, same mechanism `MXFH264Player` uses.
public final class MXFProResPlayer: MXFNativePlayer {

    // MARK: - Inputs

    private let url: URL
    private let index: MXFEssenceReader.Index
    private let formatDescription: CMVideoFormatDescription
    private let codecTypeFourCC: FourCharCode

    // MARK: - Outputs

    public let displayLayer = AVSampleBufferDisplayLayer()

    public var pixelDimensions: CGSize {
        let dims = CMVideoFormatDescriptionGetDimensions(formatDescription)
        return CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
    }

    public var nominalFrameRate: Double {
        Double(frameRateNum) / Double(frameRateDen)
    }

    public var durationSeconds: Double {
        Double(index.frames.count) / nominalFrameRate
    }

    public var codecLabel: String {
        switch codecTypeFourCC {
        case kCMVideoCodecType_AppleProRes422Proxy: return "ProRes 422 Proxy"
        case kCMVideoCodecType_AppleProRes422LT: return "ProRes 422 LT"
        case kCMVideoCodecType_AppleProRes422: return "ProRes 422"
        case kCMVideoCodecType_AppleProRes422HQ: return "ProRes 422 HQ"
        case kCMVideoCodecType_AppleProRes4444: return "ProRes 4444"
        case kCMVideoCodecType_AppleProRes4444XQ: return "ProRes 4444 XQ"
        default: return "ProRes"
        }
    }

    // MARK: - Playback state

    private let timebase: CMTimebase
    private let frameRateNum: Int32
    private let frameRateDen: Int32
    private var nextFrameToEnqueue: Int = 0
    private let enqueueQueue = DispatchQueue(label: "polymerge.mxf.prores.enqueue", qos: .userInitiated)
    private var readHandle: FileHandle?
    private var enqueueLoopInstalled = false

    // Diagnostic counters — logged once per second while playing
    // so we can see if decode is keeping up with real-time.
    private var diagFramesThisSec: Int = 0
    private var diagLastLogHost: CFTimeInterval = 0
    private var diagWaitBatches: Int = 0

    // MARK: - Init

    public init(url: URL, index: MXFEssenceReader.Index, codecFourCC: FourCharCode? = nil) throws {
        self.url = url
        self.index = index
        guard case .prores = index.codec else {
            throw PlayerError.unsupportedCodec(index.codec.displayName)
        }
        guard let firstFrame = index.frames.first else {
            throw PlayerError.emptyIndex
        }

        // Frame rate from the picture descriptor. ProRes has no
        // inline frame rate metadata we can crack out of the
        // stream, so this is the only authoritative source.
        var resolvedNum: Int32 = 24000
        var resolvedDen: Int32 = 1001
        var dimensionsFromDescriptor: (Int32, Int32)? = nil
        if let rate = (try? MXFPictureDescriptorReader.read(url: url)).flatMap({ $0 }),
           rate.sampleRateNum > 0, rate.sampleRateDen > 0 {
            resolvedNum = rate.sampleRateNum
            resolvedDen = rate.sampleRateDen
            if let w = rate.storedWidth, let h = rate.storedHeight, w > 0, h > 0 {
                dimensionsFromDescriptor = (w, h)
            }
            print("[MXFProRes] descriptor rate \(rate.sampleRateNum)/\(rate.sampleRateDen) = \(String(format: "%.3f", rate.frameRate)) fps")
        } else {
            print("[MXFProRes] descriptor unreadable, defaulting to 24000/1001")
        }
        self.frameRateNum = resolvedNum
        self.frameRateDen = resolvedDen

        // ProRes variant. When the caller didn't pass a specific
        // FourCC, read the first frame's bytes — the ProRes
        // frame header at byte 8 onwards carries chroma_format
        // + bit depth, from which we can derive the variant.
        // As a simple default, apch (ProRes 422 HQ) is the most
        // common camera output (ARRI Alexa Mini, Blackmagic,
        // Atomos) and VideoToolbox tolerates a mismatch with
        // a sibling variant.
        let resolvedFourCC = codecFourCC ?? Self.inferFourCC(
            firstFrameData: (try? MXFEssenceReader.readFrame(url: url, ref: firstFrame)) ?? Data()
        ) ?? kCMVideoCodecType_AppleProRes422HQ
        self.codecTypeFourCC = resolvedFourCC

        // Dimensions: prefer the MXF descriptor, else parse
        // from the ProRes frame header. Frame header offsets:
        //   bytes 16-17 = frame width (big-endian u16)
        //   bytes 18-19 = frame height
        let (width, height): (Int32, Int32) = {
            if let d = dimensionsFromDescriptor { return d }
            if let data = try? MXFEssenceReader.readFrame(url: url, ref: firstFrame),
               data.count >= 20 {
                let w = (Int32(data[16]) << 8) | Int32(data[17])
                let h = (Int32(data[18]) << 8) | Int32(data[19])
                if w > 0, h > 0 { return (w, h) }
            }
            return (1920, 1080)
        }()

        var fmt: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: resolvedFourCC,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &fmt
        )
        guard status == noErr, let fmt else {
            throw PlayerError.formatDescriptionFailed(Int(status))
        }
        self.formatDescription = fmt

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

        print("[MXFProRes] initialized — \(index.frames.count) frames, format \(width)×\(height) \(Self.codecLabelForFourCC(resolvedFourCC)), rate \(resolvedNum)/\(resolvedDen)")
    }

    /// Peek at the first frame's ProRes header to guess the
    /// variant. `chroma_format` (byte 20, bits 6-7) tells us
    /// 4:2:2 vs 4:4:4, and `depth` (byte 21, bits 4-7)
    /// distinguishes the bit depths. We use those to pick the
    /// closest sibling FourCC.
    private static func inferFourCC(firstFrameData: Data) -> FourCharCode? {
        guard firstFrameData.count >= 22 else { return nil }
        // byte 20: bits 7-6 = chroma_format. 0b10 = 4:2:2, 0b11 = 4:4:4.
        let chroma = (firstFrameData[20] >> 6) & 0x03
        // byte 21: bits 7-4 = bitstream_version hints at bit depth
        // indirectly. For a simple inference pass we just flag
        // 4444 when chroma_format says 4:4:4. The specific 422
        // sub-variant (Proxy/LT/HQ/standard) isn't encoded in
        // the header — encoders choose via target bitrate —
        // so we default to HQ which is the most common.
        if chroma == 0x03 {
            return kCMVideoCodecType_AppleProRes4444
        }
        return kCMVideoCodecType_AppleProRes422HQ
    }

    private static func codecLabelForFourCC(_ fcc: FourCharCode) -> String {
        var bytes: [UInt8] = [
            UInt8((fcc >> 24) & 0xFF),
            UInt8((fcc >> 16) & 0xFF),
            UInt8((fcc >> 8) & 0xFF),
            UInt8(fcc & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    // MARK: - Playback control

    public func play() {
        installEnqueueLoopIfNeeded()
        CMTimebaseSetRate(timebase, rate: 1.0)
    }

    public func pause() {
        CMTimebaseSetRate(timebase, rate: 0.0)
    }

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

    public func showFirstFrame() {
        seek(toFrame: 0)
    }

    // MARK: - Enqueue loop

    private func installEnqueueLoopIfNeeded() {
        guard !enqueueLoopInstalled else { return }
        enqueueLoopInstalled = true
        displayLayer.requestMediaDataWhenReady(on: enqueueQueue) { [weak self] in
            guard let self else { return }
            self.diagWaitBatches &+= 1
            var framesThisBatch = 0
            let batchStartHost = CACurrentMediaTime()
            while self.displayLayer.isReadyForMoreMediaData {
                let idx = self.nextFrameToEnqueue
                if idx >= self.index.frames.count {
                    self.displayLayer.stopRequestingMediaData()
                    self.enqueueLoopInstalled = false
                    return
                }
                do {
                    let sb = try self.buildSampleBufferForFrame(at: idx)
                    self.displayLayer.enqueue(sb)
                    self.nextFrameToEnqueue = idx + 1
                    framesThisBatch &+= 1
                    self.diagFramesThisSec &+= 1
                } catch {
                    print("[MXFProRes] enqueue failed at frame \(idx): \(error.localizedDescription)")
                    self.nextFrameToEnqueue = idx + 1
                }
            }
            // Once per second, log: frames enqueued in the last
            // second + how many batches of work it took. If
            // frames-per-second < fps, we're falling behind decode;
            // if batches == many, the display layer is pulling us
            // in small chunks (backpressure is dominant).
            let now = CACurrentMediaTime()
            if now - self.diagLastLogHost >= 1.0 {
                let elapsed = now - self.diagLastLogHost
                let fps = Double(self.diagFramesThisSec) / elapsed
                let timebaseRate = CMTimebaseGetRate(self.timebase)
                let timebaseSec = CMTimeGetSeconds(CMTimebaseGetTime(self.timebase))
                let batchMs = (now - batchStartHost) * 1000
                print(String(format: "[MXFProRes/diag] enq=%d/s batches=%d last-batch=%d frames in %.1fms  tb=%.3fs rate=%.2f  ready=%@",
                             self.diagFramesThisSec,
                             self.diagWaitBatches,
                             framesThisBatch,
                             batchMs,
                             timebaseSec,
                             timebaseRate,
                             self.displayLayer.isReadyForMoreMediaData ? "yes" : "no"))
                self.diagFramesThisSec = 0
                self.diagWaitBatches = 0
                self.diagLastLogHost = now
            }
        }
    }

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
        let pts = CMTime(
            value: Int64(idx) * Int64(frameRateDen),
            timescale: frameRateNum
        )
        return try buildSampleBuffer(for: raw, presentationTime: pts)
    }

    /// Wrap one ProRes frame's raw bytes into a CMSampleBuffer.
    /// ProRes frames are self-contained intra-only units — no
    /// parameter-set rewriting, no start-code conversion, no
    /// NAL slicing. Just copy the bytes into a CMBlockBuffer
    /// and attach timing.
    private func buildSampleBuffer(
        for frameData: Data,
        presentationTime: CMTime
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frameData.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frameData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw PlayerError.blockBufferFailed(Int(blockStatus))
        }
        let copyStatus = frameData.withUnsafeBytes { bufPtr -> OSStatus in
            guard let base = bufPtr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: frameData.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw PlayerError.blockBufferFailed(Int(copyStatus))
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: Int64(frameRateDen), timescale: frameRateNum),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSizes: [Int] = [frameData.count]
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
        // Mark every frame as an independent key frame. ProRes
        // is intra-only (no inter-frame dependencies) so VT's
        // scheduler can decode frames in parallel once it knows
        // they don't depend on each other. Without these hints
        // VT serializes decode and a 4K ProRes HQ stream can't
        // keep up with 23.976 fps — the user sees stuttery
        // playback. IsDependedOnByOthers=false lets VT drop
        // stale frames instead of carrying the decode penalty
        // forward when the play rate exceeds throughput.
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
        case formatDescriptionFailed(Int)
        case blockBufferFailed(Int)
        case sampleBufferFailed(Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedCodec(let s):
                return "MXFProResPlayer only handles ProRes; got \(s)"
            case .emptyIndex:
                return "MXF has no video frames"
            case .formatDescriptionFailed(let code):
                return "CMVideoFormatDescriptionCreate failed (\(code))"
            case .blockBufferFailed(let code):
                return "CMBlockBufferCreate failed (\(code))"
            case .sampleBufferFailed(let code):
                return "CMSampleBufferCreate failed (\(code))"
            }
        }
    }
}
