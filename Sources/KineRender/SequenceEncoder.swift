import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import KineCore
import KineMedia

/// Drives `OfflineSequenceCompositor` frame-by-frame at the sequence's
/// fps, feeds an `AVAssetWriter` to produce a video + audio file. Used
/// by:
///
/// - **Pre-render cache**: ProRes 422 LT segment under the per-project
///   cache directory. Same compositor path the program viewer will pull
///   from when the playhead enters the cached range.
/// - **Export**: user-chosen codec / destination, same pipeline.
///
/// Audio is mixed via `OfflineAudioMixdown` so the realtime
/// `TimelineAudioPipeline` and the offline output are guaranteed to
/// match (same fades, paired-cross-fade extensions, mute/solo gating).
///
/// **Concurrency model** (canonical pattern from Apple's docs +
/// RosyWriter / AVCustomEdit samples):
///
/// - Two `AVAssetWriterInput`s (video + audio), each pumped by its own
///   serial `DispatchQueue` via `requestMediaDataWhenReady(on:using:)`.
///   AVF flips `isReadyForMoreMediaData` on whichever input gets too
///   far ahead so the writer never chokes; the block returns when AVF
///   throttles and is re-invoked when there's room. No `Task.sleep`,
///   no manual PTS interleaving.
/// - Per-frame work is wrapped in `autoreleasepool` — AVF retains the
///   sample buffer, so per-frame allocations (CMSampleBuffer,
///   CVMetalTexture) leak without an explicit pool drain.
/// - The compositor writes directly into a `CVPixelBuffer` vended by
///   the adaptor's `pixelBufferPool`. The pool is bounded so a back-
///   pressuring hardware encoder back-pressures the compositor in turn,
///   instead of inflating IOSurface allocations until the OS pages.
/// - The compositor commits its Metal command buffer without
///   `waitUntilCompleted`. AVAssetWriter + VideoToolbox honor
///   IOSurface use-counts implicitly — the encoder waits for the GPU
///   write to finish before reading. Saves 8–15 ms per 4K frame.
public final class SequenceEncoder {

    public enum EncoderError: Error, LocalizedError {
        case writerCreate(String)
        case writerStart(String)
        case appendFailed(String)
        case cancelled
        case compositorFailed(String)
        case audioFormatCreate(OSStatus)
        case audioBlockBufferCreate(OSStatus)
        case audioSampleBufferCreate(OSStatus)
        case pixelBufferAllocFailed(Int32)
        case noPixelBufferPool

        public var errorDescription: String? {
            switch self {
            case .writerCreate(let s):           return "Could not create asset writer: \(s)"
            case .writerStart(let s):            return "Asset writer failed to start: \(s)"
            case .appendFailed(let s):           return "Asset writer rejected a frame: \(s)"
            case .cancelled:                     return "Render cancelled."
            case .compositorFailed(let s):       return "Compositor failed: \(s)"
            case .audioFormatCreate(let s):      return "CMAudioFormatDescription create failed (\(s))."
            case .audioBlockBufferCreate(let s): return "CMBlockBuffer create failed (\(s))."
            case .audioSampleBufferCreate(let s):return "CMSampleBuffer create failed (\(s))."
            case .pixelBufferAllocFailed(let s): return "Pixel buffer pool allocation failed (\(s))."
            case .noPixelBufferPool:             return "Adaptor pixel buffer pool was not available."
            }
        }
    }

    public struct Options {
        public var outputURL: URL
        /// nil → audio-only export, no video pipeline runs.
        public var videoCodec: AVVideoCodecType?
        /// Compressed-codec bitrate (target). Ignored for ProRes.
        public var videoBitrate: Int
        /// VBR ceiling for H.264 / HEVC. Ignored otherwise.
        public var videoMaximumBitrate: Int
        /// H.264 profile-level string (from AVVideoProfileLevelH264*).
        public var videoH264Profile: String
        public var keyframeIntervalFrames: Int

        /// Output dimensions. Defaults to the sequence's resolution. If
        /// different, the compositor produces frames at this size
        /// (free GPU scale via its blend shader's UV sampling).
        public var width: Int
        public var height: Int

        /// Output frame rate. Defaults to the sequence's rate. If
        /// different, the encoder steps timeline-time at this fps.
        public var frameRate: FrameRate

        public var startSeconds: Double
        public var endSeconds: Double

        /// `nil` → no audio input on the writer.
        public var audioOutputSettings: [String: Any]?
        /// Channel count for the audio input. Mirrors what the user
        /// asked for in the sheet (mono vs stereo); the mixdown will
        /// downmix if the underlying tracks are stereo + user picked
        /// mono.
        public var audioChannelCount: Int
        public var audioSampleRate: Int

