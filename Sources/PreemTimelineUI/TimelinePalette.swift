import AppKit

/// Brand colors for the AppKit timeline. Mirrors `PreemTheme` (in
/// PreemAppUI) — the timeline is a lower module and can't import it, so the
/// few hexes it needs are duplicated here. Keep in sync with PreemTheme /
/// Polymerge's `Theme`. 1:1 remap of the old system colors:
/// blue→violet (video), teal→cyan (audio), yellow→amber (marks/selection),
/// red→playhead, green→green.
enum TimelinePalette {
    static let accent   = NSColor(hex: "F0A030")   // marks, transitions, cut/fade affordances, selection
    static let video    = NSColor(hex: "C084FC")   // video clip fills (was systemBlue)
    static let audio    = NSColor(hex: "22D3EE")   // audio clip fills (was systemTeal)
    static let playhead = NSColor(hex: "FF4757")   // playhead line + triangle (was systemRed)
    static let green    = NSColor(hex: "3FB950")
}

extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = CGFloat((int >> 16) & 0xFF) / 255.0
        let g = CGFloat((int >> 8) & 0xFF) / 255.0
        let b = CGFloat(int & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
