import SwiftUI
import AppKit
import PreemCore

/// Bounding-box + handle overlay drawn over the realtime program
/// viewer when a clip is selected: center drag moves, corner handles
/// scale uniformly, edge handles scale one axis, the top grip rotates.
struct ProgramTransformOverlay: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        GeometryReader { geo in
            // Resolve the picture rect — RealtimeProgramHost's
            // CAMetalLayer uses `.resizeAspect`, so the rendered
            // picture is centered and aspect-fit within the view.
            if let seq = workspace.activeSequence {
                let pictureRect = aspectFitRect(
                    container: geo.size,
                    aspectW: seq.settings.resolution.width,
                    aspectH: seq.settings.resolution.height
                )
                ZStack {
                    if let id = workspace.selectedClipIDs.first,
                       let placed = findPlacedClip(id, in: seq),
                       let source = workspace.project.mediaPool.clips[placed.sourceClipID],
                       clipIsAtPlayhead(placed) {
                        TransformHandles(
                            workspace: workspace,
                            placedClip: placed,
                            source: source,
                            pictureRect: pictureRect,
                            sequenceResolution: seq.settings.resolution
                        )
                    }
                }
            }
        }
        .allowsHitTesting(true)
    }

    private func clipIsAtPlayhead(_ clip: PlacedClip) -> Bool {
        clip.timelineRange.contains(workspace.playheadTime)
    }

    private func findPlacedClip(_ id: PlacedClipID, in seq: Sequence) -> PlacedClip? {
        for t in seq.videoTracks { if let c = t.clips.first(where: { $0.id == id }) { return c } }
        return nil
    }

    private func aspectFitRect(container: CGSize, aspectW: Int, aspectH: Int) -> CGRect {
        let aspect = CGFloat(aspectW) / CGFloat(aspectH)
        let cAspect = container.width / max(1, container.height)
        var w = container.width, h = container.height
        if cAspect > aspect {
            w = container.height * aspect
        } else {
            h = container.width / aspect
        }
        return CGRect(
            x: (container.width - w) / 2,
            y: (container.height - h) / 2,
            width: w, height: h
        )
    }
}

private struct TransformHandles: View {
    @ObservedObject var workspace: WorkspaceModel
    let placedClip: PlacedClip
    let source: ClipSource
    let pictureRect: CGRect
    let sequenceResolution: PixelSize

    @State private var dragStartTransform: ClipTransform?

    var body: some View {
        // Outer = the full picture rect (where the image lives,
        // independent of crop). Inner = the visible-after-crop sub-rect.
        // Mirrors the compositor's layerUniforms() math exactly.
        let xform = workspace.clipTransform(placedClip.id) ?? .identity
        let outer = pictureRectInView(transform: xform)
        let visible = visibleAfterCrop(picture: outer, transform: xform)
        ZStack {
            // Outer bounding box — axis-aligned AABB even when rotated.
            // Visual chrome stays easy to grab; the rotated picture sits
            // inside this box.
            Rectangle()
                .stroke(PreemTheme.accent.opacity(0.85), lineWidth: 1.5)
                .frame(width: outer.width, height: outer.height)
                .position(x: outer.midX, y: outer.midY)

            // Visible-after-crop hint — dashed inner stroke for
            // non-zero crop.
            if visible != outer {
                Rectangle()
                    .strokeBorder(
                        PreemTheme.accent.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
                    .frame(width: visible.width, height: visible.height)
                    .position(x: visible.midX, y: visible.midY)
            }

            // Center grab — drag to move
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: max(0, outer.width - 24), height: max(0, outer.height - 24))
                .position(x: outer.midX, y: outer.midY)
                .gesture(centerDragGesture)
                .onHover { hovering in
                    if hovering { NSCursor.openHand.set() }
                    else { NSCursor.arrow.set() }
                }

            // Corner handles — uniform scale.
            ForEach(0..<4, id: \.self) { idx in
                cornerHandle(idx: idx, dest: outer)
            }

            // Mid-edge handles — non-uniform scale. 0=T, 1=R, 2=B, 3=L.
            ForEach(0..<4, id: \.self) { idx in
                edgeHandle(idx: idx, dest: outer)
            }

            // Rotation grip — a knob above the top edge.
            rotationGrip(dest: outer)
        }
    }

    // MARK: - Layout math (matches the compositor's layerUniforms())

