import SwiftUI
import AVFoundation

/// Video file recognized by PolyMerge. Holds metadata extracted from
/// the file (codec, resolution, frame rate, duration, embedded
/// timecode, scene/take if present), plus some per-file state for
/// display and bin membership.
///
/// **Scope for Video Stage 1**: this is the MINIMUM viable model.
/// PolyMerge never decodes video frames, never plays video, never
/// transcodes — video is a structural member of a bin (its TC range
/// anchors the bin's timeline, and on export we emit a reference to
/// the original file in the FCPXML). All actual video playback /
/// editing happens in the NLE the user exports to.
///
/// Future passes will add:
/// - Thumbnail generation via `AVAssetImageGenerator` (Stage 3)
/// - Guide-track extraction for audio-to-video sync when the camera
///   has no TC (Stage 4)
/// - FCPXML `asset-clip` emission (Stage 5)
///
/// **Parallel to `AudioFile`**: we intentionally keep the two types
/// separate rather than introducing a shared protocol or base class
/// in this pass. The two have very different processing pipelines
/// (audio has HPF / trim / phase align / merge; video has none of
/// that) and collapsing them prematurely would add more indirection
/// than it pays back. When Stage 3 lands and the timeline needs to
/// render both kinds of files in one scroll view, we may revisit and
/// extract a common `BinFile` protocol — but that's a follow-up,
/// not this pass.
@Observable
public final class VideoFile: Identifiable {
    public let id: UUID
    public let url: URL
    public let filename: String

    // MARK: - Format / codec

    /// Duration of the video in seconds. Reports whatever the
    /// container reports; for variable-frame-rate files this is the
    /// duration in wall-clock time, not frame count ÷ fps.
    public var duration: TimeInterval

    /// Natural video width in pixels. Zero when no video track is
    /// present (rare — a .mov with only audio is technically still a
    /// video container, but PolyMerge treats it as video if the
    /// extension suggests video).
    public var videoWidth: Int

    /// Natural video height in pixels.
    public var videoHeight: Int

    /// Nominal frame rate (fps). From `AVAssetTrack.nominalFrameRate`.
    /// Variable-frame-rate files report their nominal rate; the true
    /// per-frame timing may vary.
    public var videoFrameRate: Double

    /// Human-readable codec name ("Apple ProRes 422", "H.264", etc.).
    /// Derived from the video track's first format description via
    /// `CMFormatDescriptionGetMediaSubType` + a lookup table.
    public var videoCodec: String

    // MARK: - Camera audio inclusion

    /// How this video's embedded audio should be handled on export.
    /// Defaults to `.omit` so the merged poly BWF from the dedicated
    /// audio recorder remains the sole audio deliverable. Users can
    /// opt in to `.reference` (keep as a scratch track on the NLE
    /// sidecar, not in the merged BWF) or `.production` (include
    /// in both the sidecar AND the merged BWF, taking dedicated
    /// channels at the camera's TC offset).
    ///
    /// **Only meaningful when `hasAudioTrack` is true.** The UI
    /// hides the picker when the video has no embedded audio.
    public enum CameraAudioMode: String, CaseIterable, Identifiable, Codable {
        /// Default. Camera audio is not included in the merged BWF
        /// or the sidecar. The merged poly BWF is the sole audio
        /// deliverable.
        case omit = "Omit"
        /// Camera audio appears on the sidecar timeline as extra
        /// audio tracks (editor can A/B vs. the merged BWF), but is
        /// NOT mixed into the merged BWF itself. Good for checking
        /// sync in the NLE, or as a backup when the dedicated
        /// recorder had issues.
        case reference = "Reference"
        /// Camera audio is included in the sidecar AND the merged
        /// BWF, occupying dedicated channels at the camera's TC
        /// offset. Useful for phone / ENG-style shoots where the
        /// camera mic IS the production audio.
        case production = "Production"

        public var id: String { rawValue }

