import Foundation
import PolymergeMediaModel

public struct WAVWriter {
    public struct OutputConfig {
        public var url: URL
        public var channelCount: Int
        public var sampleRate: Int
        public var bitDepth: Int     // 16, 24, or 32
        public var isFloat: Bool     // true for 32-bit float
        public var totalSamples: UInt64
        public var bextData: BEXTOutputData?
        public var ixmlString: String?
        /// Loudness normalization target. When `.off`, the merger writes
        /// the raw mixdown unchanged. When set to a preset or custom
        /// target, the merger measures the mixdown via BS.1770-4 and
        /// applies a single gain adjustment to hit the target (capped
        /// by the true peak ceiling so the file never clips).
        public var loudnessTarget: LoudnessTarget = .off
        /// `true` for polyphonic / multi-track output (the production
        /// audio default), `false` for legacy stereo output. Drives
        /// the format chunk emission: polyphonic = WAVE_FORMAT_EXTENSIBLE
        /// (tag 0xFFFE) with `dwChannelMask = 0` for ALL multi-channel
        /// outputs (including 2-channel), so DaVinci / Premiere honor
        /// the iXML TRACK_LIST channel names. Stereo = standard PCM
        /// tag=1 for 2-channel files, where DaVinci treats the file
        /// as a stereo pair (and ignores the iXML channel labels in
        /// favor of "Embedded channel 1/2").
        public var polyphonicLayout: Bool = true

        public init(
            url: URL,
            channelCount: Int,
            sampleRate: Int,
            bitDepth: Int,
            isFloat: Bool,
            totalSamples: UInt64,
            bextData: BEXTOutputData? = nil,
            ixmlString: String? = nil,
            loudnessTarget: LoudnessTarget = .off,
            polyphonicLayout: Bool = true
        ) {
            self.url = url
            self.channelCount = channelCount
            self.sampleRate = sampleRate
            self.bitDepth = bitDepth
            self.isFloat = isFloat
            self.totalSamples = totalSamples
            self.bextData = bextData
            self.ixmlString = ixmlString
            self.loudnessTarget = loudnessTarget
            self.polyphonicLayout = polyphonicLayout
        }
    }

    public struct BEXTOutputData {
        public var description: String
        public var originator: String
        public var originatorReference: String
        public var originationDate: String
        public var originationTime: String
        public var timeReference: UInt64
        public var codingHistory: String

        public init(
            description: String,
            originator: String,
            originatorReference: String,
            originationDate: String,
            originationTime: String,
            timeReference: UInt64,
            codingHistory: String
        ) {
            self.description = description
            self.originator = originator
            self.originatorReference = originatorReference
            self.originationDate = originationDate
            self.originationTime = originationTime
            self.timeReference = timeReference
            self.codingHistory = codingHistory
        }
    }

