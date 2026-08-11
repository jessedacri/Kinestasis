import SwiftUI
import KineCore

/// Pen-tool-style editor for a shot's time-remap curve. x: output
/// progress, y: source progress. Drag points; click the curve to add one;
/// double-click a point to remove it (endpoints stay). Monotone display
/// matches the engine's ToneCurve evaluation exactly.
struct RampCurveEditor: View {
    let points: [CurvePoint]
    let onChange: ([CurvePoint]) -> Void

    @State private var dragIndex: Int? = nil

    /// Identity endpoints when unset, so there is always a curve to grab.
    private var effective: [CurvePoint] {
        points.count >= 2 ? points.sorted { $0.x < $1.x }
                          : [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let pts = effective
            let curve = ToneCurve(pts)
            ZStack {
                // Grid
                Path { p in
                    for i in 1..<4 {
                        let f = CGFloat(i) / 4
                        p.move(to: CGPoint(x: f * size.width, y: 0))
                        p.addLine(to: CGPoint(x: f * size.width, y: size.height))
                        p.move(to: CGPoint(x: 0, y: f * size.height))
                        p.addLine(to: CGPoint(x: size.width, y: f * size.height))
                    }
                }
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)

                // Identity diagonal
                Path { p in
                    p.move(to: CGPoint(x: 0, y: size.height))
                    p.addLine(to: CGPoint(x: size.width, y: 0))
                }
                .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

                // Curve
                Path { p in
                    let steps = max(32, Int(size.width / 2))
                    for i in 0...steps {
                        let x = Double(i) / Double(steps)
                        let y = curve.evaluate(x)
                        let pt = CGPoint(x: CGFloat(x) * size.width, y: (1 - CGFloat(y)) * size.height)
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(KineTheme.accent, lineWidth: 1.5)

                // Control points
                ForEach(pts.indices, id: \.self) { i in
                    let pt = pts[i]
                    Circle()
                        .fill(dragIndex == i ? Color.white : KineTheme.accent)
                        .frame(width: 8, height: 8)
                        .position(x: CGFloat(pt.x) * size.width, y: (1 - CGFloat(pt.y)) * size.height)
                        .onTapGesture(count: 2) {
                            guard i != 0 && i != pts.count - 1 else { return }
                            var updated = pts
                            updated.remove(at: i)
                            onChange(updated.count <= 2 && isIdentity(updated) ? [] : updated)
                        }
                }
            }
            .background(Color.black.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = min(1, max(0, Double(value.location.x / size.width)))
                        let y = min(1, max(0, Double(1 - value.location.y / size.height)))
                        var updated = pts
                        if dragIndex == nil {
                            // Grab the nearest point within ~12 px, else add one.
                            let hit = updated.indices.min(by: { a, b in
                                distance(updated[a], x, y, size) < distance(updated[b], x, y, size)
                            })
                            if let hit, distance(updated[hit], x, y, size) < 12 {
                                dragIndex = hit
                            } else {
                                let insert = updated.firstIndex(where: { $0.x > x }) ?? updated.count
                                updated.insert(CurvePoint(x: x, y: y), at: insert)
                                dragIndex = insert
                                onChange(updated)
                                return
                            }
                        }
                        guard let i = dragIndex else { return }
                        // Endpoints slide only vertically; interior points are
                        // boxed between neighbors so the curve stays monotone.
                        let minX = i == 0 ? 0 : updated[i - 1].x + 0.01
                        let maxX = i == updated.count - 1 ? 1 : updated[i + 1].x - 0.01
                        let minY = i == 0 ? 0 : updated[i - 1].y
                        let maxY = i == updated.count - 1 ? 1 : updated[i + 1].y
                        let nx = i == 0 ? 0 : (i == updated.count - 1 ? 1 : min(maxX, max(minX, x)))
                        updated[i] = CurvePoint(x: nx, y: min(maxY, max(minY, y)))
                        onChange(updated)
                    }
                    .onEnded { _ in dragIndex = nil }
            )
        }
    }

    private func distance(_ p: CurvePoint, _ x: Double, _ y: Double, _ size: CGSize) -> CGFloat {
        let dx = (CGFloat(p.x) - CGFloat(x)) * size.width
        let dy = (CGFloat(p.y) - CGFloat(y)) * size.height
        return (dx * dx + dy * dy).squareRoot()
    }

    private func isIdentity(_ pts: [CurvePoint]) -> Bool {
        pts.count == 2 && pts[0].x == 0 && pts[0].y == 0 && pts[1].x == 1 && pts[1].y == 1
    }
}
