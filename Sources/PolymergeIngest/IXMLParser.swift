import Foundation
import PolymergeMediaModel

public struct IXMLParser {
    public struct IXMLData {
        public var timestampSamplesSinceMidnight: UInt64?
        public var timestampSampleRate: Int?
        public var timecodeRate: Double?
        public var timecodeFlag: TimecodeFlag?
        public var tracks: [TrackInfo] = []
        public var scene: String?
        public var take: String?
        public var note: String?
        public var deviceInfo: DeviceInfo?

        public init() {}

        public enum TimecodeFlag: String {
            case NDF
            case DF
        }

        public struct TrackInfo {
            /// iXML `<CHANNEL_INDEX>`. Per the spec this is the
            /// recorder's physical input channel number (1-based
            /// across the whole mixer). On a Sound Devices 688
            /// recording its tracks 3+4 to a stereo mix file,
            /// `CHANNEL_INDEX` reads 3 / 4 even though the file
            /// only has 2 channels. Use `interleaveIndex` for the
            /// ACTUAL position within the file's sample
            /// interleave pattern.
            public var channelIndex: Int
            /// iXML `<INTERLEAVE_INDEX>`. 1-based position of this
            /// track within the file's sample layout. For a file
            /// with 2 interleaved tracks, values are 1 and 2
            /// regardless of which mixer channels the tracks came
            /// from. This is the correct index to map into
            /// `AudioFile.perChannelNames` (0-based). Optional
            /// because older / simpler recorders sometimes omit
            /// it — fall back to `channelIndex` when nil.
            public var interleaveIndex: Int?
            public var name: String

            public init(channelIndex: Int, interleaveIndex: Int?, name: String) {
                self.channelIndex = channelIndex
                self.interleaveIndex = interleaveIndex
                self.name = name
            }
        }

        public struct DeviceInfo {
            public var vendor: String?
            public var model: String?
            public var firmware: String?

            public init(vendor: String? = nil, model: String? = nil, firmware: String? = nil) {
                self.vendor = vendor
                self.model = model
                self.firmware = firmware
            }
        }
    }

    public enum ParseError: LocalizedError {
        case invalidXML(String)

        public var errorDescription: String? {
            switch self {
            case .invalidXML(let msg): return "Invalid iXML: \(msg)"
            }
        }
    }

    public static func parse(data: Data) throws -> IXMLData {
        // Strip any null bytes from the end (common in WAV chunks)
        let cleanData: Data
        if let nullIndex = data.firstIndex(of: 0) {
            cleanData = data[data.startIndex..<nullIndex]
        } else {
            cleanData = data
        }

        let delegate = IXMLParserDelegate()
        let parser = XMLParser(data: cleanData)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false

        if !parser.parse() {
            // Be lenient — try to use whatever we got
            if delegate.result.timestampSamplesSinceMidnight == nil &&
               delegate.result.tracks.isEmpty &&
               delegate.result.scene == nil {
                throw ParseError.invalidXML(parser.parserError?.localizedDescription ?? "Unknown error")
            }
        }

        return delegate.result
    }

    /// Parse an iXML `<TIMECODE_RATE>` value into a `Double`. Accepts:
    /// - rational `numerator/denominator` form (`24000/1001`, `24/1`,
    ///   `30000/1001`) — the standard form Sound Devices, Tentacle,
    ///   Zaxcom, and the iXML spec all use
    /// - plain decimal/integer form (`23.976`, `24`, `29.97`) — the
    ///   non-standard form some older recorders write
    /// Returns nil if the value is unparseable in any form. The "/"
    /// case is checked first because the rational form is the spec.
    public static func parseTimecodeRate(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = trimmed.firstIndex(of: "/") {
            let numStr = trimmed[..<slash].trimmingCharacters(in: .whitespaces)
            let denStr = trimmed[trimmed.index(after: slash)...].trimmingCharacters(in: .whitespaces)
            if let num = Double(numStr), let den = Double(denStr), den > 0 {
                return num / den
            }
            return nil
        }
        return Double(trimmed)
    }
}

private class IXMLParserDelegate: NSObject, XMLParserDelegate {
    var result = IXMLParser.IXMLData()

    private var elementStack: [String] = []
    private var currentText = ""

    // Track parsing state
    private var currentTrackIndex: Int?
    private var currentTrackInterleave: Int?
    private var currentTrackName: String?

