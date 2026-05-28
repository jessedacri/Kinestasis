import Foundation
import PolymergeMediaModel

/// Per-track audio data for the real-time mixing engine.
///
/// Holds the audio samples for one input file as raw `UnsafeMutablePointer<Float>`
/// arrays so the render callback can read them with no overhead. Owns the
/// allocations — frees them in `deinit`.
///
/// Two parallel buffers per channel:
/// - **rawChannels**: file audio with HPF (if enabled) but NO phase processing.
///   Read in BYPASS mode.
/// - **processedChannels**: either the same as raw (when no spectral correction)
///   or the spectrally-corrected channels with HPF on top. Read in normal
///   (non-bypass) mode. The integer phase delay is applied at render time as
///   an index offset (only when `usedCorrectedSource` is false), so it does
///   NOT need to be baked into this buffer.
///
/// Mute / solo are read by the audio render callback and toggled by the UI;
/// they're plain `Bool` fields whose individual reads / writes are atomic on
/// aligned memory in Swift. A frame of staleness in the callback is fine for
/// human-perception parameter changes.
///
/// **Lifetime**: TrackBuffer instances are owned by `AudioPlaybackEngine`. When
/// a track's processing changes (HPF, phase), the engine builds a NEW
/// TrackBuffer for that file and atomically swaps it into its `tracks` array,
/// retaining the old one briefly so any in-flight render call can finish.
public final class TrackBuffer {
    public let id: UUID
    public let length: Int                 // sample count per channel
    public let channelCount: Int           // 1 (mono), 2 (stereo), or more
    public let fileOffsetSamples: Int64    // start position in the timeline (samples)

    /// Pan factors. For mono files, both are `0.7071` (equal-power center pan).
    /// For stereo files, ch0 is panned full left (`panLeft = 1`) and ch1 is
    /// panned full right via the second-channel routing in the render callback.
    public let panLeft: Float
    public let panRight: Float

    /// Integer part of the phase delay. Positive = file lags reference. Applied
    /// at render time as `srcSample = outSample - fileOffset + phaseDelayInt`.
    /// Ignored when `bypassPhaseAlign` is on or when `usedCorrectedSource` is true.
    public let phaseDelayInt: Int

    /// True when `processedChannels` came from `AudioFile.correctedChannels`
    /// (already time-aligned + spectrally corrected). When true, the integer
    /// phase delay is NOT applied at render time — the alignment is already
    /// baked in.
    public let usedCorrectedSource: Bool

    /// Raw audio channels — what plays in BYPASS mode. HPF (if enabled) is
    /// already applied here. `rawChannels[ch]` is a length-`length` Float array.
    public let rawChannels: [UnsafeMutablePointer<Float>]

    /// Processed audio channels — what plays in normal mode. HPF (if enabled)
    /// is applied. May be the same buffers as `rawChannels` when no spectral
    /// correction is in use. `processedChannels[ch]` is a length-`length`
    /// Float array.
    public let processedChannels: [UnsafeMutablePointer<Float>]

    /// True when `processedChannels` and `rawChannels` point to the same
    /// allocations. In that case, only the raw set is freed in `deinit`.
    private let processedSharesRaw: Bool

    /// Read by the audio render callback. Mute = output silence for this track.
    public var muted: Bool = false
    /// Read by the audio render callback. When any track is soloed, only soloed
    /// tracks contribute to the output.
    public var soloed: Bool = false

    /// Per-channel mute flags. Length == `channelCount`. The render
    /// block reads element `[ch]` to decide whether to skip that
    /// individual channel. Independent of the file-level `muted`:
    /// a channel is silent if EITHER `muted == true` OR
    /// `mutedChannels[ch] == true`.
    ///
    /// **Why a raw pointer instead of `[Bool]`**: Swift `Array` uses
    /// CoW with reference-counted storage that races catastrophically
    /// under concurrent access between the audio render thread and
    /// the main thread (see DEVELOPMENT.md pitfall #22 — `Array`
    /// `subscript.modify` from main can collide with the audio
    /// thread's read and corrupt the storage pointer). A raw byte
    /// pointer with aligned 1-byte writes is atomic on Apple
    /// hardware so individual channel toggles are race-safe. The
    /// length is fixed at init time so we never need to resize.
    public let mutedChannels: UnsafeMutablePointer<Bool>

    /// Per-channel solo flags. Same memory model as `mutedChannels`.
    /// The render block computes the global `anySoloed` flag by
    /// scanning every track's `.soloed` AND its `soloedChannels`
    /// pointer for any `true` byte. When solo mode is active, only
    /// soloed sources contribute to the output: a channel plays if
    /// `track.soloed || soloedChannels[ch]` is true.
    public let soloedChannels: UnsafeMutablePointer<Bool>

    /// Per-track gain trim as a linear multiplier (1.0 = unity).
    /// Read by the audio render callback on every frame and applied
    /// as a scalar multiply to each output sample. Writing this from
    /// the main thread under the engine's `tracksLock` is safe; the
    /// render block reads it under the same lock so the
    /// acquire-release pair gives the correct cross-thread visibility.
    ///
    /// **Why we apply trim live in the render block instead of baking
    /// it into the buffer:** baking trim into the cached buffer means
    /// every trim change requires a full TrackBufferBuilder rebuild
    /// (load cached raw, copy, apply HPF, apply trim, swap into the
    /// engine), which takes hundreds of milliseconds even with the
    /// raw audio cache. For a slider drag at 60 Hz that's terrible
    /// UX. Applying trim as a scalar multiply at render time costs
    /// one floating point op per sample per channel (essentially
    /// free) and lets trim changes propagate INSTANTLY.
    public var gainScalar: Float = 1.0

