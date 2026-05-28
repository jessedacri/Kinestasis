import Foundation

/// Parses the MXF Sound Essence Descriptor(s) out of the header
/// metadata region. We need three things to decode PCM packets
/// off the essence stream: sample rate, sample width (bits), and
/// channel count. All three live in the Generic Sound Essence
/// Descriptor's local set per SMPTE 382M.
///
/// **Why this exists.** Reading audio essence directly (see
/// `MXFAudioExtractor`) requires knowing the bytes-per-sample
/// layout and the channel count before we can de-interleave.
/// AVFoundation can't open MXF audio without Apple Pro Video
/// Formats installed, and we don't want to shell out to ffmpeg
/// just for metadata. Same structural approach as
/// `MXFPictureDescriptorReader` — scan the first few MB for any
/// UL whose bytes 0-13 match a sound descriptor pattern, then
/// parse the local set.
///
/// **Descriptor class bytes recognized** (UL byte 14):
///   0x42 = Generic Sound Essence Descriptor
///   0x47 = AES3 Audio Essence Descriptor
///   0x48 = Wave Audio Essence Descriptor (WAV/BWF-ish in-MXF)
///   0x51 = MPEG Audio Descriptor (reported but not decodable here)
///
/// **Tags in the local set** (SMPTE 382M + 377M):
///   0x3D03 = Audio Sampling Rate (Rational, 8 bytes)
///   0x3D07 = Channel Count (UInt32)
///   0x3D01 = Quantization Bits (UInt32)
///   0x3D0A = Block Align (UInt16) — bytes per frame (all ch)
///
/// **Scope.** Reads the first 4 MB. Never touches essence. Works
/// on every camera MXF that follows SMPTE 382M for descriptor
/// encoding (Canon XF-AVC, Sony XAVC, ARRI Alexa, Panasonic
/// AVC-Intra — all of them).
public struct MXFSoundDescriptorReader {

    public struct Result: Sendable {
        /// Audio sample rate numerator (tag 0x3D03 hi 4 bytes).
        /// 48000 for 48 kHz, 96000 for 96 kHz. Den is usually 1.
        public let sampleRateNum: Int32
        /// Audio sample rate denominator (tag 0x3D03 lo 4 bytes).
        public let sampleRateDen: Int32
        /// Channel count (tag 0x3D07). Canon XF-AVC w/ 4 mono
        /// tracks reports `1` here PER DESCRIPTOR (because each
        /// track has its own descriptor); the scanner returns
        /// every descriptor it finds so callers can sum.
        public let channelCount: Int32
        /// Quantization bits (tag 0x3D01). 16 / 24 / 32 for
        /// linear PCM. The in-file byte width derives from this:
        /// 16-bit uses 2 bytes, 24-bit uses 3 bytes, 32-bit
        /// uses 4 bytes (all LE).
        public let quantizationBits: Int32
        /// Block align, when present (tag 0x3D0A). Bytes per
        /// frame across all channels. Gives us the exact sample
        /// width when channel count × (bits/8) disagrees with
        /// the descriptor's other fields.
        public let blockAlign: Int32?

        /// Sample rate as a Double. 48000.0, 48000/1001, etc.
        public var sampleRate: Double {
            guard sampleRateDen > 0 else { return 0 }
            return Double(sampleRateNum) / Double(sampleRateDen)
        }

        /// Byte width per sample for ONE channel. Driven by
        /// quantization bits (round up to whole bytes). 16→2,
        /// 24→3, 32→4.
        public var bytesPerSample: Int {
            let bits = max(8, Int(quantizationBits))
            return (bits + 7) / 8
        }

        public init(sampleRateNum: Int32, sampleRateDen: Int32, channelCount: Int32, quantizationBits: Int32, blockAlign: Int32?) {
            self.sampleRateNum = sampleRateNum
            self.sampleRateDen = sampleRateDen
            self.channelCount = channelCount
            self.quantizationBits = quantizationBits
            self.blockAlign = blockAlign
        }
    }

    public enum ReadError: Error {
        case cannotOpen(String)
    }

    /// UL byte 14 → descriptor class discriminator.
    private static let soundDescriptorDiscriminators: Set<UInt8> = [
        0x42, 0x47, 0x48, 0x51
    ]

