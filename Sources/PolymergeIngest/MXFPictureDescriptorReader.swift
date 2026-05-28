import Foundation

/// Parses the MXF Picture Essence Descriptor out of the header
/// metadata region to recover the real sample rate, stored width /
/// height, and other per-file picture attributes that the essence
/// scanner can't get from frame payloads alone.
///
/// **Why this exists.** `MXFH264Player` hardcoded 24000/1001 for
/// frame rate because it only had SPS data, and SPS doesn't carry
/// frame rate for intra-only H.264. The SampleRate item in the
/// Picture Essence Descriptor's local set (tag 0x3001) gives us
/// the authoritative answer — a rational (num/den) covering every
/// broadcast rate from 23.976 through 60000/1001. Same mechanism
/// also exposes StoredWidth (tag 0x3203) and StoredHeight (tag
/// 0x3202) so we can verify against the SPS dimensions.
///
/// **Algorithm.** Same structural approach as `MXFTimecodeReader`:
/// scan the first few MB for a UL whose bytes 0-13 match a known
/// picture-descriptor class pattern (generic / CDCI / RGBA / MPEG
/// / JPEG-2000), then parse that KLV's local set for the tags we
/// care about. Returns on the first valid match — most MXFs have
/// exactly one picture descriptor in the header.
///
/// **Scope.** Reads the first 4 MB. Never touches essence. Works
/// on every file MXFTimecodeReader works on (ARRI, Sony, Canon,
/// Panasonic) because they all follow SMPTE 377M for descriptor
/// encoding.
public struct MXFPictureDescriptorReader {

    public struct Result: Sendable {
        /// SampleRate numerator (tag 0x3001 high 4 bytes). 24000
        /// for 23.976, 30000 for 29.97, 24/25/30/60 for integer
        /// rates.
        public let sampleRateNum: Int32
        /// SampleRate denominator (tag 0x3001 low 4 bytes). 1001
        /// for broadcast rates, 1 for integer rates.
        public let sampleRateDen: Int32
        /// Stored width (tag 0x3203) as the descriptor reports it.
        /// May differ from SPS-derived width on cropped variants.
        public let storedWidth: Int32?
        /// Stored height (tag 0x3202).
        public let storedHeight: Int32?

        public var frameRate: Double {
            guard sampleRateDen > 0 else { return 0 }
            return Double(sampleRateNum) / Double(sampleRateDen)
        }

        public init(sampleRateNum: Int32, sampleRateDen: Int32, storedWidth: Int32?, storedHeight: Int32?) {
            self.sampleRateNum = sampleRateNum
            self.sampleRateDen = sampleRateDen
            self.storedWidth = storedWidth
            self.storedHeight = storedHeight
        }
    }

    public enum ReadError: Error {
        case cannotOpen(String)
    }

    /// Picture descriptor classes we recognize. SMPTE 377M byte 14
    /// of the Universal Label carries the discriminator:
    ///   0x27 = Generic Picture Essence Descriptor
    ///   0x28 = CDCI Essence Descriptor (YCbCr compressed video —
    ///          Canon XF-AVC, Sony XAVC, ARRI ProRes land here)
    ///   0x29 = RGBA Essence Descriptor (RGB video)
    ///   0x51 = MPEG Video Descriptor (H.262 / H.264 specific)
    ///   0x5a = JPEG-2000 Picture Essence Descriptor
    /// Matching any of these gets us into the local-set parse.
    private static let pictureDescriptorDiscriminators: Set<UInt8> = [
        0x27, 0x28, 0x29, 0x51, 0x5a
    ]

    public static func read(url: URL) throws -> Result? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ReadError.cannotOpen(url.lastPathComponent)
        }
        defer { try? handle.close() }

        let scanBytes = 4 * 1024 * 1024
        guard let data = try? handle.read(upToCount: scanBytes), !data.isEmpty else {
            return nil
        }

        // Walk KLV packets sequentially in the scan window. For
        // each packet whose UL matches a picture-descriptor
        // pattern, parse the local set.
        var cursor = 0
        while cursor + 25 <= data.count {
            guard cursor + 16 <= data.count else { break }
            let ulStart = cursor
            let ulEnd = cursor + 16

            // Parse the BER length that follows the UL.
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

            // Check if this UL looks like a picture descriptor.
            // Signature: SMPTE OL prefix + byte 14 ∈ discriminator set.
            let ul = data[ulStart..<ulEnd]
            let ulArr = Array(ul)
            if ulArr.count >= 16,
               ulArr[0] == 0x06, ulArr[1] == 0x0E, ulArr[2] == 0x2B, ulArr[3] == 0x34,
               ulArr[8] == 0x0D, ulArr[9] == 0x01, ulArr[10] == 0x01, ulArr[11] == 0x01,
               ulArr[12] == 0x01, ulArr[13] == 0x01,
               Self.pictureDescriptorDiscriminators.contains(ulArr[14]) {
                if let parsed = parseLocalSet(
                    data: data,
                    valueStart: valueStart,
                    valueEnd: valueEnd
                ), parsed.sampleRateNum > 0, parsed.sampleRateDen > 0 {
                    return parsed
                }
            }

            cursor = valueEnd
        }
        return nil
    }

    /// Parse a descriptor's local set — a sequence of
    /// `[2B tag][2B length][value]` items — for the three tags
    /// we care about.
    private static func parseLocalSet(
        data: Data,
        valueStart: Int,
        valueEnd: Int
    ) -> Result? {
        var sampleRateNum: Int32 = 0
        var sampleRateDen: Int32 = 0
        var storedWidth: Int32?
        var storedHeight: Int32?

        var cursor = valueStart
        while cursor + 4 <= valueEnd {
            let tag = (UInt16(data[cursor]) << 8) | UInt16(data[cursor + 1])
            let itemLen = Int((UInt16(data[cursor + 2]) << 8) | UInt16(data[cursor + 3]))
            let itemStart = cursor + 4
            let itemEnd = itemStart + itemLen
            guard itemEnd <= valueEnd else { break }

            switch tag {
            case 0x3001:  // SampleRate — Rational (UInt32 num / UInt32 den)
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
            case 0x3203:  // StoredWidth (UInt32)
                if itemLen == 4 {
                    let v: UInt32 = (UInt32(data[itemStart]) << 24)
                        | (UInt32(data[itemStart + 1]) << 16)
                        | (UInt32(data[itemStart + 2]) << 8)
                        | UInt32(data[itemStart + 3])
                    storedWidth = Int32(bitPattern: v)
                }
            case 0x3202:  // StoredHeight (UInt32)
                if itemLen == 4 {
                    let v: UInt32 = (UInt32(data[itemStart]) << 24)
                        | (UInt32(data[itemStart + 1]) << 16)
                        | (UInt32(data[itemStart + 2]) << 8)
                        | UInt32(data[itemStart + 3])
                    storedHeight = Int32(bitPattern: v)
                }
            default:
                break
            }
            cursor = itemEnd
        }
        guard sampleRateNum != 0, sampleRateDen != 0 else { return nil }
        return Result(
            sampleRateNum: sampleRateNum,
            sampleRateDen: sampleRateDen,
            storedWidth: storedWidth,
            storedHeight: storedHeight
        )
    }
}
