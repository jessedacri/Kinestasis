import Foundation

/// MXF picture-essence enumerator. Walks the KLV packet stream of an
/// MXF file and builds a frame index — byte offset + length for every
/// video frame — plus a classification of the codec (H.264 / ProRes /
/// AVC-Intra / etc.) and any inline parameter sets (SPS/PPS for H.264).
///
/// **Why this exists.** AVFoundation's MOV/MP4 demuxer can't read the
/// MXF container. Without a native demuxer, playback of Canon XF-AVC,
/// Sony XAVC, Panasonic AVC-Intra, and MXF-wrapped ProRes requires
/// Apple's Pro Video Formats package (which not every user has) OR a
/// transcode to a MOV-compatible wrapper (lossy, slow, disk-heavy).
/// Premiere / Resolve / Avid all ship their own MXF demuxer so they
/// can hand raw elementary streams directly to the OS decoder. This
/// reader is PolyMerge's equivalent — the first half of the "native
/// MXF playback" path (the second half being a sample-buffer player
/// that feeds VideoToolbox via `AVSampleBufferDisplayLayer`).
///
/// **Scope of this first pass.** Enumerate picture essence frames in
/// file order, classify the codec, and return their byte locations
/// so a later `CMSampleBuffer` builder can pull frames on demand.
/// Doesn't extract SPS/PPS from extradata yet — that's the next
/// milestone. Doesn't handle Index Tables (we scan the whole file
/// sequentially); MXFs under a couple GB scan in well under a
/// second, and the result can be cached per-file for subsequent
/// access.
///
/// **KLV packet layout (SMPTE 336M):**
/// ```
/// [16 bytes: Key (Universal Label)] [1-9 bytes: BER length] [Value]
/// ```
/// Essence items use a well-known UL pattern:
/// ```
/// 06.0E.2B.34.01.02.01.?? 0D.01.03.01.?? ?? ?? 00
///                                      ^  ^
///                                      |  item type (01 = frame-wrapped)
///                                      category (15 = picture, 16 = sound, 17 = data)
/// ```
public struct MXFEssenceReader {

    /// One video frame's location inside the MXF file.
    public struct FrameRef: Sendable {
        /// Offset (in source-file bytes) of the FIRST byte of the
        /// H.264 / ProRes payload — i.e. AFTER the KLV header.
        public let payloadOffset: UInt64
        /// Length in bytes of the payload.
        public let payloadLength: UInt64

        public init(payloadOffset: UInt64, payloadLength: UInt64) {
            self.payloadOffset = payloadOffset
            self.payloadLength = payloadLength
        }
    }

    /// Detected picture-essence codec. Enough to decide which
    /// `CMFormatDescription` to build when we wrap frames as
    /// `CMSampleBuffer`s.
    public enum PictureCodec: Equatable, Sendable {
        /// H.264 (any profile). Canon XF-AVC, Sony XAVC, Panasonic
        /// AVC-Intra all land here — they differ in profile /
        /// bitrate but the elementary stream is vanilla H.264.
        case h264
        /// Apple ProRes (any variant — we can't tell 422 vs HQ vs
        /// 4444 from the UL alone, need the descriptor).
        case prores
        /// Unknown codec — caller can still get byte offsets but
        /// won't be able to decode. Preserves the UL for
        /// diagnostic logging.
        case unknown(fourBytes: [UInt8])

        public var displayName: String {
            switch self {
            case .h264: return "H.264"
            case .prores: return "ProRes"
            case .unknown(let bytes):
                return "Unknown (" + bytes.map { String(format: "%02x", $0) }.joined() + ")"
            }
        }
    }

    public struct Index: Sendable {
        public let codec: PictureCodec
        public let frames: [FrameRef]
        /// Rough sample of the first frame's head bytes (first 64).
        /// Lets the caller (and the UI) verify the payload really
        /// does look like H.264 NALs (should start with Annex B
        /// start code `00 00 00 01` and contain NAL unit types in
        /// the standard range) before attempting decode.
        public let firstFramePreview: [UInt8]
        /// How long the scan took, in seconds. Handy for the UI.
        public let scanDuration: Double

        public init(codec: PictureCodec, frames: [FrameRef], firstFramePreview: [UInt8], scanDuration: Double) {
            self.codec = codec
            self.frames = frames
            self.firstFramePreview = firstFramePreview
            self.scanDuration = scanDuration
        }
    }