    /// Return every sound descriptor in the header metadata.
    /// Multi-mono-track MXFs (Canon XF-AVC) carry one descriptor
    /// per mono track; we return them all so the caller can
    /// match them to the track elements enumerated by
    /// `MXFEssenceReader.scanAudioIndex`.
    public static func readAll(url: URL) throws -> [Result] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ReadError.cannotOpen(url.lastPathComponent)
        }
        defer { try? handle.close() }

        let scanBytes = 4 * 1024 * 1024
        guard let data = try? handle.read(upToCount: scanBytes), !data.isEmpty else {
            return []
        }

        var results: [Result] = []
        var cursor = 0
        while cursor + 25 <= data.count {
            guard cursor + 16 <= data.count else { break }
            let ulStart = cursor
            let ulEnd = cursor + 16

            let firstLenByte = data[ulEnd]
            let valueLength: Int
            let lengthBytes: Int
            if firstLenByte < 0x80 {
                valueLength = Int(firstLenByte)
                lengthBytes = 1
            } else {
                let numBytes = Int(firstLenByte & 0x7F)
                guard numBytes > 0, numBytes <= 8,
                      ulEnd + 1 + numBytes <= data.count else { break }
                var acc: UInt64 = 0
                for i in 0..<numBytes {
                    acc = (acc << 8) | UInt64(data[ulEnd + 1 + i])
                }
                guard acc < UInt64(Int.max) else { break }
                valueLength = Int(acc)
                lengthBytes = 1 + numBytes
            }
            let valueStart = ulEnd + lengthBytes
            let valueEnd = valueStart + valueLength
            guard valueEnd <= data.count else { break }

            let ul = data[ulStart..<ulEnd]
            let ulArr = Array(ul)
            if ulArr.count >= 16,
               ulArr[0] == 0x06, ulArr[1] == 0x0E, ulArr[2] == 0x2B, ulArr[3] == 0x34,
               ulArr[8] == 0x0D, ulArr[9] == 0x01, ulArr[10] == 0x01, ulArr[11] == 0x01,
               ulArr[12] == 0x01, ulArr[13] == 0x01,
               Self.soundDescriptorDiscriminators.contains(ulArr[14]) {
                if let parsed = parseLocalSet(
                    data: data,
                    valueStart: valueStart,
                    valueEnd: valueEnd
                ), parsed.sampleRateNum > 0, parsed.channelCount > 0, parsed.quantizationBits > 0 {
                    results.append(parsed)
                }
            }

            cursor = valueEnd
        }
        return results
    }

    private static func parseLocalSet(
        data: Data,
        valueStart: Int,
        valueEnd: Int
    ) -> Result? {
        var sampleRateNum: Int32 = 0
        var sampleRateDen: Int32 = 0
        var channelCount: Int32 = 0
        var bits: Int32 = 0
        var blockAlign: Int32? = nil

        var cursor = valueStart
        while cursor + 4 <= valueEnd {
            let tag = (UInt16(data[cursor]) << 8) | UInt16(data[cursor + 1])
            let itemLen = Int((UInt16(data[cursor + 2]) << 8) | UInt16(data[cursor + 3]))
            let itemStart = cursor + 4
            let itemEnd = itemStart + itemLen
            guard itemEnd <= valueEnd else { break }

            switch tag {
            case 0x3D03:  // Audio Sampling Rate — Rational
                if itemLen == 8 {
                    let num: UInt32 = (UInt32(data[itemStart]) << 24)
                        | (UInt32(data[itemStart + 1]) << 16)
                        | (UInt32(data[itemStart + 2]) << 8)
                        | UInt32(data[itemStart + 3])
                    let den: UInt32 = (UInt32(data[itemStart + 4]) << 24)
                        | (UInt32(data[itemStart + 5]) << 16)
                        | (UInt32(data[itemStart + 6]) << 8)
                        | UInt32(data[itemStart + 7])
                    sampleRateNum = Int32(bitPattern: num)
                    sampleRateDen = Int32(bitPattern: den)
                }
            case 0x3D07:  // Channel Count (UInt32)
                if itemLen == 4 {
                    let v: UInt32 = (UInt32(data[itemStart]) << 24)
                        | (UInt32(data[itemStart + 1]) << 16)
                        | (UInt32(data[itemStart + 2]) << 8)
                        | UInt32(data[itemStart + 3])
                    channelCount = Int32(bitPattern: v)
                }
            case 0x3D01:  // Quantization Bits (UInt32)
                if itemLen == 4 {
                    let v: UInt32 = (UInt32(data[itemStart]) << 24)
                        | (UInt32(data[itemStart + 1]) << 16)
                        | (UInt32(data[itemStart + 2]) << 8)
                        | UInt32(data[itemStart + 3])
                    bits = Int32(bitPattern: v)
                }
            case 0x3D0A:  // Block Align (UInt16)
                if itemLen == 2 {
                    let v: UInt16 = (UInt16(data[itemStart]) << 8)
                        | UInt16(data[itemStart + 1])
                    blockAlign = Int32(v)
                }
            default:
                break
            }
            cursor = itemEnd
        }
        guard sampleRateNum != 0, channelCount > 0, bits > 0 else { return nil }
        return Result(
            sampleRateNum: sampleRateNum,
            sampleRateDen: sampleRateDen,
            channelCount: channelCount,
            quantizationBits: bits,
            blockAlign: blockAlign
        )
    }
}