    /// Per-track meter state, written by the render callback (audio thread) and
    /// read+reset by the display timer (main thread). MUST be plain scalar
    /// fields, NOT an Array — Swift Array uses CoW with reference-counted
    /// storage that races catastrophically under concurrent access (one
    /// thread's `subscript.modify` can collide with another thread's read,
    /// corrupting the storage pointer and causing an EXC_BAD_ACCESS in
    /// `_platform_memmove` the next time the array reallocates).
    /// Aligned 32-bit Float reads/writes ARE atomic on Apple hardware, so
    /// individual scalars are race-safe even though the four-field group is
    /// not point-in-time consistent (acceptable for visual metering).
    public var meterPeak: Float = 0
    public var meterCh0Peak: Float = 0
    public var meterCh1Peak: Float = 0

    /// Per-source-channel peak accumulators. Length == `channelCount`.
    /// Written by the render block for EVERY source channel (not just
    /// ch0/ch1 like the legacy `meterCh0Peak`/`meterCh1Peak`). Read
    /// by the meter timer to populate `channelDisplayPeaks` on the
    /// observed `TrackMeter`. Raw pointer for the same reason as
    /// `mutedChannels` — no Swift Array CoW races.
    public let meterChannelPeaks: UnsafeMutablePointer<Float>

    /// Reset all meter accumulators to zero. Called by the display timer
    /// after it samples them.
    public func resetMeters() {
        meterPeak = 0
        meterCh0Peak = 0
        meterCh1Peak = 0
        for ch in 0..<channelCount {
            meterChannelPeaks[ch] = 0
        }
    }

    public init(
        id: UUID,
        length: Int,
        channelCount: Int,
        fileOffsetSamples: Int64,
        rawChannels: [[Float]],
        processedChannels: [[Float]]?,   // nil = share raw
        phaseDelayInt: Int,
        usedCorrectedSource: Bool,
        panLeft: Float,
        panRight: Float
    ) {
        precondition(rawChannels.count == channelCount)
        precondition(rawChannels.allSatisfy { $0.count == length })
        if let p = processedChannels {
            precondition(p.count == channelCount)
            precondition(p.allSatisfy { $0.count == length })
        }

        self.id = id
        self.length = length
        self.channelCount = channelCount
        self.fileOffsetSamples = fileOffsetSamples
        self.panLeft = panLeft
        self.panRight = panRight
        self.phaseDelayInt = phaseDelayInt
        self.usedCorrectedSource = usedCorrectedSource

        // Allocate per-channel mute / solo flag arrays. Raw byte
        // pointers (NOT `[Bool]`) because the audio render thread
        // reads these on every render call and Swift `Array`'s CoW
        // races catastrophically with main-thread writes (see
        // DEVELOPMENT.md pitfall #22). Initialized to all-false
        // here; the builder copies the file's actual sets in
        // immediately after construction.
        self.mutedChannels = UnsafeMutablePointer<Bool>.allocate(capacity: channelCount)
        self.mutedChannels.initialize(repeating: false, count: channelCount)
        self.soloedChannels = UnsafeMutablePointer<Bool>.allocate(capacity: channelCount)
        self.soloedChannels.initialize(repeating: false, count: channelCount)
        self.meterChannelPeaks = UnsafeMutablePointer<Float>.allocate(capacity: channelCount)
        self.meterChannelPeaks.initialize(repeating: 0, count: channelCount)

        // Allocate raw buffers and copy in
        self.rawChannels = (0..<channelCount).map { ch in
            let ptr = UnsafeMutablePointer<Float>.allocate(capacity: length)
            ptr.initialize(repeating: 0, count: length)
            rawChannels[ch].withUnsafeBufferPointer { src in
                ptr.update(from: src.baseAddress!, count: length)
            }
            return ptr
        }

        if let p = processedChannels {
            // Allocate separate processed buffers and copy in
            self.processedChannels = (0..<channelCount).map { ch in
                let ptr = UnsafeMutablePointer<Float>.allocate(capacity: length)
                ptr.initialize(repeating: 0, count: length)
                p[ch].withUnsafeBufferPointer { src in
                    ptr.update(from: src.baseAddress!, count: length)
                }
                return ptr
            }
            self.processedSharesRaw = false
        } else {
            // Share the raw buffers — saves memory and a copy
            self.processedChannels = self.rawChannels
            self.processedSharesRaw = true
        }
    }

    deinit {
        for ptr in rawChannels {
            ptr.deinitialize(count: length)
            ptr.deallocate()
        }
        if !processedSharesRaw {
            for ptr in processedChannels {
                ptr.deinitialize(count: length)
                ptr.deallocate()
            }
        }
        mutedChannels.deinitialize(count: channelCount)
        mutedChannels.deallocate()
        soloedChannels.deinitialize(count: channelCount)
        soloedChannels.deallocate()
        meterChannelPeaks.deinitialize(count: channelCount)
        meterChannelPeaks.deallocate()
    }
}
