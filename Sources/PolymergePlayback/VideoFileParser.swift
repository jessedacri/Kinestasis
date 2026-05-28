import Foundation
import AVFoundation
import CoreMedia
import SwiftUI
import PolymergeMediaModel
import PolymergeIngest

/// Stateless parser that reads video file metadata via AVFoundation
/// and produces a `VideoFile`.
///
/// **Scope**: metadata only. No frame decoding, no thumbnails (those
/// land in Stage 3 via `AVAssetImageGenerator`), no audio extraction
/// (Stage 4). This pass just reads the container metadata and
/// surfaces it for display + bin membership.
///
/// **AVFoundation as the only dependency**: AVFoundation ships with
/// macOS and handles every container + codec we need for the common
/// case (QuickTime .mov including ProRes, MP4 H.264/H.265, most MXF
/// flavors used by Sony XAVC and Canon XF). A few exotic formats
/// (some legacy MXF OP-Atom, some RED / ARRI RAW wrappers) need an
/// FFmpeg fallback which we'll add in a later pass if real-world
/// files surface the need. For now: if AVAsset can't load it, we
/// report the error and the user sees a red banner on the file card.
///
/// **Async by design**: AVAsset's modern API is async — `load(.tracks)`,
/// `load(.duration)`, etc. The parse is called from `MergeSession.addFiles`
/// which already runs background `Task.detached` blocks, so an async
/// parse fits naturally.
public struct VideoFileParser {

