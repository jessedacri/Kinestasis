import Foundation
import CoreGraphics
import PreemCore

/// Parses raw OCR observations from a slate into structured
/// scene/take/roll fields. Slates vary wildly (digital, analog, custom
/// chalkboard, smart-slates), so we look for *labeled* tokens before
/// inferring from positions.
///
/// Supported patterns (case-insensitive, with variants):
///   "Scene 12B"          → scene = "12B"
///   "Sc. 12B"            → scene = "12B"
///   "S 12B"              → scene = "12B"     (matched only if "T"/"R" siblings also present)
///   "Take 4"             → take  = "4"
///   "TK 4"               → take  = "4"
///   "T 4"                → take  = "4"
///   "Roll 03"            → roll  = "03"
///   "R 03"               → roll  = "03"
///   "Cam A"              → (camera; ignored for slate, used by future shot-type pipeline)
///
/// Strategy:
///   1. Normalize all observed text to a single corpus per (text, confidence).
///   2. Try labeled-token regexes first (highest signal).
///   3. If labeled-tokens missed a field, scan for short-label-letter +
///      number pairs ("S 12B", "T 4", "R 03") that co-occur on the
///      same frame's observations — three-letter co-occurrence is what
///      separates a real slate from random screen text.
///   4. Score the result by (filled-field count × mean confidence) and
///      return the best parse across all frames.
public enum SlateParser {

    public struct Observation: Sendable {
        public var text: String
        public var confidence: Float
        public var boundingBox: CGRect          // normalized (Vision convention)

        public init(text: String, confidence: Float, boundingBox: CGRect) {
            self.text = text; self.confidence = confidence; self.boundingBox = boundingBox
        }
    }

    public static func parse(_ observations: [Observation]) -> SlateData? {
        guard !observations.isEmpty else { return nil }

        // Group by approximate frame (we get one batch per frame from
        // SlateOCR, but to keep this function reusable we treat the
        // whole input as one corpus and let the labeled-token matches
        // dominate). Co-occurrence is checked by string proximity.

        var bestParse: SlateData?
        var bestScore: Double = 0

        // Pass 1: labeled patterns over the entire batch.
        let labeled = matchLabeled(observations)
        let score1 = score(labeled)
        if score1 > bestScore {
            bestScore = score1
            bestParse = labeled
        }

        // Pass 2: short-letter co-occurrence. Requires at least two of
        // {S, T, R} short forms to agree on the same observation group.
        if let cooc = matchShortLetterCooccurrence(observations),
           score(cooc) > bestScore {
            bestScore = score(cooc)
            bestParse = cooc
        }

        // Pass 3: take-only fallback. If we have NO scene/roll signal,
        // a confident standalone "Take N" / "TK N" is still useful.
        if bestScore == 0 {
            if let takeOnly = matchTakeOnly(observations) {
                bestParse = takeOnly
                bestScore = score(takeOnly)
            }
        }

        guard bestScore > 0 else { return nil }
        return bestParse
    }

    // MARK: - Labeled

    private static let scenePatterns: [NSRegularExpression] = makeRegexes([
        #"(?i)\bscene\s*[:#]?\s*([0-9]+[A-Z]?)\b"#,
        #"(?i)\bsc\.?\s*[:#]?\s*([0-9]+[A-Z]?)\b"#,
    ])

    private static let takePatterns: [NSRegularExpression] = makeRegexes([
        #"(?i)\btake\s*[:#]?\s*([0-9]+)\b"#,
        #"(?i)\btk\s*[:#]?\s*([0-9]+)\b"#,
    ])

    private static let rollPatterns: [NSRegularExpression] = makeRegexes([
        #"(?i)\broll\s*[:#]?\s*([A-Z0-9]+)\b"#,
    ])

    private static func matchLabeled(_ observations: [Observation]) -> SlateData {
        let corpus = observations.map(\.text).joined(separator: " · ")

        let scene = firstMatch(in: corpus, patterns: scenePatterns)
        let take  = firstMatch(in: corpus, patterns: takePatterns)
        let roll  = firstMatch(in: corpus, patterns: rollPatterns)

        let avgConf = observations.isEmpty ? 0 : Double(observations.map(\.confidence).reduce(0, +)) / Double(observations.count)

        return SlateData(
            scene: scene,
            take: take,
            roll: roll,
            rawText: corpus,
            confidence: avgConf
        )
    }

    // MARK: - Short-letter co-occurrence

    private static let shortScene = try! NSRegularExpression(pattern: #"(?i)\bS\s*[:#]?\s*([0-9]+[A-Z]?)\b"#)
    private static let shortTake  = try! NSRegularExpression(pattern: #"(?i)\bT\s*[:#]?\s*([0-9]+)\b"#)
    private static let shortRoll  = try! NSRegularExpression(pattern: #"(?i)\bR\s*[:#]?\s*([A-Z0-9]+)\b"#)

    private static func matchShortLetterCooccurrence(_ observations: [Observation]) -> SlateData? {
        let corpus = observations.map(\.text).joined(separator: " · ")
        let scene = firstMatch(in: corpus, patterns: [shortScene])
        let take  = firstMatch(in: corpus, patterns: [shortTake])
        let roll  = firstMatch(in: corpus, patterns: [shortRoll])

        let filled = [scene, take, roll].compactMap { $0 }.count
        guard filled >= 2 else { return nil }

        let avgConf = observations.isEmpty ? 0 : Double(observations.map(\.confidence).reduce(0, +)) / Double(observations.count)
        return SlateData(
            scene: scene,
            take: take,
            roll: roll,
            rawText: corpus,
            confidence: avgConf * 0.85   // discount versus labeled match
        )
    }

    // MARK: - Take-only fallback

    private static func matchTakeOnly(_ observations: [Observation]) -> SlateData? {
        let corpus = observations.map(\.text).joined(separator: " · ")
        guard let take = firstMatch(in: corpus, patterns: takePatterns) else { return nil }

        let avgConf = observations.isEmpty ? 0 : Double(observations.map(\.confidence).reduce(0, +)) / Double(observations.count)
        return SlateData(
            scene: nil,
            take: take,
            roll: nil,
            rawText: corpus,
            confidence: avgConf * 0.6   // big discount; only take alone
        )
    }

    // MARK: - Scoring

    private static func score(_ slate: SlateData) -> Double {
        let filled = [slate.scene, slate.take, slate.roll].compactMap { $0 }.count
        return Double(filled) * slate.confidence
    }

    // MARK: - Helpers

    private static func makeRegexes(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    private static func firstMatch(in text: String, patterns: [NSRegularExpression]) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            if let match = pattern.firstMatch(in: text, range: range), match.numberOfRanges >= 2,
               let groupRange = Range(match.range(at: 1), in: text) {
                return String(text[groupRange]).uppercased()
            }
        }
        return nil
    }
}