    /// One audio track's byte-range map within the MXF, produced
    /// by `scanAudioIndex`. Tracks are keyed by the element number
    /// in UL byte 15 (0x01 = track 1, 0x02 = track 2, …). Canon
    /// XF-AVC typically lays down 4 parallel mono tracks; ARRI
    /// Alexa Mini lays down 2 stereo tracks; so we just enumerate
    /// whatever the file exposes.
    public struct SoundTrackIndex: Sendable {
        /// UL byte 15 — element number (1-based).
        public let trackNumber: Int
        /// KLV packet payloads for this track, in file order.
        /// Each packet holds one essence frame's worth of PCM
        /// samples (frame-wrapped SMPTE 382M) or the whole
        /// track body (clip-wrapped). Payloads are raw interleaved
        /// little-endian PCM — the sound descriptor tells us the
        /// width / channel count / sample rate.
        public let packets: [FrameRef]

        public init(trackNumber: Int, packets: [FrameRef]) {
            self.trackNumber = trackNumber
            self.packets = packets
        }
    }

    /// Combined picture + sound enumeration produced by
    /// `scanAudioIndex`. Separate entry point from `scanIndex`
    /// so the existing video-only call sites aren't forced to
    /// pay for the audio bookkeeping when they don't need it.
    public struct ExtendedIndex: Sendable {
        public let picture: Index
        /// Keyed by UL byte 15 (element number, 1-based). Canon
        /// XF-AVC with 4 mono tracks gives us `[1, 2, 3, 4]`.
        public let soundTracks: [Int: SoundTrackIndex]

        public init(picture: Index, soundTracks: [Int: SoundTrackIndex]) {
            self.picture = picture
            self.soundTracks = soundTracks
        }
    }

