import Foundation

/// Generates short track label abbreviations from track names, intelligently
/// skipping filler words common in production sound metadata
/// (Wired/Wireless/Mic/Track/etc) and prefixing the most meaningful word.
public struct TrackLabelGenerator {
    /// Filler words that should be skipped when picking the meaningful token.
    public static let stopWords: Set<String> = [
        "wired", "wireless",
        "mic", "microphone", "mike",
        "track", "channel", "ch",
        "audio", "sound",
        "the", "a", "an", "of", "to",
        "src", "source", "input"
    ]

    /// Words that are particularly meaningful in production sound and should be preferred.
    public static let preferredWords: Set<String> = [
        "boom", "lav", "lavalier", "plant", "mix", "mixdown",
        "iso", "main", "scratch", "guide", "ref", "reference",
        "cam", "camera", "slate", "voice"
    ]

    /// Generate a short abbreviation (max ~6 chars) from a track name.
    /// Examples:
    ///   "Wired Boom"      -> "BOOM"
    ///   "Wireless Lav 1"  -> "LAV 1"
    ///   "Plant Mic 2"     -> "PLANT2"
    ///   "Boom 1"          -> "BOOM 1"
    ///   "Mix"             -> "MIX"
    ///   "Purple"          -> "PURPLE"
    ///   ""                -> nil (caller falls back to filename or default)
    public static func abbreviation(from name: String, maxLength: Int = 6) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Tokenize: split on whitespace, dashes, underscores, slashes
        let separators = CharacterSet(charactersIn: " -_/\\.,()[]")
        let rawTokens = trimmed.components(separatedBy: separators).filter { !$0.isEmpty }
        guard !rawTokens.isEmpty else { return nil }

        let tokens = rawTokens.map { (raw: $0, lower: $0.lowercased()) }

        // Try to find a preferred word first (boom, lav, etc.)
        var meaningfulIndex = tokens.firstIndex { preferredWords.contains($0.lower) }

        // Otherwise, take the first non-stop-word
        if meaningfulIndex == nil {
            meaningfulIndex = tokens.firstIndex { !stopWords.contains($0.lower) }
        }

        // Last resort: just use the first token
        let chosenIndex = meaningfulIndex ?? 0
        let primary = tokens[chosenIndex].raw

        // Look for a trailing number after the meaningful word (e.g. "Lav 1", "Boom 2")
        var suffix = ""
        if chosenIndex + 1 < tokens.count {
            let next = tokens[chosenIndex + 1].raw
            if Int(next) != nil {
                suffix = next
            }
        }

        // Combine and uppercase
        let combined = (primary + (suffix.isEmpty ? "" : " " + suffix)).uppercased()

        // Truncate (preserving the trailing number when possible)
        if combined.count <= maxLength {
            return combined
        }
        if suffix.isEmpty {
            return String(combined.prefix(maxLength))
        }
        // Try keeping the number: trim primary, append suffix
        let primaryUpper = primary.uppercased()
        let availableForPrimary = maxLength - suffix.count - 1 // -1 for space
        if availableForPrimary >= 2 {
            return String(primaryUpper.prefix(availableForPrimary)) + " " + suffix
        }
        return String(combined.prefix(maxLength))
    }
}
