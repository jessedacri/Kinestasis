import Foundation
import KineCore

/// FCPXML 1.10 sidecar written next to a shot batch export: one asset per
/// exported movie, an event holding them all, and a project whose spine
/// strings the shots in bin order — so Resolve (and FCP) import the batch
/// as both loose clips and an assembled starting timeline.
public struct ShotBatchXMLSidecar {

    public struct Entry: Sendable {
        public let shot: BurstShot
        public let movieURL: URL
        public let outputFrames: Int64
        public let size: PixelSize

        public init(shot: BurstShot, movieURL: URL, outputFrames: Int64, size: PixelSize) {
            self.shot = shot; self.movieURL = movieURL
            self.outputFrames = outputFrames; self.size = size
        }
    }

    public init() {}

    public func write(entries: [Entry], rate: FrameRate, to directory: URL, batchName: String) throws -> URL {
        let url = directory.appendingPathComponent("\(batchName).fcpxml")
        try xml(entries: entries, rate: rate, batchName: batchName)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func xml(entries: [Entry], rate: FrameRate, batchName: String) -> String {
        let frameDur = "\(rate.rationalScale)/\(rate.rationalRate)s"
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<!DOCTYPE fcpxml>\n"
        out += "<fcpxml version=\"1.10\">\n"
        out += "  <resources>\n"

        // One format per distinct pixel size.
        var formatIDs: [PixelSize: String] = [:]
        for entry in entries where formatIDs[entry.size] == nil {
            let id = "r\(formatIDs.count + 1)"
            formatIDs[entry.size] = id
            out += "    <format id=\"\(id)\" name=\"FFVideoFormat_Kinestasis_\(entry.size.width)x\(entry.size.height)\" "
            out += "frameDuration=\"\(frameDur)\" width=\"\(entry.size.width)\" height=\"\(entry.size.height)\"/>\n"
        }

        for (i, entry) in entries.entriesWithAssetIDs() {
            let dur = "\(entry.outputFrames * Int64(rate.rationalScale))/\(rate.rationalRate)s"
            out += "    <asset id=\"\(i)\" name=\"\(escape(entry.shot.name))\" start=\"0s\" duration=\"\(dur)\" "
            out += "hasVideo=\"1\" format=\"\(formatIDs[entry.size] ?? "r1")\" videoSources=\"1\">\n"
            out += "      <media-rep kind=\"original-media\" src=\"\(escape(entry.movieURL.absoluteString))\"/>\n"
            out += "    </asset>\n"
        }
        out += "  </resources>\n"

        out += "  <library>\n"
        out += "    <event name=\"\(escape(batchName))\">\n"

        // Loose clips.
        for (i, entry) in entries.entriesWithAssetIDs() {
            let dur = "\(entry.outputFrames * Int64(rate.rationalScale))/\(rate.rationalRate)s"
            out += "      <asset-clip name=\"\(escape(entry.shot.name))\" ref=\"\(i)\" duration=\"\(dur)\" format=\"\(formatIDs[entry.size] ?? "r1")\" tcFormat=\"NDF\"/>\n"
        }

        // Assembled starting timeline in bin order.
        let firstFormat = entries.first.flatMap { formatIDs[$0.size] } ?? "r1"
        let totalFrames = entries.reduce(Int64(0)) { $0 + $1.outputFrames }
        let totalDur = "\(totalFrames * Int64(rate.rationalScale))/\(rate.rationalRate)s"
        out += "      <project name=\"\(escape(batchName)) Assembly\">\n"
        out += "        <sequence format=\"\(firstFormat)\" duration=\"\(totalDur)\" tcStart=\"0s\" tcFormat=\"NDF\">\n"
        out += "          <spine>\n"
        var offset: Int64 = 0
        for (i, entry) in entries.entriesWithAssetIDs() {
            let dur = "\(entry.outputFrames * Int64(rate.rationalScale))/\(rate.rationalRate)s"
            let off = "\(offset * Int64(rate.rationalScale))/\(rate.rationalRate)s"
            out += "            <asset-clip name=\"\(escape(entry.shot.name))\" ref=\"\(i)\" offset=\"\(off)\" duration=\"\(dur)\" format=\"\(formatIDs[entry.size] ?? "r1")\" tcFormat=\"NDF\"/>\n"
            offset += entry.outputFrames
        }
        out += "          </spine>\n"
        out += "        </sequence>\n"
        out += "      </project>\n"
        out += "    </event>\n"
        out += "  </library>\n"
        out += "</fcpxml>\n"
        return out
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private extension Array where Element == ShotBatchXMLSidecar.Entry {
    /// Stable asset IDs following the format IDs ("a1", "a2", …).
    func entriesWithAssetIDs() -> [(String, ShotBatchXMLSidecar.Entry)] {
        enumerated().map { ("a\($0.offset + 1)", $0.element) }
    }
}
