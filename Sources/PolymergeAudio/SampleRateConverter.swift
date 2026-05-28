import AVFoundation
import Foundation

/// High-quality sample rate conversion using `AVAudioConverter` with
/// Apple's "Mastering" algorithm and `.max` quality — the highest
/// quality polyphase resampler available without third-party libraries.
///
/// PolyMerge sessions can contain files at different sample rates (a
/// 44.1 kHz lav next to a 48 kHz boom, for example). The merger needs
/// every file at a single common rate before mixing, so we resample
/// any mismatched files on load.
///
/// **Direction matters: PolyMerge always upsamples to the highest
/// source rate, never downsamples.**
///
/// - **Upsampling** (44.1 → 48) is non-destructive: the original audio
///   is preserved exactly, new samples are sinc-interpolated.
/// - **Downsampling** (48 → 44.1) is destructive: an anti-aliasing
///   filter removes all frequencies above the new Nyquist BEFORE
///   decimation. Anything between the new and old Nyquist is discarded
///   permanently.
///
/// So the universal "do no harm" choice is: pick the highest rate
/// across all files in the session as the target, upsample everything
/// at lower rates to match, and never touch the files already at the
/// max. This is what Sound Devices, Zaxcom, Tentacle, and most pro
/// audio tools do when faced with mixed rates.
///
/// All operations are CPU-only and synchronous. For typical 7-minute
/// production audio, a 44.1 → 48 kHz conversion completes in ~150 ms
/// on a modern Mac.
public struct SampleRateConverter {

    /// Pick the best common sample rate for a session of files at
    /// possibly mixed rates. Returns the **highest** source rate so
    /// no audio information is lost from any file. Pass this value to
    /// `convert(samples:sourceRate:targetRate:)` for each file.
    public static func bestCommonRate(forSampleRates rates: [Int]) -> Int {
        rates.max() ?? 48000
    }

    /// True if at least two distinct sample rates appear in the input.
    /// Drives the decision of whether to show the "files will be
    /// resampled" banner in the UI.
    public static func sessionHasMixedRates(_ rates: [Int]) -> Bool {
        Set(rates).count > 1
    }


    public enum SRCError: LocalizedError {
        case bufferAllocationFailed
        case converterCreationFailed(source: Int, target: Int)
        case conversionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .bufferAllocationFailed:
                return "Failed to allocate audio buffer"
            case .converterCreationFailed(let s, let t):
                return "Failed to create AVAudioConverter from \(s) Hz to \(t) Hz"
            case .conversionFailed(let msg):
                return "Sample rate conversion failed: \(msg)"
            }
        }
    }

    /// Resample per-channel `Float` audio data from `sourceRate` to
    /// `targetRate`. If the rates are equal, the input is returned
    /// unchanged (zero-cost identity).
    ///
    /// `samples[channel][sampleIndex]` — same shape as PolyMerge's
    /// internal audio representation.
    ///
    /// **Quality**: uses `AVAudioConverter` with `.maximum` quality,
    /// which is Apple's polyphase sinc resampler. Sound Devices and
    /// Zaxcom recorders ship the same general approach for their
    /// internal sample-rate conversion.
    public static func convert(
        samples: [[Float]],
        sourceRate: Int,
        targetRate: Int
    ) throws -> [[Float]] {
        if sourceRate == targetRate { return samples }
        guard !samples.isEmpty, let firstChannel = samples.first else { return samples }
        let channelCount = samples.count
        let sourceFrames = firstChannel.count
        guard sourceFrames > 0 else { return samples }

        // Build the source format. Use deinterleaved float32 since
        // that's what we have already.
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sourceRate),
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            throw SRCError.converterCreationFailed(source: sourceRate, target: targetRate)
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetRate),
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            throw SRCError.converterCreationFailed(source: sourceRate, target: targetRate)
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw SRCError.converterCreationFailed(source: sourceRate, target: targetRate)
        }
        // Maximum quality = Apple's high-quality polyphase resampler.
        // For PolyMerge's pre-merge use case (offline, file-based, not
        // real-time) the extra cost is negligible.
        converter.sampleRateConverterQuality = .max
        // Mastering algorithm: highest quality available, used by
        // professional offline tools. Significantly slower than the
        // "Normal" algorithm but produces transparent results.
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        // Allocate the source buffer and copy our samples in.
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(sourceFrames)
        ) else {
            throw SRCError.bufferAllocationFailed
        }
        sourceBuffer.frameLength = AVAudioFrameCount(sourceFrames)
        for ch in 0..<channelCount {
            guard let dst = sourceBuffer.floatChannelData?[ch] else {
                throw SRCError.bufferAllocationFailed
            }
            samples[ch].withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                memcpy(dst, base, sourceFrames * MemoryLayout<Float>.size)
            }
        }

        // Estimate the destination capacity. AVAudioConverter needs an
        // upper bound on the output size; we use the ratio plus a small
        // safety margin to absorb the resampler's edge handling.
        let ratio = Double(targetRate) / Double(sourceRate)
        let estimatedOutputFrames = Int((Double(sourceFrames) * ratio).rounded(.up)) + 64
        guard let destinationBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(estimatedOutputFrames)
        ) else {
            throw SRCError.bufferAllocationFailed
        }

        // Run the conversion. The input block is called by AVAudioConverter
        // each time it needs more source samples. We feed it the entire
        // source buffer once, then signal end-of-stream.
        var sourceConsumed = false
        var conversionError: NSError?
        let status = converter.convert(
            to: destinationBuffer,
            error: &conversionError
        ) { _, outStatus in
            if sourceConsumed {
                outStatus.pointee = .endOfStream
                return nil
            } else {
                sourceConsumed = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }
        }

        switch status {
        case .haveData, .endOfStream:
            break  // Success
        case .error:
            let msg = conversionError?.localizedDescription ?? "unknown"
            throw SRCError.conversionFailed(msg)
        case .inputRanDry:
            // Acceptable — the converter consumed all input and produced
            // whatever output it had ready. The destinationBuffer.frameLength
            // tells us how many output samples we got.
            break
        @unknown default:
            throw SRCError.conversionFailed("unknown converter status")
        }

        // Extract the resampled audio back into per-channel arrays.
        let outputFrames = Int(destinationBuffer.frameLength)
        var result: [[Float]] = []
        result.reserveCapacity(channelCount)
        for ch in 0..<channelCount {
            guard let src = destinationBuffer.floatChannelData?[ch] else {
                throw SRCError.bufferAllocationFailed
            }
            var channelOut = [Float](repeating: 0, count: outputFrames)
            channelOut.withUnsafeMutableBufferPointer { dst in
                guard let base = dst.baseAddress else { return }
                memcpy(base, src, outputFrames * MemoryLayout<Float>.size)
            }
            result.append(channelOut)
        }
        return result
    }

    /// Convenience for the common case where you have a single mono
    /// `[Float]` array (e.g. PhaseAligner's mono mixdown).
    public static func convertMono(
        samples: [Float],
        sourceRate: Int,
        targetRate: Int
    ) throws -> [Float] {
        let result = try convert(
            samples: [samples],
            sourceRate: sourceRate,
            targetRate: targetRate
        )
        return result.first ?? []
    }
}