        public var subtitle: String {
            switch self {
            case .omit:
                return "Exclude this video's embedded audio from the deliverable. The merged poly BWF from your recorder is the only audio. Default."
            case .reference:
                return "Camera audio appears on the NLE sidecar timeline as a scratch track (editor can A/B vs. the merged BWF), but does NOT land in the merged poly BWF. FCPXML sidecar supported today; FCP7 XML pending."
            case .production:
                return "Camera audio is mixed INTO the merged poly BWF as dedicated channels at the video's TC offset, AND appears on the NLE sidecar. Pick this when the camera mic IS the production audio (boom-to-cam, phone shoots, scratch-as-primary)."
            }
        }

        /// Short one-liner used under the inline picker. Keeps the
        /// picker's footprint tight but still tells the user what
        /// each mode DOES without jargon ("sidecar" is industry
        /// shorthand that non-pro users don't always know).
        public var shortCaption: String {
            switch self {
            case .omit:
                return "Camera audio excluded from everything PolyMerge outputs."
            case .reference:
                return "In the NLE timeline / XML export ONLY. NOT mixed into the merged BWF poly WAV. Not phase-aligned."
            case .production:
                return "Mixed into the merged BWF poly WAV AND on the NLE timeline / XML export. Included in phase alignment."
            }
        }
    }

    /// Per-video camera-audio inclusion mode. Persists on the file
    /// so it survives project-file save / reload (Phase 4 of the
    /// project model roadmap). Default `.omit`.
    public var cameraAudioMode: CameraAudioMode = .omit

    /// ID of the sibling `AudioFile` that was created by extracting
    /// this video's embedded audio (set when cameraAudioMode flips
    /// from .omit to .reference or .production). The sibling file
    /// lives in `bin.files` just like any other AudioFile, tagged
    /// back via `AudioFile.sourceVideoFileID`. Nil = no extraction
    /// has run yet (either because mode is .omit or because it's
    /// still pending).
    ///
    /// Kept as a plain UUID instead of a weak reference because
    /// AudioFile is an @Observable class and cross-referencing the
    /// two via pointers would make the observation tracking graph
    /// circular.
    public var extractedAudioFileID: UUID?

    /// Progress `[0, 1]` of an in-flight extraction. Nil when no
    /// extraction is currently running. Drives the progress bar on
    /// the video card's camera-audio row so the user sees real-
    /// time stage indication ("Decoding 45%", "Writing WAV", etc.).
    public var extractionProgress: Double?

    /// Human-readable stage label for the in-flight extraction
    /// ("Loading track", "Decoding 45%", "Writing WAV", "Ready").
    /// Empty string when no extraction is running.
    public var extractionStatus: String = ""

    /// True while an extraction task is in flight. Drives the
    /// Import Setup's SET UP PROJECT gate so the user can't leave
    /// the setup sheet mid-extraction and miss the extracted
    /// audio's auto-configuration (silent-channel exclusion,
    /// channel map review, sync-ref candidacy).
    public var extractionInProgress: Bool = false

    /// Last extraction error, if any. When non-nil, the video
    /// card surfaces the message so the user can retry or revert
    /// to .omit. Cleared on next successful extraction.
    public var extractionError: String?

    /// Set to true by the extraction flow when the user picked
    /// `.production` but the extracted audio's quality grade
    /// came back as `.reference` (looks like an onboard scratch
    /// mic, not a production feed). Drives a warning dialog on
    /// the video card offering to switch back to `.reference`
    /// mode so the camera's noisy ambience doesn't land in the
    /// merged poly BWF. Cleared when the user dismisses the
    /// warning OR flips the mode.
    public var showProductionQualityWarning: Bool = false

    /// True when PolyMerge just auto-reset `cameraAudioMode` back to
    /// `.omit` because every extracted channel was silent (hard-
    /// silence or effectively-blank under the auto-exclude
    /// heuristic). Drives an informational dialog so the user
    /// understands why the AUD strip / PROD chip they were expecting
    /// didn't appear — without the dialog, the mode silently reverts
    /// and the user has no idea what happened. The message includes
    /// which video triggered it. Cleared when the user dismisses.
    public var showAllSilentCameraAudioNotice: Bool = false

