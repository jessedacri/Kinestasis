import SwiftUI

@Observable
public class AudioFile: Identifiable {
    public let id: UUID
    public let url: URL
    public let filename: String

    // MARK: - Channel Sibling Architecture
    //
    // Multi-channel polys (e.g. a Sound Devices 6-channel BWF with
    // boom + 4 lavs + mix) are split at parse time into N "channel
    // sibling" AudioFile entries — one per source channel — that
    // share the same on-disk URL. Each sibling represents a single
    // channel of the parent and carries `channelCount = 1`.
    //
    // Why split? Intra-file dynamic + spectral phase alignment.
    // The existing inter-file phase aligner already handles per-pair
    // dynamic windowing, spectral correction, drift trajectory
    // storage, and UI rendering. By splitting a poly into mono
    // siblings on import, the existing pipeline "just works"
    // intra-file with zero new alignment code.
    //
    // The split is HIDDEN from the user. The file list, file cards,
    // and timeline still present "one BWF" per parent — operations
    // on the parent card fan out to its siblings. Per-channel
    // controls (mute/solo/HPF/trim) on the parent's existing
    // per-channel UI route to the matching sibling. The user never
    // sees the underlying split.
    //
    // `parentFileID == nil` means this file is either a true mono
    // recording OR the parent of a sibling group (the parent itself
    // is kept as a session entity for UI display — siblings live
    // alongside it but are filtered out of user-facing surfaces).
    // The split is materialized only when channelCount > 1.

    /// When non-nil, this file is a channel sibling. The value is
    /// the UUID of the parent AudioFile (the one shown to the user).
    /// Siblings share the parent's URL, dataChunkOffset, sampleRate,
    /// timecode, BEXT, iXML, etc. Differences: channelCount = 1,
    /// `sourceChannelIndex` = which channel of the parent this is.
    public var parentFileID: UUID?

    /// When this file is a channel sibling, the index (0-based) into
    /// the parent's channel list that this sibling represents.
    /// Used by `TrackBufferBuilder` + `MergeSession` cache to load
    /// the parent's audio once and dispatch the right channel slice
    /// into each sibling's TrackBuffer. Nil for non-siblings.
    public var sourceChannelIndex: Int?

    /// Convenience: true when this file is a channel sibling
    /// (has a non-nil `parentFileID`).
    public var isChannelSibling: Bool { parentFileID != nil }

