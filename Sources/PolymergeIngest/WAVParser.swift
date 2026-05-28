import Foundation

public struct WAVParser {
    public struct WAVHeader {
        public var formatTag: UInt16 = 0
        public var channelCount: UInt16 = 0
        public var sampleRate: UInt32 = 0
        public var byteRate: UInt32 = 0
        public var blockAlign: UInt16 = 0
        public var bitsPerSample: UInt16 = 0
        public var validBitsPerSample: UInt16?
        public var channelMask: UInt32?
        public var subFormatGUID: [UInt8]?
        public var isFloatSubFormat: Bool = false
        public var dataChunkOffset: UInt64 = 0
        public var dataChunkSize: UInt64 = 0
        public var bextChunkData: Data?
        public var ixmlChunkData: Data?

        public init() {}
    }

    public enum ParseError: LocalizedError {
        case notRIFF
        case notWAVE
        case noFmtChunk
        case noDataChunk
        case invalidFmtChunk
        case readError(String)

        public var errorDescription: String? {
            switch self {
            case .notRIFF: return "Not a RIFF file"
            case .notWAVE: return "Not a WAVE file"
            case .noFmtChunk: return "Missing fmt chunk"
            case .noDataChunk: return "Missing data chunk"
            case .invalidFmtChunk: return "Invalid fmt chunk"
            case .readError(let msg): return msg
            }
        }
    }

    // PCM sub-format GUID: 00000001-0000-0010-8000-00aa00389b71
    private static let pcmSubFormat: [UInt8] = [
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
        0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
    ]

    // IEEE float sub-format GUID: 00000003-0000-0010-8000-00aa00389b71
    private static let floatSubFormat: [UInt8] = [
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
        0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
    ]

    public static func parse(url: URL) throws -> WAVHeader {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ParseError.readError("Cannot open file: \(url.lastPathComponent)")
        }
        defer { try? handle.close() }

        var header = WAVHeader()

        // Read RIFF header (12 bytes)
        guard let riffHeader = try handle.read(upToCount: 12), riffHeader.count == 12 else {
            throw ParseError.readError("File too small")
        }

        let riffTag = String(data: riffHeader[0..<4], encoding: .ascii)
        let waveTag = String(data: riffHeader[8..<12], encoding: .ascii)

        // Support both RIFF and RF64
        let isRF64 = riffTag == "RF64"
        guard riffTag == "RIFF" || isRF64 else {
            throw ParseError.notRIFF
        }
        guard waveTag == "WAVE" else {
            throw ParseError.notWAVE
        }

        var ds64DataSize: UInt64?

        // If RF64, the ds64 chunk should come first with the real sizes
        if isRF64 {
            if let ds64 = try readChunk(handle: handle) {
                if ds64.id == "ds64" && ds64.data.count >= 24 {
                    // bytes 8-15: data chunk size
                    ds64DataSize = ds64.data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
                }
            }
        }

        // Iterate chunks
        var foundFmt = false
        var foundData = false

        while let chunk = try readChunk(handle: handle) {
            switch chunk.id {
            case "fmt ":
                try parseFmtChunk(data: chunk.data, header: &header)
                foundFmt = true

            case "data":
                header.dataChunkOffset = chunk.dataOffset
                header.dataChunkSize = ds64DataSize ?? UInt64(chunk.data.count == 0 ? chunk.reportedSize : chunk.data.count)
                // For data chunk, we recorded the offset but didn't read the full data
                foundData = true

            case "bext":
                header.bextChunkData = chunk.data

            case "iXML", "ixml", "IXML":
                header.ixmlChunkData = chunk.data

            default:
                break // Skip unknown chunks
            }
        }

        guard foundFmt else { throw ParseError.noFmtChunk }
        guard foundData else { throw ParseError.noDataChunk }

        return header
    }

    // MARK: - Chunk Reading

    private struct ChunkInfo {
        let id: String
        let data: Data
        let dataOffset: UInt64
        let reportedSize: Int
    }

    private static func readChunk(handle: FileHandle) throws -> ChunkInfo? {
        let headerSize = 8
        guard let chunkHeader = try handle.read(upToCount: headerSize),
              chunkHeader.count == headerSize else {
            return nil
        }

        let chunkID = String(data: chunkHeader[0..<4], encoding: .ascii) ?? "????"
        let chunkSize = chunkHeader.withUnsafeBytes {
            Int($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        }

        let dataOffset = handle.offsetInFile

        // For the data chunk, don't read the actual audio — just record the offset and skip
        if chunkID == "data" {
            // Seek past the data chunk
            let skipSize = UInt64((chunkSize + 1) & ~1) // pad to even
            handle.seek(toFileOffset: dataOffset + skipSize)
            return ChunkInfo(id: chunkID, data: Data(), dataOffset: dataOffset, reportedSize: chunkSize)
        }

        // For other chunks, read the data (they're typically small)
        let readSize = min(chunkSize, 10_000_000) // safety cap at 10MB for metadata chunks
        guard let data = try handle.read(upToCount: readSize) else {
            return nil
        }

        // Chunks are padded to even byte boundaries
        if chunkSize % 2 != 0 {
            _ = try handle.read(upToCount: 1) // skip padding byte
        }

        return ChunkInfo(id: chunkID, data: data, dataOffset: dataOffset, reportedSize: chunkSize)
    }

    // MARK: - fmt Chunk Parsing

    private static func parseFmtChunk(data: Data, header: inout WAVHeader) throws {
        guard data.count >= 16 else { throw ParseError.invalidFmtChunk }

        data.withUnsafeBytes { ptr in
            header.formatTag = ptr.loadUnaligned(fromByteOffset: 0, as: UInt16.self)
            header.channelCount = ptr.loadUnaligned(fromByteOffset: 2, as: UInt16.self)
            header.sampleRate = ptr.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            header.byteRate = ptr.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            header.blockAlign = ptr.loadUnaligned(fromByteOffset: 12, as: UInt16.self)
            header.bitsPerSample = ptr.loadUnaligned(fromByteOffset: 14, as: UInt16.self)
        }

        // WAVE_FORMAT_EXTENSIBLE
        if header.formatTag == 0xFFFE && data.count >= 40 {
            data.withUnsafeBytes { ptr in
                header.validBitsPerSample = ptr.loadUnaligned(fromByteOffset: 18, as: UInt16.self)
                header.channelMask = ptr.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
            }
            let guidBytes = Array(data[24..<40])
            header.subFormatGUID = guidBytes
            header.isFloatSubFormat = (guidBytes == floatSubFormat)
            // Treat the sub-format tag as the effective format tag
            if guidBytes == pcmSubFormat {
                // PCM in extensible wrapper — keep formatTag as 0xFFFE for output detection
            }
        }
    }
}