        /// When true, the encoder writes one audio track per audible
        /// timeline audio track (instead of a single mixdown). Requires
        /// `audioSettingsBuilder` and a MOV container. Ignored for
        /// audio-only export.
        public var audioMultiTrack: Bool
        /// When true (multi-track only), each output track keeps its
        /// source clips' native channel count; otherwise each track is
        /// downmixed to `audioChannelCount`.
        public var audioPreserveSourceChannels: Bool
        /// Builds per-track output settings for a given channel count.
        /// Used only in multi-track mode (channel count varies per track
        /// under preserve-channels). `audioOutputSettings` is the
        /// single-track equivalent.
        public var audioSettingsBuilder: (@Sendable (Int) -> [String: Any])?

        public var fileType: AVFileType
        public var progress: ((Double) -> Void)?

        public init(
            outputURL: URL,
            videoCodec: AVVideoCodecType? = .proRes422LT,
            videoBitrate: Int = 40_000_000,
            videoMaximumBitrate: Int = 60_000_000,
            videoH264Profile: String = AVVideoProfileLevelH264HighAutoLevel,
            keyframeIntervalFrames: Int = 30,
            width: Int,
            height: Int,
            frameRate: FrameRate,
            startSeconds: Double,
            endSeconds: Double,
            audioOutputSettings: [String: Any]? = nil,
            audioChannelCount: Int = 2,
            audioSampleRate: Int = 48_000,
            audioMultiTrack: Bool = false,
            audioPreserveSourceChannels: Bool = false,
            audioSettingsBuilder: (@Sendable (Int) -> [String: Any])? = nil,
            fileType: AVFileType = .mov,
            progress: ((Double) -> Void)? = nil
        ) {
            self.outputURL = outputURL
            self.videoCodec = videoCodec
            self.videoBitrate = videoBitrate
            self.videoMaximumBitrate = videoMaximumBitrate
            self.videoH264Profile = videoH264Profile
            self.keyframeIntervalFrames = keyframeIntervalFrames
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.audioOutputSettings = audioOutputSettings
            self.audioChannelCount = audioChannelCount
            self.audioSampleRate = audioSampleRate
            self.audioMultiTrack = audioMultiTrack
            self.audioPreserveSourceChannels = audioPreserveSourceChannels
            self.audioSettingsBuilder = audioSettingsBuilder
            self.fileType = fileType
            self.progress = progress
        }
    }

    private let sequence: Sequence
    private let mediaPool: MediaPool
    // Created per-encode so the resolution can match the export target
    // without rebuilding the encoder.
    private var compositor: OfflineSequenceCompositor?
    // `nonisolated(unsafe)` because the pump blocks on dispatch queues
    // read this flag from main + worker threads. It's a Bool — atomic on
    // every Mac architecture; we don't need a real lock.
    nonisolated(unsafe) private var isCancelled: Bool = false

    public init(sequence: Sequence, mediaPool: MediaPool) throws {
        self.sequence = sequence
        self.mediaPool = mediaPool
    }

    public func cancel() { isCancelled = true }

