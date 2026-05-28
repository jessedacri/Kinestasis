import Foundation
import PolymergeMediaModel

/// Reads start timecode from an MXF (SMPTE 377M) file by scanning
/// the Header Metadata for a Timecode Component local set.
///
/// **Why this exists.** `AVAssetReader` returns empty sample buffers
/// for MXF timecode tracks (same pitfall as pitfall #51 for QuickTime
/// TMCD) and PolyMerge's existing ISOBMFF atom walker doesn't apply
/// to MXF — MXF is KLV (Key-Length-Value) structured, not atom /
/// box structured. ARRI Alexa Mini LF, Canon C300/C500, Sony FX6,
/// Panasonic VariCam, and most professional cameras delivered in
/// MXF carry start TC in the **Timecode Component** metadata set
/// in the Header Partition's metadata region — not in a `tmcd`
/// track. Without this reader, PolyMerge would show those clips
/// with `NO TC` and demand audio-sync for every single one.
///
/// **Algorithm.** SMPTE 377M defines the Timecode Component as a
/// "local set" of tagged metadata items. We scan the file's first
/// few MB (the Header Partition + Header Metadata region) for the
/// set's well-known SMPTE UL, then parse its local-set tags to
/// recover:
///   - Tag `0x1501`: StartTimecode (UInt64 frame count, 0 = midnight)
///   - Tag `0x1502`: RoundedTimecodeBase (UInt16 nominal integer fps:
///     24 for 23.976 NDF, 30 for 29.97 NDF, etc.)
///   - Tag `0x1503`: DropFrame (UInt8 bool)
///
/// Frame count → H:M:S:F uses the same nominal-rate arithmetic as
/// QuickTime's TMCD (per pitfall #52). Drop-frame rates route
/// through `DropFrameCalculator.framesToTimecode` for correct H:M:S:F
/// at 29.97 DF / 59.94 DF.
///
/// **UL being scanned.**
/// `06.0E.2B.34.02.53.01.01  0D.01.01.01.01.01.14.00`
/// — SMPTE 377M Material Package → Timecode Component local set.
/// The final byte (`00`) is a version byte that can vary slightly
/// across tool vendors; we match on the version-agnostic prefix
/// (first 15 bytes) so ARRI / Sony / Canon / Panasonic files all
/// work.
///
/// **Scope.** Reads the first 4 MB of the file (more than enough
/// for any real MXF's Header Metadata; the largest header I've
/// seen is ~800 KB). Never decodes essence data, never touches
/// the body partition. Zero-impact on huge files (a 193 GB clip
/// still only gets 4 MB of reads).
public struct MXFTimecodeReader {

    public enum ReadError: Error {
        case cannotOpen(String)
        case noTimecodeComponent
        case invalidStructure(String)
    }

    /// Successful parse result: start TC as frame count at the
    /// nominal integer rate, the nominal rate itself, and the
    /// drop-frame flag. Caller converts to `TimecodeValue` via
    /// the same arithmetic as the QuickTime TMCD path.
    public struct Result {
        public let startFrameCount: UInt64
        public let roundedFrameRate: Int        // 24, 25, 30, 60, etc.
        public let isDropFrame: Bool
        /// Duration of the essence in frames at the nominal
        /// integer rate, parsed from the first Sequence local
        /// set we encounter. Nil when the file doesn't carry
        /// a Sequence in its Header Metadata (rare — every
        /// standard SMPTE 377M MXF has one). Used by the
        /// VideoFile metadata-only path to avoid
        /// bitrate-estimation errors that can place sequential
        /// clips on top of each other.
        public let durationFrames: UInt64?

        public init(startFrameCount: UInt64, roundedFrameRate: Int, isDropFrame: Bool, durationFrames: UInt64?) {
            self.startFrameCount = startFrameCount
            self.roundedFrameRate = roundedFrameRate
            self.isDropFrame = isDropFrame
            self.durationFrames = durationFrames
        }
    }