    /// The full picture's destRect in view coords — the area the
    /// uncropped source would fill. Mirrors `OfflineSequenceCompositor`
    /// post-crop-decoupling: crop no longer changes this rect.
    private func pictureRectInView(transform xform: ClipTransform) -> CGRect {
        let outW = Double(sequenceResolution.width)
        let outH = Double(sequenceResolution.height)
        let srcW = Double(source.videoTracks.first?.resolution.width ?? sequenceResolution.width)
        let srcH = Double(source.videoTracks.first?.resolution.height ?? sequenceResolution.height)

        var fitW: Double, fitH: Double
        if xform.stretchToFill || srcW <= 0 || srcH <= 0 {
            fitW = outW; fitH = outH
        } else {
            let fit = min(outW / srcW, outH / srcH)
            fitW = srcW * fit
            fitH = srcH * fit
        }
        fitW *= xform.scaleX
        fitH *= xform.scaleY

        let centerXseq = outW * 0.5 + xform.positionX * outW
        let centerYseq = outH * 0.5 + xform.positionY * outH

        let sx = pictureRect.width  / outW
        let sy = pictureRect.height / outH
        let centerXview = pictureRect.minX + centerXseq * sx
        let centerYview = pictureRect.minY + centerYseq * sy
        let viewW = fitW * sx
        let viewH = fitH * sy
        return CGRect(
            x: centerXview - viewW / 2,
            y: centerYview - viewH / 2,
            width: viewW, height: viewH
        )
    }

    /// The visible sub-rect (after crop) in view coords — sits inside
    /// `picture`. Returns `picture` when no crop is active.
    private func visibleAfterCrop(picture: CGRect, transform xform: ClipTransform) -> CGRect {
        let cropL = max(0.0, min(1.0, xform.cropLeft))
        let cropT = max(0.0, min(1.0, xform.cropTop))
        let cropR = max(0.0, min(1.0 - cropL, xform.cropRight))
        let cropB = max(0.0, min(1.0 - cropT, xform.cropBottom))
        let x = picture.minX + CGFloat(cropL) * picture.width
        let y = picture.minY + CGFloat(cropT) * picture.height
        let w = picture.width  * CGFloat(1.0 - cropL - cropR)
        let h = picture.height * CGFloat(1.0 - cropT - cropB)
        return CGRect(x: x, y: y, width: max(0, w), height: max(0, h))
    }

    // MARK: - Gestures