    public enum ParseError: LocalizedError {
        case noVideoTrack
        case cannotOpen(String)
        case metadataLoadFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "File has no video track"
            case .cannotOpen(let msg): return "Cannot open video: \(msg)"
            case .metadataLoadFailed(let msg): return "Metadata load failed: \(msg)"
            }
        }
    }

    /// Parse a video file at the given URL. Returns a fully-populated
    /// `VideoFile` on success, throws on failure. The caller is
    /// responsible for handling the error (typically by creating a
    /// `VideoFile.failed(...)` placeholder so the user sees the file
    /// in the list with an error banner).
    /// MXF parse via ffprobe + our KLV walker. The KLV walker
    /// gets exact start TC (22 ms even on a 193 GB file);
    /// ffprobe gets exact duration, resolution, audio track
    /// count, and codec name (~150 ms via the MXF footer's
    /// Random Index Pack — it DOES NOT walk the essence body).
    /// No AVFoundation involvement → no memory-mapped pages,
    /// no swap pressure, no "Cannot Open" errors.
    ///
    /// Returns nil when ffprobe isn't installed, in which case
    /// the caller falls back to AVFoundation (and if that also
    /// fails, to `parseMXFMetadataOnly` with a bitrate-
    /// estimated duration).
    private static func parseMXFViaProbe(url: URL, color: Color) -> VideoFile? {
        guard MXFProbeReader.isAvailable,
              let probe = try? MXFProbeReader.probe(url: url),
              probe.durationSeconds > 0 else {
            return nil
        }
        // Start TC from our KLV walker. Could also come from
        // ffprobe (it extracts "timecode" from container-level
        // metadata tags) but the KLV walker returns the nominal
        // integer rate + drop-frame flag which we need for
        // display-accurate TC math.
        let tcResult = try? MXFTimecodeReader.readStartTimecode(url: url)

        let file = VideoFile(
            url: url,
            duration: probe.durationSeconds,
            videoWidth: probe.width,
            videoHeight: probe.height,
            videoFrameRate: probe.frameRate,
            videoCodec: probe.videoCodec,
            audioTrackCount: probe.audioTrackCount,
            audioSampleRate: probe.audioSampleRate,
            audioChannelCount: probe.audioChannelCount,
            color: color
        )

        if let tcR = tcResult {
            let frameRateEnum: TimecodeValue.FrameRate = {
                switch (tcR.roundedFrameRate, tcR.isDropFrame) {
                case (24, false):  return .fps23_976
                case (25, false):  return .fps25
                case (30, true):   return .fps29_97_DF
                case (30, false):  return .fps29_97_NDF
                case (60, _):      return .fps59_94
                case (48, false):  return .fps48
                case (50, false):  return .fps50
                default:           return .fps24
                }
            }()
            let h: Int, m: Int, s: Int, f: Int
            if tcR.isDropFrame {
                let dc = tcR.roundedFrameRate == 60 ? 4 : 2
                let tup = DropFrameCalculator.framesToTimecode(
                    Int(tcR.startFrameCount),
                    dropCount: dc,
                    nominalRate: tcR.roundedFrameRate
                )
                h = tup.h; m = tup.m; s = tup.s; f = tup.f
            } else {
                let n = tcR.roundedFrameRate
                let total = Int(tcR.startFrameCount) / n
                f = Int(tcR.startFrameCount) % n
                s = total % 60
                m = (total / 60) % 60
                h = total / 3600
            }
            file.timecode = TimecodeValue(
                hours: h, minutes: m, seconds: s, frames: f,
                sampleRate: 48000,
                frameRate: frameRateEnum
            )
            file.timecodeSource = .embeddedTCTrack
        }

        // **Live playback defaults to ON — optimistic with fallback.**
        // AVFoundation can decode MXF-wrapped ProRes / XAVC / Canon XF
        // when Apple's "Pro Video Formats" package is installed
        // (most Resolve/Premiere users have it — it's a free Apple
        // download). We no longer blanket-disable: instead,
        // `VideoPlayerController` observes the AVPlayerItem's status
        // when the user tries to view this file, and flips
        // `livePlaybackEnabled` back to false if the decoder fails
        // (the common case on systems without Pro Video Formats,
        // or on the odd 4K+ ProRes-HQ resolutions the hardware
        // decoder silently refuses). The memory bloat the old
        // "off by default" comment warned about only fires when an
        // AVAsset is OPENED — parsing uses the KLV reader instead
        // of AVFoundation (see parseMXFViaProbe above), so we pay
        // nothing at import time for 25 unopened MXFs. Playback-
        // time cost is bounded to one active item via the shared
        // `AVPlayer`.
        file.livePlaybackEnabled = true
        print("[VideoParse] \(url.lastPathComponent) → ffprobe path codec=\(probe.videoCodec) duration=\(String(format: "%.3f", probe.durationSeconds))s audio=\(probe.audioTrackCount)ch=\(probe.audioChannelCount) livePlayback=ON(optimistic)")
        return file
    }

    /// MXF-only parse path: build a VideoFile using ONLY the
    /// MXF KLV header metadata, no AVFoundation. Used when
    /// AVAsset refuses the file (ARRI Alexa Mini LF MXFs with
    /// `preferPreciseDurationAndTiming: false` consistently
    /// return "Cannot Open" from AVURLAsset) but we can still
    /// extract everything we need directly from the SMPTE 377M
    /// header. The resulting VideoFile is flagged as
    /// `metadataOnly` for playback (viewer shows a placeholder)
    /// but flows through every sync / export path correctly:
    /// TC is real, region matching works, FCPXML emission uses
    /// the right UL frame rate, the user's NLE (Resolve,
    /// Premiere, Avid) decodes the file on import.
    private static func parseMXFMetadataOnly(url: URL, color: Color) -> VideoFile? {
        guard let mxfResult = try? MXFTimecodeReader.readStartTimecode(url: url) else {
            return nil
        }
        // Picture descriptor — dimensions + real rational frame
        // rate (24000/1001, 30000/1001, etc.). Falls back to the
        // timecode reader's rounded rate when the descriptor is
        // unreadable on an exotic MXF.
        let pictureDesc = (try? MXFPictureDescriptorReader.read(url: url)).flatMap { $0 }
        let width = Int(pictureDesc?.storedWidth ?? 0)
        let height = Int(pictureDesc?.storedHeight ?? 0)
        let exactFrameRate: Double = pictureDesc.map {
            $0.frameRate > 0 ? $0.frameRate : Double(mxfResult.roundedFrameRate)
        } ?? Double(mxfResult.roundedFrameRate)

        // Sound descriptors — one per mono track on Canon XF-AVC,
        // a single stereo/multichannel one on ARRI / Sony. Sum
        // channels across all descriptors so a 4-mono-track file
        // reports 4 audio channels (matches what the audio
        // extractor will actually produce).
        let soundDescs = (try? MXFSoundDescriptorReader.readAll(url: url)) ?? []
        let totalAudioChannels = soundDescs.reduce(0) { $0 + Int($1.channelCount) }
        let audioSampleRate: Int? = soundDescs.first.map { Int($0.sampleRate.rounded()) }

        // Essence scan: frame count × frame rate is the most
        // accurate duration — better than file-size / bitrate
        // and works without ffprobe. Also tells us the codec
        // (H.264 / ProRes / unknown) for the playback capability
        // decision. The scan is fast for typical camera MXFs
        // (<100 ms for a 4 GB Canon clip) but can run several
        // seconds on a 100 GB+ ARRI take — that's still far
        // better than AVFoundation's "Cannot Open" failure
        // mode, and it only runs once per import.
        var durationFromScan: Double? = nil
        var codecFromScan: MXFEssenceReader.PictureCodec? = nil
        if let idx = try? MXFEssenceReader.scanIndex(url: url), !idx.frames.isEmpty {
            durationFromScan = Double(idx.frames.count) / exactFrameRate
            codecFromScan = idx.codec
        }

        let frameRateEnum: TimecodeValue.FrameRate = {
            // Map the nominal integer rate to the closest
            // TimecodeValue.FrameRate. ARRI / Sony / Canon
            // typically stamp `RoundedTimecodeBase = 24` for
            // 23.976 NDF, `30` for 29.97 NDF, etc. We can't
            // distinguish 23.976 NDF from 24p cleanly from the
            // metadata alone, so we prefer the "NDF" variants
            // since that's the vastly more common case on-set.
            switch (mxfResult.roundedFrameRate, mxfResult.isDropFrame) {
            case (24, false):  return .fps23_976       // most common on-set
            case (25, false):  return .fps25
            case (30, true):   return .fps29_97_DF
            case (30, false):  return .fps29_97_NDF
            case (60, _):      return .fps59_94        // 59.94 DF and NDF share one enum case
            case (48, false):  return .fps48
            case (50, false):  return .fps50
            default:           return .fps24
            }
        }()
        let h: Int, m: Int, s: Int, f: Int
        if mxfResult.isDropFrame {
            let dropCount = mxfResult.roundedFrameRate == 60 ? 4 : 2
            let tup = DropFrameCalculator.framesToTimecode(
                Int(mxfResult.startFrameCount),
                dropCount: dropCount,
                nominalRate: mxfResult.roundedFrameRate
            )
            h = tup.h; m = tup.m; s = tup.s; f = tup.f
        } else {
            let n = mxfResult.roundedFrameRate
            let total = Int(mxfResult.startFrameCount) / n
            f = Int(mxfResult.startFrameCount) % n
            s = total % 60
            m = (total / 60) % 60
            h = total / 3600
        }
        let tc = TimecodeValue(
            hours: h, minutes: m, seconds: s, frames: f,
            sampleRate: 48000,
            frameRate: frameRateEnum
        )
        // Duration: essence scan wins when we have it; otherwise
        // fall back to a bitrate estimate so the timeline bar
        // still has a length.
        let duration: Double = {
            if let d = durationFromScan { return d }
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let estimatedBytesPerSecond: Double = 130_000_000
            return max(1.0, Double(fileSize) / estimatedBytesPerSecond)
        }()
        // Codec label: prefer the scanner's classification
        // (H.264 / ProRes / unknown-fourcc) since the user sees
        // it in the file card. Falls back to the generic "MXF"
        // tag when we couldn't scan.
        let codecLabel: String = {
            if let c = codecFromScan {
                switch c {
                case .h264: return "H.264 (MXF)"
                case .prores: return "ProRes (MXF)"
                case .unknown: return "MXF"
                }
            }
            return "MXF (metadata only)"
        }()

        let file = VideoFile(
            url: url,
            duration: duration,
            videoWidth: width,
            videoHeight: height,
            videoFrameRate: exactFrameRate,
            videoCodec: codecLabel,
            audioTrackCount: soundDescs.count,
            audioSampleRate: audioSampleRate,
            audioChannelCount: totalAudioChannels,
            color: color
        )
        file.timecode = tc
        file.timecodeSource = .embeddedTCTrack
        // H.264 and ProRes MXFs ride our native
        // `MXFH264Player` / `MXFProResPlayer` playback pipelines
        // — no AVFoundation, no Pro Video Formats, nothing to
        // install. Anything else we couldn't classify still
        // needs an NLE to decode, so it defaults to
        // livePlaybackEnabled = false with the UI placeholder.
        switch codecFromScan {
        case .h264, .prores:
            file.livePlaybackEnabled = true
        default:
            file.livePlaybackEnabled = false
            file.warnings.append("MXF uses a codec this build doesn't decode natively (\(codecLabel)). TC and sync work; no live video preview. Your NLE will decode the file on import.")
        }
        return file
    }

    /// Parse a video file at the given URL. Returns a fully-
    /// populated `VideoFile` on success, throws on failure. The
    /// `color` parameter is the swatch color assigned by the
    /// host app's track-color palette (the library has no
    /// opinion about color schemes; the app passes one in).
    public static func parse(url: URL, color: Color) async throws -> VideoFile {
        // **MXF files bypass AVFoundation entirely.**
        // AVFoundation's MXF handler costs ~2-10 GB of
        // memory-mapped pages per file when `preferPrecise` is
        // on (to walk essence body for duration), or outright
        // refuses to open when it's off ("Cannot Open"). Neither
        // is workable for a shoot day with 25+ huge MXFs.
        //
        // Our KLV walker extracts TC from the header (22ms even
        // on a 193 GB file), and ffprobe extracts exact duration
        // + stream metadata (~150ms per file via the MXF Random
        // Index Pack, no essence walk). Together they replace
        // AVFoundation for MXF with near-zero memory and much
        // faster parse times.
        if url.pathExtension.lowercased() == "mxf" {
            if let mxfFile = parseMXFViaProbe(url: url, color: color) {
                return mxfFile
            }
            // ffprobe missing / failed → fall through to the
            // AVFoundation path below. If THAT also fails we
            // drop to our header-only estimator.
        }

        // **`preferPreciseDurationAndTiming: true`** — we need this
        // because ARRI / Sony / Canon MXFs don't populate their
        // Duration fields in Header Metadata (all 0xFFFFFFFFFFFFFFFF
        // "undefined" per the spec's streaming-container
        // convention). AVFoundation with precise timing walks the
        // file's essence body to count actual frame packets,
        // giving us the exact duration.
        //
        // The earlier "preferPrecise=false, bound memory via flag"
        // approach failed because:
        //   1. With preferPrecise=false, AVFoundation outright
        //      refused to open these ARRI OP1a files ("Cannot Open").
        //   2. When it DID open with preferPrecise=true, it
        //      allocated multi-GB index buffers per file, and 4
        //      parallel parses peaked at ~30-50 GB on drop.
        //
        // The fix is serialization, not flag flipping:
        //   1. Video parse parallelism capped at 1 (MergeSession).
        //   2. The global heavy-I/O semaphore also limits disk
        //      contention when MixLoudness / preparePlayback /
        //      waveform scans run alongside.
        //   3. Each precise parse allocates + releases its buffers
        //      before the next starts, so peak RAM stays bounded
        //      at roughly one file's parse cost (~2-5 GB for a
        //      193 GB file; cheaper for typical clips).
        //
        // For files where AVFoundation still fails (rare —
        // non-standard MXF variants), we fall back below to the
        // manual KLV walker in `parseMXFMetadataOnly`.
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])

        // Load duration + tracks concurrently. AVFoundation's modern
        // API returns these as async properties; we batch them so the
        // parse call doesn't serialize across multiple round trips.
        let duration: CMTime
        let tracks: [AVAssetTrack]
        do {
            async let durationPromise = asset.load(.duration)
            async let tracksPromise = asset.load(.tracks)
            duration = try await durationPromise
            tracks = try await tracksPromise
        } catch {
            // **MXF fallback** — AVFoundation refuses to open some
            // ARRI / Sony / Canon MXFs (especially 4K+ ProRes OP1a
            // variants) with `preferPreciseDurationAndTiming: false`.
            // The error is usually just "Cannot Open" with no
            // detail. When the file IS an MXF, fall back to our
            // own KLV walker — we get TC, frame rate, and enough
            // identity metadata to route the file through the
            // sync + export paths. The file shows up as
            // "metadata only" in the UI (no live viewer) but the
            // sync math and FCPXML relink all work correctly.
            if url.pathExtension.lowercased() == "mxf",
               let mxfFile = Self.parseMXFMetadataOnly(url: url, color: color) {
                print("[VideoParse] \(url.lastPathComponent) → MXF-HEADER-ONLY path (AVFoundation failed: \(error.localizedDescription)) duration≈\(String(format: "%.1f", mxfFile.duration))s")
                return mxfFile
            }
            throw ParseError.cannotOpen(error.localizedDescription)
        }

        // Find the video track. PolyMerge requires at least one
        // video track — a "video file" with only audio isn't a
        // video file for our purposes (the user would drop the .wav
        // in instead).
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw ParseError.noVideoTrack
        }

        // Load video track metadata
        let naturalSize: CGSize
        let frameRate: Float
        let formatDescriptions: [CMFormatDescription]
        do {
            async let sizePromise = videoTrack.load(.naturalSize)
            async let rateePromise = videoTrack.load(.nominalFrameRate)
            async let fdsPromise = videoTrack.load(.formatDescriptions)
            naturalSize = try await sizePromise
            frameRate = try await rateePromise
            formatDescriptions = try await fdsPromise
        } catch {
            throw ParseError.metadataLoadFailed(error.localizedDescription)
        }

        // Human-readable codec name from the first format description.
        let codec: String
        if let fd = formatDescriptions.first {
            let subtype = CMFormatDescriptionGetMediaSubType(fd)
            codec = Self.codecName(from: subtype)
        } else {
            codec = "Unknown"
        }

        // Audio tracks
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        var audioChannelCount = 0
        var audioSampleRate: Int? = nil
        if let firstAudio = audioTracks.first {
            do {
                let fds = try await firstAudio.load(.formatDescriptions)
                if let fd = fds.first,
                   let streamBasicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                    audioSampleRate = Int(streamBasicDesc.mSampleRate)
                }
            } catch {
                // Non-fatal — we can still use the file without the
                // audio stream basic description. Just means we
                // don't know the sample rate.
            }
            // Sum channel counts across all audio tracks.
            for track in audioTracks {
                do {
                    let fds = try await track.load(.formatDescriptions)
                    if let fd = fds.first,
                       let sbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                        audioChannelCount += Int(sbd.mChannelsPerFrame)
                    }
                } catch {
                    continue
                }
            }
        }

        // Construct the file object before we look for timecode,
        // scene/take, etc. — those are additive and won't block the
        // parse if any of them are missing.
        let file = VideoFile(
            url: url,
            duration: duration.seconds,
            videoWidth: Int(naturalSize.width),
            videoHeight: Int(naturalSize.height),
            videoFrameRate: Double(frameRate),
            videoCodec: codec,
            audioTrackCount: audioTracks.count,
            audioSampleRate: audioSampleRate,
            audioChannelCount: audioChannelCount,
            color: color
        )
        if url.pathExtension.lowercased() == "mxf" {
            print("[VideoParse] \(url.lastPathComponent) → AVFoundation path codec=\(codec) duration=\(String(format: "%.3f", duration.seconds))s audioTracks=\(audioTracks.count)")
        }
        // Default live playback state follows the playback
        // capability. Realtime-capable files (ProRes, H.264,
        // HEVC, DNx) default to LIVE ON so the user sees
        // frames in the viewer. Metadata-only files (Canon
        // CRM, RED R3D, Blackmagic BRAW, ARRIRAW) default to
        // LIVE OFF — the viewer shows a placeholder and no
        // AVPlayer is attached, saving the CPU / memory that
        // would be wasted trying to decode an unsupported
        // codec. The user can override either way per-file.
        if case .metadataOnly = file.playbackCapability {
            file.livePlaybackEnabled = false
        }

        // Load embedded timecode if present. The timecode track is a
        // separate track type on QuickTime files; when the camera was
        // jammed to external TC, this track carries the start TC as
        // a 32-bit frame count at the timecode track's timescale.
        if let tcTrack = tracks.first(where: { $0.mediaType == .timecode }) {
            if let tc = try? await Self.readStartTimecode(
                track: tcTrack,
                nominalFrameRate: Double(frameRate)
            ) {
                file.timecode = tc
                file.timecodeSource = .embeddedTCTrack
            }
        }

        // **MXF fallback.** MXF files (ARRI Alexa Mini LF, Sony
        // FX9, Canon C500, Panasonic VariCam, etc.) don't carry
        // TC in a tmcd-style track. Their start TC lives in the
        // Header Metadata's Timecode Component local set — a
        // SMPTE 377M construct that our QuickTime atom walker
        // can't reach because MXF is KLV-structured, not atom-
        // structured. When the QuickTime path above didn't
        // produce a TC AND the file extension is `.mxf`, try
        // the MXF KLV reader.
        if file.timecode == nil,
           url.pathExtension.lowercased() == "mxf",
           let mxfResult = try? MXFTimecodeReader.readStartTimecode(url: url) {
            let nominalInt = mxfResult.roundedFrameRate
            let frameRateEnum: TimecodeValue.FrameRate = {
                if let fr = TimecodeValue.FrameRate.from(rate: Double(frameRate), isDropFrame: mxfResult.isDropFrame) {
                    return fr
                }
                return .fps24
            }()
            // Convert frame count to H:M:S:F using the nominal
            // rate, matching the QuickTime TMCD path's math.
            let h: Int, m: Int, s: Int, f: Int
            if mxfResult.isDropFrame {
                let dropCount: Int
                switch nominalInt {
                case 30: dropCount = 2    // 29.97 DF
                case 60: dropCount = 4    // 59.94 DF
                default: dropCount = 0    // no other rates are standard DF
                }
                let tup = DropFrameCalculator.framesToTimecode(
                    Int(mxfResult.startFrameCount),
                    dropCount: dropCount,
                    nominalRate: nominalInt
                )
                h = tup.h; m = tup.m; s = tup.s; f = tup.f
            } else {
                let nominal = nominalInt
                let totalSeconds = Int(mxfResult.startFrameCount) / nominal
                f = Int(mxfResult.startFrameCount) % nominal
                s = totalSeconds % 60
                m = (totalSeconds / 60) % 60
                h = totalSeconds / 3600
            }
            let tc = TimecodeValue(
                hours: h, minutes: m, seconds: s, frames: f,
                sampleRate: 48000,
                frameRate: frameRateEnum
            )
            file.timecode = tc
            file.timecodeSource = .embeddedTCTrack
        }

        // Load optional metadata (scene, take, reel, camera make/model).
        // Most of this comes from the QuickTime common metadata space
        // plus some vendor-specific namespaces. Missing metadata is
        // non-fatal — nil fields just don't render in the file card.
        if let metadata = try? await asset.load(.metadata) {
            for item in metadata {
                guard let key = item.commonKey?.rawValue ?? item.key as? String else { continue }
                let value = (try? await item.load(.stringValue)) ?? ""
                guard !value.isEmpty else { continue }

                switch key.lowercased() {
                case "reel", "com.apple.quicktime.reel", "reelname":
                    file.reel = value
                case "scene", "com.apple.quicktime.scene":
                    file.scene = value
                case "take", "com.apple.quicktime.take":
                    file.take = value
                case "make", "com.apple.quicktime.make":
                    file.cameraMake = value
                case "model", "com.apple.quicktime.model":
                    file.cameraModel = value
                case "creationdate", "com.apple.quicktime.creationdate":
                    // Use the creation date as the origination date
                    // if we don't already have one from another
                    // source. Format it to the ISO yyyy-MM-dd shape
                    // the auto-grouper expects.
                    if file.originationDate == nil {
                        file.originationDate = Self.iso8601DateOnly(from: value)
                    }
                default:
                    continue
                }
            }
        }

        // File system modification date as a last-resort origination
        // date fallback. Used by the auto-grouper's date partition
        // stage when no BEXT/iXML/QT metadata date is present.
        if file.originationDate == nil {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let modDate = attrs[.modificationDate] as? Date {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withFullDate]
                file.originationDate = formatter.string(from: modDate)
            }
        }

        // Warn the user if the file has no TC — this is the signal
        // they'll need audio sync inference (Stage 4) to position
        // the clip on the bin's timeline.
        if file.timecode == nil {
            file.warnings.append("No embedded timecode — will need audio sync to position on the bin timeline")
        }

        return file
    }

    // MARK: - Helpers

    /// Convert a `CMFormatDescription`'s media subtype FourCC to a
    /// human-readable codec name. Covers the common pro / consumer
    /// formats PolyMerge's target users shoot on.
    private static func codecName(from subtype: CMVideoCodecType) -> String {
        switch subtype {
        // ProRes family
        case kCMVideoCodecType_AppleProRes422:        return "Apple ProRes 422"
        case kCMVideoCodecType_AppleProRes422HQ:      return "Apple ProRes 422 HQ"
        case kCMVideoCodecType_AppleProRes422LT:      return "Apple ProRes 422 LT"
        case kCMVideoCodecType_AppleProRes422Proxy:   return "Apple ProRes 422 Proxy"
        case kCMVideoCodecType_AppleProRes4444:       return "Apple ProRes 4444"
        case kCMVideoCodecType_AppleProRes4444XQ:     return "Apple ProRes 4444 XQ"
        case kCMVideoCodecType_AppleProResRAW:        return "Apple ProRes RAW"
        case kCMVideoCodecType_AppleProResRAWHQ:      return "Apple ProRes RAW HQ"
        // H.264 / H.265
        case kCMVideoCodecType_H264:                  return "H.264"
        case kCMVideoCodecType_HEVC:                  return "H.265 / HEVC"
        case kCMVideoCodecType_HEVCWithAlpha:         return "H.265 w/ alpha"
        // Older codecs still seen occasionally
        case kCMVideoCodecType_MPEG4Video:            return "MPEG-4"
        case kCMVideoCodecType_MPEG2Video:            return "MPEG-2"
        case kCMVideoCodecType_DVCNTSC:               return "DV NTSC"
        case kCMVideoCodecType_DVCPAL:                return "DV PAL"
        case kCMVideoCodecType_JPEG:                  return "Motion JPEG"
        // Fallback: print the FourCC for debugging
        default:
            let chars = [
                Character(UnicodeScalar(UInt8((subtype >> 24) & 0xFF))),
                Character(UnicodeScalar(UInt8((subtype >> 16) & 0xFF))),
                Character(UnicodeScalar(UInt8((subtype >> 8) & 0xFF))),
                Character(UnicodeScalar(UInt8(subtype & 0xFF)))
            ]
            return String(chars)
        }
    }

    /// Read the start timecode from a QuickTime timecode track.
    ///
    /// **Why this doesn't use AVAssetReader**. The obvious path is
    /// to create an `AVAssetReader` with an
    /// `AVAssetReaderTrackOutput` on the TMCD track and read the
    /// first sample's 4 bytes as a big-endian frame count. That
    /// compiles, runs, and returns an empty sample buffer
    /// (`totalSampleSize=0`, `CMSampleBufferGetDataBuffer == nil`).
    /// AVFoundation doesn't expose TMCD track sample data via the
    /// reader API — the sample buffers come back as zero-length
    /// marker buffers regardless of `outputSettings` /
    /// `alwaysCopiesSampleData` / `AVAssetReaderSampleReferenceOutput`
    /// or any other variant I tried. This is a quirk of the
    /// framework, not the file (ffprobe reads the TMCD sample fine,
    /// and so does our manual atom walker below).
    ///
    /// **So we walk the MOV/MP4 atom structure directly** to find
    /// the TMCD track's first sample offset, then seek to it and
    /// read the 4 bytes. The atom walker below handles the
    /// ISOBMFF-compatible container format (which covers .mov,
    /// .mp4, .m4v, .qt, and most ProRes / H.264 / HEVC files). It
    /// does NOT handle raw MXF — those files have a different KLV
    /// structure and need separate extraction (TODO: Stage 1.5).
    ///
    /// **The nominal integer rate trick**. The TMCD frame count is
    /// NOT computed as `real_seconds × actual_fps`. It's computed
    /// using the NOMINAL INTEGER rate from the format description
    /// (24 for 23.976 NDF, 30 for 29.97, etc.):
    /// `frame_count = (H × 3600 + M × 60 + S) × nominal_fps + F`
    /// For 23.976 NDF, a frame count of 1,664,682 divided by 24
    /// (not 23.976) gives 69361 seconds + 18 frames = 19:16:01:18.
    /// Using the actual 23.976 rate gives a ~70-second drift
    /// because the nominal rate is what's baked into the sample
    /// data. We read the nominal rate from the format description
    /// via `CMTimeCodeFormatDescriptionGetFrameQuanta`.
    private static func readStartTimecode(
        track: AVAssetTrack,
        nominalFrameRate: Double
    ) async throws -> TimecodeValue? {
        // Load the format description to get the nominal frame
        // quanta (the integer rate for TC arithmetic) and the
        // drop-frame flag.
        let fds = try await track.load(.formatDescriptions)
        guard let fd = fds.first else { return nil }

        let frameQuanta = CMTimeCodeFormatDescriptionGetFrameQuanta(fd)
        guard frameQuanta > 0 else { return nil }

        // CMTimeCodeFlags in Swift is a raw UInt32, not an OptionSet.
        // The drop-frame bit is bit 0 (`kCMTimeCodeFlag_DropFrame = 1`).
        let flags = CMTimeCodeFormatDescriptionGetTimeCodeFlags(fd)
        let isDropFrame = (flags & UInt32(kCMTimeCodeFlag_DropFrame)) != 0

        // Walk the MOV/MP4 atom tree to find the TMCD track's first
        // sample data. We can't rely on AVAssetReader for this.
        guard let urlAsset = track.asset as? AVURLAsset else { return nil }
        guard let frameCount = try readTMCDFirstSampleViaAtomWalk(url: urlAsset.url) else {
            return nil
        }

        // Convert frame count to HH:MM:SS:FF using the nominal integer
        // quanta, then build a TimecodeValue that stores the position
        // as samples-since-midnight at a nominal 48 kHz display rate.
        let nominalInt = Int(frameQuanta)
        let frameRateEnum: TimecodeValue.FrameRate
        if let fr = TimecodeValue.FrameRate.from(rate: nominalFrameRate, isDropFrame: isDropFrame) {
            frameRateEnum = fr
        } else {
            frameRateEnum = .fps24
        }

        // For non-drop-frame (and the drop-frame calculator we have
        // handles both), the frame count in the TMCD sample is just
        // total-frames-at-the-nominal-rate. Split it into
        // H:M:S:F components using integer math:
        //   seconds = frameCount / nominalInt
        //   frames  = frameCount % nominalInt
        // Then H:M:S from seconds. Drop-frame requires the full
        // DropFrameCalculator walk to account for dropped frame
        // numbers at minute boundaries.
        let h: Int
        let m: Int
        let s: Int
        let f: Int
        if isDropFrame && frameRateEnum.dropCount > 0 {
            // Use the drop-frame calculator to convert the RAW TMCD
            // frame count (which is already a DF-encoded count) to
            // H:M:S:F components.
            let comps = DropFrameCalculator.framesToTimecode(
                Int(frameCount),
                dropCount: frameRateEnum.dropCount,
                nominalRate: nominalInt
            )
            h = comps.h
            m = comps.m
            s = comps.s
            f = comps.f
        } else {
            let totalSec = Int(frameCount) / nominalInt
            f = Int(frameCount) % nominalInt
            s = totalSec % 60
            m = (totalSec / 60) % 60
            h = totalSec / 3600
        }

        // Build the TimecodeValue via its H:M:S:F initializer —
        // this handles the conversion back to samples-since-midnight
        // using the actual (fractional) sample-per-frame rate so
        // the merger + timeline arithmetic stay consistent with
        // audio files' BEXT-derived timecodes.
        return TimecodeValue(
            hours: h,
            minutes: m,
            seconds: s,
            frames: f,
            sampleRate: 48000,
            frameRate: frameRateEnum
        )
    }

    /// Walk the MOV/MP4 ISOBMFF atom tree to locate the first TMCD
    /// track's first sample's file offset, then read 4 bytes at
    /// that offset as a big-endian `UInt32` frame count.
    ///
    /// **Why walk the atoms manually**. AVAssetReader's TMCD sample
    /// reads return empty sample buffers — see the doc comment on
    /// `readStartTimecode` for the full rationale. The atom walk
    /// is the reliable path that matches what ffprobe / MediaInfo
    /// do under the hood.
    ///
    /// **Container support**: MOV, MP4, M4V, QT (all ISOBMFF
    /// variants). Does NOT handle MXF — that's a different
    /// container format with its own KLV metadata structure.
    ///
    /// Returns nil when the file has no TMCD track, when any atom
    /// walk step fails, or when the sample offset is out of
    /// bounds.
    private static func readTMCDFirstSampleViaAtomWalk(url: URL) throws -> UInt32? {
        let fh: FileHandle
        do {
            fh = try FileHandle(forReadingFrom: url)
        } catch {
            return nil
        }
        defer { try? fh.close() }

        let fileSize: UInt64
        do {
            fileSize = try fh.seekToEnd()
        } catch {
            return nil
        }

        // State carried across the recursive walk: set to `true`
        // when we enter a `trak` whose `hdlr` has handler type
        // `tmcd`, reset to `false` when we leave that trak. We only
        // read `stco` / `co64` entries while this flag is true.
        var insideTMCDTrak = false

        func readUInt32BE(at offset: UInt64) throws -> UInt32? {
            try fh.seek(toOffset: offset)
            guard let data = try fh.read(upToCount: 4), data.count == 4 else { return nil }
            return UInt32(bigEndian: data.withUnsafeBytes { $0.load(as: UInt32.self) })
        }

        func readUInt64BE(at offset: UInt64) throws -> UInt64? {
            try fh.seek(toOffset: offset)
            guard let data = try fh.read(upToCount: 8), data.count == 8 else { return nil }
            return UInt64(bigEndian: data.withUnsafeBytes { $0.load(as: UInt64.self) })
        }

        /// Read an atom header at `offset`. Returns (total size
        /// including header, 4-char type code, header size).
        /// Handles the 64-bit extended-size case (`size == 1`) and
        /// the "atom extends to end of file" case (`size == 0`).
        func readHeader(at offset: UInt64) throws -> (size: UInt64, type: String, headerSize: UInt64)? {
            try fh.seek(toOffset: offset)
            guard let header = try fh.read(upToCount: 8), header.count == 8 else { return nil }
            var size = UInt64(header[0..<4].withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) })
            let type = String(data: header[4..<8], encoding: .ascii) ?? "????"
            var headerSize: UInt64 = 8
            if size == 1 {
                guard let longSize = try readUInt64BE(at: offset + 8) else { return nil }
                size = longSize
                headerSize = 16
            } else if size == 0 {
                // Atom extends to the end of the file.
                size = fileSize - offset
            }
            return (size, type, headerSize)
        }

        /// Recursive walker. Returns the first TMCD sample's frame
        /// count as soon as it finds it (short-circuits the walk).
        func walk(start: UInt64, end: UInt64) throws -> UInt32? {
            var pos = start
            while pos < end {
                guard let (size, type, headerSize) = try readHeader(at: pos) else { return nil }
                let atomEnd = pos + size
                if atomEnd > end || size < headerSize { return nil }

                // Container atoms whose children we need to walk
                // into. Everything else is a leaf for our purposes.
                let isContainer = (type == "moov" || type == "trak" ||
                                   type == "mdia" || type == "minf" || type == "stbl")

                if type == "trak" {
                    // New trak — reset the state flag so we don't
                    // mistakenly read a neighbour trak's stco.
                    insideTMCDTrak = false
                    if let result = try walk(start: pos + headerSize, end: atomEnd) { return result }
                } else if type == "hdlr" {
                    // hdlr box: version(1) flags(3) pre_defined(4) handler_type(4) ...
                    // Read the handler type at offset +8 (skip version/flags/pre_defined).
                    try fh.seek(toOffset: pos + headerSize + 8)
                    if let handlerBytes = try fh.read(upToCount: 4), handlerBytes.count == 4 {
                        let handlerType = String(data: handlerBytes, encoding: .ascii) ?? ""
                        if handlerType == "tmcd" {
                            insideTMCDTrak = true
                        }
                    }
                } else if type == "stco" && insideTMCDTrak {
                    // stco: version(1) flags(3) entry_count(4) entries[entry_count * 4]
                    // First entry is the file offset of the first chunk (which holds our sample).
                    if let offset = try readUInt32BE(at: pos + headerSize + 4 + 4) {
                        return try readUInt32BE(at: UInt64(offset))
                    }
                } else if type == "co64" && insideTMCDTrak {
                    // co64 is the 64-bit variant of stco.
                    if let offset = try readUInt64BE(at: pos + headerSize + 4 + 4) {
                        return try readUInt32BE(at: offset)
                    }
                } else if isContainer {
                    if let result = try walk(start: pos + headerSize, end: atomEnd) { return result }
                }

                // Safety: guard against pathological zero-size atoms
                // that would loop forever.
                if size == 0 { break }
                pos = atomEnd
            }
            return nil
        }

        return try walk(start: 0, end: fileSize)
    }

    /// Best-effort conversion from a QuickTime creation date string
    /// (which varies in format per vendor: ISO8601, RFC3339, or even
    /// "2024:03:15 14:30:00") into a bare `yyyy-MM-dd` date string
    /// the auto-grouper can parse.
    private static func iso8601DateOnly(from value: String) -> String? {
        // Try ISO8601 first (most common).
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) {
            let out = ISO8601DateFormatter()
            out.formatOptions = [.withFullDate]
            return out.string(from: date)
        }
        // EXIF-style "yyyy:MM:dd HH:mm:ss"
        let exif = DateFormatter()
        exif.dateFormat = "yyyy:MM:dd HH:mm:ss"
        exif.timeZone = TimeZone(identifier: "UTC")
        if let date = exif.date(from: value) {
            let out = ISO8601DateFormatter()
            out.formatOptions = [.withFullDate]
            return out.string(from: date)
        }
        // Last resort: grab the first ten characters if they look
        // like a date.
        if value.count >= 10 {
            let prefix = String(value.prefix(10))
            if prefix.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                return prefix
            }
        }
        return nil
    }
}
