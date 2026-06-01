import SwiftUI

/// Preem's brand palette — a sibling of the Polymerge design system
/// (`PolyMerge/Views/Components/Theme.swift`). Same family: dark,
/// purple-tinted near-black chrome with an amber signature accent and a
/// violet secondary. One source of truth — recolor here, not inline.
///
/// Dark-first by construction (these are fixed dark values, not
/// system-adaptive) — the program picture is the brightest thing on screen.
public enum PreemTheme {
    // Backgrounds (window → panel → card → hover → selected)
    public static let bg            = Color(hex: "18161B")
    public static let bgPanel       = Color(hex: "1E1C22")
    public static let bgCard        = Color(hex: "26232B")
    public static let bgCardHover   = Color(hex: "2E2A35")
    public static let bgCardSelected = Color(hex: "332840")

    // Borders
    public static let border        = Color(hex: "36323D")
    public static let borderLight   = Color(hex: "443F4D")

    // Text
    public static let text          = Color(hex: "EDE8F2")
    public static let textMuted     = Color(hex: "9B93A6")
    public static let textDim       = Color(hex: "6B6278")

    // Accents
    public static let accent        = Color(hex: "F0A030")          // amber — signature
    public static let accentDim     = Color(hex: "F0A030").opacity(0.12)
    public static let accentGlow    = Color(hex: "F0A030").opacity(0.25)
    public static let secondary     = Color(hex: "C084FC")          // violet
    public static let secondaryDim  = Color(hex: "C084FC").opacity(0.12)

    // Status
    public static let error         = Color(hex: "FF4757")
    public static let green         = Color(hex: "3FB950")
    public static let greenDim      = Color(hex: "3FB950").opacity(0.12)
    public static let cyan          = Color(hex: "22D3EE")

    /// Per-file/track color cycle (matches Polymerge).
    public static let trackColors: [Color] = [
        accent, secondary, cyan, green,
        Color(hex: "FF6B9D"), Color(hex: "45B7D1"),
        Color(hex: "96CEB4"), Color(hex: "FFEAA7"),
    ]

    // Fonts — system, monospaced for data/labels (Polymerge convention).
    public static let mono: Font      = .system(size: 12, design: .monospaced)
    public static let monoSmall: Font = .system(size: 10, design: .monospaced)
    public static let monoLarge: Font = .system(size: 13, weight: .medium, design: .monospaced)
    public static let label: Font     = .system(size: 10, weight: .semibold)
    public static let heading: Font   = .system(size: 11, weight: .bold)
}

public extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        default:
            r = 0; g = 0; b = 0
        }
        self.init(red: r, green: g, blue: b)
    }
}