    private var centerDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStartTransform == nil {
                    dragStartTransform = workspace.clipTransform(placedClip.id) ?? .identity
                    workspace.beginUndoBatch()
                }
                guard let start = dragStartTransform else { return }
                // Convert pixel delta → normalized-sequence-coord delta.
                // positionX is in sequence-widths; pictureRect.width
                // maps to one sequence width.
                let dx = (value.location.x - value.startLocation.x) / pictureRect.width
                let dy = (value.location.y - value.startLocation.y) / pictureRect.height
                var t = start
                t.positionX = start.positionX + Double(dx)
                t.positionY = start.positionY + Double(dy)
                workspace.setClipTransformLight(placedClip.id, t)
            }
            .onEnded { _ in
                dragStartTransform = nil
                workspace.endUndoBatch()
                workspace.commitTransformEdits()
            }
    }

    @ViewBuilder
    private func cornerHandle(idx: Int, dest: CGRect) -> some View {
        let pos: CGPoint = {
            switch idx {
            case 0: return CGPoint(x: dest.minX, y: dest.minY)
            case 1: return CGPoint(x: dest.maxX, y: dest.minY)
            case 2: return CGPoint(x: dest.minX, y: dest.maxY)
            default: return CGPoint(x: dest.maxX, y: dest.maxY)
            }
        }()
        Rectangle()
            .fill(PreemTheme.accent)
            .frame(width: 10, height: 10)
            .position(pos)
            .onHover { hovering in
                if hovering {
                    let cursor: NSCursor
                    switch idx {
                    case 0, 3: cursor = NSCursor.crosshair      // TL / BR
                    case 1, 2: cursor = NSCursor.crosshair      // TR / BL
                    default:   cursor = NSCursor.arrow
                    }
                    cursor.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(cornerScaleGesture(idx: idx, dest: dest))
    }

    private func cornerScaleGesture(idx: Int, dest: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStartTransform == nil {
                    dragStartTransform = workspace.clipTransform(placedClip.id) ?? .identity
                    workspace.beginUndoBatch()
                }
                guard let start = dragStartTransform else { return }
                // Scale around the rect's center using the cursor's
                // distance from center vs. the start distance.
                let center = CGPoint(x: dest.midX, y: dest.midY)
                let startCorner: CGPoint = {
                    switch idx {
                    case 0: return CGPoint(x: dest.minX, y: dest.minY)
                    case 1: return CGPoint(x: dest.maxX, y: dest.minY)
                    case 2: return CGPoint(x: dest.minX, y: dest.maxY)
                    default: return CGPoint(x: dest.maxX, y: dest.maxY)
                    }
                }()
                let startD = max(1, hypot(startCorner.x - center.x, startCorner.y - center.y))
                let nowD = max(1, hypot(value.location.x - center.x, value.location.y - center.y))
                let ratio = nowD / startD
                var t = start
                t.scaleX = max(0.05, start.scaleX * Double(ratio))
                t.scaleY = max(0.05, start.scaleY * Double(ratio))
                workspace.setClipTransformLight(placedClip.id, t)
            }
            .onEnded { _ in
                dragStartTransform = nil
                workspace.endUndoBatch()
                workspace.commitTransformEdits()
            }
    }

    // MARK: - Edge handles (non-uniform scale)

    @ViewBuilder
    private func edgeHandle(idx: Int, dest: CGRect) -> some View {
        let pos: CGPoint = {
            switch idx {
            case 0: return CGPoint(x: dest.midX, y: dest.minY)  // T
            case 1: return CGPoint(x: dest.maxX, y: dest.midY)  // R
            case 2: return CGPoint(x: dest.midX, y: dest.maxY)  // B
            default: return CGPoint(x: dest.minX, y: dest.midY) // L
            }
        }()
        let isVertical = (idx == 1 || idx == 3) // R / L → horizontal scale = vertical-bar handle
        Rectangle()
            .fill(PreemTheme.accent.opacity(0.9))
            .frame(width: isVertical ? 4 : 16, height: isVertical ? 16 : 4)
            .position(pos)
            .onHover { hovering in
                if hovering {
                    let cursor: NSCursor = isVertical ? .resizeLeftRight : .resizeUpDown
                    cursor.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(edgeScaleGesture(idx: idx, dest: dest))
    }

    private func edgeScaleGesture(idx: Int, dest: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStartTransform == nil {
                    dragStartTransform = workspace.clipTransform(placedClip.id) ?? .identity
                    workspace.beginUndoBatch()
                }
                guard let start = dragStartTransform else { return }
                let center = CGPoint(x: dest.midX, y: dest.midY)
                // Scale from center on the dragged axis only. Ratio =
                // (cursor distance from center) / (start edge's distance
                // from center) on that axis.
                let isHorizontal = (idx == 1 || idx == 3)
                var t = start
                if isHorizontal {
                    let startD = max(1, abs(dest.width / 2))
                    let nowD = max(1, abs(value.location.x - center.x))
                    let ratio = nowD / startD
                    t.scaleX = max(0.05, start.scaleX * Double(ratio))
                } else {
                    let startD = max(1, abs(dest.height / 2))
                    let nowD = max(1, abs(value.location.y - center.y))
                    let ratio = nowD / startD
                    t.scaleY = max(0.05, start.scaleY * Double(ratio))
                }
                workspace.setClipTransformLight(placedClip.id, t)
            }
            .onEnded { _ in
                dragStartTransform = nil
                workspace.endUndoBatch()
                workspace.commitTransformEdits()
            }
    }

    // MARK: - Rotation grip

    @ViewBuilder
    private func rotationGrip(dest: CGRect) -> some View {
        let knobPos = CGPoint(x: dest.midX, y: dest.minY - 22)
        ZStack {
            // Connector line from top edge to the knob.
            Path { p in
                p.move(to: CGPoint(x: dest.midX, y: dest.minY))
                p.addLine(to: knobPos)
            }
            .stroke(PreemTheme.accent.opacity(0.7), lineWidth: 1)

            // The knob itself — a small circle.
            Circle()
                .fill(PreemTheme.accent)
                .frame(width: 10, height: 10)
                .position(knobPos)
                .onHover { hovering in
                    if hovering {
                        NSCursor.openHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
                .gesture(rotationGesture(center: CGPoint(x: dest.midX, y: dest.midY)))
        }
    }

    @State private var dragStartRotationAngle: Double?
    @State private var dragStartCursorAngle: Double?

    private func rotationGesture(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartTransform == nil {
                    let t = workspace.clipTransform(placedClip.id) ?? .identity
                    dragStartTransform = t
                    dragStartRotationAngle = t.rotationDegrees
                    // Initial cursor angle, measured from center. The
                    // grip starts above center so we offset by π/2 so a
                    // straight-up cursor reads as 0°.
                    let dx0 = Double(value.startLocation.x - center.x)
                    let dy0 = Double(value.startLocation.y - center.y)
                    dragStartCursorAngle = atan2(dy0, dx0) * 180.0 / .pi + 90.0
                    workspace.beginUndoBatch()
                }
                guard let startRot = dragStartRotationAngle,
                      let startCur = dragStartCursorAngle else { return }
                let dx = Double(value.location.x - center.x)
                let dy = Double(value.location.y - center.y)
                let curAngle = atan2(dy, dx) * 180.0 / .pi + 90.0
                var delta = curAngle - startCur
                // Wrap to (-180, 180] so small drags don't flip 360°.
                while delta > 180 { delta -= 360 }
                while delta < -180 { delta += 360 }
                let newAngle = startRot + delta
                workspace.setTransformParameterOnSelectionLight(.rotation, newAngle)
            }
            .onEnded { _ in
                dragStartTransform = nil
                dragStartRotationAngle = nil
                dragStartCursorAngle = nil
                workspace.endUndoBatch()
                workspace.commitTransformEdits()
            }
    }
}