    /// Number of audio tracks in the video container. Many pro video
    /// files (MXF, ProRes .mov) have 2-8 embedded audio tracks — we
    /// surface the count so the user knows the file has a guide
    /// audio track that can be used for sync when the camera has no
    /// TC. Zero for silent video.
    public var audioTrackCount: Int

    /// Sample rate of the first audio track (Hz), or nil if no audio.
    public var audioSampleRate: Int?

    /// Total channel count across all audio tracks. Reported so the
    /// user knows what guide audio is available for sync.
    public var audioChannelCount: Int

    /// True if the file contains at least one audio track that could
    /// be used as a guide for sync inference. Convenience accessor.
    public var hasAudioTrack: Bool { audioTrackCount > 0 }

    // MARK: - Timecode

    /// Start timecode of the file. Extracted from the QuickTime
    /// timecode track if present, otherwise nil. A nil TC on a video
    /// file is common — phones, GoPros, drones, and consumer cameras
    /// typically don't stamp TC. In Stage 4 we'll add audio-sync
    /// inference to derive a TC by cross-correlating the file's
    /// guide audio against the bin's reference audio.
    public var timecode: TimecodeValue?

    /// Where the timecode came from, for display in the file card.
    public var timecodeSource: TimecodeSource = .none

    public enum TimecodeSource: String {
        case none              // no TC yet
        case embeddedTCTrack   // QuickTime timecode track from camera
        case manual            // user-entered (Stage 4+)
        case audioSync         // inferred by cross-correlating guide audio (Stage 4+)
    }

    // MARK: - Camera metadata (scene / take / reel)

    /// Reel / camera identifier ("A", "B", "A001", "CAM1"). Extracted
    /// from the QuickTime metadata if present.
    public var reel: String?

    /// Scene number. Extracted from QuickTime metadata if present.
    public var scene: String?

    /// Take number. Extracted from QuickTime metadata if present.
    public var take: String?

    /// Camera vendor / model. Extracted from the file's format
    /// descriptions or QuickTime metadata. Useful for debugging
    /// format support and for the user to confirm which camera a
    /// file is from.
    public var cameraMake: String?
    public var cameraModel: String?

    /// File origination date (from QuickTime metadata or file
    /// system modification date as fallback). Used by the auto-
    /// grouper for date-partition.
    public var originationDate: String?

    // MARK: - Display

    /// Color for the file card / timeline track. Assigned by the
    /// session when the file is added.
    public var color: Color

    /// Free-text notes, user-editable. Persisted in-session only
    /// (Phase 4 of the project model will persist to .polymerge).
    public var notes: String = ""

    // MARK: - Validation

    /// Warnings about the file. Shown as a yellow banner on the
    /// file card. e.g. "No embedded TC — will need audio sync to
    /// position on timeline".
    public var warnings: [String] = []

