import Foundation
import PreemCore

/// Emits an FCPXML 1.10 document from a `Project`. Targets the
/// intersection that Premiere Pro, DaVinci Resolve, and Final Cut Pro
/// all import cleanly.
///
/// v0.1 scope:
///   * One `<format>` per (resolution + frame rate + audio rate) combo
///   * One `<asset>` per `ClipSource`
///   * One `<event>` containing every clip as an `<asset-clip>`
///   * Slate scene/take/roll, shot type, and camera roll as `<keyword>`
///     annotations on each clip
///   * Transcript text (if any) as a `<note>` attribute
///   * No sequences/timelines (Preem doesn't have them yet in M1)
///
/// When Preem grows a timeline (M2+), this exporter gains a code path
/// that emits `<project>/<sequence>/<spine>` from a `Sequence` value.
public struct FCPXMLExporter: Sendable {

    public init() {}

    public func export(project: Project) -> String {
        var out = ""
        out += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<!DOCTYPE fcpxml>\n"
        out += "<fcpxml version=\"1.10\">\n"

        let clips = orderedClips(in: project)
        let formats = buildFormats(for: clips, default: project.settings)

        out += emitResources(clips: clips, formats: formats)
        out += emitLibrary(project: project, clips: clips, formats: formats)

        out += "</fcpxml>\n"
        return out
    }