    public func encode(_ options: Options) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: options.outputURL.path) {
            try? fm.removeItem(at: options.outputURL)
        }
        try? fm.createDirectory(
            at: options.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let width = options.width
        let height = options.height
        let frameRate = options.frameRate
        let timescale = frameRate.rationalRate
        let frameDurationValue = frameRate.rationalScale
        let secondsPerFrame = Double(frameDurationValue) / Double(timescale)
        let audioSampleRate = Double(options.audioSampleRate)
        let audioChannelCount = options.audioChannelCount
        let isAudioOnly = options.videoCodec == nil

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: options.outputURL, fileType: options.fileType)
        } catch {
            throw EncoderError.writerCreate(error.localizedDescription)
        }

        // ── Video input (skipped for audio-only) ─────────────────────
        var videoInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        var compositor: OfflineSequenceCompositor?

        if let videoCodec = options.videoCodec {
            compositor = try OfflineSequenceCompositor(
                sequence: sequence, mediaPool: mediaPool,
                outputWidth: width, outputHeight: height
            )
            self.compositor = compositor

            let videoSettings = Self.buildVideoSettings(
                codec: videoCodec,
                width: width, height: height,
                frameRate: frameRate,
                bitrate: options.videoBitrate,
                profileLevel: options.videoH264Profile,
                keyframeInterval: options.keyframeIntervalFrames
            )
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = false
            input.transform = .identity

            let sourceAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            let ad = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: sourceAttrs
            )
            guard writer.canAdd(input) else {
                throw EncoderError.writerCreate("Writer rejected the video input.")
            }
            writer.add(input)
            videoInput = input
            adaptor = ad
        }

        // ── Audio input(s) ───────────────────────────────────────────
        // Each entry pairs a writer input with the float mix it's pumped
        // from. The single-track mix is rendered after startWriting; the
        // multi-track mixes are rendered HERE because their per-track
        // channel counts must be known before the inputs are added.
        // Source-side CMSampleBuffer format is always 32-bit float
        // interleaved — AVAssetWriter transcodes to the output format.
        struct PendingAudio {
            let input: AVAssetWriterInput
            let formatDesc: CMAudioFormatDescription
            let channelCount: Int
            var mix: [[Float]]          // empty == not rendered yet
        }
        var pendingAudio: [PendingAudio] = []

        let wantsMultiTrack = options.audioMultiTrack
            && !isAudioOnly
            && options.audioSettingsBuilder != nil
            && options.audioOutputSettings != nil

        if wantsMultiTrack, let builder = options.audioSettingsBuilder {
            let mixer = OfflineAudioMixdown(
                sequence: sequence, mediaPool: mediaPool,
                sampleRate: audioSampleRate, channelCount: audioChannelCount
            )
            let mixes = await mixer.renderPerTrack(
                startSeconds: options.startSeconds, endSeconds: options.endSeconds,
                preserveSourceChannels: options.audioPreserveSourceChannels
            )
            for mix in mixes {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: builder(mix.channelCount))
                input.expectsMediaDataInRealTime = false
                guard writer.canAdd(input) else {
                    KineDebugLog.log("[Encoder] writer rejected audio track \(mix.label)")
                    continue
                }
                writer.add(input)
                let fmt = try Self.makeAudioFormatDescription(
                    sampleRate: audioSampleRate, channelCount: mix.channelCount
                )
                pendingAudio.append(PendingAudio(input: input, formatDesc: fmt,
                                                 channelCount: mix.channelCount, mix: mix.channels))
            }
            KineDebugLog.log("[Encoder] multi-track audio: \(pendingAudio.count) track(s), preserveChannels=\(options.audioPreserveSourceChannels)")
        } else if let audioSettings = options.audioOutputSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                let fmt = try Self.makeAudioFormatDescription(
                    sampleRate: audioSampleRate, channelCount: audioChannelCount
                )
                pendingAudio.append(PendingAudio(input: input, formatDesc: fmt,
                                                 channelCount: audioChannelCount, mix: []))
            } else {
                KineDebugLog.log("[Encoder] writer rejected audio input")
                if isAudioOnly {
                    throw EncoderError.writerCreate("Writer rejected the audio input for audio-only export.")
                }
            }
        }

        // ── Start the session ────────────────────────────────────────
        guard writer.startWriting() else {
            throw EncoderError.writerStart(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        // Pool is only valid after startWriting(); audio-only skips it.
        let pool: CVPixelBufferPool?
        if let adaptor {
            guard let p = adaptor.pixelBufferPool else {
                writer.cancelWriting()
                throw EncoderError.noPixelBufferPool
            }
            pool = p
        } else {
            pool = nil
        }

        let rangeSeconds = max(0, options.endSeconds - options.startSeconds)
        let totalVideoFrames = isAudioOnly ? 0 : Int((rangeSeconds / secondsPerFrame).rounded())
        if !isAudioOnly && totalVideoFrames <= 0 {
            videoInput?.markAsFinished()
            pendingAudio.forEach { $0.input.markAsFinished() }
            await writer.finishWriting()
            return
        }

        // Single-track audio: render the mixdown now (multi-track mixes
        // were pre-rendered above). Fast and bounded; lets the audio pump
        // just memcpy + interleave into CMSampleBuffers.
        if pendingAudio.count == 1 && pendingAudio[0].mix.isEmpty {
            let mixer = OfflineAudioMixdown(
                sequence: sequence, mediaPool: mediaPool,
                sampleRate: audioSampleRate, channelCount: audioChannelCount
            )
            pendingAudio[0].mix = await mixer.render(
                startSeconds: options.startSeconds, endSeconds: options.endSeconds
            )
        }

        if pendingAudio.isEmpty && isAudioOnly {
            writer.cancelWriting()
            throw EncoderError.writerCreate("Audio-only export needs an audio input.")
        }

        let totalAudioFrames = pendingAudio.reduce(0) { $0 + ($1.mix.first?.count ?? 0) }
        let codecLabel = options.videoCodec?.rawValue ?? "audio-only"
        KineDebugLog.log("[Encoder] start: video=\(totalVideoFrames) frames @ \(width)x\(height) codec=\(codecLabel), audioTracks=\(pendingAudio.count) audioFrames=\(totalAudioFrames)")

        // ── State shared across pump callbacks ───────────────────────
        let stateLock = NSLock()
        nonisolated(unsafe) var nextVideoFrame = 0
        // One cursor per audio track; each pump writes only its own slot.
        nonisolated(unsafe) var audioCursors = [Int](repeating: 0, count: pendingAudio.count)
        nonisolated(unsafe) var encodedVideo = 0
        nonisolated(unsafe) var lastLoggedFrame = 0
        nonisolated(unsafe) var pipelineError: Error?
        let startedAt = Date()

        let audioWeight: Double = pendingAudio.isEmpty ? 0.0 : 0.10
        let videoWeight: Double = 1.0 - audioWeight

        func reportError(_ e: Error) {
            stateLock.lock()
            if pipelineError == nil { pipelineError = e }
            stateLock.unlock()
        }
        func errorAlreadySet() -> Bool {
            stateLock.lock(); defer { stateLock.unlock() }
            return pipelineError != nil
        }

        // ── Video pump ───────────────────────────────────────────────
        let videoQueue = DispatchQueue(label: "kine.encode.video", qos: .userInitiated)
        let group = DispatchGroup()

        let progressCallback = options.progress
        let isCancelledCheck = { [weak self] in self?.isCancelled ?? true }

        if let videoInput, let adaptor, let pool, let compositorRef = compositor {
            group.enter()
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    if isCancelledCheck() || errorAlreadySet() {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    if nextVideoFrame >= totalVideoFrames {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    let i = nextVideoFrame
                    let didAppend = autoreleasepool { () -> Bool in
                        var outBuf: CVPixelBuffer?
                        var status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf)
                        if status == kCVReturnWouldExceedAllocationThreshold {
                            compositorRef.flushTextureCache()
                            status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf)
                        }
                        guard status == kCVReturnSuccess, let outBuffer = outBuf else {
                            reportError(EncoderError.pixelBufferAllocFailed(status))
                            return false
                        }

                        let timelineTime = options.startSeconds + Double(i) * secondsPerFrame
                        do {
                            try compositorRef.compose(at: timelineTime, into: outBuffer)
                        } catch {
                            reportError(EncoderError.compositorFailed(error.localizedDescription))
                            return false
                        }

                        let pts = CMTime(
                            value: CMTimeValue(Int64(i) * Int64(frameDurationValue)),
                            timescale: CMTimeScale(timescale)
                        )
                        if !adaptor.append(outBuffer, withPresentationTime: pts) {
                            let reason = writer.error?.localizedDescription ?? "unknown"
                            reportError(EncoderError.appendFailed(reason))
                            return false
                        }
                        return true
                    }
                    if !didAppend {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    nextVideoFrame = i + 1
                    encodedVideo += 1
                    let vp = Double(encodedVideo) / Double(totalVideoFrames) * videoWeight
                    let audioDone = audioCursors.reduce(0, +)
                    let ap = totalAudioFrames > 0
                        ? Double(audioDone) / Double(totalAudioFrames) * audioWeight
                        : 0
                    progressCallback?(vp + ap)
                    if encodedVideo - lastLoggedFrame >= 30 || encodedVideo == totalVideoFrames {
                        let elapsed = Date().timeIntervalSince(startedAt)
                        let fps = elapsed > 0 ? Double(encodedVideo) / elapsed : 0
                        KineDebugLog.log("[Encoder] video \(encodedVideo)/\(totalVideoFrames) audio \(audioDone)/\(totalAudioFrames) @ \(String(format: "%.1f", fps)) fps")
                        lastLoggedFrame = encodedVideo
                    }
                }
                // Fell out of the while because AVF throttled us. Return —
                // AVF re-invokes the block when it wants more data.
            }
        }

        // ── Audio pump(s) — one per output track ─────────────────────
        let audioChunkFrames = 4096
        for (jobIndex, job) in pendingAudio.enumerated() {
            let input = job.input
            let fmt = job.formatDesc
            let mix = job.mix
            let channels = job.channelCount
            let frames = mix.first?.count ?? 0
            let queue = DispatchQueue(label: "kine.encode.audio.\(jobIndex)", qos: .userInitiated)
            group.enter()
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if isCancelledCheck() || errorAlreadySet() {
                        input.markAsFinished(); group.leave(); return
                    }
                    let cursor = audioCursors[jobIndex]
                    if cursor >= frames {
                        input.markAsFinished(); group.leave(); return
                    }
                    let take = min(audioChunkFrames, frames - cursor)
                    let didAppend = autoreleasepool { () -> Bool in
                        do {
                            let sb = try Self.makeAudioSampleBuffer(
                                nonInterleaved: mix,
                                startFrame: cursor,
                                frameCount: take,
                                channelCount: channels,
                                sampleRate: audioSampleRate,
                                formatDescription: fmt
                            )
                            if !input.append(sb) {
                                let reason = writer.error?.localizedDescription ?? "unknown"
                                reportError(EncoderError.appendFailed("audio: \(reason)"))
                                return false
                            }
                            return true
                        } catch {
                            reportError(error)
                            return false
                        }
                    }
                    if !didAppend {
                        input.markAsFinished(); group.leave(); return
                    }
                    audioCursors[jobIndex] = cursor + take
                }
            }
        }

        // ── Wait for both pumps, then finish the file ────────────────
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global(qos: .userInitiated)) {
                if pipelineError != nil || self.isCancelled {
                    writer.cancelWriting()
                    cont.resume()
                    return
                }
                writer.finishWriting { cont.resume() }
            }
        }

        compositor?.teardown()
        self.compositor = nil

        if let e = pipelineError { throw e }
        if isCancelled {
            try? fm.removeItem(at: options.outputURL)
            throw EncoderError.cancelled
        }
        if writer.status == .failed {
            throw EncoderError.appendFailed(writer.error?.localizedDescription ?? "writer failed")
        }
        KineDebugLog.log("[Encoder] pass complete: \(encodedVideo) video frames in \(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s")
        options.progress?(1.0)
    }

    // MARK: - Video settings

    /// Build a known-good output settings dictionary. ProRes is fixed-
    /// rate intra-only — no compression properties needed. H.264 and
    /// HEVC need profile + entropy + bitrate + GOP keys; missing any
    /// of those triggers the "stalls at N frames" bug at 4K.
    private static func buildVideoSettings(
        codec: AVVideoCodecType,
        width: Int, height: Int,
        frameRate: FrameRate,
        bitrate: Int,
        profileLevel: String,
        keyframeInterval: Int
    ) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let fpsInt = max(1, Int(frameRate.fps.rounded()))
        switch codec {
        case .proRes422Proxy, .proRes422LT, .proRes422, .proRes422HQ, .proRes4444:
            // Intra-only, fixed-rate. Adding compression-properties is a
            // no-op at best and a confusion at worst.
            break
        case .h264:
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoProfileLevelKey: profileLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: keyframeInterval,
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoExpectedSourceFrameRateKey: fpsInt,
            ]
        case .hevc:
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: keyframeInterval,
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoExpectedSourceFrameRateKey: fpsInt,
            ]
        default:
            break
        }
        return settings
    }

    // MARK: - Audio CMSampleBuffer plumbing

    private static func makeAudioFormatDescription(
        sampleRate: Double, channelCount: Int
    ) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channelCount * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channelCount * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            throw EncoderError.audioFormatCreate(status)
        }
        return format
    }

    private static func makeAudioSampleBuffer(
        nonInterleaved: [[Float]],
        startFrame: Int,
        frameCount: Int,
        channelCount: Int,
        sampleRate: Double,
        formatDescription: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        let bytesPerFrame = channelCount * MemoryLayout<Float>.size
        let dataLength = frameCount * bytesPerFrame

        let block = UnsafeMutableRawPointer.allocate(
            byteCount: dataLength,
            alignment: MemoryLayout<Float>.alignment
        )
        let typedBlock = block.assumingMemoryBound(to: Float.self)
        for i in 0..<frameCount {
            for c in 0..<channelCount {
                let src = c < nonInterleaved.count ? nonInterleaved[c] : nil
                let frameIdx = startFrame + i
                let value: Float = (src != nil && frameIdx < src!.count) ? src![frameIdx] : 0
                typedBlock[i * channelCount + c] = value
            }
        }

        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: block,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard bbStatus == noErr, let blockBuffer else {
            block.deallocate()
            throw EncoderError.audioBlockBufferCreate(bbStatus)
        }

        let pts = CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate))
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frameCount),
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else {
            throw EncoderError.audioSampleBufferCreate(sbStatus)
        }
        return sampleBuffer
    }
}
