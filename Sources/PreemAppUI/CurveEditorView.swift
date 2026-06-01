import SwiftUI
import AppKit
import PreemCore

/// Interactive RGB / master tone-curve editor. Drag control points;
/// click empty curve to add a point; double-click a point to remove it
/// (endpoints stay). Writes through `setColorCurveOnSelection` so the
/// Program viewer updates live.
struct CurveEditorView: View {
    @ObservedObject var workspace: WorkspaceModel
    let leadID: PlacedClipID?
    let grade: ColorGrade

    enum Channel: String, CaseIterable { case master = "Master", red = "Red", green = "Green", blue = "Blue" }
    @State private var channel: Channel = .master
    @State private var dragIndex: Int? = nil

    private var curveName: String {
        switch channel {
        case .master: return "curveMaster"
        case .red:    return "curveRed"
        case .green:  return "curveGreen"
        case .blue:   return "curveBlue"
        }
    }

    private var tint: Color {
        switch channel {
        case .master: return .white
        case .red:    return .red
        case .green:  return .green
        case .blue:   return .blue
        }
    }

    /// Source-of-truth points (identity when unset).
    private var points: [CurvePoint] {
        let stored: [CurvePoint]
        switch channel {
        case .master: stored = grade.curveMaster
        case .red:    stored = grade.curveRed
        case .green:  stored = grade.curveGreen
        case .blue:   stored = grade.curveBlue
        }
        if stored.count < 2 { return [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)] }
        return stored.sorted { $0.x < $1.x }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $channel) {
                ForEach(Channel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            GeometryReader { geo in
                let size = geo.size
                plot(size: size)
                    .contentShape(Rectangle())
                    .gesture(drag(in: size))
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2).onEnded { removeNearest(at: $0.location, in: size) }
                    )
            }
            .frame(height: 180)
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.1)))

            HStack {
                Text("Drag to bend · click to add · double-click a point to remove")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Reset") { write(identity(), commit: true) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .disabled(leadID == nil)
            }
        }
        .disabled(leadID == nil)
        .opacity(leadID == nil ? 0.5 : 1)
    }

    private func plot(size: CGSize) -> some View {
        let pts = points
        let curve = ToneCurve(pts)
        return Canvas { ctx, _ in
            // Grid (quarters).
            for i in 1..<4 {
                let f = CGFloat(i) / 4
                var v = Path(); v.move(to: CGPoint(x: f * size.width, y: 0)); v.addLine(to: CGPoint(x: f * size.width, y: size.height))
                var h = Path(); h.move(to: CGPoint(x: 0, y: f * size.height)); h.addLine(to: CGPoint(x: size.width, y: f * size.height))
                ctx.stroke(v, with: .color(.white.opacity(0.07)), lineWidth: 0.5)
                ctx.stroke(h, with: .color(.white.opacity(0.07)), lineWidth: 0.5)
            }
            // Identity diagonal.
            var diag = Path()
            diag.move(to: pt(CurvePoint(x: 0, y: 0), size))
            diag.addLine(to: pt(CurvePoint(x: 1, y: 1), size))
            ctx.stroke(diag, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

            // The smooth curve.
            var path = Path()
            let steps = 64
            for i in 0...steps {
                let x = Double(i) / Double(steps)
                let p = pt(CurvePoint(x: x, y: curve.evaluate(x)), size)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: .color(tint.opacity(0.95)), lineWidth: 1.5)

            // Control points.
            for cp in pts {
                let p = pt(cp, size)
                let r: CGFloat = 4
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2*r, height: 2*r)),
                         with: .color(tint))
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2*r, height: 2*r)),
                           with: .color(.black.opacity(0.5)), lineWidth: 0.5)
            }
        }
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if dragIndex == nil {
                    workspace.beginUndoBatch()
                    dragIndex = pickOrCreate(at: g.startLocation, in: size)
                }
                guard let i = dragIndex else { return }
                var pts = points
                guard i < pts.count else { return }
                let nx = clamp(Double(g.location.x / size.width))
                let ny = clamp(1 - Double(g.location.y / size.height))
                // Endpoints keep their x; interior points clamp between neighbors.
                if i == 0 { pts[0] = CurvePoint(x: 0, y: ny) }
                else if i == pts.count - 1 { pts[i] = CurvePoint(x: 1, y: ny) }
                else {
                    let lo = pts[i - 1].x + 0.001, hi = pts[i + 1].x - 0.001
                    pts[i] = CurvePoint(x: min(max(nx, lo), hi), y: ny)
                }
                write(pts, commit: false)
            }
            .onEnded { _ in
                workspace.endUndoBatch()
                workspace.commitTransformEdits()
                dragIndex = nil
            }
    }

    /// Find a point under the cursor; if none, insert a new one on the curve.
    private func pickOrCreate(at loc: CGPoint, in size: CGSize) -> Int? {
        var pts = points
        let hit: CGFloat = 12
        for (i, cp) in pts.enumerated() {
            let p = pt(cp, size)
            if hypot(p.x - loc.x, p.y - loc.y) <= hit { return i }
        }
        // Insert a new interior point at the cursor x.
        let nx = clamp(Double(loc.x / size.width))
        let ny = clamp(1 - Double(loc.y / size.height))
        guard nx > 0.001, nx < 0.999 else { return nil }
        var insertAt = pts.count - 1
        for i in 0..<(pts.count - 1) where nx > pts[i].x && nx < pts[i + 1].x { insertAt = i + 1; break }
        pts.insert(CurvePoint(x: nx, y: ny), at: insertAt)
        write(pts, commit: false)
        return insertAt
    }

    /// Double-click removes the nearest interior point.
    private func removeNearest(at loc: CGPoint, in size: CGSize) {
        var pts = points
        guard pts.count > 2 else { return }
        let hit: CGFloat = 12
        for i in 1..<(pts.count - 1) {
            let p = pt(pts[i], size)
            if hypot(p.x - loc.x, p.y - loc.y) <= hit {
                pts.remove(at: i)
                write(pts, commit: true)
                return
            }
        }
    }

    private func identity() -> [CurvePoint] { [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)] }

    private func write(_ pts: [CurvePoint], commit: Bool) {
        if commit { workspace.setColorCurveOnSelection(curveName, pts) }
        else { workspace.setColorCurveOnSelectionLight(curveName, pts) }
    }

    private func pt(_ cp: CurvePoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(cp.x) * size.width, y: (1 - CGFloat(cp.y)) * size.height)
    }
    private func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
}