    public enum WriteError: LocalizedError {
        case cannotCreateFile
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .cannotCreateFile: return "Cannot create output file"
            case .writeFailed(let msg): return "Write failed: \(msg)"
            }
        }
    }

    // MARK: - Public

    public static func createAndWriteHeader(config: OutputConfig) throws -> FileHandle {
        FileManager.default.createFile(atPath: config.url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: config.url) else {
            throw WriteError.cannotCreateFile
        }

        // Calculate sizes
        let bytesPerSample = config.bitDepth / 8
        let blockAlign = bytesPerSample * config.channelCount
        let dataSize = config.totalSamples * UInt64(blockAlign)

        // Build chunks
        let fmtChunk = buildFmtChunk(config: config, blockAlign: blockAlign, bytesPerSample: bytesPerSample)
        let bextChunk = config.bextData.map { buildBextChunk(bext: $0) } ?? Data()
        let ixmlChunk = config.ixmlString.map { buildIXMLChunk(xml: $0) } ?? Data()

        // RIFF header: 4 (WAVE) + fmt chunk + bext chunk + ixml chunk + 8 (data header) + data
        let riffContentSize = 4
            + fmtChunk.count
            + bextChunk.count
            + ixmlChunk.count
            + 8 // data chunk header
            + Int(min(dataSize, UInt64(UInt32.max)))

        // Write RIFF header
        var riffData = Data()
        riffData.append("RIFF".data(using: .ascii)!)
        riffData.appendUInt32(UInt32(min(riffContentSize, Int(UInt32.max))))
        riffData.append("WAVE".data(using: .ascii)!)
        handle.write(riffData)

        // Write fmt chunk
        handle.write(fmtChunk)

        // Write bext chunk (if any)
        if !bextChunk.isEmpty {
            handle.write(bextChunk)
        }

        // Write iXML chunk (if any)
        if !ixmlChunk.isEmpty {
            handle.write(ixmlChunk)
        }

        // Write data chunk header (size will be finalized later)
        var dataHeader = Data()
        dataHeader.append("data".data(using: .ascii)!)
        dataHeader.appendUInt32(UInt32(min(dataSize, UInt64(UInt32.max))))
        handle.write(dataHeader)

        return handle
    }

    public static func finalizeHeader(handle: FileHandle, config: OutputConfig, actualDataBytes: UInt64) throws {
        // Update RIFF size (offset 4). The fmt chunk size depends on
        // which form `buildFmtChunk` chose — keep the two in sync via
        // the same predicate.
        let useExtensible: Bool
        if config.channelCount > 2 {
            useExtensible = true
        } else if config.channelCount == 2 {
            useExtensible = config.polyphonicLayout
        } else {
            useExtensible = false
        }
        let actualFmtSize = useExtensible ? (8 + 40) : (8 + 16)
        let bextSize = config.bextData != nil ? bextChunkSize(config.bextData!) : 0
        let ixmlSize = config.ixmlString != nil ? ixmlChunkSize(config.ixmlString!) : 0
        let riffContentSize = UInt32(min(
            4 + UInt64(actualFmtSize) + UInt64(bextSize) + UInt64(ixmlSize) + 8 + actualDataBytes,
            UInt64(UInt32.max)
        ))

        handle.seek(toFileOffset: 4)
        var riffSize = riffContentSize
        handle.write(Data(bytes: &riffSize, count: 4))

        // Update data chunk size — need to find the data chunk header position
        let dataChunkHeaderOffset = 12 + UInt64(actualFmtSize) + UInt64(bextSize) + UInt64(ixmlSize) + 4
        handle.seek(toFileOffset: dataChunkHeaderOffset)
        var dataSizeU32 = UInt32(min(actualDataBytes, UInt64(UInt32.max)))
        handle.write(Data(bytes: &dataSizeU32, count: 4))

        // Seek to end
        handle.seekToEndOfFile()
    }

    // MARK: - Chunk Builders

    private static func buildFmtChunk(config: OutputConfig, blockAlign: Int, bytesPerSample: Int) -> Data {
        var chunk = Data()
        chunk.append("fmt ".data(using: .ascii)!)

        // Decide which format chunk shape to write.
        //
        // **WAVE_FORMAT_EXTENSIBLE** (tag 0xFFFE, 40-byte chunk) is
        // required for >2 channels and STRONGLY preferred for any
        // multi-channel polyphonic output (including 2-channel) — it's
        // the Sound Devices / Tentacle / Zaxcom convention and the
        // only thing DaVinci Resolve will look at the iXML TRACK_LIST
        // for. With `dwChannelMask = 0` it tells the host "these are
        // independent production-audio tracks, label them however
        // metadata says."
        //
        // **WAVE_FORMAT_PCM** (tag 1, 16-byte chunk) is the legacy
        // shape and is what DaVinci treats as a hardcoded stereo pair
        // when the channel count is 2. We only emit it when the user
        // explicitly opts in via `polyphonicLayout == false`, OR when
        // the channel count is 1 (single-channel mono can stay as
        // standard PCM since there's nothing to label).
        let useExtensible: Bool
        if config.channelCount > 2 {
            useExtensible = true
        } else if config.channelCount == 2 {
            useExtensible = config.polyphonicLayout
        } else {
            // Mono — standard PCM is fine.
            useExtensible = false
        }

        if useExtensible {
            // WAVE_FORMAT_EXTENSIBLE
            chunk.appendUInt32(40) // chunk size
            chunk.appendUInt16(0xFFFE) // format tag: extensible
            chunk.appendUInt16(UInt16(config.channelCount))
            chunk.appendUInt32(UInt32(config.sampleRate))
            chunk.appendUInt32(UInt32(config.sampleRate * blockAlign))
            chunk.appendUInt16(UInt16(blockAlign))
            chunk.appendUInt16(UInt16(config.bitDepth))
            chunk.appendUInt16(22) // cbSize: extension size
            chunk.appendUInt16(UInt16(config.bitDepth)) // valid bits per sample
            chunk.appendUInt32(0) // channel mask: 0 for production audio
            // Sub-format GUID
            if config.isFloat {
                // IEEE Float: 00000003-0000-0010-8000-00aa00389b71
                chunk.append(contentsOf: [0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
                                          0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
            } else {
                // PCM: 00000001-0000-0010-8000-00aa00389b71
                chunk.append(contentsOf: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
                                          0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
            }
        } else {
            // Standard format (mono OR explicit stereo pair)
            chunk.appendUInt32(16) // chunk size
            chunk.appendUInt16(config.isFloat ? 3 : 1) // format tag: PCM or IEEE Float
            chunk.appendUInt16(UInt16(config.channelCount))
            chunk.appendUInt32(UInt32(config.sampleRate))
            chunk.appendUInt32(UInt32(config.sampleRate * blockAlign))
            chunk.appendUInt16(UInt16(blockAlign))
            chunk.appendUInt16(UInt16(config.bitDepth))
        }

        return chunk
    }

    private static func buildBextChunk(bext: BEXTOutputData) -> Data {
        var body = Data(count: 602) // fixed fields through UMID + loudness (v2)

        // Description (0-255)
        writeString(bext.description, into: &body, offset: 0, maxLength: 256)
        // Originator (256-287)
        writeString(bext.originator, into: &body, offset: 256, maxLength: 32)
        // OriginatorReference (288-319)
        writeString(bext.originatorReference, into: &body, offset: 288, maxLength: 32)
        // OriginationDate (320-329)
        writeString(bext.originationDate, into: &body, offset: 320, maxLength: 10)
        // OriginationTime (330-337)
        writeString(bext.originationTime, into: &body, offset: 330, maxLength: 8)
        // TimeReferenceLow (338-341)
        var timeRefLow = UInt32(bext.timeReference & 0xFFFFFFFF)
        body.replaceSubrange(338..<342, with: Data(bytes: &timeRefLow, count: 4))
        // TimeReferenceHigh (342-345)
        var timeRefHigh = UInt32(bext.timeReference >> 32)
        body.replaceSubrange(342..<346, with: Data(bytes: &timeRefHigh, count: 4))
        // Version (346-347)
        var version: UInt16 = 2
        body.replaceSubrange(346..<348, with: Data(bytes: &version, count: 2))

        // CodingHistory (after fixed fields)
        if let historyData = bext.codingHistory.data(using: .utf8) {
            body.append(historyData)
        }

        // Build chunk with header
        var chunk = Data()
        chunk.append("bext".data(using: .ascii)!)
        chunk.appendUInt32(UInt32(body.count))
        chunk.append(body)

        // Pad to even
        if chunk.count % 2 != 0 {
            chunk.append(0)
        }

        return chunk
    }

    private static func buildIXMLChunk(xml: String) -> Data {
        guard let xmlData = xml.data(using: .utf8) else { return Data() }
        var chunk = Data()
        chunk.append("iXML".data(using: .ascii)!)
        chunk.appendUInt32(UInt32(xmlData.count))
        chunk.append(xmlData)
        // Pad to even
        if chunk.count % 2 != 0 {
            chunk.append(0)
        }
        return chunk
    }

    // MARK: - Helpers

    private static func bextChunkSize(_ bext: BEXTOutputData) -> Int {
        let bodySize = 602 + (bext.codingHistory.utf8.count)
        return 8 + bodySize + (bodySize % 2 != 0 ? 1 : 0) // header + body + padding
    }

    private static func ixmlChunkSize(_ xml: String) -> Int {
        let bodySize = xml.utf8.count
        return 8 + bodySize + (bodySize % 2 != 0 ? 1 : 0)
    }

    private static func writeString(_ string: String, into data: inout Data, offset: Int, maxLength: Int) {
        let bytes = Array(string.utf8.prefix(maxLength))
        for (i, byte) in bytes.enumerated() {
            data[offset + i] = byte
        }
    }

    // MARK: - iXML Generation

    public static func generateOutputIXML(
        files: [AudioFile],
        outputTimecode: TimecodeValue,
        outputSampleRate: Int,
        outputBitDepth: Int,
        processingNote: String? = nil
    ) -> String {
        // **Root element: `<BWFXML>`, NOT `<IXML>`.** This is the
        // Sound Devices / Zoom / Tentacle convention and the only
        // root that DaVinci Resolve, Premiere, and Pro Tools actually
        // recognize when reading per-channel iXML metadata. The literal
        // iXML spec uses `<IXML>` as the nominal root, but no real
        // recorder writes that — every NLE in the field has been
        // taught (by years of real source files from F6 / F8 / 833 /
        // Tentacle / Zaxcom) that BWF iXML lives under `<BWFXML>`.
        // When the root is `<IXML>` Resolve falls through to its
        // "Embedded Channel N" defaults for the channel labels AND to
        // the project frame rate for the TC display, since it never
        // finds its expected root and ignores the entire payload.
        // Symptom: per-channel labels become "Embedded Channel 1/2/3"
        // and the file imports as "24.00 fps" regardless of what
        // TIMECODE_RATE actually says inside the chunk.
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<BWFXML>\n"
        xml += "  <IXML_VERSION>1.5</IXML_VERSION>\n"

        // Speed block from output timecode. The order and field set
        // mirror what Sound Devices / Zoom F6/F8 emit so DaVinci's
        // strict-path lookups all hit. We include MASTER_SPEED,
        // CURRENT_SPEED, FILE_SAMPLE_RATE, AUDIO_BIT_DEPTH, and
        // DIGITIZER_SAMPLE_RATE in addition to the canonical TIMECODE_*
        // fields because some NLEs key their rate detection off
        // MASTER_SPEED rather than TIMECODE_RATE.
        let tc = outputTimecode
        let bitDepth = outputBitDepth
        xml += "  <SPEED>\n"
        xml += "    <NOTE></NOTE>\n"
        // Use the exact rational rate (`24000/1001`, `24/1`, `30000/1001`,
        // etc.) instead of the rounded `nominalRate` integer. The
        // previous version wrote "24" for 23.976 files, which DaVinci
        // and Premiere read as 24.000 fps and used to label the file —
        // silently breaking sync against 23.976 video tracks.
        xml += "    <MASTER_SPEED>\(tc.frameRate.iXMLRate)</MASTER_SPEED>\n"
        xml += "    <CURRENT_SPEED>\(tc.frameRate.iXMLRate)</CURRENT_SPEED>\n"
        xml += "    <TIMECODE_RATE>\(tc.frameRate.iXMLRate)</TIMECODE_RATE>\n"
        xml += "    <TIMECODE_FLAG>\(tc.frameRate.isDropFrame ? "DF" : "NDF")</TIMECODE_FLAG>\n"
        xml += "    <FILE_SAMPLE_RATE>\(outputSampleRate)</FILE_SAMPLE_RATE>\n"
        xml += "    <AUDIO_BIT_DEPTH>\(bitDepth)</AUDIO_BIT_DEPTH>\n"
        xml += "    <DIGITIZER_SAMPLE_RATE>\(outputSampleRate)</DIGITIZER_SAMPLE_RATE>\n"
        xml += "    <TIMESTAMP_SAMPLES_SINCE_MIDNIGHT_HI>\(tc.samplesSinceMidnight >> 32)</TIMESTAMP_SAMPLES_SINCE_MIDNIGHT_HI>\n"
        xml += "    <TIMESTAMP_SAMPLES_SINCE_MIDNIGHT_LO>\(tc.samplesSinceMidnight & 0xFFFFFFFF)</TIMESTAMP_SAMPLES_SINCE_MIDNIGHT_LO>\n"
        xml += "    <TIMESTAMP_SAMPLE_RATE>\(outputSampleRate)</TIMESTAMP_SAMPLE_RATE>\n"
        xml += "  </SPEED>\n"

        // Track list — one <TRACK> entry per OUTPUT CHANNEL, not per
        // source file. This is what DaVinci Resolve, Pro Tools, and
        // Premiere actually read to populate per-channel labels.
        //
        // **Per the iXML spec:**
        //   - `CHANNEL_INDEX` = 1-based index of the channel within
        //     the take (the recording session — could span multiple
        //     source files on a multi-file recorder).
        //   - `INTERLEAVE_INDEX` = 1-based index of which channel
        //     this is in the *interleaved file's data*. This is the
        //     field DaVinci Resolve uses to bind a TRACK entry to a
        //     specific physical channel of the polyphonic WAV.
        //
        // For our merged poly BWF the file IS the take (we're
        // collapsing multiple source files into one polyphonic file),
        // so both indices are equal to the output channel position.
        //
        // **Bug history:** an earlier version wrote
        // `INTERLEAVE_INDEX = sourceChannelWithinSourceFile + 1`,
        // which is always `1` for any mono source file. Two mono
        // sources merged into a stereo BWF would emit two TRACK
        // entries both with `INTERLEAVE_INDEX = 1`, and DaVinci would
        // bind the first name to channel 1 and fall back to "Embedded
        // Channel 2" for channel 2 because no TRACK entry pointed at
        // channel 2 of the file. The CHANNEL_INDEX values were
        // sequential and correct, but DaVinci doesn't use that field
        // for channel binding — it uses INTERLEAVE_INDEX exclusively.
        // Both values must be the output channel position so that
        // each physical channel has exactly one matching TRACK entry.
        //
        // For each output channel we emit:
        //   - CHANNEL_INDEX: output channel position (1, 2, 3, …)
        //   - INTERLEAVE_INDEX: same — the channel's position within
        //     our interleaved poly WAV. DaVinci binds NAME → channel
        //     by matching this field.
        //   - NAME: friendly display label, with " L" / " R" suffixes
        //     auto-added for stereo source files (or " 1" / " 2" / ...
        //     for >2-channel sources). DaVinci shows this in the audio
        //     inspector. The user can override per-channel via the
        //     Export screen's track mapping section, in which case the
        //     override wins over the auto-generated label.
        //   - WAV_FILENAME: original source filename (Sound Devices
        //     convention). DaVinci surfaces this in clip metadata.
        //
        // Channels not in `file.includedChannels` are skipped — the
        // export screen can deselect blank or unwanted channels.
        let totalOutputChannels = files.reduce(0) { count, file in
            count + file.includedChannels.filter { $0 < Int(file.channelCount) }.count
        }
        xml += "  <TRACK_LIST>\n"
        xml += "    <TRACK_COUNT>\(totalOutputChannels)</TRACK_COUNT>\n"
        var outputChannelCursor = 1
        for file in files {
            let chCount = Int(file.channelCount)
            let sortedIncluded = file.includedChannels.sorted().filter { $0 < chCount }
            for ch in sortedIncluded {
                let displayName = nameForOutputChannel(file: file, sourceChannel: ch)
                xml += "    <TRACK>\n"
                xml += "      <CHANNEL_INDEX>\(outputChannelCursor)</CHANNEL_INDEX>\n"
                xml += "      <INTERLEAVE_INDEX>\(outputChannelCursor)</INTERLEAVE_INDEX>\n"
                xml += "      <NAME>\(escapeXML(displayName))</NAME>\n"
                xml += "      <WAV_FILENAME>\(escapeXML(file.filename))</WAV_FILENAME>\n"
                xml += "    </TRACK>\n"
                outputChannelCursor += 1
            }
        }
        xml += "  </TRACK_LIST>\n"

        // Scene/Take from first file that has them
        if let scene = files.compactMap(\.scene).first {
            xml += "  <SCENE>\(escapeXML(scene))</SCENE>\n"
        }
        if let take = files.compactMap(\.take).first {
            xml += "  <TAKE>\(escapeXML(take))</TAKE>\n"
        }

        let fileNames = files.map(\.filename).joined(separator: ", ")
        var noteText = "Merged by PolyMerge from \(files.count) source files: \(fileNames)"
        if let processingNote {
            noteText += ". " + processingNote
        }
        xml += "  <NOTE>\(escapeXML(noteText))</NOTE>\n"
        xml += "</BWFXML>"

        return xml
    }

    /// Choose the best human-readable name for an input file's
    /// per-channel TRACK entry. Priority:
    ///   1. User's custom track name (set via Track Setup card)
    ///   2. iXML track name from the source file
    ///   3. Filename without extension
    /// Returns the trimmed value, never an empty string.
    private static func preferredTrackName(for file: AudioFile) -> String {
        if let custom = file.customTrackName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        if let track = file.trackName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !track.isEmpty {
            return track
        }
        return (file.filename as NSString).deletingPathExtension
    }

    /// Compute the iXML `<NAME>` for one output channel.
    ///
    /// Priority:
    ///   1. Per-channel override from the export screen (used as-is,
    ///      no auto suffixes — the user typed exactly what they want)
    ///   2. Default label: `{trackName}{ L/R/N suffix} ({filename})`
    ///      e.g. `Wired Boom L (F6_01_260323_005)`
    ///
    /// We bake the filename into `<NAME>` itself (instead of relying
    /// on `<WAV_FILENAME>`) because not every NLE actually surfaces
    /// `<WAV_FILENAME>` in its UI — DaVinci's per-channel labels read
    /// from `<NAME>` only. Putting both pieces of info there means
    /// the editor can see which mic AND which source file each
    /// channel came from, regardless of how the host treats the rest
    /// of the iXML payload.
    ///
    /// The filename is omitted from the parens when the baseName IS
    /// already the filename (file had no iXML track name, so we'd be
    /// printing `F6_01_260323_005 (F6_01_260323_005)` otherwise).
    public static func nameForOutputChannel(file: AudioFile, sourceChannel ch: Int) -> String {
        if let override = file.perChannelNames[ch]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        let baseName = preferredTrackName(for: file)
        let chCount = Int(file.channelCount)
        let suffix: String
        if chCount == 1 {
            suffix = ""
        } else if chCount == 2 {
            suffix = ch == 0 ? " L" : " R"
        } else {
            suffix = " \(ch + 1)"
        }
        let labeled = baseName + suffix

        // Append the filename stem in parens unless baseName is
        // already the filename stem — avoid the redundant
        // `F6_01 (F6_01)` case.
        let filenameStem = (file.filename as NSString).deletingPathExtension
        if baseName == filenameStem {
            return labeled
        }
        return "\(labeled) (\(filenameStem))"
    }

    private static func escapeXML(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
              .replacingOccurrences(of: "<", with: "&lt;")
              .replacingOccurrences(of: ">", with: "&gt;")
              .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Data Extension

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var v = value
        append(Data(bytes: &v, count: 2))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var v = value
        append(Data(bytes: &v, count: 4))
    }

    mutating func appendInt32(_ value: Int32) {
        var v = value
        append(Data(bytes: &v, count: 4))
    }
}
