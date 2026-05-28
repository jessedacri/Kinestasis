import Foundation
import Accelerate
import PolymergeMediaModel

/// Builds `TrackBuffer` instances from `AudioFile` source files.
///
/// Reads the WAV data, applies HPF (if enabled), determines whether to use
/// the spectrally-corrected source channels, and packages everything into a
/// real-time-ready `TrackBuffer`.
///
/// This is the bridge between the file-based world (`AudioFile` + WAV I/O)
/// and the audio-thread world (`TrackBuffer` + raw float pointers).
public struct TrackBufferBuilder {

    public enum BuildError: LocalizedError {
        case readError(String)

        public var errorDescription: String? {
            switch self {
            case .readError(let msg): return msg
            }
        }
    }

    /// Build a TrackBuffer for one file at the given file offset (samples
    /// from the start of the timeline).
    ///
    /// `cachedRaw`: optional pre-decoded raw audio for the file. When the
    /// caller already has this in memory (typical for HPF rebuilds — the
    /// session caches it after the first build), we reuse it instead of
    /// re-reading the WAV from disk. This is the single biggest perf win
    /// for the rebuild path.
    /// Build a TrackBuffer for the given file.
    ///
    /// `parent`: when `file` is a channel sibling (its `parentFileID`
    /// is non-nil), pass the parent AudioFile here. Per-channel state
    /// (HPF, mute/solo, channel exclusion, gain trim) lives on the
    /// PARENT — siblings exist purely as engine entities. This builder
    /// reads the parent's state at the sibling's `sourceChannelIndex`
    /// and seeds the resulting TrackBuffer accordingly. Pass nil for
    /// non-sibling files (today's behavior).
    public static func build(
        file: AudioFile,
        fileOffsetSamples: Int64,
        cachedRaw: [[Float]]? = nil,
        parent: AudioFile? = nil
    ) throws -> TrackBuffer {
        // Source audio:
        //   1. If file has spectrally-corrected channels → use them as the
        //      processed source. They're already time-aligned. The raw set
        //      is loaded separately for BYPASS mode.
        //   2. Otherwise: load raw audio once, share between raw and processed
        //      (the integer phase delay is applied at render time).

        // Use the cached raw audio if available; otherwise load from disk.
        // The cached array uses Swift's CoW — when we mutate `rawSource[ch][i]`
        // below, the inner array is uniquely-copied before mutation, leaving
        // the cache untouched. (Verified: toggling HPF off after enabling it
        // returns to the unfiltered original sum.)
        var rawSource: [[Float]]
        if let cached = cachedRaw {
            rawSource = cached
        } else {
            rawSource = try loadAllChannels(file: file)
        }

        // If spectral correction is in effect, the processed source comes
        // from the corrected buffer, not the raw file
        var processedSource: [[Float]]? = nil
        let usedCorrected: Bool
        if let corrected = file.correctedChannels {
            processedSource = corrected
            usedCorrected = true
        } else {
            usedCorrected = false
        }
        let ccLen = file.correctedChannels?.first?.count ?? 0
        let ccCh = file.correctedChannels?.count ?? 0
        print("[ALIGN-DIAG] TBB.build file=\(file.filename) ch=\(file.channelCount) rawLen=\(rawSource.first?.count ?? 0) correctedChannels=\(ccCh)ch len=\(ccLen) usedCorrected=\(usedCorrected) phaseDelayInt=\(file.phaseDelayIntegerPart)")

        // **Sibling state lookup.** When `file` is a channel sibling,
        // per-channel UI state lives on the PARENT and we must read
        // it at the sibling's `sourceChannelIndex`. For non-siblings
        // these resolvers fall through to the file's own state.
        let stateProvider: AudioFile = parent ?? file
        let stateChannelIndex: Int? = file.sourceChannelIndex

        // Apply HPF per-channel. For sibling files, channelCount is
        // 1 but the HPF setting we want to apply is the parent's
        // per-channel HPF at `sourceChannelIndex`. For non-siblings,
        // `stateProvider == file` and `stateChannelIndex == nil`, so
        // the loop reads `file.hpfFor(channel: ch)` exactly as today.
        let anyHPFEnabledForBuild: Bool
        if let chIdx = stateChannelIndex {
            anyHPFEnabledForBuild = stateProvider.hpfFor(channel: chIdx).enabled
        } else {
            anyHPFEnabledForBuild = stateProvider.hasAnyHPFEnabled
        }
        if anyHPFEnabledForBuild {
            let sr = Double(file.sampleRate)

            // Raw set
            for ch in 0..<rawSource.count {
                // Map this sibling channel back to the parent's channel
                // index when applicable. Sibling has chCount=1, ch=0,
                // resolves to parent.hpfFor(sourceChannelIndex).
                let stateCh = stateChannelIndex ?? ch
                let chHPF = stateProvider.hpfFor(channel: stateCh)
                guard chHPF.enabled else { continue }
                let hpf = HighPassFilter(frequency: chHPF.frequency, slope: chHPF.slope, sampleRate: sr)
                let count = rawSource[ch].count
                rawSource[ch].withUnsafeMutableBufferPointer { buf in
                    let base = buf.baseAddress!
                    hpf.processBuffer(input: base, output: base, count: count)
                }
            }
            // Processed set (only if it's a separate buffer from raw)
            if processedSource != nil {
                for ch in 0..<processedSource!.count {
                    let stateCh = stateChannelIndex ?? ch
                    let chHPF = stateProvider.hpfFor(channel: stateCh)
                    guard chHPF.enabled else { continue }
                    let hpf = HighPassFilter(frequency: chHPF.frequency, slope: chHPF.slope, sampleRate: sr)
                    let count = processedSource![ch].count
                    processedSource![ch].withUnsafeMutableBufferPointer { buf in
                        let base = buf.baseAddress!
                        hpf.processBuffer(input: base, output: base, count: count)
                    }
                }
            }
        }

        // **Per-track gain trim is NOT baked into the buffer here.**
        // The playback engine's render block applies trim live as
        // a scalar multiply via `TrackBuffer.gainScalar`, so trim
        // changes propagate INSTANTLY (~5-10 ms) without needing a
        // buffer rebuild. Baking it in would require a rebuild on
        // every slider tick which produces visibly slow UX even
        // with the cached raw audio. The merger still applies trim
        // separately in its mixdown so the merged output reflects
        // the final user-set trim value at merge time.

        // Compute pan factors
        // mono → equal-power center
        // stereo → ch0 panned full L, ch1 panned full R via render-time routing
        let channelCount = rawSource.count
        let panLeft: Float
        let panRight: Float
        if channelCount == 1 {
            panLeft = 0.7071
            panRight = 0.7071
        } else {
            panLeft = 1.0
            panRight = 1.0
        }

        let length = rawSource[0].count

        let buffer = TrackBuffer(
            id: file.id,
            length: length,
            channelCount: channelCount,
            fileOffsetSamples: fileOffsetSamples,
            rawChannels: rawSource,
            processedChannels: processedSource,
            phaseDelayInt: file.phaseDelayIntegerPart,
            usedCorrectedSource: usedCorrected,
            panLeft: panLeft,
            panRight: panRight
        )
        // Seed the live gain scalar — sibling reads parent's gain.
        buffer.gainScalar = stateProvider.gainTrimLinear

        // Seed per-channel mute / solo state. For siblings, the
        // sibling's single channel maps to the parent's channel at
        // `sourceChannelIndex`. For non-siblings, identity mapping
        // (today's behavior).
        for ch in 0..<channelCount {
            let stateCh = stateChannelIndex ?? ch
            if stateProvider.mutedChannels.contains(stateCh) {
                buffer.mutedChannels[ch] = true
            }
            if stateProvider.soloedChannels.contains(stateCh) {
                buffer.soloedChannels[ch] = true
            }
        }
        // Whole-file mute / solo. Sibling inherits parent's whole-
        // file mute (e.g., user mutes the parent BWF → all 6
        // siblings silenced). We OR in the parent's per-channel
        // mute at the sibling's channel index too, so a per-channel
        // mute on the parent ("mute lav 2") silences just sibling 2
        // even though the parent's whole-file mute is off.
        if let chIdx = stateChannelIndex {
            buffer.muted = stateProvider.muted
                || stateProvider.mutedChannels.contains(chIdx)
            buffer.soloed = stateProvider.soloed
                || stateProvider.soloedChannels.contains(chIdx)
        } else {
            buffer.muted = file.muted
            buffer.soloed = file.soloed
        }
        return buffer
    }