    public func write(project: Project, to url: URL) throws {
        let xml = export(project: project)
        try xml.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Ordered clips

    private func orderedClips(in project: Project) -> [ClipSource] {
        project.mediaPool.rootBin.children.compactMap { item in
            if case .clip(let id) = item { return project.mediaPool.clips[id] }
            return nil
        }
    }

    // MARK: - Formats

    /// One `<format>` per distinct (resolution, frame rate, audio rate)
    /// combo. FCPXML requires every asset to point to a defined format.
    private struct FormatKey: Hashable {
        var width: Int
        var height: Int
        var frameRate: FrameRate
        var hasVideo: Bool

        var sortKey: String { "\(width)x\(height)@\(frameRate.rawValue)/\(hasVideo)" }
    }

    private func buildFormats(for clips: [ClipSource], default settings: ProjectSettings) -> [FormatKey: String] {
        var keys: Set<FormatKey> = []
        for clip in clips {
            if let v = clip.videoTracks.first {
                keys.insert(FormatKey(width: v.resolution.width, height: v.resolution.height, frameRate: v.frameRate, hasVideo: true))
            } else {
                // Audio-only clips still need a format reference.
                keys.insert(FormatKey(width: 0, height: 0, frameRate: settings.defaultFrameRate, hasVideo: false))
            }
        }
        var mapping: [FormatKey: String] = [:]
        for (idx, key) in keys.sorted(by: { $0.sortKey < $1.sortKey }).enumerated() {
            mapping[key] = "r_format_\(idx + 1)"
        }
        return mapping
    }

    private func formatKey(for clip: ClipSource, default settings: ProjectSettings) -> FormatKey {
        if let v = clip.videoTracks.first {
            return FormatKey(width: v.resolution.width, height: v.resolution.height, frameRate: v.frameRate, hasVideo: true)
        }
        return FormatKey(width: 0, height: 0, frameRate: settings.defaultFrameRate, hasVideo: false)
    }

    // MARK: - Resources section

    private func emitResources(clips: [ClipSource], formats: [FormatKey: String]) -> String {
        var out = "  <resources>\n"
        for (key, id) in formats.sorted(by: { $0.value < $1.value }) {
            out += emitFormat(id: id, key: key)
        }
        for (idx, clip) in clips.enumerated() {
            let formatID = formats[formatKey(for: clip, default: ProjectSettings.default)] ?? ""
            out += emitAsset(clip: clip, index: idx, formatID: formatID)
        }
        out += "  </resources>\n"
        return out
    }

    private func emitFormat(id: String, key: FormatKey) -> String {
        let frameDuration = rationalString(rate: key.frameRate)
        var attrs: [String] = [
            "id=\"\(id)\"",
            "name=\"FFVideoFormat\(key.width)x\(key.height)p\(key.frameRate.rawValue.replacingOccurrences(of: ".", with: ""))\"",
            "frameDuration=\"\(frameDuration)\"",
        ]
        if key.hasVideo {
            attrs.append("width=\"\(key.width)\"")
            attrs.append("height=\"\(key.height)\"")
        }
        return "    <format \(attrs.joined(separator: " "))/>\n"
    }

    private func emitAsset(clip: ClipSource, index: Int, formatID: String) -> String {
        let id = "r_asset_\(index + 1)"
        let duration = secondsToFcpDuration(clip.duration.seconds)
        let src = clip.url.absoluteString
        let hasVideo = !clip.videoTracks.isEmpty ? "1" : "0"
        let audioCh = clip.audioTracks.first?.channelCount ?? 0
        let audioRate = clip.audioTracks.first?.sampleRate ?? 48000

        var attrs: [String] = [
            "id=\"\(id)\"",
            "name=\"\(xmlEscape(clip.name))\"",
            "uid=\"\(clip.id.rawValue.uuidString)\"",
            "src=\"\(xmlEscape(src))\"",
            "start=\"0s\"",
            "duration=\"\(duration)\"",
            "hasVideo=\"\(hasVideo)\"",
            "format=\"\(formatID)\"",
            "hasAudio=\"\(audioCh > 0 ? 1 : 0)\"",
        ]
        if audioCh > 0 {
            attrs.append("audioSources=\"1\"")
            attrs.append("audioChannels=\"\(audioCh)\"")
            attrs.append("audioRate=\"\(audioRate)\"")
        }
        return "    <asset \(attrs.joined(separator: " "))/>\n"
    }

    // MARK: - Library/Event/Clips

    private func emitLibrary(project: Project, clips: [ClipSource], formats: [FormatKey: String]) -> String {
        var out = "  <library>\n"
        out += "    <event name=\"\(xmlEscape(project.name))\">\n"

        // Asset-clips at event level: media-pool catalog so editors
        // can browse the imported files independently from edits.
        for (idx, clip) in clips.enumerated() {
            let assetID = "r_asset_\(idx + 1)"
            out += emitAssetClip(clip: clip, assetID: assetID)
        }

        // One <project>/<sequence>/<spine> per Preem sequence. V1 clips
        // sit on the spine in order with gaps between them; higher
        // video tracks attach as connected clips with positive lanes
        // (V2 = 1, V3 = 2, …); audio tracks attach with negative
        // lanes (A1 = -1, A2 = -2, …). Premiere, Resolve, and Final
        // Cut all consume this idiom.
        let assetIDByClip = Dictionary(
            uniqueKeysWithValues: clips.enumerated().map { ($1.id, "r_asset_\($0 + 1)") }
        )
        for sequence in project.sequences {
            out += emitProject(
                sequence: sequence,
                projectName: project.name,
                formats: formats,
                assetIDByClip: assetIDByClip
            )
        }

        out += "    </event>\n"
        out += "  </library>\n"
        return out
    }

    private func emitProject(
        sequence: Sequence,
        projectName: String,
        formats: [FormatKey: String],
        assetIDByClip: [ClipID: String]
    ) -> String {
        let formatKey = FormatKey(
            width: sequence.settings.resolution.width,
            height: sequence.settings.resolution.height,
            frameRate: sequence.settings.frameRate,
            hasVideo: true
        )
        let formatID = formats[formatKey]
            ?? formats.values.sorted().first
            ?? "r_format_1"
        let totalSeconds = sequenceEndSeconds(sequence)
        let dur = secondsToFcpDuration(totalSeconds)

        var out = ""
        out += "      <project name=\"\(xmlEscape(sequence.name))\">\n"
        out += "        <sequence format=\"\(formatID)\" duration=\"\(dur)\" tcStart=\"0s\" tcFormat=\"NDF\">\n"
        out += "          <spine>\n"
        out += emitSpine(sequence: sequence, assetIDByClip: assetIDByClip)
        out += "          </spine>\n"
        out += "        </sequence>\n"
        out += "      </project>\n"
        return out
    }

    private func sequenceEndSeconds(_ sequence: Sequence) -> Double {
        let all = sequence.videoTracks.flatMap(\.clips) + sequence.audioTracks.flatMap(\.clips)
        return all.map { $0.timelineRange.end.seconds }.max() ?? 0
    }

    /// A non-V1 clip pending attachment to a spine element as a
    /// connected lane. Lane > 0 for V2+, lane < 0 for audio tracks
    /// (FCPXML convention).
    private struct LanedClip {
        var clip: PlacedClip
        var lane: Int
    }

    /// Emit the primary spine for `sequence`. V1 clips drive the spine
    /// order; gaps fill any timeline space without a V1 clip; every
    /// non-V1 clip attaches as a connected lane on whichever spine
    /// element contains its timeline start.
    private func emitSpine(sequence: Sequence, assetIDByClip: [ClipID: String]) -> String {
        let v1 = sequence.videoTracks.first?.clips
            .sorted { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
            ?? []

        var connected: [LanedClip] = []
        for (vIdx, track) in sequence.videoTracks.enumerated() where vIdx > 0 {
            for c in track.clips { connected.append(LanedClip(clip: c, lane: vIdx)) }
        }
        for (aIdx, track) in sequence.audioTracks.enumerated() {
            for c in track.clips { connected.append(LanedClip(clip: c, lane: -(aIdx + 1))) }
        }

        func contains(_ c: LanedClip, _ start: Double, _ end: Double) -> Bool {
            let s = c.clip.timelineRange.start.seconds
            return s >= start && s < end
        }

        var out = ""
        var cursor: Double = 0
        let totalEnd = sequenceEndSeconds(sequence)

        for primary in v1 {
            let pStart = primary.timelineRange.start.seconds
            let pEnd = primary.timelineRange.end.seconds

            if pStart > cursor + 0.0005 {
                let inGap = connected.filter { contains($0, cursor, pStart) }
                out += emitSpineGap(
                    absoluteStart: cursor, duration: pStart - cursor,
                    connected: inGap, assetIDByClip: assetIDByClip
                )
            }

            let inPrimary = connected.filter { contains($0, pStart, pEnd) }
            out += emitSpineAssetClip(
                primary: primary,
                connected: inPrimary,
                assetIDByClip: assetIDByClip
            )
            cursor = pEnd
        }

        if totalEnd > cursor + 0.0005 {
            let inTail = connected.filter { contains($0, cursor, totalEnd) }
            out += emitSpineGap(
                absoluteStart: cursor, duration: totalEnd - cursor,
                connected: inTail, assetIDByClip: assetIDByClip
            )
        }
        return out
    }

    private func emitSpineAssetClip(
        primary: PlacedClip,
        connected: [LanedClip],
        assetIDByClip: [ClipID: String]
    ) -> String {
        let ref = assetIDByClip[primary.sourceClipID] ?? ""
        let attrs: [String] = [
            "name=\"\(xmlEscape(referenceName(primary, assetIDByClip: assetIDByClip)))\"",
            "ref=\"\(ref)\"",
            "offset=\"\(secondsToFcpDuration(primary.timelineRange.start.seconds))\"",
            "duration=\"\(secondsToFcpDuration(primary.timelineRange.duration.seconds))\"",
            "start=\"\(secondsToFcpDuration(primary.sourceRange.start.seconds))\"",
        ]
        if connected.isEmpty {
            return "            <asset-clip \(attrs.joined(separator: " "))/>\n"
        }
        var out = "            <asset-clip \(attrs.joined(separator: " "))>\n"
        for c in connected {
            out += emitConnected(c.clip, lane: c.lane, parentOffset: primary.timelineRange.start.seconds, assetIDByClip: assetIDByClip)
        }
        out += "            </asset-clip>\n"
        return out
    }

    private func emitSpineGap(
        absoluteStart: Double,
        duration: Double,
        connected: [LanedClip],
        assetIDByClip: [ClipID: String]
    ) -> String {
        let attrs = "offset=\"\(secondsToFcpDuration(absoluteStart))\" duration=\"\(secondsToFcpDuration(duration))\""
        if connected.isEmpty {
            return "            <gap \(attrs)/>\n"
        }
        var out = "            <gap \(attrs)>\n"
        for c in connected {
            out += emitConnected(c.clip, lane: c.lane, parentOffset: absoluteStart, assetIDByClip: assetIDByClip)
        }
        out += "            </gap>\n"
        return out
    }

    private func emitConnected(
        _ clip: PlacedClip,
        lane: Int,
        parentOffset: Double,
        assetIDByClip: [ClipID: String]
    ) -> String {
        let ref = assetIDByClip[clip.sourceClipID] ?? ""
        // FCPXML spec: a connected clip's `offset` is RELATIVE to its
        // parent's offset, not absolute on the timeline.
        let relativeOffset = clip.timelineRange.start.seconds - parentOffset
        let tag = lane < 0 ? "audio" : "asset-clip"
        var attrs: [String] = [
            "name=\"\(xmlEscape(referenceName(clip, assetIDByClip: assetIDByClip)))\"",
            "ref=\"\(ref)\"",
            "lane=\"\(lane)\"",
            "offset=\"\(secondsToFcpDuration(relativeOffset))\"",
            "duration=\"\(secondsToFcpDuration(clip.timelineRange.duration.seconds))\"",
            "start=\"\(secondsToFcpDuration(clip.sourceRange.start.seconds))\"",
        ]
        if lane < 0 {
            attrs.append("role=\"dialogue\"")
        }
        return "              <\(tag) \(attrs.joined(separator: " "))/>\n"
    }

    private func referenceName(_ clip: PlacedClip, assetIDByClip: [ClipID: String]) -> String {
        // We don't store a per-PlacedClip name today; fall back to the
        // source clip's id-derived asset id so the importer still has
        // something to display.
        return assetIDByClip[clip.sourceClipID] ?? "Clip"
    }

    private func emitAssetClip(clip: ClipSource, assetID: String) -> String {
        let duration = secondsToFcpDuration(clip.duration.seconds)
        var attrs: [String] = [
            "name=\"\(xmlEscape(clip.name))\"",
            "ref=\"\(assetID)\"",
            "offset=\"0s\"",
            "duration=\"\(duration)\"",
            "start=\"0s\"",
        ]

        let kind = !clip.videoTracks.isEmpty ? "asset-clip" : "audio"
        let transcriptNote = clip.ml.transcript?.segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = transcriptNote, !n.isEmpty {
            attrs.append("note=\"\(xmlEscape(n))\"")
        }

        let keywords = collectKeywords(for: clip)
        if keywords.isEmpty {
            return "      <\(kind) \(attrs.joined(separator: " "))/>\n"
        }

        var out = "      <\(kind) \(attrs.joined(separator: " "))>\n"
        for kw in keywords {
            out += "        <keyword start=\"0s\" duration=\"\(duration)\" value=\"\(xmlEscape(kw))\"/>\n"
        }
        out += "      </\(kind)>\n"
        return out
    }

    private func collectKeywords(for clip: ClipSource) -> [String] {
        var keywords: [String] = []
        if let s = clip.scene { keywords.append("Scene \(s)") }
        if let t = clip.take  { keywords.append("Take \(t)") }
        if let r = clip.roll  { keywords.append("Roll \(r)") }
        if let shot = clip.ml.shotType, shot != .unknown { keywords.append(shotKeyword(shot)) }
        if let cam = clip.camera?.reel { keywords.append("Camera \(cam)") }
        return keywords
    }

    private func shotKeyword(_ shot: ShotType) -> String {
        switch shot {
        case .extremeWide:    return "Extreme Wide"
        case .wide:           return "Wide"
        case .medium:         return "Medium"
        case .mediumCloseUp:  return "Medium Close-Up"
        case .closeUp:        return "Close-Up"
        case .extremeCloseUp: return "Extreme Close-Up"
        case .insert:         return "Insert"
        case .unknown:        return "Unknown"
        }
    }

    // MARK: - Rational time formatting

    /// FCPXML expects time as "N/Ds" where N/D is a rational seconds value.
    /// `RationalTime` already stores in that shape.
    private func secondsToFcpDuration(_ seconds: Double) -> String {
        // 1000-scale rationalization is fine; FCP/Resolve/Premiere all
        // accept it. Producers that need frame-accurate boundaries will
        // round to the timeline's frame rate at import.
        let value = Int64(seconds * 1000)
        return "\(value)/1000s"
    }

    private func rationalString(rate: FrameRate) -> String {
        // frameDuration is "denominator/numerator s" of one frame.
        // 23.976 → frame = 1001/24000s
        // 24    → frame = 100/2400s (or 1/24s)
        // We use scale/rate (denominator over numerator).
        let num = rate.rationalScale
        let den = rate.rationalRate
        return "\(num)/\(den)s"
    }

    // MARK: - XML escape

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