    // Format info (from fmt chunk)
    public var sampleRate: Int
    public var bitDepth: Int
    public var channelCount: UInt16
    public var formatTag: UInt16 // 1=PCM, 3=IEEE Float, 0xFFFE=Extensible
    public var totalSamples: UInt64
    public var isFloat: Bool

    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(totalSamples) / Double(sampleRate)
    }

    // Timecode
    public var timecode: TimecodeValue?
    public var timecodeSource: TimecodeSource?

    public enum TimecodeSource: String {
        case bext = "BEXT"
        case ixml = "iXML"
        case manual = "Manual"
        case audioLTC = "Audio LTC"        // decoded from a striped LTC channel
        case waveformSync = "Audio Sync"   // inferred via cross-correlation to a reference
    }

    // iXML metadata
    public var trackName: String?
    public var scene: String?
    public var take: String?
    public var deviceInfo: String?

    // User overrides (set via track config UI)
    public var customTrackName: String?  // overrides iXML trackName for display
    public var customLabel: String?      // overrides smart abbreviation for timeline label
    public var notes: String = ""        // free-text notes for editorial

    // BEXT metadata
    public var bextDescription: String?
    public var originationDate: String?
    public var originationTime: String?
    public var codingHistory: String?

    // Display
    public var color: Color
    public var isReference: Bool = false
    public var waveformData: [Float]?

    /// Per-channel waveform peaks. Outer index is channel, inner array
    /// is the per-display-point peak amplitude. Populated by the
    /// background `WaveformGenerator.generatePerChannel` scan when the
    /// file is added. The timeline uses this to render one waveform
    /// row PER CHANNEL of a multi-channel file (instead of collapsing
    /// all channels into the single combined `waveformData`).
    public var waveformChannels: [[Float]]?

    /// Detected LTC scan result (channel + decoder result + the
    /// computed TC at sample 0). Set by `MergeSession.detectLTC` when
    /// the user invokes "Detect LTC stripe" on the track setup card.
    /// The detected TC is NOT auto-applied — the user reviews and
    /// confirms via the UI before it overwrites `timecode`.
    public var ltcDetection: LTCDetection?

    /// True while a background LTC scan is running for this file.
    /// Drives a spinner on the track setup card.
    public var ltcScanInProgress: Bool = false

    /// Inferred TC from a waveform sync against a reference track.
    /// Same "ask first" pattern as `ltcDetection` — set by the
    /// inference task, applied via the user's confirmation.
    public var inferredWaveformTimecode: TimecodeValue?
    /// Confidence score from the cross-correlation that produced
    /// `inferredWaveformTimecode`. Surfaced in the UI so the user
    /// can sanity-check before applying. Higher = more reliable;
    /// values >5 are very confident, 1.5..5 are plausible, <1.5
    /// would have been rejected as noise.
    public var inferredWaveformConfidence: Double = 0
    /// Raw delay (in samples at the reference's sample rate) the
    /// cross-correlation reported. Surfaced in the UI for debugging
    /// and so the user can convert it to seconds at a glance.
    public var inferredWaveformDelaySamples: Int64 = 0
    /// ID of the file that was used as the reference for the
    /// inference. Stored so the popover/result UI can show "synced
    /// against [exact file]" even after the user changes the active
    /// session reference between sync and apply. Without this, the
    /// "synced against" badge would always read the CURRENT session
    /// ref, which can lie if the user changed it post-sync.
    public var inferredWaveformReferenceID: UUID?

    /// True while a background waveform sync is running for this file.
    public var waveformSyncInProgress: Bool = false
    /// Human-readable status of the in-progress waveform sync. Drives
    /// the per-file progress UI (e.g. "Loading reference audio…",
    /// "Cross-correlating…"). Empty when no scan is running.
    public var waveformSyncStatus: String = ""

    /// Status string for the in-progress LTC scan. Same purpose as
    /// `waveformSyncStatus`.
    public var ltcScanStatus: String = ""

    // Per-track processing

    /// Per-channel high-pass filter settings. ONE entry per source
    /// channel of the file (length == channelCount). Replaces the
    /// previous file-level `hpfEnabled / hpfFrequency / hpfSlope`
    /// triple, which forced all channels of a poly source to share
    /// the same HPF — wrong for production audio where the L and R
    /// of a "bonded" stereo file are routinely independent mics
    /// (e.g. a Sound Devices LR boom feed where L is the lav and R
    /// is the wireless boom). The new model lets each channel have
    /// its own HPF settings independently.
    ///
    /// Initialized to all-disabled `ChannelHPF()` defaults at parse
    /// time via `ensureChannelHPFInitialized()`. The session-level
    /// `setHPF(fileID:channel:...)` API and the HPF tool window
    /// both write through this array.
    ///
    /// **Reading from the engine paths** (AudioMerger,
    /// TrackBufferBuilder, MixLoudnessMeasurer): always loop over
    /// the actual array indices and skip channels where
    /// `enabled == false`. Don't assume the array length matches
    /// channelCount in defensive code — use
    /// `hpfFor(channel:)` which clamps + returns a default for
    /// out-of-range lookups.
    public var hpfPerChannel: [ChannelHPF] = []

    /// Per-channel HPF settings. Identical fields to the old file-
    /// level HPF triple, just stored once per channel. Equatable +
    /// Hashable so the UI can compare and the merger can detect
    /// "all channels identical" (which collapses the BEXT
    /// CodingHistory line for that file).
    public struct ChannelHPF: Equatable, Hashable {
        public var enabled: Bool = false
        public var frequency: Double = 80.0   // Hz
        public var slope: HighPassFilter.Slope = .db18

        public init(enabled: Bool = false, frequency: Double = 80.0, slope: HighPassFilter.Slope = .db18) {
            self.enabled = enabled
            self.frequency = frequency
            self.slope = slope
        }
    }

    /// Lazy-initialize `hpfPerChannel` to a `count`-length array of
    /// default ChannelHPF if it's currently empty (which is the
    /// case for any file that was parsed before this method was
    /// called). Always called at the start of `AudioFile.parse`.
    /// Idempotent — safe to call multiple times.
    public func ensureChannelHPFInitialized() {
        let need = Int(channelCount)
        if hpfPerChannel.count != need {
            hpfPerChannel = Array(repeating: ChannelHPF(), count: need)
        }
    }

    /// Safe lookup for a specific channel's HPF settings. Returns
    /// a default `ChannelHPF()` if the channel index is out of
    /// range (which can happen briefly during reload / channel
    /// count mutation). Use this in engine code that needs to be
    /// resilient to model state transitions.
    public func hpfFor(channel: Int) -> ChannelHPF {
        guard channel >= 0, channel < hpfPerChannel.count else {
            return ChannelHPF()
        }
        return hpfPerChannel[channel]
    }

    /// True when ANY channel of this file has HPF enabled. Used by
    /// the merger and the loudness measurer to fast-skip files
    /// where no HPF processing is needed.
    public var hasAnyHPFEnabled: Bool {
        hpfPerChannel.contains { $0.enabled }
    }

    /// True when EVERY channel of this file shares identical HPF
    /// settings (and at least one is enabled). Used by the BEXT
    /// CodingHistory generator to collapse the per-channel HPF
    /// lines into a single per-file line when all channels match.
    public var hasUniformHPF: Bool {
        guard let first = hpfPerChannel.first, hpfPerChannel.count > 1 else {
            return hpfPerChannel.first?.enabled == true
        }
        return hpfPerChannel.allSatisfy { $0 == first }
    }

    // MARK: - Per-channel inclusion / track cleanup

    // Per-channel inclusion state is stored on `includedChannels`
    // further down the model (a `Set<Int>` populated with 0..<count
    // at parse time, pruned by the CHANNELS / TRACK CLEANUP panel
    // and by `autoExcludeSilentChannels()`). The merger + track
    // mapping + sync ref candidate picker all already honor that
    // set. The helpers below layer peak-measurement and auto-
    // exclusion on top of it so the CHANNELS panel has both the
    // state (who's in, who's out) and the data (how loud is each
    // channel) it needs to render.

    /// Measured peak in dBFS per source channel, populated during
    /// import when the waveform generator walks the file. Used by
    /// the CHANNELS / TRACK CLEANUP panel to show the peak level
    /// next to each channel AND by `autoExcludeSilentChannels()`
    /// as one of three signals. `-Double.infinity` represents true
    /// digital silence (peak sample == 0). nil means the peak
    /// hasn't been measured yet.
    public var perChannelPeakDB: [Double]?

    /// Measured long-term RMS in dBFS per source channel. Catches
    /// channels that hit a loud peak once (transient click, rare
    /// bird chirp, passing cable hit) but are near-silent
    /// otherwise. Peak alone would mark such a channel as "has
    /// signal" at -55 dB even though no usable content exists.
    /// RMS near -infinity + peak near -60 means "almost all
    /// silence with one outlier" — safe to exclude.
    public var perChannelRMSDB: [Double]?

    /// Fraction of samples per source channel that exceed -50
    /// dBFS. In [0, 1]. Near-zero on truly silent channels; high
    /// (>0.1) on channels with continuous audio. Third signal in
    /// the auto-exclude decision: a channel has real content if
    /// ANY non-trivial slice of it has above-noise energy.
    public var perChannelActiveRatio: [Float]?

    /// Peak threshold: if a channel's peak is BELOW this, it's
    /// always auto-excluded (clearly silent). Above this, the
    /// decision depends on RMS + active ratio.
    public static let silentChannelThresholdDB: Double = -55.0

    /// RMS threshold combined with a relaxed peak check. A channel
    /// with peak above `silentChannelThresholdDB` but RMS below
    /// this value AND active ratio below
    /// `silentChannelActiveRatioThreshold` is considered
    /// effectively blank (loud transient over silent noise floor).
    public static let silentChannelRMSThresholdDB: Double = -65.0

    /// Fraction-of-active-samples threshold. A channel needs BOTH
    /// low RMS AND low active-ratio to be excluded under the
    /// relaxed-peak branch; this lets a channel with an actual
    /// continuous signal (even a quiet room tone) stay included
    /// even when its peak is modest.
    public static let silentChannelActiveRatioThreshold: Float = 0.005

    /// Convenience: how many channels of this file will land in
    /// the merged output after exclusion. Used by the CHANNELS
    /// panel's "N of M included" label. Route through this
    /// instead of `includedChannels.count` so future changes to
    /// inclusion semantics (e.g. "muted, but still emitted")
    /// don't require grep-and-fix across callers.
    public var includedChannelCount: Int {
        includedChannels.filter { $0 < Int(channelCount) }.count
    }

    /// Rough classification of this file's audio, derived from the
    /// per-channel stats populated at import. Used by the UI to
    /// warn the user when they pick PRODUCTION mode on what looks
    /// like an onboard reference mic (no hot peaks, continuous
    /// low-level ambience — classic scratch-track profile). Also
    /// useful for the per-region sync reference recommender.
    ///
    /// Classification is intentionally fuzzy. "Production" vs
    /// "reference" is a judgment call from stats; a noisy set
    /// location can make a true production feed look scratch-like
    /// Human-visible classification of what dynamic phase alignment
    /// actually produced for this file. Written by `PhaseAligner.align`
    /// after the trajectory + confidence are computed. Lets the UI
    /// speak plainly — "STATIC ±9 ms" vs "DYNAMIC DRIFT ±3 ms" vs
    /// "NOT APPLIED — actors may be in different rooms" — instead of
    /// forcing the user to decode a raw confidence number or stare at
    /// a flat ribbon at 0.00 ms trying to figure out if the aligner
    /// did anything. Every non-reference file gets exactly one outcome
    /// per run.
    public enum AlignmentOutcome: Equatable {
        /// No alignment run has completed against this file yet.
        case notAnalyzed
        /// This file is the reference for its region — nothing
        /// aligned TO it, it's the anchor others align against.
        case reference
        /// The aligner detected meaningful time-varying drift across
        /// the file (talent motion, clock drift between separate
        /// recorders, etc.). `correctedChannels` holds the time-
        /// varying correction. `driftRangeMs` is the peak-to-peak
        /// range of the per-window delay across the file.
        case dynamicDrift(offsetMs: Double, driftRangeMs: Double, confidence: Double)
        /// The aligner detected a constant delay (no meaningful time
        /// variation) and applied it as a fixed time shift. Typical
        /// on channel siblings of one poly (sample-locked + talent
        /// stationary relative to mics) or separate mono files from
        /// the same recorder. `correctedChannels` holds the applied
        /// shift.
        case staticOffset(offsetMs: Double, confidence: Double)
        /// Detected delay was effectively zero AND flat. Nothing was
        /// applied because nothing needed to be. Common when two mics
        /// are physically adjacent or when the source tracks were
        /// already time-aligned at capture.
        case alreadyAligned(confidence: Double)
        /// Alignment was applied, but only a minority of analysis
        /// windows (5-20%) had strong cross-correlation with the
        /// reference. The remaining windows filled in from nearest-
        /// confident-neighbor extrapolation. This is the 10-minute
        /// scene where actors are in a different room from the
        /// boom for most of the take but come together for a
        /// smaller portion — the confident portion DOES get real
        /// alignment; the rest gets an extrapolated delay that's
        /// harmless (those channels weren't phase-coherent anyway).
        /// `confidentFraction` is the ratio of windows above the
        /// confidence floor.
        case partiallyReliable(offsetMs: Double, driftRangeMs: Double, confidentFraction: Double)
        /// The aligner ran but the result isn't reliable — fewer
        /// than 5% of analysis windows had strong cross-correlation
        /// with the reference. NOTHING was written to
        /// `correctedChannels`; the file remains in its pre-align
        /// state. `reason` carries the specific cause so the UI can
        /// explain it in plain language.
        case unreliable(reason: UnreliableReason, confidence: Double)

        /// Specific reason a file's alignment came back unreliable.
        /// Shown to the user as a plain-language hint so they know
        /// whether to fix setup (mic placement, room separation) or
        /// just accept that this take can't be phase-aligned.
        public enum UnreliableReason: Equatable {
            /// GCC-PHAT couldn't find a stable peak across windows —
            /// typically "actors in a different room from the boom,"
            /// "mics too far apart to share the same signal," or
            /// "one track is silent while the other isn't."
            case lowSignalCorrelation
            /// Reference and target overlap in timecode for less
            /// than the dynamic aligner's minimum analysis duration
            /// (~3 s). Not enough content to make a decision.
            case insufficientOverlap
            /// Either file has no content above the analysis floor
            /// (all silence / dead channel). Cross-correlation with
            /// silence is undefined.
            case silentInput
        }

        /// True when the aligner DID write `correctedChannels` (and
        /// by extension, when the merger/playback will read from the
        /// corrected buffer). False for reference, already-aligned,
        /// unreliable, and not-yet-analyzed.
        public var isApplied: Bool {
            switch self {
            case .dynamicDrift, .staticOffset, .partiallyReliable: return true
            case .reference, .alreadyAligned, .unreliable, .notAnalyzed: return false
            }
        }

        /// Short badge text shown inline on the file card + timeline
        /// rows. Uppercase, no emoji, kept under ~20 chars so it
        /// fits in tight row chrome.
        public var badgeLabel: String {
            switch self {
            case .notAnalyzed: return "NOT ANALYZED"
            case .reference: return "SYNC REF"
            case .dynamicDrift(_, let range, _):
                return "DYNAMIC DRIFT \(String(format: "±%.2f ms", range / 2))"
            case .staticOffset(let offset, _):
                return "STATIC \(String(format: "%+.2f ms", offset))"
            case .alreadyAligned: return "ALIGNED"
            case .partiallyReliable(_, let range, let frac):
                return "PARTIAL (\(Int(frac * 100))%) ±\(String(format: "%.2f ms", range / 2))"
            case .unreliable: return "NOT APPLIED"
            }
        }

        /// Multi-line plain-language explanation surfaced in tooltips
        /// and the Phase Align window's detail row. Tells the user
        /// WHAT happened and, for failures, WHY — so they don't have
        /// to guess from a cryptic confidence number.
        public var detailMessage: String {
            switch self {
            case .notAnalyzed:
                return "Dynamic phase alignment hasn't run on this track yet. Enable ALIGN and start an analysis pass."
            case .reference:
                return "This track is the reference anchor. Other tracks in its region align to it, so it doesn't align to anything itself."
            case .dynamicDrift(let offset, let range, let conf):
                let rangeStr = String(format: "%.2f ms peak-to-peak", range)
                let offsetStr = String(format: "%+.2f ms mean", offset)
                return "Time-varying drift detected and corrected. Range: \(rangeStr). \(offsetStr). Confidence: \(String(format: "%.1f", conf)). Typical causes: clock drift between separate recorders, or talent motion changing the boom-to-lav acoustic delay."
            case .staticOffset(let offset, let conf):
                return "A constant \(String(format: "%+.2f ms", offset)) offset was detected and applied. Confidence: \(String(format: "%.1f", conf)). Common on channel siblings from one poly recorder, or separate WAVs from the same sample-locked source — there's acoustic delay between the mics but no clock drift to track over time."
            case .alreadyAligned(let conf):
                return "No drift or offset above the detection floor. The tracks were already in sync (likely sharing a clock and acoustically adjacent). Nothing applied. Confidence: \(String(format: "%.1f", conf))."
            case .partiallyReliable(let offset, let range, let frac):
                let pct = Int(frac * 100)
                return "Alignment applied, but only \(pct)% of the analysis windows locked onto a shared signal. Typical on long takes where the actors move in and out of the boom's pickup range (different rooms, walking offscreen, etc.). The confident sections got real alignment; the rest was extrapolated from the nearest confident neighbor. Mean offset: \(String(format: "%+.2f ms", offset)). Drift range: \(String(format: "%.2f ms", range))."
            case .unreliable(let reason, let conf):
                let why: String
                switch reason {
                case .lowSignalCorrelation:
                    why = "The reference and this track don't share enough common signal for the aligner to lock on. Common causes: actors are in a different room from the boom, mics are too far apart to pick up the same source, or one track is mostly silent while the other isn't. Consider picking a different reference for this region (try the per-region SYNC REF picker), or accept that this take can't be phase-aligned — the merged output will still be sample-accurate via timecode."
                case .insufficientOverlap:
                    why = "Not enough timecode overlap between this track and the reference to run a reliable analysis (the dynamic aligner needs at least ~3 seconds of shared content)."
                case .silentInput:
                    why = "One or both tracks are effectively silent on the overlap window, so there's nothing for the aligner to cross-correlate against."
                }
                return "Phase alignment was NOT applied. Confidence came back too low to trust the result (\(String(format: "%.1f", conf))). \(why)"
            }
        }

        /// Semantic color: green for clean applied cases, amber for
        /// neutral "nothing to do" cases, red for failures. Renderers
        /// map this to `Theme.*` colors.
        public enum Severity { case ok, neutral, warning, critical }
        public var severity: Severity {
            switch self {
            case .notAnalyzed: return .neutral
            case .reference: return .ok
            case .dynamicDrift, .staticOffset: return .ok
            case .alreadyAligned: return .neutral
            case .partiallyReliable: return .warning
            case .unreliable: return .warning
            }
        }
    }

    /// and vice versa. The UI surfaces `QualityGrade.warning` and
    /// `helpText` so the user can override without friction.
    public enum QualityGrade {
        /// Stats haven't been computed yet.
        case unknown
        /// Hot peaks (≥ -18 dBFS on some channel) with wide
        /// dynamic range. Looks like a mixer feed / lav / boom:
        /// dialogue pattern with silent gaps between bursts.
        case production
        /// Quiet continuous audio. No hot peaks (< -28 dBFS),
        /// narrow dynamic range (RMS close to peak), samples
        /// mostly above -50 dBFS (ambient room floor). Looks
        /// like an onboard camera mic / environmental scratch.
        case reference
        /// Doesn't match either profile cleanly. Used when the
        /// signal has some hot peaks but also a lot of ambient
        /// floor, or too little signal to classify confidently.
        case mixed
    }

    /// Classify this file's audio using the per-channel stats.
    /// Uses a weighted-score model instead of strict peak
    /// thresholds so a noisy onboard cam (wind transients that
    /// hit hot peaks on top of continuous ambience) still gets
    /// flagged as reference. Averages stats across INCLUDED
    /// channels so multi-channel files with silent junk don't
    /// skew the classification (the silent channels already got
    /// removed from `includedChannels` by the auto-exclude pass).
    ///
    /// ## Reference signals (each is independent; higher weight
    /// means stronger evidence)
    ///
    /// - **High active-ratio ≥ 0.40**: 40%+ of samples above
    ///   -50 dBFS means there's barely any silence. Dialogue
    ///   normally has silent gaps between bursts; continuous
    ///   energy above -50 dB is a hallmark of room tone, wind,
    ///   handling noise, or other non-dialogue content.
    /// - **Narrow dynamic range (peak - RMS) < 22 dB**: RMS
    ///   close to peak means the signal level is nearly
    ///   constant. Clean dialogue has ≥ 28 dB because silences
    ///   between speech drag the RMS down.
    /// - **High RMS ≥ -45 dBFS**: loud noise floor. The noise
    ///   floor of a pro recorder is ≈ -90 dBFS; anything above
    ///   -45 means the channel is carrying continuous audible
    ///   content.
    /// - **Modest peak < -12 dBFS**: the signal is never really
    ///   hot. Production feeds typically peak above -12 dB.
    ///
    /// ## Production signals
    ///
    /// - **Hot peak ≥ -12 dBFS**: mixed at broadcast level or
    ///   close.
    /// - **Wide dynamic range > 28 dB**: dialogue + silence
    ///   pattern.
    /// - **Low active-ratio < 0.35**: silences between bursts.
    ///
    /// Sum the weights: total ≥ 5 classifies. Both scores
    /// calculated; whichever is higher wins. Ties / both-low →
    /// `.mixed`.
    public var qualityGrade: QualityGrade {
        guard let peaks = perChannelPeakDB,
              let rms = perChannelRMSDB,
              let active = perChannelActiveRatio,
              peaks.count == rms.count,
              peaks.count == active.count,
              !peaks.isEmpty else {
            return .unknown
        }
        let included = includedChannels.isEmpty
            ? Array(peaks.indices)
            : Array(includedChannels).filter { $0 < peaks.count }
        guard !included.isEmpty else { return .unknown }

        // Average across every INCLUDED channel. Using average
        // instead of the hottest catches the stereo-onboard-mic
        // case where both channels show the same ambient noise.
        let count = Double(included.count)
        let avgPeak = included.map { peaks[$0] }.reduce(0, +) / count
        let avgRMS = included.map { rms[$0] }.reduce(0, +) / count
        let avgActive = included.map { Double(active[$0]) }.reduce(0, +) / count

        guard avgPeak > -60 else { return .unknown }
        let dynamicRange = avgPeak - avgRMS

        // Channel symmetry — do multi-channel included channels
        // have near-identical peak + RMS? Real stereo pairs (two
        // lavs, L/R boom in ORTF, etc.) typically spread 5+ dB
        // between channels. Single-capsule sources (onboard cam
        // mic, dual-mono feed) cluster within 3 dB.
        var hasChannelSymmetry = false
        if included.count >= 2 {
            let chPeaks = included.map { peaks[$0] }
            let chRMS = included.map { rms[$0] }
            let peakSpread = (chPeaks.max() ?? 0) - (chPeaks.min() ?? 0)
            let rmsSpread = (chRMS.max() ?? 0) - (chRMS.min() ?? 0)
            hasChannelSymmetry = (peakSpread < 3 && rmsSpread < 3)
        }

        // High-confidence reference: tightly symmetric channels
        // (single-capsule source) AND continuous energy (RMS
        // above -48 dBFS means there's always audible signal —
        // room tone, wind, handling noise). Together these are
        // near-definitive for a consumer onboard mic even when
        // other metrics look dialogue-like. A001's proxy
        // (peak -14, RMS -45, active 0.21 — looks dialogue-
        // pattern on peak/DR alone) trips this rule because its
        // 2.7 dB peak spread and 0.9 dB RMS spread between the
        // "usable" channels gives away the single-capsule
        // origin.
        if hasChannelSymmetry && avgRMS >= -48 {
            return .reference
        }

        var refScore = 0
        if avgActive >= 0.40   { refScore += 3 }
        if dynamicRange < 22   { refScore += 2 }
        if avgRMS >= -45       { refScore += 2 }
        if avgPeak < -12       { refScore += 1 }
        if hasChannelSymmetry  { refScore += 3 }

        // Production bonuses gate on actually-hot peaks so
        // dialogue-pattern-but-quiet signals don't accidentally
        // classify as production. A field recorder feed typically
        // peaks above -12 dBFS; if the signal never does, it's
        // more likely reference regardless of dynamic range.
        var prodScore = 0
        if avgPeak >= -12 {
            prodScore += 3
            if dynamicRange > 28 { prodScore += 2 }
            if avgActive < 0.35  { prodScore += 2 }
        }

        if refScore >= 5 && refScore > prodScore { return .reference }
        if prodScore >= 5 && prodScore > refScore { return .production }
        return .mixed
    }

    /// User-facing reason string for why a file got classified a
    /// particular way. Surfaced in the PROD-on-reference warning
    /// dialog so the user can judge whether the heuristic got it
    /// right.
    public var qualityGradeReason: String {
        guard let peaks = perChannelPeakDB,
              let rms = perChannelRMSDB,
              let active = perChannelActiveRatio,
              !peaks.isEmpty, !rms.isEmpty, !active.isEmpty else {
            return "Stats not yet measured."
        }
        let included = includedChannels.isEmpty
            ? Array(peaks.indices)
            : Array(includedChannels).filter { $0 < peaks.count }
        guard let loudestIdx = included.max(by: { peaks[$0] < peaks[$1] }) else {
            return "No included channels."
        }
        let peak = peaks[loudestIdx]
        let rmsValue = rms[loudestIdx]
        let activeValue = active[loudestIdx]
        return String(
            format: "Loudest channel: %.1f dBFS peak, %.1f dBFS RMS, %.0f%% of samples above -50 dBFS.",
            peak, rmsValue, Double(activeValue) * 100
        )
    }

    /// Walk the per-channel statistics and remove "effectively
    /// blank" channels from `includedChannels`. Called once after
    /// import stats are populated, before any pipeline touches
    /// the file. Idempotent.
    ///
    /// Decision rule: a channel is excluded when ANY of the
    /// following is true:
    ///   1. Peak < `silentChannelThresholdDB` (-55 dB)
    ///      — clearly silent, no questions
    ///   2. RMS < `silentChannelRMSThresholdDB` (-65 dB)
    ///      AND active-signal ratio < `silentChannelActiveRatioThreshold` (0.5%)
    ///      — catches "one loud transient over mostly silence"
    ///        (e.g. A001's CH1 at -58 dB peak but -85 dB RMS)
    ///
    /// Without the relaxed-peak-plus-low-RMS branch, channels
    /// like A001's CH1 (peak -58.3 dB, basically blank) slip
    /// through the peak-only check. RMS + active-ratio give the
    /// "continuous content?" signal.
    ///
    /// Returns the indices of channels that were auto-excluded so
    /// the Import Setup card can surface a "N silent channels
    /// excluded, click to review" banner. Empty array means
    /// nothing changed.
    @discardableResult
    public func autoExcludeSilentChannels() -> [Int] {
        guard let peaks = perChannelPeakDB, !peaks.isEmpty else { return [] }
        var excluded: [Int] = []
        for (i, peak) in peaks.enumerated() where i < Int(channelCount) {
            guard includedChannels.contains(i) else { continue }
            let rms = (perChannelRMSDB?.indices.contains(i) == true) ? perChannelRMSDB![i] : 0
            let active = (perChannelActiveRatio?.indices.contains(i) == true) ? perChannelActiveRatio![i] : 1
            // Rule 1: hard silence by peak.
            let hardSilent = peak < Self.silentChannelThresholdDB
            // Rule 2: loud-transient-over-silence. Peak may be
            // above the hard threshold (e.g. -58 dB), but RMS and
            // active-ratio say the channel is empty otherwise.
            let effectivelySilent = rms < Self.silentChannelRMSThresholdDB
                && active < Self.silentChannelActiveRatioThreshold
            if hardSilent || effectivelySilent {
                includedChannels.remove(i)
                excluded.append(i)
            }
        }
        return excluded
    }

    /// Per-track static gain trim in dB. Applied to the source samples
    /// after HPF and before mixing — both during merge AND during live
    /// playback. Used to balance hot/quiet mics so the merged output
    /// doesn't have wildly different per-channel levels.
    ///
    /// Range is intentionally generous (-24 .. +24 dB). The UI shows
    /// a clipping warning when the resulting peak would exceed the
    /// safe ceiling; the merger / encoder hard-clamps as a final
    /// safety net so an aggressive trim can never wrap to negative.
    public var gainTrimDB: Double = 0

    /// Origin of the current `gainTrimDB` value. Drives the AUTO /
    /// CUSTOM label next to each per-track row in the loudness window
    /// so the user can tell at a glance which tracks they've
    /// hand-tweaked vs which are still at an auto-computed level.
    /// `MergeSession.setTrim` automatically transitions this to
    /// `.user` whenever the user moves a slider. The sweet-spot
    /// preset and auto-normalize set it to `.sweetSpot` /
    /// `.autoNormalize` respectively. Default `.none` means the
    /// trim is still at the parser's 0 dB initial value.
    public enum GainTrimSource: String {
        case none           // never set; still at default 0 dB
        case user           // user adjusted the slider
        case sweetSpot      // set by the SWEET SPOT preset button
        case matchRef       // set by the MATCH REF button on the track setup card
        case autoNormalize  // set by the future per-track auto-normalizer
    }
    public var gainTrimSource: GainTrimSource = .none

    /// Microphone type. Drives the sweet-spot mix preset (which needs
    /// to know which track is the boom and which are lavs to apply
    /// the boom-leading mix). Can be auto-detected from the iXML
    /// track name or filename via `MicType.guess(from:)`, and the
    /// user can override it from the track setup card on the file.
    public enum MicType: String, CaseIterable, Identifiable {
        case unknown    = "Unknown"
        case boom       = "Boom"
        case lav        = "Lavalier"
        case ambient    = "Ambient"
        case other      = "Other"

        public var id: String { rawValue }

        /// SF Symbol used to represent this mic type in the UI.
        public var icon: String {
            switch self {
            case .unknown: return "questionmark.circle"
            case .boom:    return "music.mic"
            case .lav:     return "person.crop.circle"
            case .ambient: return "waveform.circle"
            case .other:   return "circle"
            }
        }

        /// One-line description of what this mic type means in
        /// production sound terms.
        public var subtitle: String {
            switch self {
            case .unknown: return "Type not specified"
            case .boom:    return "Hypercardioid or shotgun on a pole. The primary dialogue mic."
            case .lav:     return "Lavalier (chest or hidden body mic). Fill mic for the boom."
            case .ambient: return "Room tone, wild audio, or B-roll capture. Not in the dialogue mix."
            case .other:   return "Custom or unspecified mic type."
            }
        }

        /// Best-effort guess at the mic type from a track name or
        /// filename. Looks for the obvious keywords production sound
        /// recorders inject into iXML and filenames. Returns
        /// `.unknown` when no match is found so the user can pick
        /// it manually from the track setup card.
        public static func guess(from text: String?) -> MicType {
            guard let text, !text.isEmpty else { return .unknown }
            let lower = text.lowercased()
            // Boom keywords. Check first because some recorders write
            // "boom" even alongside "lav" in the same name.
            let boomKeywords = ["boom", "shotgun", "hyper", "ntg", "mkh", "416", "8060", "cmit"]
            for kw in boomKeywords where lower.contains(kw) { return .boom }
            // Lavalier keywords. "lav" matches "lavalier" too.
            let lavKeywords = ["lav", "wirele", "transmit", "tx ", "tx_", "lapel", "tram", "cos11", "dpa"]
            for kw in lavKeywords where lower.contains(kw) { return .lav }
            // Ambient keywords.
            let ambientKeywords = ["ambient", "room", "wild", "atmos", "background", "amb"]
            for kw in ambientKeywords where lower.contains(kw) { return .ambient }
            return .unknown
        }
    }

    /// User-overrideable mic type for the file as a whole. Auto-
    /// detected from the iXML track name and filename when the file
    /// is parsed; the user can change it from the gear menu on the
    /// file card. Drives the sweet-spot mix preset (which needs at
    /// least one boom and one lav to apply).
    ///
    /// **For multi-channel files**, prefer `perChannelMicTypes` if it
    /// has an entry for the channel in question. The file-level
    /// `micType` is the fallback when no per-channel override is set.
    public var micType: MicType = .unknown

    /// Per-channel mic type overrides for multi-channel files. The
    /// gear menu on the file card lets the user pick a different mic
    /// type per channel (e.g. ch1 = boom, ch2 = lav). When a channel
    /// has an entry here, sweet-spot and any other per-channel
    /// auto-mix logic uses it instead of the file-level `micType`.
    /// Empty by default; an unset channel falls through to `micType`.
    public var perChannelMicTypes: [Int: MicType] = [:]

    /// Effective mic type for a specific channel of this file. Looks
    /// up the per-channel override first, falls back to the file-level
    /// `micType`.
    public func micType(forChannel channel: Int) -> MicType {
        perChannelMicTypes[channel] ?? micType
    }

    /// Linear multiplier for `gainTrimDB`. Read by the merger,
    /// playback engine track buffer builder, and timeline waveform
    /// view to apply the trim consistently everywhere.
    public var gainTrimLinear: Float {
        if abs(gainTrimDB) < 0.001 { return 1.0 }
        return Float(pow(10.0, gainTrimDB / 20.0))
    }

    /// Peak amplitude of the source file in linear units (0..1).
    /// Computed from the waveform peak data when it loads. Used by
    /// the trim UI to surface a clipping warning when
    /// `sourcePeakLinear * gainTrimLinear` would exceed the safe
    /// ceiling, and by the source-clip detector below.
    public var sourcePeakLinear: Float = 0

    /// Per-channel peak amplitudes in linear units (0..1). Populated
    /// by `WaveformGenerator.scanChannelPeaks` shortly after file
    /// load. Used by the export screen's track mapping section to
    /// detect blank channels and surface a "skip blank on export"
    /// toggle. Empty until the scan completes.
    public var channelPeaks: [Float] = []

    /// True when the source file already has samples at or above the
    /// near-clip threshold (0.997, ~−0.026 dBFS). Drives a "SOURCE
    /// CLIPPED" badge on the file card so the user knows the
    /// recording itself has issues — no amount of trim will fix this.
    public var sourceClipped: Bool = false

    /// Set of source channel indices (0-based) to INCLUDE in the
    /// merged output. Defaults to "all channels". The export screen
    /// can edit this to skip blank or unwanted channels. AudioMerger
    /// + WAVWriter both honor this set when building output channel
    /// layout. When the set is empty, the file contributes nothing
    /// to the merge.
    public var includedChannels: Set<Int> = []

    /// When non-nil, this AudioFile was produced by extracting the
    /// embedded audio track from a video file (camera-audio
    /// inclusion flow). The UUID points at the `VideoFile` in the
    /// same bin so UI code can render this AudioFile as tethered
    /// to its source video (color-match, grouped placement in
    /// region cards, "from CAM A" label, etc.) and the export
    /// pipeline can route it differently (e.g. the FCP7 XML writer
    /// references the camera video file rather than the extracted
    /// WAV for NLE relink).
    ///
    /// Extracted AudioFiles live in `bin.files` just like any
    /// other audio so every existing pipeline (merger, phase
    /// aligner, sync ref picker, loudness measurement, HPF /
    /// gain / CHANNELS panel) automatically works on them.
    public var sourceVideoFileID: UUID?

    /// Convenience: true when this audio was extracted from a
    /// video. Used by UI layers to render tethered visuals
    /// (color stripe tied to video, "CAM A AUDIO" badge,
    /// suppressed in the audio file list outside its parent
    /// video's region, etc.).
    public var isExtractedCameraAudio: Bool { sourceVideoFileID != nil }

    /// When true, this file is a "scratch" track: visible in the
    /// UI + eligible as a sync reference + shown on the sidecar
    /// timeline at export, but NOT mixed into the merged poly
    /// BWF. Drives the REFERENCE vs PRODUCTION distinction for
    /// extracted camera audio:
    ///   - `.production` mode → `isScratchTrack = false` (the
    ///     camera audio IS in the merged BWF, occupying its own
    ///     channels)
    ///   - `.reference` mode → `isScratchTrack = true` (the
    ///     camera audio is NOT in the merged BWF; it only lands
    ///     on the sidecar as a checkable NLE track)
    ///
    /// Default `false` so ordinary audio files (every WAV the
    /// user drops) behave exactly as before — fully included.
    /// The merger's `honoredFiles` filter skips scratch tracks
    /// so their channels never enter the mix even when they sit
    /// in `bin.files` alongside the rest.
    public var isScratchTrack: Bool = false

    /// Per-channel name overrides keyed by source channel index
    /// (0-based). When non-nil for a given channel, this string is
    /// used as the iXML `<NAME>` for that output channel instead of
    /// the auto-generated label. The export screen's track mapping
    /// section is the only place these get set.
    public var perChannelNames: [Int: String] = [:]

    /// True when a channel has effectively no signal (peak below
    /// `blankChannelThreshold`). Used by the export screen to flag
    /// channels that are safe to skip.
    public func isChannelBlank(_ channel: Int) -> Bool {
        guard channel < channelPeaks.count else { return false }
        return channelPeaks[channel] < AudioFile.blankChannelThreshold
    }

    /// Threshold below which a channel is treated as silent. -84 dBFS
    /// — well below dither floor on 16-bit recordings, conservative
    /// enough to avoid false positives on quiet but real signal.
    public static let blankChannelThreshold: Float = 0.0000631  // 10^(-84/20)

    /// True when applying the current `gainTrimDB` to `sourcePeakLinear`
    /// would push the resulting peak past 0 dBFS. Live indicator on
    /// the trim slider; the merger's encode clamp catches the actual
    /// overshoot.
    public var trimWillClip: Bool {
        sourcePeakLinear > 0 && Double(sourcePeakLinear * gainTrimLinear) > 1.0
    }

    /// Trim headroom in dB — how much positive trim the user can
    /// apply before clipping. Negative when source is already at peak.
    /// Returns +Infinity when source peak is unknown / silent.
    public var trimHeadroomDB: Double {
        guard sourcePeakLinear > 0 else { return .infinity }
        return -20.0 * log10(Double(sourcePeakLinear))
    }

    // Per-track playback state (does not affect merge output)
    public var muted: Bool = false
    public var soloed: Bool = false

    /// Per-channel mute set. Independent of the file-level `muted`
    /// flag — both gates apply, so a channel is silent if EITHER
    /// `muted == true` OR `mutedChannels.contains(channel)`.
    /// Indexed by source channel index (0-based).
    ///
    /// **Why per-channel:** multi-track poly recorder files (Sound
    /// Devices 6-channel polys, Zoom F8/F8n iso recordings, Atomos /
    /// ARRI / RED multi-mic captures) carry several independent mics
    /// in a single file. Production sound mixers expect to mute the
    /// boom or solo the lav INDIVIDUALLY without silencing the whole
    /// file. The earlier file-level model forced an all-or-nothing
    /// mute, which made multi-channel poly imports unworkable as
    /// soon as the user wanted to A/B individual mics.
    ///
    /// **Playback only.** Like `muted` / `soloed`, this is never
    /// read by `AudioMerger`. The merge output always contains the
    /// honored channels of every honored file. If you need to drop
    /// a channel from the merge, exclude it via
    /// `AudioFile.includedChannels` instead.
    public var mutedChannels: Set<Int> = []

    /// Per-channel solo set. Same semantics as `mutedChannels` but
    /// for solo. When ANY track in the session has `soloed == true`
    /// OR a non-empty `soloedChannels`, the playback engine enters
    /// solo mode: only soloed sources contribute to the output. A
    /// channel of a track plays in solo mode if either
    /// `track.soloed` (whole-file solo) OR
    /// `soloedChannels.contains(ch)` (per-channel solo) is true.
    public var soloedChannels: Set<Int> = []

    /// True when ANY mute state (file-level OR per-channel) is
    /// active for this file. The lane-level M button uses this to
    /// derive its highlighted/depressed state when the lane spans
    /// multiple files.
    public func channelIsMuted(_ channel: Int) -> Bool {
        muted || mutedChannels.contains(channel)
    }

    /// True when ANY solo state (file-level OR per-channel) is
    /// active for this file's channel.
    public func channelIsSoloed(_ channel: Int) -> Bool {
        soloed || soloedChannels.contains(channel)
    }

    // Phase alignment results (set by PhaseAligner)
    /// Detected sub-sample delay relative to the reference track, in samples.
    /// Positive means this track lags the reference. Applied during merge as a
    /// negative shift on the source read position so this track plays earlier.
    /// Sub-sample precision via parabolic interpolation in GCC-PHAT.
    public var phaseDelaySamples: Double = 0
    /// Confidence score from GCC-PHAT (peak-to-mean ratio of cross-correlation).
    /// Higher = more confident the delay is real. Reference track has nil.
    public var phaseConfidence: Double?
    /// True if phase alignment has been computed for this track.
    public var phaseAligned: Bool = false

    /// Integer part of the phase delay (in samples). Used for the source read position.
    public var phaseDelayIntegerPart: Int {
        Int(phaseDelaySamples.rounded(.down))
    }
    /// Fractional part of the phase delay, in [0, 1). Used by SincInterpolator.
    public var phaseDelayFractionalPart: Double {
        phaseDelaySamples - Double(phaseDelayIntegerPart)
    }

    // Spectral phase correction (set by PhaseAligner)
    /// Pre-processed audio buffer per channel. When non-nil, the merger reads from
    /// this buffer instead of doing file I/O + sinc — the time delay AND spectral
    /// phase correction are already applied. Length matches `totalSamples`.
    /// Cleared by `MergeSession.clearPhaseAlignment()`.
    public var correctedChannels: [[Float]]?
    /// True if spectral phase correction has been applied to this file.
    public var spectralCorrectionApplied: Bool = false
    /// Per-bin magnitude-squared coherence at the time of correction (for UI display).
    public var spectralCoherence: [Float]?

    // Dynamic phase alignment (set by PhaseAligner in dynamic mode)
    /// Per-window delay trajectory captured during dynamic-mode analysis. When
    /// non-nil the merger / playback engine reads from `correctedChannels`,
    /// which has the time-varying delay already baked in. The trajectory
    /// itself is kept for the UI (drift range readout, future graph).
    public var phaseTrajectory: PhaseTrajectory?
    /// True when dynamic-mode time-varying delay has been applied to
    /// `correctedChannels`. Used by the codingHistory / iXML notes to
    /// document which kind of alignment was used.
    public var dynamicAlignmentApplied: Bool = false

    /// High-level classification of what phase alignment actually did
    /// for this file. Written by `PhaseAligner.align` after analysis.
    /// Drives the file card badge, the timeline ribbon gate, and the
    /// Phase Align window's per-row detail. Separates the four
    /// conceptually-different outcomes of a dynamic run — reliable-
    /// drift, reliable-static, reliable-but-already-aligned, and
    /// unreliable (typically actors in different rooms or mics too
    /// far apart for GCC-PHAT to lock onto a shared signal).
    public var alignmentOutcome: AlignmentOutcome = .notAnalyzed

    // MARK: - Intra-file (per-channel) phase alignment

    /// Per-channel delay in samples relative to the reference channel.
    /// Index = source channel, value = delay. Reference channel's
    /// value is always 0. Positive = channel lags the reference
    /// (sound arrived later — further from source). Nil before
    /// intra-file alignment runs.
    public var channelPhaseDelays: [Double]?

    /// Which channel was used as the alignment reference. Typically
    /// the boom (channel 0 or the iXML "BOOM" track). Nil before
    /// intra-file alignment runs.
    public var channelPhaseReferenceChannel: Int?

    /// True when intra-file per-channel alignment has been computed.
    /// The delays are baked into `correctedChannels` (each channel
    /// shifted by its integer delay relative to the ref) so the
    /// existing render path picks them up automatically.
    public var channelPhaseAligned: Bool = false

    /// Sample-level normalized cross-correlation between this track's RAW
    /// audio and the reference track at lag 0, in [-1, 1]. Computed once
    /// before correction so we can compare it against `correctedCorrelation`
    /// to quantify how much alignment improved the match. Nil before
    /// analysis runs.
    public var rawCorrelation: Double?
    /// Same as `rawCorrelation` but on the post-correction buffer. The
    /// difference between this and `rawCorrelation` is the most direct
    /// measure of "did alignment do useful work":
    ///   - Both around 0.6+ → already well-aligned, alignment found little
    ///     to do (a few dB improvement at most)
    ///   - Raw ~0.05–0.2, corrected ~0.5+ → alignment is doing major work
    ///     (the raw target was sample-level misaligned → audible comb
    ///     filtering when summed → corrected version sums constructively)
    ///   - Both very low → tracks may not share common content (warn user)
    /// Nil before analysis runs or if correction wasn't attempted.
    public var correctedCorrelation: Double?

    /// Convenience: dB improvement from raw to corrected correlation.
    /// 20·log10(corrected / raw). Returns nil if either is missing or
    /// raw is too small to compute meaningfully.
    public var correlationImprovementDB: Double? {
        guard let raw = rawCorrelation, let corr = correctedCorrelation,
              abs(raw) > 1e-6 else { return nil }
        return 20.0 * log10(abs(corr) / abs(raw))
    }

    // Validation
    public var warnings: [String] = []
    public var errors: [String] = []

    // File layout (for streaming reads)
    public var dataChunkOffset: UInt64 = 0
    public var dataChunkSize: UInt64 = 0

    // Alignment (set by TimecodeAligner)
    public var sampleOffset: Int64 = 0

    public var endTimecode: TimecodeValue? {
        timecode?.adding(samples: Int64(totalSamples))
    }

    /// Effective track name shown to the user — user override, then iXML, then filename stem.
    public var displayTrackName: String {
        if let custom = customTrackName?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        if let name = trackName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return (filename as NSString).deletingPathExtension
    }

    /// Short label shown in the timeline track row.
    /// Uses the user override, otherwise smart-abbreviates the display name.
    public var displayLabel: String {
        if let custom = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom.uppercased()
        }
        if let abbrev = TrackLabelGenerator.abbreviation(from: displayTrackName) {
            return abbrev
        }
        return channelCount >= 2 ? "BOOM" : "TRACK"
    }

    public var channelDescription: String {
        switch channelCount {
        case 1: return "Mono"
        case 2: return "Stereo"
        default: return "\(channelCount)ch"
        }
    }

    public var sampleRateDescription: String {
        "\(sampleRate / 1000)kHz"
    }

    public var bitDepthDescription: String {
        isFloat ? "\(bitDepth)bit float" : "\(bitDepth)bit"
    }

    public var durationString: String {
        TimecodeFormatter.durationString(from: duration)
    }

    public var bytesPerSample: Int {
        Int(bitDepth) / 8
    }

    public var blockAlign: Int {
        bytesPerSample * Int(channelCount)
    }

    // MARK: - Factory

    /// Master switch for the channel-sibling architecture. When
    /// true (default), `parseWithSiblings` produces one parent + N
    /// siblings for multi-channel polys, enabling intra-file dynamic
    /// + spectral phase alignment via the existing inter-file
    /// pipeline. Phases 3-6 (cache sharing, UI filtering, ops fan-
    /// out, alignment integration) make this transparent to the user.
    /// Flip to false to fall back to legacy "one AudioFile per WAV"
    /// behavior — useful as an emergency rollback if a regression
    /// surfaces.
    public static var useChannelSiblings: Bool = true

    // NOTE: The static factories `parse`, `parseWithSiblings`,
    // `makeChannelSibling`, and `failed` live in the PolyMerge
    // executable target as extensions on `AudioFile` (see
    // `AudioFile+Factory.swift`). They depend on engine types
    // (`WAVParser`, `BEXTParser`, `IXMLParser`, `Theme`) that
    // aren't part of this library.

    /// Canonical "no TC" warning string. Stored as a constant so the
    /// parse-time warning and the post-apply cleanup helper can match
    /// against the same source of truth (no typo risk).
    public static let noTimecodeWarning = "No timecode found. File will be excluded from alignment."

    /// Strip the "no timecode" warning from this file. Called after
    /// any path that successfully populates `timecode` (LTC auto-apply,
    /// LTC manual apply, waveform-sync apply) so the yellow warning
    /// triangle on the file card disappears once the TC is recovered.
    public func clearNoTimecodeWarning() {
        warnings.removeAll { $0 == Self.noTimecodeWarning }
    }

    // MARK: - Init

    public init(id: UUID, url: URL, filename: String, sampleRate: Int, bitDepth: Int,
         channelCount: UInt16, formatTag: UInt16, totalSamples: UInt64, isFloat: Bool,
         color: Color) {
        self.id = id
        self.url = url
        self.filename = filename
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channelCount = channelCount
        self.formatTag = formatTag
        self.totalSamples = totalSamples
        self.isFloat = isFloat
        self.color = color
        // Default: every source channel is included in the export.
        // The user can deselect individual channels (or auto-skip
        // blanks) from the export screen's track mapping section.
        self.includedChannels = Set(0..<Int(channelCount))
    }
}