    /// Public load helper — read the WAV's PCM data into per-channel Float
    /// arrays. Used by `MergeSession` to populate its raw-audio cache.
    /// Pass `targetSampleRate` to have the loader automatically resample
    /// the audio to a common output rate (used in multi-rate sessions).
    /// Pass `maxSamples` to cap the read at the first N source-rate samples
    /// (used by LTC scans — they only need the first 10 seconds, not the
    /// full file).
    /// Pass `progress` to receive a completion fraction in [0, 1] as each
    /// 16 MB chunk is read. Fired from the background thread; callers
    /// must hop to the main actor for UI updates.
    public static func loadRawAudio(
        file: AudioFile,
        targetSampleRate: Int? = nil,
        maxSamples: Int? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> [[Float]] {
        try loadAllChannels(
            file: file,
            targetSampleRate: targetSampleRate,
            maxSamples: maxSamples,
            progress: progress
        )
    }

    /// Load all channels of a file as separate Float arrays.
    ///
    /// **Hot path — heavily optimized.** The previous implementation
    /// called `data.withUnsafeBytes { ... }` and switched on bit
    /// depth INSIDE the inner per-sample loop, which meant a closure
    /// allocation + branch prediction miss + function call PER
    /// sample. For a 5-minute stereo file at 48 kHz that's 30 million
    /// closure calls — multiple seconds of pointless overhead.
    /// The current version lifts the raw byte pointer out of the
    /// loop, dispatches once on (bitDepth, isFloat), and uses vDSP
    /// for the int → float conversion where possible. Roughly
    /// 50-100× faster on typical material.
    ///
    /// `targetSampleRate`: when non-nil and different from `file.sampleRate`,
    /// the loaded audio is resampled to the target rate via `SampleRateConverter`
    /// (Apple's mastering-quality polyphase resampler) before being returned.
    /// Used for multi-rate sessions where every file must end up at a
    /// common rate before mixing.
    public static func loadAllChannels(
        file: AudioFile,
        targetSampleRate: Int? = nil,
        maxSamples: Int? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> [[Float]] {
        // Check for cancellation before doing anything expensive.
        // `preparePlayback` can cancel its Task.detached when a newer
        // prep comes in; the hot path (`handle.read` of multi-GB) is
        // syscall-uninterruptible, so the checkpoint here catches the
        // case where the task was cancelled between enqueue and start.
        try Task.checkCancellation()

        // F_NOCACHE: this reads the whole file once into a Float
        // buffer that gets copied into the playback engine's
        // TrackBuffer. After this call returns we never re-read
        // from this FD, so unified buffer caching just pollutes
        // the page cache with evictable-but-charged-to-process
        // memory that Activity Monitor counts against PolyMerge.
        guard let handle = try? NoCacheFileHandle.open(url: file.url) else {
            throw BuildError.readError("Cannot open \(file.filename)")
        }
        defer { try? handle.close() }

        // `maxSamples` clamps the source-rate sample count for this
        // load. LTC scans pass `maxSamples = sampleRate * 11 s` so we
        // read ~4 MB per file instead of the full 2+ GB. Still produces
        // enough audio for `LTCDecoder` to lock onto a frame boundary
        // and extrapolate TC-at-start.
        let fullFileSamples = Int(file.totalSamples)
        let totalSamples: Int
        if let cap = maxSamples {
            totalSamples = min(fullFileSamples, max(0, cap))
        } else {
            totalSamples = fullFileSamples
        }
        let channels = Int(file.channelCount)
        let blockAlign = file.blockAlign
        let totalBytes = totalSamples * blockAlign

        print("[TBB] load start \(file.filename) samples=\(totalSamples)\(maxSamples != nil ? " (capped from \(fullFileSamples))" : "") channels=\(channels)")

        handle.seek(toFileOffset: file.dataChunkOffset)

        // **Single pre-allocated buffer, chunked `read(2)`.**
        //
        // Previously we looped `handle.read(upToCount: 64MB)` and
        // `Data.append`-ed each chunk into a growing Data. That
        // pattern has two problems on fast SSDs:
        //   1. Even with `reserveCapacity`, `Data.append(_:)` copies
        //      the chunk's bytes into the Data's backing store — a
        //      second memcpy per chunk. For a 2 GB file that's 2 GB
        //      of extra memory bandwidth consumed.
        //   2. `FileHandle.read(upToCount:)` allocates a fresh Data
        //      per call, then the Data goes through Swift's
        //      Foundation bridge. Measured cost: ~30-40% overhead vs
        //      raw POSIX `read(2)` into a preallocated buffer.
        //
        // The user reported 403 MB/s `dd` speed on this drive vs
        // 270 MB/s observed in prep — the ~33% delta is this
        // overhead. The fix: allocate a single raw buffer of
        // `totalBytes`, loop POSIX `read(2)` directly into it, and
        // wrap the result in a no-copy `Data` for the downstream
        // decode path (which does `data.withUnsafeBytes { ... }`
        // anyway).
        //
        // Chunking to 64 MB is still preserved so the cancellation
        // checkpoint + progress callback have a hook mid-file.
        let chunkBytes = 64 * 1024 * 1024
        let progressThreshold = 128 * 1024 * 1024
        let data: Data
        let fd = handle.fileDescriptor
        // Allocate one contiguous buffer large enough for the whole
        // read. Owned by a `Data` that frees it on dealloc via
        // `.free` deallocator. For huge files this is a single
        // ~2-14 GB malloc rather than growing through many reallocs.
        let rawBuf = UnsafeMutableRawPointer.allocate(
            byteCount: totalBytes,
            alignment: MemoryLayout<UInt8>.alignment
        )
        var bytesRead = 0
        var lastProgressFireBytes = 0
        while bytesRead < totalBytes {
            try Task.checkCancellation()
            let remaining = totalBytes - bytesRead
            let toRead = min(chunkBytes, remaining)
            let n = Darwin.read(fd, rawBuf.advanced(by: bytesRead), toRead)
            if n <= 0 { break }  // EOF or error
            bytesRead += n
            if bytesRead - lastProgressFireBytes >= progressThreshold
                || bytesRead == totalBytes {
                progress?(Double(bytesRead) / Double(totalBytes))
                lastProgressFireBytes = bytesRead
            }
        }
        guard bytesRead >= totalBytes else {
            rawBuf.deallocate()
            throw BuildError.readError("Cannot read \(file.filename) (short read \(bytesRead)/\(totalBytes) bytes)")
        }
        // No-copy wrap: Data takes ownership of the buffer and
        // calls `.free` (our deallocator) when it's destroyed.
        data = Data(
            bytesNoCopy: rawBuf,
            count: totalBytes,
            deallocator: .custom { ptr, _ in ptr.deallocate() }
        )

        // Guard the giant allocation: for a 5-hour 14-channel poly
        // this is ~40 GB of zero-initialized float. Checking
        // cancellation here means a cancelled task drops BEFORE
        // committing that memory, which is the single most important
        // checkpoint in this whole function for RAM stability.
        try Task.checkCancellation()
        var buffers = Array(
            repeating: [Float](repeating: 0, count: totalSamples),
            count: channels
        )

        // Single withUnsafeBytes wrapping the entire decode + deinterleave.
        // The branches on bitDepth/isFloat happen ONCE here, not per sample.
        data.withUnsafeBytes { rawBuffer in
            guard let basePtr = rawBuffer.baseAddress else { return }

            if file.isFloat && file.bitDepth == 32 {
                // 32-bit float — already in the target format. Use vDSP_zvmov
                // (or just a strided copy via vDSP_vsadd with 0) to deinterleave.
                let floatPtr = basePtr.assumingMemoryBound(to: Float.self)
                deinterleaveFloat(
                    src: floatPtr, channels: channels,
                    totalSamples: totalSamples, into: &buffers
                )
            } else if file.bitDepth == 16 {
                // 16-bit signed int → float. vDSP_vflt16 is the
                // SIMD-optimized conversion; we use it per channel
                // with a stride to deinterleave.
                let i16Ptr = basePtr.assumingMemoryBound(to: Int16.self)
                var scale: Float = 1.0 / 32768.0
                for ch in 0..<channels {
                    buffers[ch].withUnsafeMutableBufferPointer { dst in
                        guard let dstBase = dst.baseAddress else { return }
                        // Deinterleave + convert to float
                        vDSP_vflt16(
                            i16Ptr.advanced(by: ch),
                            vDSP_Stride(channels),
                            dstBase, 1,
                            vDSP_Length(totalSamples)
                        )
                        // Scale to [-1, 1]
                        vDSP_vsmul(
                            dstBase, 1, &scale,
                            dstBase, 1,
                            vDSP_Length(totalSamples)
                        )
                    }
                }
            } else if file.bitDepth == 24 {
                // 24-bit packed PCM (no native Swift type). Manual
                // unrolled loop with raw byte pointer access — still
                // ~30× faster than the old per-sample closure path.
                let bytePtr = basePtr.assumingMemoryBound(to: UInt8.self)
                let scale: Float = 1.0 / 8388608.0
                for ch in 0..<channels {
                    let chOffset = ch * 3
                    buffers[ch].withUnsafeMutableBufferPointer { dst in
                        guard let dstBase = dst.baseAddress else { return }
                        for s in 0..<totalSamples {
                            let off = s * blockAlign + chOffset
                            // Read 3 bytes as little-endian int24, sign extend
                            var i32 = Int32(bytePtr[off])
                                    | (Int32(bytePtr[off + 1]) << 8)
                                    | (Int32(bytePtr[off + 2]) << 16)
                            if i32 & 0x800000 != 0 { i32 |= Int32(bitPattern: 0xFF000000) }
                            dstBase[s] = Float(i32) * scale
                        }
                    }
                }
            } else if file.bitDepth == 32 {
                // 32-bit signed int → float. vDSP_vflt32.
                let i32Ptr = basePtr.assumingMemoryBound(to: Int32.self)
                var scale: Float = 1.0 / 2147483648.0
                for ch in 0..<channels {
                    buffers[ch].withUnsafeMutableBufferPointer { dst in
                        guard let dstBase = dst.baseAddress else { return }
                        vDSP_vflt32(
                            i32Ptr.advanced(by: ch),
                            vDSP_Stride(channels),
                            dstBase, 1,
                            vDSP_Length(totalSamples)
                        )
                        vDSP_vsmul(
                            dstBase, 1, &scale,
                            dstBase, 1,
                            vDSP_Length(totalSamples)
                        )
                    }
                }
            }
            // Other bit depths fall through with zero buffers — unsupported.
        }

        // Resample to target rate if requested and the file is at a
        // different rate. The result has the same number of channels
        // but a different number of samples per channel.
        if let target = targetSampleRate, target != file.sampleRate {
            return try SampleRateConverter.convert(
                samples: buffers,
                sourceRate: file.sampleRate,
                targetRate: target
            )
        }
        return buffers
    }

    /// Deinterleave a 32-bit float buffer into per-channel arrays.
    /// Uses a strided copy per channel — fast for small channel
    /// counts (1-8) which is the only realistic case for production
    /// audio.
    private static func deinterleaveFloat(
        src: UnsafePointer<Float>,
        channels: Int,
        totalSamples: Int,
        into buffers: inout [[Float]]
    ) {
        for ch in 0..<channels {
            buffers[ch].withUnsafeMutableBufferPointer { dst in
                guard let dstBase = dst.baseAddress else { return }
                // Identity copy with stride: src[ch], src[ch+channels], ...
                // -> dst[0], dst[1], ...
                vDSP_mmov(
                    src.advanced(by: ch), dstBase,
                    1, vDSP_Length(totalSamples),
                    vDSP_Length(channels), 1
                )
            }
        }
    }
}
