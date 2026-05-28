import Foundation
import PolymergeMediaModel

public struct TimecodeAligner {
    public struct AlignmentResult {
        public var outputSampleRate: Int
        public var outputBitDepth: Int
        public var outputIsFloat: Bool
        public var outputTotalSamples: UInt64
        public var outputTimecode: TimecodeValue // earliest, expressed at outputSampleRate
        public var fileOffsets: [UUID: Int64]    // file ID -> offset in OUTPUT-RATE samples from output start
        /// Per-file source sample rate. Used by the load sites to know
        /// whether each file needs resampling before being mixed into
        /// the output. Files where source rate ≠ output rate get
        /// resampled by `SampleRateConverter` after loading.
        public var fileSourceSampleRates: [UUID: Int]
        /// True when at least one file's source rate differs from the
        /// output rate. Triggers the "files will be resampled" status
        /// banner in the UI.
        public var hasMixedRates: Bool

        public init(
            outputSampleRate: Int,
            outputBitDepth: Int,
            outputIsFloat: Bool,
            outputTotalSamples: UInt64,
            outputTimecode: TimecodeValue,
            fileOffsets: [UUID: Int64],
            fileSourceSampleRates: [UUID: Int],
            hasMixedRates: Bool
        ) {
            self.outputSampleRate = outputSampleRate
            self.outputBitDepth = outputBitDepth
            self.outputIsFloat = outputIsFloat
            self.outputTotalSamples = outputTotalSamples
            self.outputTimecode = outputTimecode
            self.fileOffsets = fileOffsets
            self.fileSourceSampleRates = fileSourceSampleRates
            self.hasMixedRates = hasMixedRates
        }
    }

    public enum AlignError: LocalizedError {
        case noFiles
        case noTimecodes

        public var errorDescription: String? {
            switch self {
            case .noFiles: return "No files to align"
            case .noTimecodes: return "No files have valid timecode"
            }
        }
    }

    /// Compute the merge timeline.
    ///
    /// **Mixed sample rates are now handled.** When the session contains
    /// files at different sample rates, PolyMerge picks the **highest**
    /// rate as the output rate (so no audio information is lost from
    /// any file — see `SampleRateConverter` for the upsample-vs-
    /// downsample reasoning). The per-file offsets are computed in the
    /// OUTPUT sample rate, derived from each file's TC by going through
    /// seconds-since-midnight as a rate-independent intermediate.
    /// Align files into a merge timeline.
    ///
    /// - Parameters:
    ///   - files: source files (only those with non-nil `timecode` are
    ///     used; others are silently dropped).
    ///   - frameRateOverride: optional override for the output TC's
    ///     frame rate. When nil (the default) we use the earliest
    ///     source file's `timecode.frameRate`. Frame rate is purely a
    ///     metadata / display field — the audio sample positions are
    ///     unaffected by the choice — but downstream NLEs use it to
    ///     interpret the timecode HH:MM:SS:FF, so a mismatch with the
    ///     project's video tracks displays the wrong TC and offsets
    ///     the audio incorrectly. Set this from `ExportConfig.frameRateOverride`.
    public static func align(
        files: [AudioFile],
        frameRateOverride: TimecodeValue.FrameRate? = nil
    ) throws -> AlignmentResult {
        let validFiles = files.filter { $0.timecode != nil }
        guard !validFiles.isEmpty else { throw AlignError.noTimecodes }

        let sourceRates = validFiles.map(\.sampleRate)
        let outputSampleRate = SampleRateConverter.bestCommonRate(forSampleRates: sourceRates)
        let hasMixedRates = SampleRateConverter.sessionHasMixedRates(sourceRates)

        // Find earliest start (in seconds-since-midnight, rate-independent)
        // and latest end (also in seconds), then convert both to OUTPUT
        // sample rate units to build the timeline.
        var earliestSeconds: Double = .greatestFiniteMagnitude
        var earliestTC: TimecodeValue?
        var latestEndSeconds: Double = -.greatestFiniteMagnitude
        for file in validFiles {
            guard let tc = file.timecode else { continue }
            let startSeconds = Double(tc.samplesSinceMidnight) / Double(file.sampleRate)
            let durationSeconds = Double(file.totalSamples) / Double(file.sampleRate)
            let endSeconds = startSeconds + durationSeconds
            if startSeconds < earliestSeconds {
                earliestSeconds = startSeconds
                earliestTC = tc
            }
            if endSeconds > latestEndSeconds {
                latestEndSeconds = endSeconds
            }
        }
        guard let earliestTC else { throw AlignError.noTimecodes }

        // Output total samples in the OUTPUT rate. Round up so we don't
        // truncate the last fractional output sample.
        let totalDurationSeconds = latestEndSeconds - earliestSeconds
        let totalOutputSamples = UInt64((totalDurationSeconds * Double(outputSampleRate)).rounded(.up))

        // Per-file offsets: convert each file's TC to seconds, subtract
        // the session-earliest seconds, then multiply by the output
        // sample rate. This gives the file's position in OUTPUT-RATE
        // samples, which is what AudioMerger and the playback engine
        // both index against. After SRC, every file's audio data is
        // in output-rate samples too, so the offset works directly.
        var offsets: [UUID: Int64] = [:]
        var fileSourceSampleRates: [UUID: Int] = [:]
        for file in validFiles {
            guard let tc = file.timecode else { continue }
            let startSeconds = Double(tc.samplesSinceMidnight) / Double(file.sampleRate)
            let offsetSeconds = startSeconds - earliestSeconds
            let offset = Int64((offsetSeconds * Double(outputSampleRate)).rounded())
            offsets[file.id] = offset
            file.sampleOffset = offset
            fileSourceSampleRates[file.id] = file.sampleRate
        }

        // Re-express the earliest TC at the output sample rate so the
        // output BEXT TimeReference is consistent with the output rate.
        // The frame rate is either the explicit override (Export screen
        // setting) or the earliest source file's rate. Frame rate is
        // metadata-only and doesn't affect any sample positions.
        let earliestSamplesAtOutputRate = UInt64((earliestSeconds * Double(outputSampleRate)).rounded())
        let outputFrameRate = frameRateOverride ?? earliestTC.frameRate
        let outputTimecode = TimecodeValue(
            samplesSinceMidnight: earliestSamplesAtOutputRate,
            sampleRate: outputSampleRate,
            frameRate: outputFrameRate
        )

        // Determine output bit depth (highest among inputs)
        let maxBitDepth = validFiles.map(\.bitDepth).max() ?? 24
        let hasFloat = validFiles.contains { $0.isFloat }

        return AlignmentResult(
            outputSampleRate: outputSampleRate,
            outputBitDepth: hasFloat ? 32 : maxBitDepth,
            outputIsFloat: hasFloat,
            outputTotalSamples: totalOutputSamples,
            outputTimecode: outputTimecode,
            fileOffsets: offsets,
            fileSourceSampleRates: fileSourceSampleRates,
            hasMixedRates: hasMixedRates
        )
    }
}
