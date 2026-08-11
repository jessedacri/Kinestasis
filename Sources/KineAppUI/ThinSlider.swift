import SwiftUI

/// SwiftUI-native slim slider. macOS SwiftUI `Slider` is chunky even
/// with `.controlSize(.small)` — its thumb stays the system-standard
/// size and the track is a heavy bevel. This control draws a 3 px
/// pill track plus a small circular thumb, with full drag-anywhere
/// semantics and the same Slider API surface we use elsewhere.
///
/// API mirrors `SwiftUI.Slider`:
///   ThinSlider(value:, in:) { editing in ... }
struct ThinSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var trackHeight: CGFloat = 3
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var dragging = false
    @State private var hovering = false

    private var thumbWidth: CGFloat  { (dragging || hovering) ? 6 : 4 }
    private var thumbHeight: CGFloat { (dragging || hovering) ? 16 : 12 }
    private var rowHeight: CGFloat   { 16 }

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let frac = clampedFraction()
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(KineTheme.accent.opacity(0.85))
                    .frame(width: CGFloat(frac) * width, height: trackHeight)
                Capsule()
                    .fill(Color.white)
                    .overlay(
                        Capsule().strokeBorder(Color.black.opacity(0.20), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
                    .frame(width: thumbWidth, height: thumbHeight)
                    .offset(x: CGFloat(frac) * width - thumbWidth / 2)
                    .animation(.easeOut(duration: 0.12), value: hovering)
                    .animation(.easeOut(duration: 0.12), value: dragging)
            }
            .frame(height: rowHeight, alignment: .center)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging {
                            dragging = true
                            onEditingChanged(true)
                        }
                        let frac = max(0, min(1, g.location.x / width))
                        value = range.lowerBound + Double(frac) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: rowHeight)
    }

    private func clampedFraction() -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return max(0, min(1, (value - range.lowerBound) / span))
    }
}
