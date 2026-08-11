import SwiftUI

/// Branded About panel. Draws Kine's mark (timeline-track bars — the
/// Polymerge waveform on its side) so it needs no bundled asset, and uses
/// the brand palette/typography.
struct AboutView: View {
    var onClose: () -> Void

    private let barWidths: [CGFloat] = [0.74, 0.40, 0.28, 0.54, 0.88]

    var body: some View {
        VStack(spacing: 16) {
            mark
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text("Kinestasis")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(KineTheme.text)
                Text("Non-linear editor")
                    .font(KineTheme.monoSmall)
                    .foregroundStyle(KineTheme.textMuted)
            }

            VStack(spacing: 2) {
                Text("A Polymerge sibling")
                    .font(.system(size: 11))
                    .foregroundStyle(KineTheme.accent)
                Text("Built on the Polymerge engine")
                    .font(.system(size: 10))
                    .foregroundStyle(KineTheme.textDim)
            }

            Button("Close") { onClose() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 320)
        .background(KineTheme.bg)
    }

    /// Mini version of the app icon: dark rounded square + horizontal amber
    /// bars with a soft glow.
    private var mark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(colors: [KineTheme.bgCard, KineTheme.bg],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(KineTheme.border, lineWidth: 1))

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let n = barWidths.count
                let barH = h * 0.085
                let gap = (h * 0.62 - barH * CGFloat(n)) / CGFloat(n - 1)
                let top = h * 0.19
                VStack(spacing: 0) {
                    ForEach(0..<n, id: \.self) { i in
                        Capsule()
                            .fill(LinearGradient(colors: [KineTheme.accent, Color(hex: "FFC46B")],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: w * barWidths[i], height: barH)
                            .shadow(color: KineTheme.accentGlow, radius: 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, w * 0.13)
                            .padding(.top, i == 0 ? top : gap)
                    }
                }
            }
        }
    }
}
