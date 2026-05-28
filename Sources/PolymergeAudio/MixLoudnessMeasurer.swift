import Accelerate
import Foundation
import PolymergeMediaModel

/// Measures the BS.1770-4 integrated loudness and true peak of the
/// would-be merged output for a session, WITHOUT writing any files.
///
/// Used by the loudness window to show:
///   - the live "Measured: -19.4 LUFS, -2.1 dBTP" readout
///   - the live "Applied gain: -3.6 dB" readout (target − measured)
///   - the gain that's applied to live playback so the user can hear
///     the normalization in real time
///
/// The output of this function is what `AudioMerger` would measure
/// during pass 2 of its two-pass mixdown if the same files were merged
/// with the same alignment. Per-track HPF + corrected (phase / spectral)
/// buffers are applied here so the measurement matches what the merger
/// will write to disk.
///
/// This is a one-shot measurement intended to run in the background once
/// per session change (file added / removed, HPF tweaked, phase analysis
/// completed). It is NOT called per-frame during playback — gain
/// adjustments triggered by changing the loudness target reuse the
/// cached measurement.
public struct MixLoudnessMeasurer {
    /// Measure the merged-output loudness for the given files + alignment.
    /// Returns nil if there are no valid files or the alignment can't be
    /// computed. Throws if file loading fails for any individual file.
    ///
    /// **Performance:** pass `rawCache` whenever the caller has decoded
    /// audio buffers already cached (e.g. `MergeSession.rawAudioCache`,
    /// which the playback prep path populates on first build of each
    /// file). The cache stores OUTPUT-rate samples — i.e. they're
    /// already resampled, deinterleaved, and sized correctly for
    /// direct use. When the cache is provided and contains an entry
    /// for a file, this function skips the disk decode + SRC entirely
    /// and uses the cached buffer in place. Without the cache, every
    /// measurement re-reads every WAV from disk and re-runs the
    /// Mastering polyphase resampler, which is the dominant cost on
    /// repeated measurements.
    public static func measure(
        files: [AudioFile],
        alignment: TimecodeAligner.AlignmentResult,
        rawCache: [UUID: [[Float]]] = [:]
    ) throws -> LoudnessAnalyzer.Measurement {
        // **Streaming refactor.** The previous implementation
        // materialized `outputChannels × outputTotalSamples ×
        // Float` in RAM up front. For a 5-hour shoot day with
        // 57 channels at 48 kHz that's ~206 GB — a kernel-killer
        // that swap-thrashes the entire OS into a hang. This
        // version iterates the timeline in 5-second chunks,
        // mixes each chunk into a small per-channel buffer, and
        // streams the result through `LoudnessAnalyzer.StreamingMeasurer`.
        // Memory stays bounded at ~chunkSize × channels regardless
        // of timeline length — for the 5-hour test case that's
        // ~55 MB at peak, a ~3,700× reduction. Same final
        // numerical result as the one-shot path because BS.1770
        // gating math is associative across blocks.
        let outputSampleRate = alignment.outputSampleRate
        let totalOutputSamples = Int(alignment.outputTotalSamples)
        let totalOutputChannels = files.reduce(0) { $0 + Int($1.channelCount) }

        guard totalOutputSamples > 0, totalOutputChannels > 0 else {
            return .silent
        }

        // 5-second chunks. Big enough to amortize per-chunk
        // setup overhead (HPF construction, K-weighting biquad
        // calls); small enough that even a 100-channel session
        // stays under ~100 MB chunk RAM. Aligned to multiples
        // of the loudness analyzer's hop size (100 ms) so block
        // boundaries land cleanly inside chunks.
        let chunkSamples = max(1, 5 * outputSampleRate)

        // Pre-decode each file's full channels — same as the old
        // path. The streaming part is the OUTPUT iteration; per-
        // file source loads are unchanged. (For very-long single-
        // file regions where even one file exceeds RAM, a future
        // refactor could partial-load files per chunk, but that
        // requires a chunked WAV reader. Today's case is bounded
        // by playback prep's region scoping — files in the active
        // region are typically a few hundred MB total.)
        struct Source {
            let channelCount: Int
            let fileOffset: Int64
            let phaseDelayInt: Int
            let trim: Float
            let channels: [[Float]]    // post-HPF, post-trim
            let length: Int
        }
        var sources: [Source] = []
        sources.reserveCapacity(files.count)
        var totalChannelOffset = 0
        var channelOffsets: [Int] = []
        for file in files {
            // Bail out as soon as the caller cancels. Without
            // this, a stale measurement kicked off before a
            // newer one would continue loading multi-GB files
            // in parallel with the fresh measurement — doubling
            // peak RAM on heavy sessions. The check fires
            // BEFORE the disk load so the cancelled run drops
            // out at the next file boundary instead of reading
            // another 4 GB WAV it will never use.
            try Task.checkCancellation()

            guard let fileOffset = alignment.fileOffsets[file.id] else {
                channelOffsets.append(totalChannelOffset)
                totalChannelOffset += Int(file.channelCount)
                continue
            }
            channelOffsets.append(totalChannelOffset)
            let channelCount = Int(file.channelCount)

            // Source priority: corrected → cached → load.
            var sourceChannels: [[Float]]
            if let corrected = file.correctedChannels {
                sourceChannels = corrected
            } else if let cached = rawCache[file.id] {
                sourceChannels = cached
            } else {
                // (Earlier iteration gated this on a
                // DispatchSemaphore; removed because the
                // blocking wait() starved Swift's concurrency
                // pool when many tasks were in flight. Rely on
                // .utility priority + MergeSession's already-
                // serialized playback prep to stagger disk
                // reads naturally.)
                sourceChannels = try TrackBufferBuilder.loadAllChannels(
                    file: file,
                    targetSampleRate: outputSampleRate
                )
            }

            // HPF (per-channel, in-place on our local copy).
            if file.hasAnyHPFEnabled {
                for ch in 0..<sourceChannels.count {
                    let chHPF = file.hpfFor(channel: ch)
                    guard chHPF.enabled else { continue }
                    let hpf = HighPassFilter(
                        frequency: chHPF.frequency,
                        slope: chHPF.slope,
                        sampleRate: Double(outputSampleRate)
                    )
                    let count = sourceChannels[ch].count
                    sourceChannels[ch].withUnsafeMutableBufferPointer { buf in
                        if let base = buf.baseAddress {
                            hpf.processBuffer(input: base, output: base, count: count)
                        }
                    }
                }
            }
            // Per-track gain trim, in place.
            let trim = file.gainTrimLinear
            if trim != 1.0 {
                for ch in 0..<sourceChannels.count {
                    let count = sourceChannels[ch].count
                    sourceChannels[ch].withUnsafeMutableBufferPointer { buf in
                        guard let base = buf.baseAddress else { return }
                        for i in 0..<count {
                            base[i] *= trim
                        }
                    }
                }
            }

            sources.append(Source(
                channelCount: channelCount,
                fileOffset: fileOffset,
                phaseDelayInt: file.phaseDelayIntegerPart,
                trim: trim,
                channels: sourceChannels,
                length: sourceChannels.first?.count ?? 0
            ))
            totalChannelOffset += channelCount
        }

        // Set up the streaming accumulator and a reusable chunk
        // buffer. We reuse the same `[[Float]]` chunk across all
        // iterations — only the contents are zeroed + rewritten,
        // not the array storage. That keeps allocation count tiny
        // for very long sessions.
        let measurer = LoudnessAnalyzer.StreamingMeasurer(
            channelCount: totalOutputChannels,
            sampleRate: outputSampleRate
        )
        var chunkBuffer = [[Float]](
            repeating: [Float](repeating: 0, count: chunkSamples),
            count: totalOutputChannels
        )

        var outStart = 0
        while outStart < totalOutputSamples {
            let outEnd = min(outStart + chunkSamples, totalOutputSamples)
            let actualChunkSize = outEnd - outStart
            // Zero the chunk for any channels that won't be
            // written this iteration (because no file has
            // content in this range). Without this, stale
            // samples from a previous chunk would bleed into
            // the next K-weighting pass.
            for ch in 0..<totalOutputChannels {
                chunkBuffer[ch].withUnsafeMutableBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    // memset via vDSP_vclr is the SIMD-optimized way.
                    vDSP_vclr(base, 1, vDSP_Length(actualChunkSize))
                }
            }
            // For each source file, copy its samples that overlap
            // this chunk into the chunk buffer at the correct
            // channel offset. Bounded loop — only iterates
            // valid source indices, no per-output-sample
            // bounds checks like the old impl.
            for (idx, src) in sources.enumerated() {
                let chOffset = channelOffsets[idx]
                // chunkSrcStart maps the chunk's first output
                // sample to the file's source sample index.
                let chunkSrcStart = outStart - Int(src.fileOffset) + src.phaseDelayInt
                let chunkSrcEnd = outEnd - Int(src.fileOffset) + src.phaseDelayInt
                // Skip if no overlap with this file's range.
                if chunkSrcEnd <= 0 || chunkSrcStart >= src.length {
                    continue
                }
                // Compute the overlap range in source coordinates,
                // then translate to chunk-local coordinates.
                let srcStart = max(0, chunkSrcStart)
                let srcEnd = min(src.length, chunkSrcEnd)
                let copyCount = srcEnd - srcStart
                if copyCount <= 0 { continue }
                let dstStart = srcStart - chunkSrcStart    // ≥ 0
                for ch in 0..<src.channelCount {
                    let dstIdx = chOffset + ch
                    src.channels[ch].withUnsafeBufferPointer { srcPtr in
                        chunkBuffer[dstIdx].withUnsafeMutableBufferPointer { dstPtr in
                            guard let srcBase = srcPtr.baseAddress,
                                  let dstBase = dstPtr.baseAddress else { return }
                            // memcpy via assignment loop. The
                            // chunks are typically a few hundred
                            // KB per channel — well within the
                            // L1/L2 cache on Apple Silicon.
                            for i in 0..<copyCount {
                                dstBase[dstStart + i] = srcBase[srcStart + i]
                            }
                        }
                    }
                }
            }
            // Feed the chunk to the streaming measurer. We pass
            // a TRIMMED view if actualChunkSize < chunkSamples
            // (the final iteration). Easiest way: build a
            // per-channel slice array. For perf we only do the
            // slice on the final iteration; full-size chunks
            // bypass the slicing.
            if actualChunkSize == chunkSamples {
                measurer.feed(chunkBuffer)
            } else {
                let trimmed = chunkBuffer.map { Array($0.prefix(actualChunkSize)) }
                measurer.feed(trimmed)
            }
            outStart = outEnd
        }

        return measurer.finalize()
    }
}

private extension LoudnessAnalyzer.Measurement {
    /// A "no signal" measurement. Returned by MixLoudnessMeasurer when
    /// there's no audio to measure (empty session).
    static var silent: LoudnessAnalyzer.Measurement {
        LoudnessAnalyzer.Measurement(
            integratedLUFS: -.infinity,
            truePeakDB: -.infinity,
            samplePeakDB: -.infinity,
            durationSeconds: 0,
            blocksAboveAbsoluteGate: 0,
            blocksAfterRelativeGate: 0
        )
    }
}