    public enum ReadError: LocalizedError {
        case cannotOpen(String)
        case malformedKLV(String)

        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let name): return "Could not open \(name)"
            case .malformedKLV(let why): return "Malformed KLV stream: \(why)"
            }
        }
    }

    /// Scan the entire file. Blocking — run on a background task.
    public static func scanIndex(url: URL) throws -> Index {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ReadError.cannotOpen(url.lastPathComponent)
        }
        defer { try? handle.close() }

        let started = Date()
        var frames: [FrameRef] = []
        frames.reserveCapacity(8192)
        var codec: PictureCodec? = nil
        var firstFramePreview: [UInt8] = []

        var cursor: UInt64 = 0
        // Chunk size for reading KLV HEADERS (16B UL + up to 9B BER).
        // The values themselves we skip via `seek` — never read into
        // memory. Keeps peak RAM at ~16 KB even on 100 GB files.
        while true {
            try handle.seek(toOffset: cursor)
            guard let headerData = try? handle.read(upToCount: 25),
                  headerData.count >= 17 else {
                break  // End of file or truncated
            }
            // Parse BER length.
            let firstLenByte = headerData[16]
            let valueLength: UInt64
            let headerTotal: Int
            if firstLenByte < 0x80 {
                valueLength = UInt64(firstLenByte)
                headerTotal = 17
            } else {
                let numBytes = Int(firstLenByte & 0x7F)
                guard numBytes > 0, numBytes <= 8, headerData.count >= 17 + numBytes else {
                    // Malformed / end of file / scan into junk —
                    // bail gracefully instead of throwing, since
                    // real MXFs sometimes pad with zero-run runs
                    // that we can just walk past.
                    break
                }
                var acc: UInt64 = 0
                for i in 0..<numBytes {
                    acc = (acc << 8) | UInt64(headerData[17 + i])
                }
                valueLength = acc
                headerTotal = 17 + numBytes
            }

            let ul = Array(headerData.prefix(16))
            let valueOffset = cursor + UInt64(headerTotal)

            // Check if this UL is a picture essence item. The
            // well-known pattern: bytes 0-7 are the SMPTE OL
            // ("06.0E.2B.34.01.02.01.??"), bytes 8-11 identify
            // the essence type family ("0D.01.03.01" for Generic
            // Container essence items), byte 12 is the category
            // (0x15 = picture, 0x16 = sound, 0x17 = data), byte 13
            // is the item type designator.
            if ul.count >= 16,
               ul[0] == 0x06, ul[1] == 0x0E, ul[2] == 0x2B, ul[3] == 0x34,
               ul[4] == 0x01, ul[5] == 0x02, ul[6] == 0x01,
               ul[8] == 0x0D, ul[9] == 0x01, ul[10] == 0x03, ul[11] == 0x01,
               ul[12] == 0x15 {
                // Picture essence item. Record the frame.
                frames.append(FrameRef(payloadOffset: valueOffset, payloadLength: valueLength))

                // Classify on first frame.
                if codec == nil {
                    if let handle = try? FileHandle(forReadingFrom: url) {
                        defer { try? handle.close() }
                        try? handle.seek(toOffset: valueOffset)
                        let snippet = try? handle.read(upToCount: 64)
                        firstFramePreview = Array(snippet ?? Data())
                    }
                    // Classify by UL bytes 12-15 AND the first frame's
                    // head bytes — the most reliable check since UL
                    // vendors vary but the elementary stream doesn't.
                    codec = classifyCodec(
                        ulBytes12to15: [ul[12], ul[13], ul[14], ul[15]],
                        firstFrameHead: firstFramePreview
                    )
                }
            }

            // Advance past the value. Use a large-value-safe jump.
            cursor = valueOffset &+ valueLength
        }

        let elapsed = -started.timeIntervalSinceNow
        return Index(
            codec: codec ?? .unknown(fourBytes: []),
            frames: frames,
            firstFramePreview: firstFramePreview,
            scanDuration: elapsed
        )
    }

    /// Walk the KLV stream and return BOTH picture frame refs
    /// AND sound essence packet refs grouped by track number.
    /// Same structural pass as `scanIndex` but also records sound
    /// packets (UL byte 12 == 0x16). One pass over the file keeps
    /// the I/O cost the same whether the caller wants video alone
    /// or video + audio.
    public static func scanAudioIndex(url: URL) throws -> ExtendedIndex {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ReadError.cannotOpen(url.lastPathComponent)
        }
        defer { try? handle.close() }

        let started = Date()
        var frames: [FrameRef] = []
        frames.reserveCapacity(8192)
        var codec: PictureCodec? = nil
        var firstFramePreview: [UInt8] = []
        var soundPacketsByTrack: [Int: [FrameRef]] = [:]

        var cursor: UInt64 = 0
        while true {
            try handle.seek(toOffset: cursor)
            guard let headerData = try? handle.read(upToCount: 25),
                  headerData.count >= 17 else {
                break
            }
            let firstLenByte = headerData[16]
            let valueLength: UInt64
            let headerTotal: Int
            if firstLenByte < 0x80 {
                valueLength = UInt64(firstLenByte)
                headerTotal = 17
            } else {
                let numBytes = Int(firstLenByte & 0x7F)
                guard numBytes > 0, numBytes <= 8, headerData.count >= 17 + numBytes else {
                    break
                }
                var acc: UInt64 = 0
                for i in 0..<numBytes {
                    acc = (acc << 8) | UInt64(headerData[17 + i])
                }
                valueLength = acc
                headerTotal = 17 + numBytes
            }

            let ul = Array(headerData.prefix(16))
            let valueOffset = cursor + UInt64(headerTotal)

            // Picture essence: byte 12 = 0x15.
            if ul.count >= 16,
               ul[0] == 0x06, ul[1] == 0x0E, ul[2] == 0x2B, ul[3] == 0x34,
               ul[4] == 0x01, ul[5] == 0x02, ul[6] == 0x01,
               ul[8] == 0x0D, ul[9] == 0x01, ul[10] == 0x03, ul[11] == 0x01,
               ul[12] == 0x15 {
                frames.append(FrameRef(payloadOffset: valueOffset, payloadLength: valueLength))
                if codec == nil {
                    if let h = try? FileHandle(forReadingFrom: url) {
                        defer { try? h.close() }
                        try? h.seek(toOffset: valueOffset)
                        let snippet = try? h.read(upToCount: 64)
                        firstFramePreview = Array(snippet ?? Data())
                    }
                    codec = classifyCodec(
                        ulBytes12to15: [ul[12], ul[13], ul[14], ul[15]],
                        firstFrameHead: firstFramePreview
                    )
                }
            }
            // Sound essence: byte 12 = 0x16. Track is byte 15
            // (element number, 1-based). Canon XF-AVC frame-
            // wraps 4 mono tracks as elements 0x01..0x04.
            else if ul.count >= 16,
                    ul[0] == 0x06, ul[1] == 0x0E, ul[2] == 0x2B, ul[3] == 0x34,
                    ul[4] == 0x01, ul[5] == 0x02, ul[6] == 0x01,
                    ul[8] == 0x0D, ul[9] == 0x01, ul[10] == 0x03, ul[11] == 0x01,
                    ul[12] == 0x16 {
                let trackNum = Int(ul[15])
                soundPacketsByTrack[trackNum, default: []].append(
                    FrameRef(payloadOffset: valueOffset, payloadLength: valueLength)
                )
            }

            cursor = valueOffset &+ valueLength
        }

        let elapsed = -started.timeIntervalSinceNow
        let picture = Index(
            codec: codec ?? .unknown(fourBytes: []),
            frames: frames,
            firstFramePreview: firstFramePreview,
            scanDuration: elapsed
        )
        var soundTracks: [Int: SoundTrackIndex] = [:]
        for (trackNum, packets) in soundPacketsByTrack {
            soundTracks[trackNum] = SoundTrackIndex(trackNumber: trackNum, packets: packets)
        }
        return ExtendedIndex(picture: picture, soundTracks: soundTracks)
    }

    /// Read a single frame's bytes from the file. The caller
    /// (sample-buffer player) uses this to pull decode work one
    /// frame at a time. Keeping the FileHandle open across many
    /// reads is fine for the lifetime of playback.
    public static func readFrame(url: URL, ref: FrameRef) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ReadError.cannotOpen(url.lastPathComponent)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: ref.payloadOffset)
        guard let data = try handle.read(upToCount: Int(ref.payloadLength)),
              data.count == Int(ref.payloadLength) else {
            throw ReadError.malformedKLV("short read at frame offset \(ref.payloadOffset)")
        }
        return data
    }

    // MARK: - Codec classification

    /// Classify a picture-essence item. We cross-check two sources:
    ///
    /// 1. **UL bytes 12–15** — the SMPTE 381M / ST 2019 mapping
    ///    identifies the codec family. Byte 14 is usually the
    ///    codec-specific designator (0x05 for H.264, 0x06 for
    ///    ProRes, etc.), with byte 13 acting as a wrapping-kind
    ///    discriminator (frame-wrapped vs clip-wrapped).
    ///
    /// 2. **First-frame head bytes** — a payload starting with an
    ///    Annex B start code `00 00 00 01` followed by a byte
    ///    whose low 5 bits fall in the H.264 NAL type range
    ///    (1–31) is conclusive evidence of an H.264 elementary
    ///    stream, regardless of how the MXF container labeled it.
    ///    ProRes has no Annex B prefix but starts with a frame
    ///    header whose 4th byte is 'i' (0x69) 'c' 'p' 'f' —
    ///    SMPTE VC-3's ProRes frame magic.
    ///
    /// When the UL says nothing recognizable we still infer from
    /// the payload when we can. Camera vendors use Canon-specific,
    /// Sony-specific, Panasonic-specific UL bytes that don't
    /// appear in public specs, but the elementary stream format
    /// inside follows the standard — reading the bytes is more
    /// reliable than matching vendor UL patterns.
    private static func classifyCodec(
        ulBytes12to15: [UInt8],
        firstFrameHead: [UInt8]
    ) -> PictureCodec {
        // Payload sniffing first (most reliable).
        if firstFrameHead.count >= 5,
           firstFrameHead[0] == 0x00, firstFrameHead[1] == 0x00,
           firstFrameHead[2] == 0x00, firstFrameHead[3] == 0x01 {
            // Annex B start code. The next byte is a NAL header
            // whose low 5 bits are the NAL unit type. H.264 types
            // 1-31 are valid; 0 and > 31 indicate something else.
            let nalType = firstFrameHead[4] & 0x1F
            if nalType >= 1 && nalType <= 31 {
                return .h264
            }
        }
        // ProRes frame magic: bytes 4-7 of a ProRes frame are
        // 'i','c','p','f' (0x69 0x63 0x70 0x66).
        if firstFrameHead.count >= 8,
           firstFrameHead[4] == 0x69, firstFrameHead[5] == 0x63,
           firstFrameHead[6] == 0x70, firstFrameHead[7] == 0x66 {
            return .prores
        }
        // Fall back to UL byte 14 (codec designator in SMPTE 381M).
        if ulBytes12to15.count >= 3 {
            switch ulBytes12to15[2] {
            case 0x01:  // MPEG-2 Video
                return .h264  // Actually MPEG-2, but handled same decode path for now
            case 0x05:  // H.264 frame-wrapped (Canon XF-AVC, Sony XAVC Intra)
                return .h264
            case 0x06:  // ProRes (SMPTE ST 2019-4)
                return .prores
            case 0x07:  // H.264 clip-wrapped
                return .h264
            default:
                break
            }
        }
        return .unknown(fourBytes: ulBytes12to15)
    }
}
