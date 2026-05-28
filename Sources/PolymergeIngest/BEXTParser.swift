import Foundation

public struct BEXTParser {
    public struct BEXTData {
        public var description: String
        public var originator: String
        public var originatorReference: String
        public var originationDate: String
        public var originationTime: String
        public var timeReference: UInt64  // samples since midnight
        public var version: UInt16
        public var codingHistory: String

        public init(
            description: String,
            originator: String,
            originatorReference: String,
            originationDate: String,
            originationTime: String,
            timeReference: UInt64,
            version: UInt16,
            codingHistory: String
        ) {
            self.description = description
            self.originator = originator
            self.originatorReference = originatorReference
            self.originationDate = originationDate
            self.originationTime = originationTime
            self.timeReference = timeReference
            self.version = version
            self.codingHistory = codingHistory
        }
    }

    public enum ParseError: LocalizedError {
        case dataTooShort

        public var errorDescription: String? {
            switch self {
            case .dataTooShort: return "BEXT chunk data too short"
            }
        }
    }

    /// BEXT chunk layout (EBU Tech 3285):
    /// 0-255:   Description (256 bytes, ASCII null-padded)
    /// 256-287: Originator (32 bytes)
    /// 288-319: OriginatorReference (32 bytes)
    /// 320-329: OriginationDate (10 bytes, "YYYY-MM-DD" or "YYYY:MM:DD")
    /// 330-337: OriginationTime (8 bytes, "HH:MM:SS")
    /// 338-341: TimeReferenceLow (UInt32)
    /// 342-345: TimeReferenceHigh (UInt32)
    /// 346-347: Version (UInt16)
    /// 348-411: UMID (64 bytes)
    /// 412+:    (v2: loudness fields, then CodingHistory)
    /// The CodingHistory starts after all fixed fields and runs to the end.
    public static func parse(data: Data) throws -> BEXTData {
        guard data.count >= 348 else {
            throw ParseError.dataTooShort
        }

        let description = extractString(from: data, offset: 0, length: 256)
        let originator = extractString(from: data, offset: 256, length: 32)
        let originatorReference = extractString(from: data, offset: 288, length: 32)
        let originationDate = extractString(from: data, offset: 320, length: 10)
        let originationTime = extractString(from: data, offset: 330, length: 8)

        let timeRefLow: UInt32 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 338, as: UInt32.self) }
        let timeRefHigh: UInt32 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 342, as: UInt32.self) }
        let timeReference = UInt64(timeRefHigh) << 32 | UInt64(timeRefLow)

        let version: UInt16 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 346, as: UInt16.self) }

        // CodingHistory: after UMID (byte 412) for v1, or after loudness fields for v2+
        // v2 adds 10 bytes of loudness data at 412-421, so coding history starts at 602 for v2
        // But to be safe, just look for coding history after byte 602 if v2+, else 412
        let codingHistoryOffset: Int
        if version >= 2 && data.count > 602 {
            codingHistoryOffset = 602
        } else {
            codingHistoryOffset = 412
        }

        let codingHistory: String
        if data.count > codingHistoryOffset {
            codingHistory = extractString(from: data, offset: codingHistoryOffset, length: data.count - codingHistoryOffset)
        } else {
            codingHistory = ""
        }

        return BEXTData(
            description: description,
            originator: originator,
            originatorReference: originatorReference,
            originationDate: originationDate,
            originationTime: originationTime,
            timeReference: timeReference,
            version: version,
            codingHistory: codingHistory
        )
    }

    private static func extractString(from data: Data, offset: Int, length: Int) -> String {
        let end = min(offset + length, data.count)
        guard offset < end else { return "" }
        let slice = data[offset..<end]
        // Trim null bytes and whitespace
        if let str = String(data: slice, encoding: .utf8) {
            return str.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespaces)
        }
        if let str = String(data: slice, encoding: .ascii) {
            return str.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }
}