    /// Hard errors that prevent the file from being used. e.g. the
    /// container couldn't be opened, or the extension suggested
    /// video but no video track was found.
    public var errors: [String] = []

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        url: URL,
        duration: TimeInterval,
        videoWidth: Int,
        videoHeight: Int,
        videoFrameRate: Double,
        videoCodec: String,
        audioTrackCount: Int = 0,
        audioSampleRate: Int? = nil,
        audioChannelCount: Int = 0,
        color: Color
    ) {
        self.id = id
        self.url = url
        self.filename = url.lastPathComponent
        self.duration = duration
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoFrameRate = videoFrameRate
        self.videoCodec = videoCodec
        self.audioTrackCount = audioTrackCount
        self.audioSampleRate = audioSampleRate
        self.audioChannelCount = audioChannelCount
        self.color = color
    }

    // NOTE: `static func failed(url:error:colorIndex:)` lives in the
    // PolyMerge executable target as an extension on `VideoFile`
    // (see `VideoFile+Factory.swift`) because it depends on `Theme`
    // which is part of the executable's view layer, not the model
    // library.

    // MARK: - Display helpers

    /// Short codec label for the file card, e.g. "ProRes" instead of
    /// "Apple ProRes 422". Fallback to the full codec string when we
    /// don't have a friendly short form.
    public var shortCodec: String {
        if videoCodec.contains("ProRes") { return "ProRes" }
        if videoCodec.contains("H.264") || videoCodec.contains("h264") { return "H.264" }
        if videoCodec.contains("HEVC") || videoCodec.contains("H.265") { return "H.265" }
        if videoCodec.contains("DNxHD") || videoCodec.contains("DNxHR") { return "DNxHD" }
        if videoCodec.contains("XAVC") { return "XAVC" }
        // RAW / vendor-proprietary codecs that AVFoundation can't
        // decode without vendor SDKs. We recognize them for UX so
        // the user sees "Canon Cinema RAW Light — METADATA ONLY"
        // instead of a blank card.
        let ext = url.pathExtension.lowercased()
        if ext == "crm" { return "Canon RAW" }
        if ext == "r3d" { return "RED RAW" }
        if ext == "braw" { return "BRAW" }
        if ext == "ari" { return "ARRIRAW" }
        return videoCodec
    }

    /// **Playback capability assessment.** Tells the UI whether
    /// PolyMerge's `AVPlayer`-backed viewer can actually decode
    /// frames from this file, or whether we can only READ its
    /// metadata (TC, audio streams) and PASS it through to the
    /// NLE for relink via the exported FCPXML / FCP7 XML sidecar.
    ///
    /// The philosophy: support the WIDEST possible set of video
    /// formats for the SYNC + EXPORT path, even when we can't
    /// play them. The user's NLE (Resolve, Premiere, Avid) has
    /// vendor SDKs we don't — let it handle decode. PolyMerge
    /// just needs the TC and optional embedded audio.
    public enum PlaybackCapability {
        /// AVFoundation can decode frames — viewer works,
        /// timeline shows live frames at the playhead.
        case realtime
        /// Format is recognized but the codec needs a vendor SDK
        /// we don't have. Viewer shows a placeholder. The file
        /// still carries TC and audio through the export.
        case metadataOnly(reason: String)
        /// We haven't probed yet.
        case unknown
    }

    /// Computed capability based on codec + extension. Called at
    /// parse time; could be upgraded later if we add vendor SDKs.
    public var playbackCapability: PlaybackCapability {
        let ext = url.pathExtension.lowercased()
        // Known-undecodable (need vendor SDK):
        switch ext {
        case "crm":   return .metadataOnly(reason: "Canon Cinema RAW Light (SDK required)")
        case "r3d":   return .metadataOnly(reason: "RED R3D (RED SDK required)")
        case "braw":  return .metadataOnly(reason: "Blackmagic RAW (BRAW SDK required)")
        case "ari":   return .metadataOnly(reason: "ARRIRAW (ARRI SDK required)")
        default:      break
        }
        // AVFoundation-supported codecs. Trust AVFoundation to
        // decode anything it recognized a video track for —
        // errors surface in the card's error banner if decode
        // actually fails.
        if !videoCodec.isEmpty && videoWidth > 0 {
            return .realtime
        }
        return .unknown
    }

    /// Short label for the playback capability chip. One-liner
    /// shown next to the codec so the user sees "ProRes · LIVE"
    /// or "CRM · METADATA ONLY" at a glance.
    public var playbackCapabilityLabel: String {
        switch playbackCapability {
        case .realtime:               return "LIVE"
        case .metadataOnly:           return "META ONLY"
        case .unknown:                return "—"
        }
    }

    /// Tooltip text for the capability chip, describing what the
    /// current state means for the user's workflow.
    public var playbackCapabilityTooltip: String {
        switch playbackCapability {
        case .realtime:
            return "\(shortCodec) — PolyMerge can decode this format. Live video is available in the viewer and on the timeline. If you'd rather save CPU / RAM, turn off real-time playback below."
        case .metadataOnly(let reason):
            return "\(reason). PolyMerge can't decode this format without a vendor SDK, but it CAN read the timecode and any embedded audio so the clip syncs correctly. The merged BWF + XML export will include this file at its correct TC; your NLE (Resolve / Premiere / Avid) decodes it on import."
        case .unknown:
            return "Codec unknown — parse didn't produce enough info to classify. Likely safe to treat as metadata-only."
        }
    }

    /// User toggle for live video playback. Defaults to ON for
    /// realtime-capable files and OFF for metadata-only files.
    /// The user can turn this off on realtime-capable files too
    /// if they'd rather save the CPU / memory overhead of
    /// streaming video while they focus on audio.
    ///
    /// When false, the floating viewer + timeline preview show a
    /// placeholder poster; the AVPlayer isn't loaded at all.
    public var livePlaybackEnabled: Bool = true

    // MARK: - PPE color prep (M7)

    /// Per-video exposure adjustment in stops. Applied in the
    /// PPE fragment shader as `color * pow(2, exposureStops)`
    /// in linear light before the optional 3D LUT lookup. Range
    /// roughly [-3, +3] stops; the UI clamps to that. 0 means
    /// no change.
    ///
    /// Preview-only today (M7 preview milestone). Export bake
    /// is a future milestone; when it lands, this value gets
    /// applied once more as a baked pixel transform during
    /// export, not as a runtime shader pass.
    public var exposureStops: Double = 0

    /// Per-video 3D LUT applied after exposure in the PPE
    /// fragment shader. nil = no LUT. The path is stored so we
    /// can keep the LUT selection stable across relaunches; the
    /// loader re-reads + re-uploads on each session open. See
    /// `PPELUTLoader` for the format support list.
    public var lutURL: URL?

    /// "1920 × 1080" format resolution label. Empty string for files
    /// where resolution couldn't be determined.
    public var resolutionLabel: String {
        guard videoWidth > 0, videoHeight > 0 else { return "" }
        return "\(videoWidth) × \(videoHeight)"
    }

    /// "23.98 fps" / "24 fps" / "59.94 fps" — the nominal rate
    /// rounded to two decimals, or a clean integer when appropriate.
    public var frameRateLabel: String {
        guard videoFrameRate > 0 else { return "" }
        let rounded = (videoFrameRate * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return "\(Int(rounded)) fps"
        }
        return String(format: "%.2f fps", rounded)
    }

    // MARK: - Audio sync (Stage 4)

    /// Inference result from the most recent audio-to-video sync run.
    /// Stored on the file so the UI can show the inferred TC,
    /// confidence, and reference file alongside an APPLY action
    /// before the user commits.
    public var inferredTimecode: TimecodeValue?
    public var inferredConfidence: Double = 0
    public var inferredReferenceFileID: UUID?
    public var inferredDelaySeconds: Double = 0

    /// Stage progress for the live audio sync UI.
    public enum SyncStatus: String {
        case idle
        case loadingReference = "Loading reference"
        case loadingTarget    = "Loading video audio"
        case mixingDown       = "Mixing channels"
        case crossCorrelating = "Cross-correlating"
        case done             = "Done"
        case failed           = "Sync failed"
    }
    public var syncStatus: SyncStatus = .idle

    /// Commit the most recent inference result to the file's
    /// timecode. Clears the inference state. Sets `timecodeSource`
    /// to `.audioSync` so the UI can display where the TC came
    /// from. Removes the no-TC warning if present.
    public func applyInferredTimecode() {
        guard let inferred = inferredTimecode else { return }
        timecode = inferred
        timecodeSource = .audioSync
        // Clear the no-TC warning that the parser added at load
        // time. The exact text from `VideoFileParser` is
        // "No embedded timecode — will need audio sync to position
        // on the bin timeline" — match on "embedded timecode" so a
        // future tweak to the wording doesn't quietly leave the
        // warning stranded after a successful sync.
        warnings.removeAll { $0.lowercased().contains("embedded timecode") }
    }

    /// Discard the most recent inference result without applying it.
    /// Used when the user wants to re-run the sync against a
    /// different reference.
    public func clearInference() {
        inferredTimecode = nil
        inferredConfidence = 0
        inferredReferenceFileID = nil
        inferredDelaySeconds = 0
        syncStatus = .idle
    }
}