    private var currentPath: String {
        elementStack.joined(separator: "/")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        elementStack.append(elementName.uppercased())
        currentText = ""

        if elementName.uppercased() == "TRACK" {
            currentTrackIndex = nil
            currentTrackInterleave = nil
            currentTrackName = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = currentPath

        switch path {
        // SPEED block — canonical timecode source
        case let p where p.hasSuffix("SPEED/TIMESTAMP_SAMPLES_SINCE_MIDNIGHT_LO"):
            if let val = UInt64(text) {
                let hi = result.timestampSamplesSinceMidnight ?? 0
                result.timestampSamplesSinceMidnight = (hi & 0xFFFFFFFF_00000000) | val
            }

        case let p where p.hasSuffix("SPEED/TIMESTAMP_SAMPLES_SINCE_MIDNIGHT_HI"):
            if let val = UInt64(text) {
                let lo = result.timestampSamplesSinceMidnight ?? 0
                result.timestampSamplesSinceMidnight = (val << 32) | (lo & 0xFFFFFFFF)
            }

        case let p where p.hasSuffix("SPEED/TIMESTAMP_SAMPLE_RATE"):
            result.timestampSampleRate = Int(text)

        case let p where p.hasSuffix("SPEED/TIMECODE_RATE"):
            // Sound Devices, Tentacle Sync, and Zaxcom all write the
            // standard rational form `numerator/denominator` here:
            //   24/1, 24000/1001, 25/1, 30000/1001, 30/1, 60000/1001
            // Plain `Double(text)` returns nil for `24000/1001` and we
            // silently fell through to the default of 24, which then
            // labelled every 23.976 file as 24 fps. We accept BOTH
            // forms now: a rational `n/d` AND a plain decimal/integer
            // string for files that use the older non-standard form.
            result.timecodeRate = IXMLParser.parseTimecodeRate(text)

        case let p where p.hasSuffix("SPEED/TIMECODE_FLAG"):
            result.timecodeFlag = IXMLParser.IXMLData.TimecodeFlag(rawValue: text.uppercased())

        // Track list
        case let p where p.hasSuffix("TRACK/CHANNEL_INDEX"):
            currentTrackIndex = Int(text)

        case let p where p.hasSuffix("TRACK/INTERLEAVE_INDEX"):
            currentTrackInterleave = Int(text)

        case let p where p.hasSuffix("TRACK/NAME"):
            currentTrackName = text

        // Scene / Take / Note
        // Match either `<IXML>` (the literal iXML spec root) or
        // `<BWFXML>` (the Sound Devices / Zoom / Tentacle convention,
        // which is what every real recorder writes and what PolyMerge
        // now emits too — see WAVWriter.generateOutputIXML for the
        // full rationale on why DaVinci / Premiere / Pro Tools require
        // BWFXML as the root).
        case let p where p.hasSuffix("IXML/SCENE") || p.hasSuffix("BWFXML/SCENE"):
            result.scene = text

        case let p where p.hasSuffix("IXML/TAKE") || p.hasSuffix("BWFXML/TAKE"):
            result.take = text

        case let p where p.hasSuffix("IXML/NOTE") || p.hasSuffix("BWFXML/NOTE"):
            result.note = text

        // Tentacle Sync device info
        case let p where p.hasSuffix("TENTACLE/DEVICE"):
            if result.deviceInfo == nil { result.deviceInfo = .init() }
            result.deviceInfo?.vendor = "Tentacle"
            result.deviceInfo?.model = text

        case let p where p.hasSuffix("TENTACLE/FIRMWARE"):
            if result.deviceInfo == nil { result.deviceInfo = .init() }
            result.deviceInfo?.firmware = text

        // Zoom device info
        case let p where p.hasSuffix("USER/ZOOM_MODEL"):
            if result.deviceInfo == nil { result.deviceInfo = .init() }
            result.deviceInfo?.vendor = "Zoom"
            result.deviceInfo?.model = text

        default:
            break
        }

        // Finalize track on TRACK end
        if elementName.uppercased() == "TRACK" {
            if let idx = currentTrackIndex, let name = currentTrackName {
                result.tracks.append(.init(
                    channelIndex: idx,
                    interleaveIndex: currentTrackInterleave,
                    name: name
                ))
            }
            currentTrackIndex = nil
            currentTrackInterleave = nil
            currentTrackName = nil
        }

        elementStack.removeLast()
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        // Be lenient — continue with whatever we parsed so far
    }
}