    /// Read start TC from the MXF's header metadata. Returns nil
    /// (no throw) when the file doesn't contain a Timecode
    /// Component — some MXF flavors (MXF OP-Atom audio-only stems,
    /// very old variants) don't carry one. Throws only on I/O
    /// errors.
    public static func readStartTimecode(url: URL) throws -> Result? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ReadError.cannotOpen(url.lastPathComponent)
        }
        defer { try? handle.close() }

        // Read the first 4 MB. ARRI Mini LF, Sony FX9, Canon C500,
        // Panasonic VariCam all place Header Metadata well within
        // the first megabyte. 4 MB is a safety margin for files
        // with unusually verbose DMS-1 (Descriptive Metadata Scheme)
        // content.
        let scanBytes = 4 * 1024 * 1024
        guard let data = try? handle.read(upToCount: scanBytes), !data.isEmpty else {
            throw ReadError.invalidStructure("empty file or read failed")
        }

        // Timecode Component local set UL (SMPTE 377M / S377 DMS-1).
        // Match the first 15 bytes so we tolerate version-byte
        // variants across tool vendors (ARRI, Sony, Canon, etc.
        // stamp different values at byte 15).
        let tcUL: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34,  0x02, 0x53, 0x01, 0x01,
            0x0D, 0x01, 0x01, 0x01,  0x01, 0x01, 0x14    // bytes 0-14
        ]

        // Scan for the UL, parse the first match's local set.
        var searchStart = 0
        while searchStart + tcUL.count <= data.count {
            guard let foundRange = data.range(
                of: Data(tcUL),
                options: [],
                in: searchStart..<data.count
            ) else {
                return nil  // No Timecode Component in scan window
            }

            // The UL is 16 bytes; our match is 15 bytes (ignoring
            // the version byte). Advance past the full 16-byte UL.
            let ulStart = foundRange.lowerBound
            let ulEnd = ulStart + 16
            guard ulEnd < data.count else {
                return nil
            }

            // BER-encoded length follows the UL. BER rules:
            //   - If first byte < 0x80: that IS the length.
            //   - Else: low 7 bits = number of following length bytes
            //     (big-endian).
            let berStart = ulEnd
            let firstLenByte = data[berStart]
            let valueLength: Int
            let lengthBytes: Int
            if firstLenByte < 0x80 {
                valueLength = Int(firstLenByte)
                lengthBytes = 1
            } else {
                let numBytes = Int(firstLenByte & 0x7F)
                guard berStart + 1 + numBytes <= data.count, numBytes > 0, numBytes <= 8 else {
                    searchStart = ulEnd
                    continue
                }
                var lenAcc: UInt64 = 0
                for i in 0..<numBytes {
                    lenAcc = (lenAcc << 8) | UInt64(data[berStart + 1 + i])
                }
                guard lenAcc < UInt64(Int.max) else {
                    searchStart = ulEnd
                    continue
                }
                valueLength = Int(lenAcc)
                lengthBytes = 1 + numBytes
            }
            let valueStart = berStart + lengthBytes
            let valueEnd = valueStart + valueLength
            guard valueEnd <= data.count else {
                // Timecode Component spans past our scan window;
                // bail — we sized the window generously, so this
                // indicates a degenerate file.
                return nil
            }

            // Parse local set: [2B tag][2B length][value]* repeated.
            var startFrameCount: UInt64?
            var roundedFrameRate: Int?
            var isDropFrame = false
            var cursor = valueStart
            while cursor + 4 <= valueEnd {
                let tag = (UInt16(data[cursor]) << 8) | UInt16(data[cursor + 1])
                let itemLen = Int((UInt16(data[cursor + 2]) << 8) | UInt16(data[cursor + 3]))
                let itemStart = cursor + 4
                let itemEnd = itemStart + itemLen
                guard itemEnd <= valueEnd else { break }

                switch tag {
                case 0x1501:  // StartTimecode (UInt64)
                    if itemLen == 8 {
                        var v: UInt64 = 0
                        for i in 0..<8 {
                            v = (v << 8) | UInt64(data[itemStart + i])
                        }
                        startFrameCount = v
                    }
                case 0x1502:  // RoundedTimecodeBase (UInt16)
                    if itemLen == 2 {
                        let v = (UInt16(data[itemStart]) << 8) | UInt16(data[itemStart + 1])
                        roundedFrameRate = Int(v)
                    }
                case 0x1503:  // DropFrame (UInt8 bool)
                    if itemLen == 1 {
                        isDropFrame = data[itemStart] != 0
                    }
                default:
                    break
                }
                cursor = itemEnd
            }

            // If this Timecode Component lacked a StartTimecode or
            // RoundedTimecodeBase, try the next one in the file —
            // some MXF files have multiple TC components (one per
            // Source Package track) and only the Material Package
            // version has all three fields populated.
            if let frames = startFrameCount, let rate = roundedFrameRate, rate > 0 {
                return Result(
                    startFrameCount: frames,
                    roundedFrameRate: rate,
                    isDropFrame: isDropFrame,
                    durationFrames: nil    // ARRI MXFs don't populate duration in Timecode Component
                )
            }
            searchStart = ulEnd
        }
        return nil
    }
}
