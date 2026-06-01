import Foundation
import AppKit
import PreemCore

/// The main timeline view. Quartz-drawn for M2 v0.1; will move to a
/// Metal-backed surface when clip counts make redraw cost matter.
///
/// Layout:
///   ┌───────────────────────────────────────────────────────┐
///   │ ┌──Lane controls──┐┌────Ruler───────────────────────┐│
///   │ │ V1  ●  🔒  M  S ││  | : : : : : : : : : : : : :  ││
///   │ ├─────────────────┤├──────────────────────────────────┤│
///   │ │ V1              ││  ▓▓▓▓▓▓▓     ▓▓▓▓▓             ▓▓▓│
///   │ ├─────────────────┤├──────────────────────────────────┤│
///   │ │ A1              ││  ▓▓▓▓▓▓▓     ▓▓▓▓▓             ▓▓▓│
///   │ └─────────────────┘└──────────────────────────────────┘│
///   │                          ↑ red playhead                │
///   └───────────────────────────────────────────────────────┘
public final class PreemTimelineView: NSView {

    /// Provides live peak level (0...1) for an audio track index.
    /// PreemAppUI wires this to TimelineAudioPipeline.peakLevel.
    public var audioTrackLevelProvider: ((Int) -> Float)?

    public struct Callbacks {
        /// `targetVideoTrackIndex` is 0 for V1, 1 for V2, etc. A value
        /// >= the sequence's current track count signals "create the
        /// required new tracks above" (Premiere-style drop-above).
        public var insertClip: ((ClipID, RationalTime, Int) -> Void)?
        /// Drop of a source-viewer-originated fragment with explicit
        /// (sourceStart, sourceDuration). The trailing Int is
        /// `targetVideoTrackIndex` (see `insertClip`).
        public var insertClipFragment: ((ClipID, Double, Double, RationalTime, Int) -> Void)?
        public var setPlayhead: ((RationalTime) -> Void)?
        public var selectClip: ((PlacedClipID, Bool) -> Void)?     // (id, additive)
        public var clearSelection: (() -> Void)?
        /// `targetTrack` carries the destination track of a vertical
        /// move. `(kind, index)`. Kind 0 = video, 1 = audio. Negative
        /// index = no change. Workspace ignores cross-kind moves
        /// (audio clip dragged into a video row, etc.).
        public var moveClip: ((PlacedClipID, RationalTime, MoveTargetTrack?) -> Void)?
        public var trimLeft: ((PlacedClipID, RationalTime) -> Void)?
        public var trimRight: ((PlacedClipID, RationalTime) -> Void)?
        /// Resolve a `ClipID` to a `ClipSource` so we can render the
        /// drag-ghost at the right duration before the drop commits.
        public var clipSourceForID: ((ClipID) -> ClipSource?)?
        public var requestToggleLink: (() -> Void)?
        public var requestUnlink: (() -> Void)?
        public var requestDeleteSelected: (() -> Void)?
        public var requestRippleDeleteSelected: (() -> Void)?
        /// Fired when the user clicks on empty space between clips on a
        /// track. The workspace stores the gap in `selectedGap`; the
        /// timeline view renders it highlighted; Delete ripples all
        /// tracks to close it.
        public var selectGap: ((GapSelection) -> Void)?

        /// Fired when the user clicks on the small grip between two
        /// abutting clips on a track (the "cut").
        public var selectCut: ((CutSelection) -> Void)?

        /// "Add Transition" requested from the right-click menu on a
        /// cut with no existing transition.
        public var requestAddTransition: ((CutSelection) -> Void)?
        public var requestRemoveTransition: ((CutSelection) -> Void)?

        /// Drag-resize of an existing transition's edge. `side` is 0 for
        /// left edge (outgoing clip's transitionOut), 1 for right
        /// (incoming clip's transitionIn). `newHalfSeconds` is the new
        /// half-duration for that side. Workspace clamps + applies.
        public var resizeTransitionEdge: ((CutSelection, Int, Double) -> Void)?

        /// Solo-fade right-click flow: the user picked a clip's edge.
        public var selectClipEdge: ((ClipEdgeSelection) -> Void)?
        public var requestAddFade: ((ClipEdgeSelection) -> Void)?
        public var requestRemoveFade: ((ClipEdgeSelection) -> Void)?
        /// Drag-resize of a solo fade's inner tip.
        public var resizeSoloFade: ((ClipEdgeSelection, Double) -> Void)?

        /// Trackpad magnify (pinch) zoom — workspace clamps + applies.
        public var setPixelsPerSecond: ((Double) -> Void)?

        /// Blade tool click on a specific clip: split THAT clip (and
        /// its linked siblings) at the click position. Other clips on
        /// other tracks are untouched.
        public var bladeClip: ((PlacedClipID, Double) -> Void)?
        public var didReceiveFocus: (() -> Void)?
        /// Called once at the start of a clip drag or trim gesture so
        /// the workspace can begin an undo batch.
        public var beginClipDragOrTrim: (() -> Void)?
        /// Called once when the gesture ends (mouse up). `clipID`
        /// identifies the clip that was dragged or trimmed so the
        /// workspace can finalize same-track overlaps (overwrite the
        /// underlying clips). nil for transition-edge drags.
        public var endClipDragOrTrim: ((PlacedClipID?) -> Void)?
        // Track-header button taps. `index` is the original (non-reversed)
        // index in `sequence.videoTracks` / `audioTracks`.
        public var requestToggleVideoEnabled: ((Int) -> Void)?
        public var requestToggleVideoLocked: ((Int) -> Void)?
        public var requestToggleAudioMuted: ((Int) -> Void)?
        public var requestToggleAudioSolo: ((Int) -> Void)?
        public var requestToggleAudioLocked: ((Int) -> Void)?
        /// Lane-header click (outside M/S/L). Sets that track as the
        /// exclusive target for 3-point source edits. The "T:Vn" chip
        /// follows the active target.
        public var requestSetVideoTarget: ((Int) -> Void)?
        public var requestSetAudioTarget: ((Int) -> Void)?
        public init() {}
    }

    /// Target track for a vertical-drag move. `kind` is 0 = video, 1 = audio.
    public struct MoveTargetTrack: Equatable {
        public var kind: Int        // 0 = video, 1 = audio
        public var index: Int
        public init(kind: Int, index: Int) { self.kind = kind; self.index = index }
    }

    /// Parsed form of a drag pasteboard payload.
    private struct DragPayload {
        let clipID: ClipID
        /// nil = no marks (full clip), Double = explicit sourceStart and duration
        let sourceStart: Double?
        let sourceDuration: Double?

        static func parse(_ string: String) -> DragPayload? {
            let parts = string.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard let uuid = UUID(uuidString: String(parts[0])) else { return nil }
            let clipID = ClipID(rawValue: uuid)
            if parts.count == 3,
               let start = Double(parts[1]),
               let duration = Double(parts[2]) {
                return DragPayload(clipID: clipID, sourceStart: start, sourceDuration: duration)
            }
            return DragPayload(clipID: clipID, sourceStart: nil, sourceDuration: nil)
        }
    }

    public var callbacks = Callbacks()

    public var sequence: Sequence? {
        didSet { needsDisplay = true }
    }

    public var clipSources: [ClipID: ClipSource] = [:] {
        didSet { needsDisplay = true }
    }

    /// Per-source audio peaks (one [Float] per source ClipID).
    /// Values are in [0, 1] and span the source's full duration.
    /// PreemAppUI snapshots these from `WorkspaceModel.previewCache`
    /// each `updateNSView` cycle.
    public var audioPeaks: [ClipID: [Float]] = [:] {
        didSet { needsDisplay = true }
    }

    /// Per-source thumbnail strips, evenly spaced across the source's
    /// full duration. PreemAppUI populates these from
    /// `WorkspaceModel.previewCache`.
    public var videoThumbnails: [ClipID: [CGImage]] = [:] {
        didSet { needsDisplay = true }
    }

    public var playheadTime: RationalTime = .zero {
        // Reposition the playhead overlay layer only — no full redraw.
        didSet { positionPlayheadLayer() }
    }

    /// Per-frame playhead drive during playback. Moves the overlay layer
    /// instead of repainting the timeline.
    public func movePlayhead(to time: RationalTime) {
        guard time != playheadTime else { return }
        playheadTime = time
    }

    public var selectedClipIDs: Set<PlacedClipID> = [] {
        didSet { needsDisplay = true }
    }

    public var selectedGap: GapSelection? {
        didSet { needsDisplay = true }
    }

    public var selectedCut: CutSelection? {
        didSet { needsDisplay = true }
    }

    public var selectedClipEdge: ClipEdgeSelection? {
        didSet { needsDisplay = true }
    }

    /// Mirrors `PreemSettings.shared.snappingEnabled`. When false, drag
    /// math doesn't snap; N toggles in the SwiftUI key monitor.
    public var snappingEnabled: Bool = true {
        didSet { needsDisplay = true }
    }

    /// Active timeline tool. With `.blade` a click slices clips at the
    /// click position instead of selecting / dragging them.
    public var activeTool: ActiveTool = .pointer {
        didSet {
            needsDisplay = true
            // Cursor reflects the tool immediately even before the
            // mouse moves — the user expects a B-key tap to flip the
            // cursor right away.
            if activeTool == .blade {
                Self.bladeCursor.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    /// Custom cursor for the blade tool — a single-pixel-thin razor
    /// drawn into a small image so the cursor renders reliably (SF
    /// Symbols don't play well with NSCursor's pixel pipeline). The
    /// tip is the hot spot so the cut lines up with the cursor's
    /// pointy bottom edge.
    private static let bladeCursor: NSCursor = {
        let size = NSSize(width: 18, height: 24)
        let img = NSImage(size: size)
        img.lockFocus()
        // Outline (black) drawn first so the white razor stays
        // legible over both light and dark timeline backgrounds.
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: 9, y: 22))
        outline.line(to: NSPoint(x: 7, y: 6))
        outline.line(to: NSPoint(x: 9, y: 0))
        outline.line(to: NSPoint(x: 11, y: 6))
        outline.line(to: NSPoint(x: 9, y: 22))
        outline.close()
        NSColor.black.setStroke()
        outline.lineWidth = 2
        outline.stroke()
        // Inner blade fill
        let blade = NSBezierPath()
        blade.move(to: NSPoint(x: 9, y: 22))
        blade.line(to: NSPoint(x: 8, y: 6))
        blade.line(to: NSPoint(x: 9, y: 0))
        blade.line(to: NSPoint(x: 10, y: 6))
        blade.close()
        NSColor.white.setFill()
        blade.fill()
        img.unlockFocus()
        img.isTemplate = false
        return NSCursor(image: img, hotSpot: NSPoint(x: 9, y: 0))
    }()

    // MARK: - Layout metrics

    private enum Metrics {
        static let rulerHeight: CGFloat = 26
        static let laneControlsWidth: CGFloat = 120
        static let trackHeight: CGFloat = 44
        static let trackSpacing: CGFloat = 2
        static let separatorHeight: CGFloat = 4
    }

    // MARK: - State

    public var pixelsPerSecond: Double = 60 {
        didSet { needsDisplay = true }
    }
    private var scrollOffsetSeconds: Double = 0

    /// Pre-rendered cache spans (start, end) in seconds. Drawn as a
    /// thin green bar atop the ruler. Pushed in from PreemAppUI each
    /// `updateNSView`, sourced from `WorkspaceModel.cacheSegmentsForActiveSequence`.
    public var cacheSegmentsSeconds: [(start: Double, end: Double)] = [] {
        didSet {
            // Treat as changed only if the count or any boundary moved
            // — otherwise the timeline thrashes on every observed tick.
            if oldValue.count != cacheSegmentsSeconds.count {
                needsDisplay = true
                return
            }
            for i in 0..<cacheSegmentsSeconds.count {
                if cacheSegmentsSeconds[i].start != oldValue[i].start
                    || cacheSegmentsSeconds[i].end != oldValue[i].end {
                    needsDisplay = true
                    return
                }
            }
        }
    }

    /// Clamp range for zoom (px/s). The lower bound keeps a full clip
    /// visible at extreme zoom-out; the upper bound is large enough
    /// to show single frames as wide rectangles at the highest zoom.
    public static let minPixelsPerSecond: Double = 4
    public static let maxPixelsPerSecond: Double = 800

    private static let trimGripWidth: CGFloat = 6
    private static let snapThresholdPixels: CGFloat = 8

    private enum Interaction {
        case idle
        case scrubbing
        case draggingClip(
            id: PlacedClipID,
            grabOffsetSeconds: Double,
            originalStartSeconds: Double,
            originalTrack: MoveTargetTrack?,
            currentTrack: MoveTargetTrack?
        )
        case trimmingLeft(id: PlacedClipID, originalStartSeconds: Double)
        case trimmingRight(id: PlacedClipID, originalEndSeconds: Double)
        /// Dragging an edge of an existing transition wedge. `side` 0 =
        /// left (changes outgoing.transitionOut), 1 = right (incoming
        /// .transitionIn). The cut location is fixed during this drag.
        case draggingTransitionEdge(cut: CutSelection, side: Int)
        /// Dragging the inner tip of a solo fade triangle to resize it.
        case draggingSoloFadeTip(edge: ClipEdgeSelection, clipStart: Double, clipEnd: Double)
        /// Rubber-band selection box. Drag through empty timeline space
        /// to select every clip whose laid-out rect intersects.
        case boxSelecting(startPoint: CGPoint, currentPoint: CGPoint)
    }
    private var interaction: Interaction = .idle

    /// While a clip is being dragged, this carries (clipID,
    /// destination-track-y) so drawTracks can render the clip at the
    /// cursor's row instead of its actual model row. Track moves are
    /// committed on mouseUp, not on every tick.
    private struct FloatingDraggedClip {
        var clipID: PlacedClipID
        var targetTrack: MoveTargetTrack       // where to render this tick
        var originalTrack: MoveTargetTrack     // for change detection on release
    }
    private var floatingDraggedClip: FloatingDraggedClip?

    private struct LaidOutClip {
        var rect: CGRect
        var clipID: PlacedClipID
        var startSeconds: Double
        var endSeconds: Double
    }
    private var laidOutClips: [LaidOutClip] = []

    /// Per-track abutting-cut hit zone. Drawn whether or not a
    /// transition exists; click selects the cut, right-click offers
    /// "Add / Remove Transition."
    private struct LaidOutCut {
        var rect: CGRect
        var cutSeconds: Double
        var trackKind: Int
        var trackIndex: Int
        var leftClipID: PlacedClipID
        var rightClipID: PlacedClipID
        var leftHalfSeconds: Double?    // nil = no outgoing transition on left clip
        var rightHalfSeconds: Double?   // nil = no incoming transition on right clip
        var hasTransition: Bool { leftHalfSeconds != nil || rightHalfSeconds != nil }
    }
    private var laidOutCuts: [LaidOutCut] = []

    /// Per-track laid-out cross-dissolve wedge with edge drag rects.
    private struct LaidOutTransition {
        var rect: CGRect
        var leftHandleRect: CGRect
        var rightHandleRect: CGRect
        var cutSeconds: Double
        var trackKind: Int
        var trackIndex: Int
        var leftClipID: PlacedClipID
        var rightClipID: PlacedClipID
        var leftHalfSeconds: Double
        var rightHalfSeconds: Double
    }
    private var laidOutTransitions: [LaidOutTransition] = []

    /// Per-track laid-out solo fade (clip's transitionIn or transitionOut
    /// with no paired partner). Used for hover, click selection, and the
    /// drag-resize at the fade's inner tip.
    private struct LaidOutSoloFade {
        var tipHandleRect: CGRect
        var wedgeRect: CGRect
        var clipRect: CGRect
        var edge: ClipEdgeSelection
        var currentDurationSeconds: Double
        var clipStartSeconds: Double
        var clipEndSeconds: Double
    }
    private var laidOutSoloFades: [LaidOutSoloFade] = []

    private static let cutGripWidth: CGFloat = 6
    private static let transitionEdgeGripWidth: CGFloat = 6
    private static let soloFadeTipGripWidth: CGFloat = 6

    /// Set while an external drag is hovering the timeline. Used to draw
    /// a translucent preview of the clip's V+A footprint at the cursor.
    private struct DragGhost {
        var clipID: ClipID
        var source: ClipSource
        var startSeconds: Double          // snapped drop time
        var durationSeconds: Double       // marked range length, or full clip
        /// Phantom-track depth above V1: 0 = land on V1, 1 = create V2,
        /// 2 = create V3, etc. Computed from cursor Y position.
        var newVideoTracksAbove: Int
    }
    private var dragGhost: DragGhost?

    // Playhead is a CALayer overlay, not drawn in draw(rect:). Moving it
    // during playback repositions the layer instead of repainting the
    // whole 4K timeline every frame (the playback-staccato cause).
    private let playheadLineLayer = CALayer()
    private let playheadTriLayer = CAShapeLayer()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 1.0).cgColor
        setupPlayheadLayers()
        registerForDraggedTypes([.string])
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupPlayheadLayers()
        registerForDraggedTypes([.string])
    }

    private func setupPlayheadLayers() {
        playheadLineLayer.backgroundColor = NSColor.systemRed.cgColor
        playheadLineLayer.zPosition = 1000
        playheadLineLayer.isHidden = true
        playheadTriLayer.fillColor = NSColor.systemRed.cgColor
        playheadTriLayer.zPosition = 1000
        playheadTriLayer.isHidden = true
        layer?.addSublayer(playheadLineLayer)
        layer?.addSublayer(playheadTriLayer)
    }

    private func positionPlayheadLayer() {
        guard let host = layer else { return }
        let x = xForTime(playheadTime.seconds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard x >= Metrics.laneControlsWidth else {
            playheadLineLayer.isHidden = true
            playheadTriLayer.isHidden = true
            return
        }
        let h = bounds.height
        playheadLineLayer.isHidden = false
        playheadTriLayer.isHidden = false
        playheadLineLayer.frame = CGRect(x: x - 0.625, y: 0, width: 1.25, height: h)
        // Triangle handle at the visible TOP of the ruler. The backing
        // layer's geometry may or may not be flipped to match the view;
        // honor whichever so the handle sits at the top either way.
        let flipped = host.isGeometryFlipped
        let topY: CGFloat = flipped ? 0 : h
        let tipY: CGFloat = flipped ? 8 : h - 8
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x - 5, y: topY))
        p.addLine(to: CGPoint(x: x + 5, y: topY))
        p.addLine(to: CGPoint(x: x, y: tipY))
        p.closeSubpath()
        playheadTriLayer.frame = bounds
        playheadTriLayer.path = p
    }

    // MARK: - Hover tracking

    private var hoveredClipEdge: ClipEdgeSelection? {
        didSet {
            if hoveredClipEdge != oldValue { needsDisplay = true }
        }
    }
    private var hoverTrackingArea: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Blade tool wins regardless of what's under the cursor —
        // the only useful gesture is a click anywhere on a clip.
        if activeTool == .blade {
            hoveredClipEdge = nil
            Self.bladeCursor.set()
            return
        }
        if let hit = clipEdgeHitTest(p) {
            hoveredClipEdge = ClipEdgeSelection(
                clipID: hit.clipID, trackKind: hit.trackKind,
                trackIndex: hit.trackIndex, side: hit.side
            )
            NSCursor.resizeLeftRight.set()
            return
        }
        hoveredClipEdge = nil
        if soloFadeTipHitTest(p) != nil
            || transitionEdgeHitTest(p) != nil {
            NSCursor.resizeLeftRight.set()
            return
        }
        NSCursor.arrow.set()
    }

    public override func magnify(with event: NSEvent) {
        // NSEvent.magnification is the incremental scale delta. Apply
        // it multiplicatively so a series of pinch ticks compounds the
        // way a slider scrub would. Clamp to the view's bounds.
        let factor = 1.0 + event.magnification
        let target = max(Self.minPixelsPerSecond,
                         min(Self.maxPixelsPerSecond, pixelsPerSecond * factor))
        if target != pixelsPerSecond {
            callbacks.setPixelsPerSecond?(target)
        }
    }

    public override func mouseExited(with event: NSEvent) {
        hoveredClipEdge = nil
        // Blade leaves the crosshair cursor sticky until we re-enter.
        if activeTool != .blade {
            NSCursor.arrow.set()
        }
    }

    public override var isFlipped: Bool { true }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        laidOutClips.removeAll(keepingCapacity: true)
        laidOutCuts.removeAll(keepingCapacity: true)
        laidOutTransitions.removeAll(keepingCapacity: true)
        laidOutSoloFades.removeAll(keepingCapacity: true)

        drawBackground(ctx: ctx)
        drawRuler(ctx: ctx)

        if let sequence {
            drawLaneControls(ctx: ctx, sequence: sequence)
            drawTracks(ctx: ctx, sequence: sequence)
        } else {
            drawEmptyState(ctx: ctx)
        }

        if let sequence {
            drawInOutMarks(ctx: ctx, sequence: sequence)
        }
        drawCacheBars(ctx: ctx)
        drawDragGhost(ctx: ctx)
        drawBoxSelection(ctx: ctx)
        // Playhead is a CALayer overlay; reposition it here so a full
        // redraw (scroll / zoom / resize) keeps it aligned.
        positionPlayheadLayer()
    }

    /// Thin green bar at the bottom of the ruler showing pre-rendered
    /// ranges for the active sequence.
    private func drawCacheBars(ctx: CGContext) {
        guard !cacheSegmentsSeconds.isEmpty else { return }
        let timelineMinX = Metrics.laneControlsWidth
        let timelineMaxX = bounds.width
        let barHeight: CGFloat = 3
        let barY = Metrics.rulerHeight - barHeight - 1
        for seg in cacheSegmentsSeconds {
            let xStart = max(timelineMinX, xForTime(seg.start))
            let xEnd   = min(timelineMaxX, xForTime(seg.end))
            guard xEnd > xStart else { continue }
            let rect = CGRect(x: xStart, y: barY, width: xEnd - xStart, height: barHeight)
            ctx.setFillColor(NSColor.systemGreen.withAlphaComponent(0.85).cgColor)
            ctx.fill(rect)
        }
    }

    private func drawInOutMarks(ctx: CGContext, sequence: Sequence) {
        let inSec = sequence.inMark?.seconds
        let outSec = sequence.outMark?.seconds

        let timelineMinX = Metrics.laneControlsWidth
        let timelineMaxX = bounds.width
        let trackBandY = Metrics.rulerHeight
        let trackBandHeight = bounds.height - Metrics.rulerHeight

        // Ruler band (above the ticks). Shade between in/out, or
        // open-ended toward the matching edge when only one is set.
        if inSec != nil || outSec != nil {
            let xIn  = inSec.map  { max(timelineMinX, xForTime($0)) } ?? timelineMinX
            let xOut = outSec.map { min(timelineMaxX, xForTime($0)) } ?? timelineMaxX
            if xOut > xIn {
                let rulerBand = CGRect(
                    x: xIn, y: 0,
                    width: xOut - xIn,
                    height: 5
                )
                ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.55).cgColor)
                ctx.fill(rulerBand)

                // Faint vertical wash across the track area so editors
                // can see at a glance which clips are inside the range.
                let trackWash = CGRect(
                    x: xIn, y: trackBandY,
                    width: xOut - xIn,
                    height: trackBandHeight
                )
                ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.06).cgColor)
                ctx.fill(trackWash)
            }
        }

        // Bracket markers in the ruler at each mark.
        if let s = inSec {
            let x = xForTime(s)
            if x >= timelineMinX - 0.5 {
                drawMarkBracket(ctx: ctx, x: x, isIn: true)
            }
        }
        if let s = outSec {
            let x = xForTime(s)
            if x >= timelineMinX - 0.5 {
                drawMarkBracket(ctx: ctx, x: x, isIn: false)
            }
        }
    }

    /// Bracket-shaped marker drawn in the ruler. `isIn=true` opens to
    /// the right (like Premiere's In), `isIn=false` opens to the left.
    private func drawMarkBracket(ctx: CGContext, x: CGFloat, isIn: Bool) {
        let topY: CGFloat = 6
        let height: CGFloat = Metrics.rulerHeight - 8
        let armLen: CGFloat = 6
        let dir: CGFloat = isIn ? 1 : -1
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineCap(.square)
        ctx.move(to: CGPoint(x: x, y: topY))
        ctx.addLine(to: CGPoint(x: x, y: topY + height))
        ctx.strokePath()
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: x, y: topY))
        ctx.addLine(to: CGPoint(x: x + dir * armLen, y: topY))
        ctx.move(to: CGPoint(x: x, y: topY + height))
        ctx.addLine(to: CGPoint(x: x + dir * armLen, y: topY + height))
        ctx.strokePath()
        ctx.setLineCap(.butt)
    }

    private func drawBoxSelection(ctx: CGContext) {
        guard case .boxSelecting(let startPoint, let currentPoint) = interaction else { return }
        let rect = CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
        guard rect.width > 1, rect.height > 1 else { return }
        ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(0.10).cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        ctx.setLineDash(phase: 0, lengths: [])
    }

    private func drawDragGhost(ctx: CGContext) {
        guard let ghost = dragGhost, let sequence else { return }

        let durationSeconds = ghost.durationSeconds
        guard durationSeconds > 0 else { return }

        let startX = xForTime(ghost.startSeconds)
        let widthPx = CGFloat(durationSeconds * pixelsPerSecond)
        guard startX + widthPx > Metrics.laneControlsWidth else { return }

        // Find V1 + A1 vertical positions by walking the lane stack.
        var y = Metrics.rulerHeight
        var v1Y: CGFloat?
        var a1Y: CGFloat?
        for lane in enumeratedLanes(sequence: sequence) {
            switch lane {
            case .separator:
                y += Metrics.separatorHeight
            case .video(let track):
                if v1Y == nil, track.id == sequence.videoTracks.first?.id { v1Y = y }
                y += Metrics.trackHeight + Metrics.trackSpacing
            case .audio(let track):
                if a1Y == nil, track.id == sequence.audioTracks.first?.id { a1Y = y }
                y += Metrics.trackHeight + Metrics.trackSpacing
            }
        }

        // If the ghost is above V1 (phantom tracks), shift the ghost's
        // video target row UP by one trackHeight per phantom level.
        // The audio still lands on A1.
        if ghost.newVideoTracksAbove > 0, let existingV1 = v1Y {
            let bandHeight = Metrics.trackHeight + Metrics.trackSpacing
            // Render the phantom-track outline + a "new track" hint
            let phantomY = existingV1 - bandHeight * CGFloat(ghost.newVideoTracksAbove)
            drawPhantomTrackHint(
                ctx: ctx,
                yTop: phantomY,
                label: "+ V\(sequence.videoTracks.count + ghost.newVideoTracksAbove)"
            )
            v1Y = phantomY
        }

        // Snap-line: vertical highlight at the drop-time so the user can
        // line up with edit points / zero / other clips.
        ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.move(to: CGPoint(x: startX, y: Metrics.rulerHeight))
        ctx.addLine(to: CGPoint(x: startX, y: bounds.height))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // Ghost rect on V1 + A1
        let hasVideo = !ghost.source.videoTracks.isEmpty
        let hasAudio = !ghost.source.audioTracks.isEmpty

        if hasVideo, let yV = v1Y {
            drawGhostRect(
                ctx: ctx,
                rect: CGRect(x: startX, y: yV + 2, width: widthPx, height: Metrics.trackHeight - 4),
                fill: NSColor.systemBlue,
                label: ghost.source.name + "  (V)"
            )
        }
        if hasAudio, let yA = a1Y {
            drawGhostRect(
                ctx: ctx,
                rect: CGRect(x: startX, y: yA + 2, width: widthPx, height: Metrics.trackHeight - 4),
                fill: NSColor.systemTeal,
                label: ghost.source.name + "  (A)"
            )
        }

        // Drop-time readout above the ruler line
        let timeLabel = formatRulerTime(ghost.startSeconds)
        let readoutAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.systemYellow,
        ]
        let textSize = (timeLabel as NSString).size(withAttributes: readoutAttrs)
        let badgeRect = CGRect(
            x: startX + 4,
            y: 4,
            width: textSize.width + 10,
            height: textSize.height + 4
        )
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 3, yRadius: 3)
        badgePath.fill()
        (timeLabel as NSString).draw(
            at: CGPoint(x: badgeRect.minX + 5, y: badgeRect.minY + 2),
            withAttributes: readoutAttrs
        )
    }

    private func drawPhantomTrackHint(ctx: CGContext, yTop: CGFloat, label: String) {
        let rect = CGRect(
            x: 0,
            y: yTop,
            width: bounds.width,
            height: Metrics.trackHeight
        )
        // Dashed accent-tinted band for the phantom lane
        ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(rect.insetBy(dx: 1, dy: 1))
        ctx.setLineDash(phase: 0, lengths: [])

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.systemYellow,
        ]
        (label as NSString).draw(
            at: CGPoint(x: 10, y: yTop + (Metrics.trackHeight - 14) / 2),
            withAttributes: attrs
        )
    }

    private func drawGhostRect(ctx: CGContext, rect: CGRect, fill: NSColor, label: String) {
        ctx.setFillColor(fill.withAlphaComponent(0.32).cgColor)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        path.fill()

        ctx.setStrokeColor(fill.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        path.stroke()
        ctx.setLineDash(phase: 0, lengths: [])

        if rect.width > 40 {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            ]
            (label as NSString).draw(in: rect.insetBy(dx: 8, dy: 4), withAttributes: attrs)
        }
    }

    private func drawBackground(ctx: CGContext) {
        ctx.setFillColor(NSColor(white: 0.10, alpha: 1.0).cgColor)
        ctx.fill(bounds)

        // Lane controls strip
        ctx.setFillColor(NSColor(white: 0.16, alpha: 1.0).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: Metrics.laneControlsWidth, height: bounds.height))

        // Hairline between lane controls and timeline
        ctx.setStrokeColor(NSColor(white: 0.0, alpha: 1.0).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: Metrics.laneControlsWidth - 0.5, y: 0))
        ctx.addLine(to: CGPoint(x: Metrics.laneControlsWidth - 0.5, y: bounds.height))
        ctx.strokePath()
    }

    private func drawEmptyState(ctx: CGContext) {
        let title = "No sequence"
        let subtitle = "Create a sequence to begin  (⌘N)"
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor(white: 0.55, alpha: 1.0),
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(white: 0.45, alpha: 1.0),
        ]
        let titleSize = (title as NSString).size(withAttributes: titleAttrs)
        let subSize = (subtitle as NSString).size(withAttributes: subAttrs)

        let centerX = (bounds.width + Metrics.laneControlsWidth) / 2
        let centerY = bounds.height / 2

        (title as NSString).draw(
            at: CGPoint(x: centerX - titleSize.width / 2, y: centerY - titleSize.height),
            withAttributes: titleAttrs
        )
        (subtitle as NSString).draw(
            at: CGPoint(x: centerX - subSize.width / 2, y: centerY + 6),
            withAttributes: subAttrs
        )
    }

    private func drawRuler(ctx: CGContext) {
        let rulerRect = CGRect(x: Metrics.laneControlsWidth, y: 0, width: bounds.width - Metrics.laneControlsWidth, height: Metrics.rulerHeight)
        ctx.setFillColor(NSColor(white: 0.14, alpha: 1.0).cgColor)
        ctx.fill(rulerRect)

        // Bottom border
        ctx.setStrokeColor(NSColor(white: 0.0, alpha: 1.0).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: rulerRect.minX, y: rulerRect.maxY - 0.5))
        ctx.addLine(to: CGPoint(x: rulerRect.maxX, y: rulerRect.maxY - 0.5))
        ctx.strokePath()

        // Tick marks + labels.
        let tickInterval = adaptiveTickInterval()
        let startSec = floor(scrollOffsetSeconds / tickInterval) * tickInterval
        let endSec = scrollOffsetSeconds + Double(rulerRect.width) / pixelsPerSecond

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor(white: 0.6, alpha: 1.0),
        ]

        ctx.setStrokeColor(NSColor(white: 0.35, alpha: 1.0).cgColor)
        ctx.setLineWidth(1)

        var t = startSec
        while t < endSec {
            let x = xForTime(t)
            if x >= rulerRect.minX {
                ctx.move(to: CGPoint(x: x, y: rulerRect.maxY - 6))
                ctx.addLine(to: CGPoint(x: x, y: rulerRect.maxY))
                ctx.strokePath()

                let label = formatRulerTime(t)
                (label as NSString).draw(
                    at: CGPoint(x: x + 3, y: rulerRect.minY + 6),
                    withAttributes: labelAttrs
                )
            }
            t += tickInterval
        }
    }

    private enum HeaderButtonKind { case mute, solo, lock }

    private struct HeaderButton {
        var rect: CGRect
        var kind: HeaderButtonKind
        var trackIsVideo: Bool
        var trackIndex: Int        // original (non-reversed) index
    }
    private var laidOutHeaderButtons: [HeaderButton] = []

    /// Whole-lane header rect for click-to-target. Hit-tested after the
    /// header-button rects so M/S/L still win.
    private struct HeaderRow {
        var rect: CGRect
        var trackIsVideo: Bool
        var trackIndex: Int
    }
    private var laidOutHeaderRows: [HeaderRow] = []

    /// Target-chip rects so tooltips can be (re-)installed after each
    /// redraw. Currently used for the "Source target" hover label.
    private var laidOutTargetChipRects: [CGRect] = []

    private func drawLaneControls(ctx: CGContext, sequence: Sequence) {
        laidOutHeaderButtons.removeAll(keepingCapacity: true)
        laidOutHeaderRows.removeAll(keepingCapacity: true)
        laidOutTargetChipRects.removeAll(keepingCapacity: true)
        var y = Metrics.rulerHeight
        let lanes = enumeratedLanes(sequence: sequence)
        for lane in lanes {
            switch lane {
            case .separator:
                ctx.setFillColor(NSColor(white: 0.0, alpha: 1.0).cgColor)
                ctx.fill(CGRect(x: 0, y: y, width: bounds.width, height: Metrics.separatorHeight))
                y += Metrics.separatorHeight
            case .video(let track):
                drawHeader(
                    ctx: ctx, atY: y, name: track.name,
                    isVideo: true,
                    isMuted: !track.isEnabled,
                    isSolo: false,
                    isLocked: track.isLocked,
                    isTargeted: track.isTargeted,
                    trackIndex: sequence.videoTracks.firstIndex(where: { $0.id == track.id }) ?? 0,
                    audioLevel: nil
                )
                y += Metrics.trackHeight + Metrics.trackSpacing
            case .audio(let track):
                let level = audioTrackLevelProvider?(sequence.audioTracks.firstIndex(where: { $0.id == track.id }) ?? 0) ?? 0
                drawHeader(
                    ctx: ctx, atY: y, name: track.name,
                    isVideo: false,
                    isMuted: track.isMuted || !track.isEnabled,
                    isSolo: track.isSolo,
                    isLocked: track.isLocked,
                    isTargeted: track.isTargeted,
                    trackIndex: sequence.audioTracks.firstIndex(where: { $0.id == track.id }) ?? 0,
                    audioLevel: level
                )
                y += Metrics.trackHeight + Metrics.trackSpacing
            }
        }
        syncTargetChipTooltips()
    }

    /// Rebuild tooltip rects so each target chip surfaces "Source target"
    /// on hover. Cheap — there are at most one V and one A chip.
    private func syncTargetChipTooltips() {
        removeAllToolTips()
        for rect in laidOutTargetChipRects {
            addToolTip(rect, owner: "Source target" as NSString, userData: nil)
        }
    }

    private func drawHeader(
        ctx: CGContext,
        atY y: CGFloat,
        name: String,
        isVideo: Bool,
        isMuted: Bool,
        isSolo: Bool,
        isLocked: Bool,
        isTargeted: Bool,
        trackIndex: Int,
        audioLevel: Float?
    ) {
        // Name label
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(white: 0.78, alpha: 1.0),
        ]
        let nameSize = (name as NSString).size(withAttributes: nameAttrs)
        (name as NSString).draw(at: CGPoint(x: 8, y: y + 4), withAttributes: nameAttrs)

        // Target chip — only drawn on the currently-targeted row. Sits
        // immediately right of the name and carries the track designator
        // ("V1", "A1"). Hover shows "Source target". Clicking anywhere
        // in the lane header band sets that row as the target.
        if isTargeted {
            let chipAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let chipTextSize = (name as NSString).size(withAttributes: chipAttrs)
            let chipRect = CGRect(
                x: 8 + nameSize.width + 6,
                y: y + 5,
                width: chipTextSize.width + 8,
                height: chipTextSize.height + 2
            )
            ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.85).cgColor)
            NSBezierPath(roundedRect: chipRect, xRadius: 3, yRadius: 3).fill()
            (name as NSString).draw(
                at: CGPoint(x: chipRect.minX + 4, y: chipRect.minY + 1),
                withAttributes: chipAttrs
            )
            laidOutTargetChipRects.append(chipRect)
        }

        // Button row (right side of lane controls). Right-to-left layout
        // so the rightmost stays anchored as we add buttons.
        let buttonY = y + Metrics.trackHeight - 18
        let buttonSize: CGFloat = 14
        let spacing: CGFloat = 2
        var bx = Metrics.laneControlsWidth - 4 - buttonSize

        // Lock (rightmost)
        let lockRect = CGRect(x: bx, y: buttonY, width: buttonSize, height: buttonSize)
        drawHeaderButton(ctx: ctx, rect: lockRect, label: "L", active: isLocked, color: .systemOrange)
        laidOutHeaderButtons.append(HeaderButton(rect: lockRect, kind: .lock, trackIsVideo: isVideo, trackIndex: trackIndex))
        bx -= (buttonSize + spacing)

        // Solo (only on audio)
        if !isVideo {
            let soloRect = CGRect(x: bx, y: buttonY, width: buttonSize, height: buttonSize)
            drawHeaderButton(ctx: ctx, rect: soloRect, label: "S", active: isSolo, color: .systemYellow)
            laidOutHeaderButtons.append(HeaderButton(rect: soloRect, kind: .solo, trackIsVideo: false, trackIndex: trackIndex))
            bx -= (buttonSize + spacing)
        }

        // Mute / Output toggle
        let muteRect = CGRect(x: bx, y: buttonY, width: buttonSize, height: buttonSize)
        drawHeaderButton(ctx: ctx, rect: muteRect, label: "M", active: isMuted, color: .systemRed)
        laidOutHeaderButtons.append(HeaderButton(rect: muteRect, kind: .mute, trackIsVideo: isVideo, trackIndex: trackIndex))

        // Record the full lane-header band so a click outside the
        // buttons targets this row.
        laidOutHeaderRows.append(HeaderRow(
            rect: CGRect(x: 0, y: y, width: Metrics.laneControlsWidth, height: Metrics.trackHeight),
            trackIsVideo: isVideo,
            trackIndex: trackIndex
        ))

        // Audio meter bar (left of buttons, on audio tracks)
        if let level = audioLevel {
            let meterRect = CGRect(
                x: 8,
                y: y + Metrics.trackHeight - 8,
                width: Metrics.laneControlsWidth - 16 - CGFloat(laidOutHeaderButtons.filter { $0.trackIsVideo == isVideo && $0.trackIndex == trackIndex }.count) * (buttonSize + spacing) - 4,
                height: 4
            )
            ctx.setFillColor(NSColor(white: 0.05, alpha: 1.0).cgColor)
            ctx.fill(meterRect)
            let clamped = CGFloat(max(0, min(1, level)))
            let fillWidth = meterRect.width * clamped
            let fillRect = CGRect(x: meterRect.minX, y: meterRect.minY, width: fillWidth, height: meterRect.height)
            // Gradient color: green → yellow → red based on level
            let fillColor: NSColor
            if clamped < 0.7 {
                fillColor = .systemGreen
            } else if clamped < 0.9 {
                fillColor = .systemYellow
            } else {
                fillColor = .systemRed
            }
            ctx.setFillColor(fillColor.cgColor)
            ctx.fill(fillRect)
        }
    }

    private func drawHeaderButton(ctx: CGContext, rect: CGRect, label: String, active: Bool, color: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        if active {
            ctx.setFillColor(color.cgColor)
            path.fill()
        } else {
            ctx.setFillColor(NSColor(white: 0.22, alpha: 1.0).cgColor)
            path.fill()
            ctx.setStrokeColor(NSColor(white: 0.35, alpha: 1.0).cgColor)
            ctx.setLineWidth(1)
            path.stroke()
        }
        let textColor: NSColor = active ? .white : NSColor(white: 0.7, alpha: 1.0)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: textColor,
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attrs
        )
    }

    private func drawTracks(ctx: CGContext, sequence: Sequence) {
        // Clip the timeline content to the area RIGHT of the lane
        // controls. Without this, scrolled-back clips paint over the
        // track headers (V1/A1 etc. + their mute/solo/lock buttons).
        ctx.saveGState()
        let timelineColumn = CGRect(
            x: Metrics.laneControlsWidth,
            y: Metrics.rulerHeight,
            width: bounds.width - Metrics.laneControlsWidth,
            height: bounds.height - Metrics.rulerHeight
        )
        ctx.clip(to: timelineColumn)
        defer { ctx.restoreGState() }

        var y = Metrics.rulerHeight
        let lanes = enumeratedLanes(sequence: sequence)
        for lane in lanes {
            switch lane {
            case .separator:
                y += Metrics.separatorHeight
            case .video(let track):
                drawTrackBackground(ctx: ctx, atY: y, isAudio: false)
                let originalIndex = sequence.videoTracks.firstIndex(where: { $0.id == track.id }) ?? 0
                drawSelectedGap(ctx: ctx, atY: y, trackKind: 0, trackIndex: originalIndex)
                drawClips(ctx: ctx, clips: track.clips, atY: y, isAudio: false, trackIndex: originalIndex)
                y += Metrics.trackHeight + Metrics.trackSpacing
            case .audio(let track):
                drawTrackBackground(ctx: ctx, atY: y, isAudio: true)
                let originalIndex = sequence.audioTracks.firstIndex(where: { $0.id == track.id }) ?? 0
                drawSelectedGap(ctx: ctx, atY: y, trackKind: 1, trackIndex: originalIndex)
                drawClips(ctx: ctx, clips: track.clips, atY: y, isAudio: true, trackIndex: originalIndex)
                y += Metrics.trackHeight + Metrics.trackSpacing
            }
        }

        // Floating-dragged-clip overlay (above all other clip rendering)
        drawFloatingDraggedClip(ctx: ctx, sequence: sequence)
    }

    private func drawSelectedGap(ctx: CGContext, atY y: CGFloat, trackKind: Int, trackIndex: Int) {
        guard let gap = selectedGap,
              gap.trackKind == trackKind,
              gap.trackIndex == trackIndex else { return }
        let x = xForTime(gap.startSeconds)
        let w = gap.durationSeconds * pixelsPerSecond
        guard w > 0 else { return }
        let rect = CGRect(x: x, y: y + 2, width: CGFloat(w), height: Metrics.trackHeight - 4)
        ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(0.22).cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.25)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        ctx.setLineDash(phase: 0, lengths: [])
    }

    private func drawFloatingDraggedClip(ctx: CGContext, sequence: Sequence) {
        guard let floating = floatingDraggedClip,
              floating.targetTrack != floating.originalTrack else { return }
        // Look up the dragged clip and its source.
        var draggedClip: PlacedClip?
        var isAudioClip = false
        for track in sequence.videoTracks {
            if let c = track.clips.first(where: { $0.id == floating.clipID }) {
                draggedClip = c; isAudioClip = false; break
            }
        }
        if draggedClip == nil {
            for track in sequence.audioTracks {
                if let c = track.clips.first(where: { $0.id == floating.clipID }) {
                    draggedClip = c; isAudioClip = true; break
                }
            }
        }
        guard let placed = draggedClip else { return }
        // Translate the target track into a Y coordinate (handling
        // phantom tracks above V_top or below A_last).
        let band = Metrics.trackHeight + Metrics.trackSpacing
        let y: CGFloat
        let phantomDepth: Int?
        if floating.targetTrack.kind == 0
            && floating.targetTrack.index >= sequence.videoTracks.count {
            let depth = floating.targetTrack.index - sequence.videoTracks.count + 1
            phantomDepth = depth
            // V_top sits at rulerHeight; one phantom level above means
            // shifted up by a band. Clamp at 0 so it stays visible.
            y = max(0, Metrics.rulerHeight - CGFloat(depth) * band)
        } else if floating.targetTrack.kind == 1
            && floating.targetTrack.index >= sequence.audioTracks.count {
            let depth = floating.targetTrack.index - sequence.audioTracks.count + 1
            phantomDepth = depth
            let audioBlockBottom = Metrics.rulerHeight
                + CGFloat(sequence.videoTracks.count) * band
                + Metrics.separatorHeight
                + CGFloat(sequence.audioTracks.count) * band
            // One level below A_last is audioBlockBottom; deeper levels
            // continue downward. Caller clip-region clips to the view.
            y = audioBlockBottom + CGFloat(depth - 1) * band
        } else {
            phantomDepth = nil
            y = trackTopY(for: floating.targetTrack, in: sequence)
        }
        let x = xForTime(placed.timelineRange.start.seconds)
        let w = max(2, placed.timelineRange.duration.seconds * pixelsPerSecond)
        let rect = CGRect(x: x, y: y + 2, width: w, height: Metrics.trackHeight - 4)

        // Phantom-track hint: dashed yellow band spanning the would-be
        // row, with a "+ V3" or "+ A4" label so the user sees the new
        // track that will be created on release.
        if let depth = phantomDepth {
            let phantomBand = CGRect(x: 0, y: y, width: bounds.width, height: Metrics.trackHeight)
            let label = floating.targetTrack.kind == 0
                ? "+ V\(sequence.videoTracks.count + depth)"
                : "+ A\(sequence.audioTracks.count + depth)"
            drawPhantomTrackHint(ctx: ctx, yTop: phantomBand.minY, label: label)
        }

        // Cross-kind moves (video clip onto audio track or vice versa)
        // are rejected by the workspace — show them tinted red so the
        // user knows the drop won't commit.
        let isCrossKind = (isAudioClip && floating.targetTrack.kind == 0) ||
                          (!isAudioClip && floating.targetTrack.kind == 1)
        let fillColor: NSColor = isCrossKind
            ? .systemRed
            : (isAudioClip ? .systemTeal : .systemBlue)

        ctx.setFillColor(fillColor.withAlphaComponent(0.55).cgColor)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        path.fill()
        ctx.setStrokeColor(fillColor.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        path.stroke()
        ctx.setLineDash(phase: 0, lengths: [])
    }

    private func trackTopY(for target: MoveTargetTrack, in sequence: Sequence) -> CGFloat {
        var cursor = Metrics.rulerHeight
        // Video tracks are drawn reversed (top track first visually).
        for v in sequence.videoTracks.reversed() {
            let originalIdx = sequence.videoTracks.firstIndex(where: { $0.id == v.id }) ?? 0
            if target.kind == 0 && target.index == originalIdx {
                return cursor
            }
            cursor += Metrics.trackHeight + Metrics.trackSpacing
        }
        cursor += Metrics.separatorHeight
        for (aIdx, _) in sequence.audioTracks.enumerated() {
            if target.kind == 1 && target.index == aIdx {
                return cursor
            }
            cursor += Metrics.trackHeight + Metrics.trackSpacing
        }
        return cursor
    }

    private func drawTrackBackground(ctx: CGContext, atY y: CGFloat, isAudio: Bool) {
        let rect = CGRect(
            x: Metrics.laneControlsWidth,
            y: y,
            width: bounds.width - Metrics.laneControlsWidth,
            height: Metrics.trackHeight
        )
        ctx.setFillColor(NSColor(white: isAudio ? 0.13 : 0.15, alpha: 1.0).cgColor)
        ctx.fill(rect)
    }

    private func drawClips(ctx: CGContext, clips: [PlacedClip], atY y: CGFloat, isAudio: Bool, trackIndex: Int) {
        for placed in clips {
            // If this clip is being dragged AND the user has moved
            // their cursor to a different track, suppress drawing it
            // here. We'll render it at the cursor's row later, in
            // drawFloatingDraggedClip.
            if let floating = floatingDraggedClip,
               floating.clipID == placed.id,
               floating.targetTrack != floating.originalTrack {
                continue
            }
            let x = xForTime(placed.timelineRange.start.seconds)
            let w = max(2, placed.timelineRange.duration.seconds * pixelsPerSecond)
            let rect = CGRect(x: x, y: y + 2, width: w, height: Metrics.trackHeight - 4)
            drawClip(ctx: ctx, rect: rect, placed: placed, isAudio: isAudio)
            laidOutClips.append(LaidOutClip(
                rect: rect,
                clipID: placed.id,
                startSeconds: placed.timelineRange.start.seconds,
                endSeconds: placed.timelineRange.end.seconds
            ))
        }
        // After clips, overlay transition wedges (and cut handles) at
        // every abutting pair on this track.
        drawTransitions(ctx: ctx, clips: clips, atY: y, isAudio: isAudio, trackIndex: trackIndex)
    }

    private func drawTransitions(ctx: CGContext, clips: [PlacedClip], atY y: CGFloat, isAudio: Bool, trackIndex: Int) {
        guard clips.count >= 2 else { return }
        let sorted = clips.sorted { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i]
            let b = sorted[i + 1]
            // Abutting check
            guard abs(a.timelineRange.end.seconds - b.timelineRange.start.seconds) < 0.001 else { continue }
            let cutT = a.timelineRange.end.seconds

            // Lay out a hit zone at every abutting cut so right-click /
            // single-click can target it, transition or no.
            let cutX = xForTime(cutT)
            let cutHitRect = CGRect(
                x: cutX - Self.cutGripWidth,
                y: y + 2,
                width: Self.cutGripWidth * 2,
                height: Metrics.trackHeight - 4
            )
            laidOutCuts.append(LaidOutCut(
                rect: cutHitRect,
                cutSeconds: cutT,
                trackKind: isAudio ? 1 : 0,
                trackIndex: trackIndex,
                leftClipID: a.id,
                rightClipID: b.id,
                leftHalfSeconds: a.transitionOut?.duration.seconds,
                rightHalfSeconds: b.transitionIn?.duration.seconds
            ))

            // Selection highlight on cut handle when no transition.
            let isCutSelected = (selectedCut?.trackKind == (isAudio ? 1 : 0)
                                 && selectedCut?.trackIndex == trackIndex
                                 && abs((selectedCut?.cutSeconds ?? -1) - cutT) < 0.001)

            guard let tOut = a.transitionOut, let tIn = b.transitionIn else {
                // No transition — draw a faint clickable cut handle
                // so the user can see the affordance.
                let handle = CGRect(
                    x: cutX - 2, y: y + 6, width: 4, height: Metrics.trackHeight - 12
                )
                ctx.setFillColor(NSColor.white.withAlphaComponent(isCutSelected ? 0.85 : 0.18).cgColor)
                ctx.fill(handle)
                if isCutSelected {
                    ctx.setStrokeColor(NSColor.systemYellow.cgColor)
                    ctx.setLineWidth(1.5)
                    ctx.stroke(handle.insetBy(dx: -3, dy: -3))
                }
                continue
            }
            guard tOut.kind == tIn.kind else { continue }
            let leftHalf = tOut.duration.seconds
            let rightHalf = tIn.duration.seconds
            let totalDur = leftHalf + rightHalf
            guard totalDur > 0 else { continue }

            let startT = max(a.timelineRange.start.seconds, cutT - leftHalf)
            let endT = min(b.timelineRange.end.seconds, cutT + rightHalf)
            let x0 = xForTime(startT)
            let x1 = xForTime(endT)
            let rect = CGRect(x: x0, y: y + 2, width: max(2, x1 - x0), height: Metrics.trackHeight - 4)

            // Fill — selected wedge gets a strong tint so it's
            // obvious the user has clicked it (and can now hit Delete).
            let baseFill = NSColor.systemYellow.withAlphaComponent(isCutSelected ? 0.55 : 0.18)
            ctx.setFillColor(baseFill.cgColor)
            ctx.fill(rect)

            // Crossed diagonals — the cross-dissolve glyph.
            ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: rect.minX, y: rect.minY))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            ctx.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            ctx.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            ctx.strokePath()

            // Outline — bumped 2px stroke when selected.
            ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(isCutSelected ? 1.0 : 0.55).cgColor)
            ctx.setLineWidth(isCutSelected ? 2 : 0.75)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))

            // Drag handles on the L and R edges of the wedge.
            let leftHandle = CGRect(x: rect.minX - 1, y: rect.minY + 2, width: 4, height: rect.height - 4)
            let rightHandle = CGRect(x: rect.maxX - 3, y: rect.minY + 2, width: 4, height: rect.height - 4)
            ctx.setFillColor(NSColor.white.withAlphaComponent(isCutSelected ? 0.8 : 0.35).cgColor)
            ctx.fill(leftHandle)
            ctx.fill(rightHandle)

            laidOutTransitions.append(LaidOutTransition(
                rect: rect,
                leftHandleRect: leftHandle.insetBy(dx: -4, dy: 0),
                rightHandleRect: rightHandle.insetBy(dx: -4, dy: 0),
                cutSeconds: cutT,
                trackKind: isAudio ? 1 : 0,
                trackIndex: trackIndex,
                leftClipID: a.id,
                rightClipID: b.id,
                leftHalfSeconds: leftHalf,
                rightHalfSeconds: rightHalf
            ))
        }
    }

    private func drawClip(ctx: CGContext, rect: CGRect, placed: PlacedClip, isAudio: Bool) {
        let isSelected = selectedClipIDs.contains(placed.id)
        let baseFill: NSColor = isAudio
            ? NSColor.systemTeal.withAlphaComponent(0.55)
            : NSColor.systemBlue.withAlphaComponent(0.7)
        let fill = isSelected ? baseFill.blended(withFraction: 0.25, of: .white) ?? baseFill : baseFill
        ctx.setFillColor(fill.cgColor)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        path.fill()

        // Preview content (waveform / thumbnails) drawn INSIDE the clip
        // rect with the rounded-rect clip so it can't paint over neighbors.
        ctx.saveGState()
        path.addClip()
        if isAudio {
            drawWaveform(ctx: ctx, rect: rect, placed: placed)
        } else {
            drawThumbnails(ctx: ctx, rect: rect, placed: placed)
        }
        ctx.restoreGState()

        if isSelected {
            ctx.setStrokeColor(NSColor.systemYellow.cgColor)
            ctx.setLineWidth(2)
        } else {
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1)
        }
        path.stroke()

        // Edge tactile feedback: handles brighten on hover and stay
        // highlighted when selected for transition purposes.
        if rect.width > 24 {
            let leftEdgeSelected = selectedClipEdge?.clipID == placed.id && selectedClipEdge?.side == .left
            let rightEdgeSelected = selectedClipEdge?.clipID == placed.id && selectedClipEdge?.side == .right
            let leftHovered = hoveredClipEdge?.clipID == placed.id && hoveredClipEdge?.side == .left
            let rightHovered = hoveredClipEdge?.clipID == placed.id && hoveredClipEdge?.side == .right
            let leftAlpha: CGFloat = leftEdgeSelected
                ? 0.95
                : (leftHovered ? 0.75 : (isSelected ? 0.55 : 0.18))
            let rightAlpha: CGFloat = rightEdgeSelected
                ? 0.95
                : (rightHovered ? 0.75 : (isSelected ? 0.55 : 0.18))
            let leftWidth: CGFloat = (leftEdgeSelected || leftHovered) ? 3 : 2
            let rightWidth: CGFloat = (rightEdgeSelected || rightHovered) ? 3 : 2
            let leftHandle = CGRect(x: rect.minX + 2, y: rect.minY + 4, width: leftWidth, height: rect.height - 8)
            let rightHandle = CGRect(x: rect.maxX - 2 - rightWidth, y: rect.minY + 4, width: rightWidth, height: rect.height - 8)
            ctx.setFillColor(NSColor.white.withAlphaComponent(leftAlpha).cgColor)
            ctx.fill(leftHandle)
            ctx.setFillColor(NSColor.white.withAlphaComponent(rightAlpha).cgColor)
            ctx.fill(rightHandle)
            if leftEdgeSelected {
                ctx.setStrokeColor(NSColor.systemYellow.cgColor)
                ctx.setLineWidth(1.5)
                ctx.stroke(leftHandle.insetBy(dx: -2, dy: -2))
            }
            if rightEdgeSelected {
                ctx.setStrokeColor(NSColor.systemYellow.cgColor)
                ctx.setLineWidth(1.5)
                ctx.stroke(rightHandle.insetBy(dx: -2, dy: -2))
            }
        }

        // Solo fade overlay — a yellow gradient hint inside the clip
        // where transitionIn / transitionOut applies (but only when no
        // paired partner is on the adjacent abutting clip).
        drawSoloFadeOverlay(ctx: ctx, rect: rect, placed: placed)

        // Name overlay (truncated)
        let source = clipSources[placed.sourceClipID]
        let label = source?.name ?? "Clip"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            .shadow: {
                let s = NSShadow()
                s.shadowColor = NSColor.black.withAlphaComponent(0.7)
                s.shadowOffset = NSSize(width: 0, height: -1)
                s.shadowBlurRadius = 1.5
                return s
            }(),
        ]
        if rect.width > 30 {
            let textRect = rect.insetBy(dx: 8, dy: 4)
            (label as NSString).draw(in: textRect, withAttributes: attrs)
        }
    }

    /// Draws a yellow gradient hint at the clip's in/out where a solo
    /// fade lives. Skips the side if a paired transition exists on a
    /// neighboring abutting clip — that's handled by the cross-dissolve
    /// wedge instead. Also lays out the inner-tip drag handle so the
    /// user can resize the fade by dragging.
    private func drawSoloFadeOverlay(ctx: CGContext, rect: CGRect, placed: PlacedClip) {
        guard let sequence else { return }
        // Locate this clip on its track.
        var trackClips: [PlacedClip] = []
        var trackKind: Int = 0
        var trackIndex: Int = 0
        var found = false
        for (vIdx, vt) in sequence.videoTracks.enumerated() {
            if vt.clips.contains(where: { $0.id == placed.id }) {
                trackClips = vt.clips
                trackKind = 0
                trackIndex = vIdx
                found = true
                break
            }
        }
        if !found {
            for (aIdx, at) in sequence.audioTracks.enumerated() {
                if at.clips.contains(where: { $0.id == placed.id }) {
                    trackClips = at.clips
                    trackKind = 1
                    trackIndex = aIdx
                    found = true
                    break
                }
            }
        }
        guard found else { return }
        let sorted = trackClips.sorted { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        guard let i = sorted.firstIndex(where: { $0.id == placed.id }) else { return }

        let pixelsPerSec = pixelsPerSecond
        // Left side fade-in: only solo if there's no paired prev.
        if let tIn = placed.transitionIn {
            let prevPaired: Bool = {
                guard i > 0 else { return false }
                let prev = sorted[i - 1]
                return abs(prev.timelineRange.end.seconds - placed.timelineRange.start.seconds) < 0.001
                    && prev.transitionOut != nil
            }()
            if !prevPaired {
                let widthPx = min(rect.width, CGFloat(tIn.duration.seconds * pixelsPerSec))
                let wedgeRect = CGRect(x: rect.minX, y: rect.minY, width: widthPx, height: rect.height)
                let edge = ClipEdgeSelection(
                    clipID: placed.id, trackKind: trackKind,
                    trackIndex: trackIndex, side: .left
                )
                drawFadeWedge(ctx: ctx, rect: wedgeRect, leftToRight: true, isSelected: selectedClipEdge == edge)
                let tipX = rect.minX + widthPx
                let tipHandle = CGRect(x: tipX - Self.soloFadeTipGripWidth, y: rect.minY, width: Self.soloFadeTipGripWidth * 2, height: rect.height)
                laidOutSoloFades.append(LaidOutSoloFade(
                    tipHandleRect: tipHandle,
                    wedgeRect: wedgeRect,
                    clipRect: rect,
                    edge: edge,
                    currentDurationSeconds: tIn.duration.seconds,
                    clipStartSeconds: placed.timelineRange.start.seconds,
                    clipEndSeconds: placed.timelineRange.end.seconds
                ))
                drawSoloFadeTipHandle(ctx: ctx, x: tipX, rect: rect, edge: edge)
            }
        }
        if let tOut = placed.transitionOut {
            let nextPaired: Bool = {
                guard i + 1 < sorted.count else { return false }
                let next = sorted[i + 1]
                return abs(next.timelineRange.start.seconds - placed.timelineRange.end.seconds) < 0.001
                    && next.transitionIn != nil
            }()
            if !nextPaired {
                let widthPx = min(rect.width, CGFloat(tOut.duration.seconds * pixelsPerSec))
                let wedgeRect = CGRect(x: rect.maxX - widthPx, y: rect.minY, width: widthPx, height: rect.height)
                let edge = ClipEdgeSelection(
                    clipID: placed.id, trackKind: trackKind,
                    trackIndex: trackIndex, side: .right
                )
                drawFadeWedge(ctx: ctx, rect: wedgeRect, leftToRight: false, isSelected: selectedClipEdge == edge)
                let tipX = rect.maxX - widthPx
                let tipHandle = CGRect(x: tipX - Self.soloFadeTipGripWidth, y: rect.minY, width: Self.soloFadeTipGripWidth * 2, height: rect.height)
                laidOutSoloFades.append(LaidOutSoloFade(
                    tipHandleRect: tipHandle,
                    wedgeRect: wedgeRect,
                    clipRect: rect,
                    edge: edge,
                    currentDurationSeconds: tOut.duration.seconds,
                    clipStartSeconds: placed.timelineRange.start.seconds,
                    clipEndSeconds: placed.timelineRange.end.seconds
                ))
                drawSoloFadeTipHandle(ctx: ctx, x: tipX, rect: rect, edge: edge)
            }
        }
    }

    private func drawSoloFadeTipHandle(ctx: CGContext, x: CGFloat, rect: CGRect, edge: ClipEdgeSelection) {
        let isSelected = selectedClipEdge == edge
        let alpha: CGFloat = isSelected ? 0.95 : 0.55
        let handle = CGRect(x: x - 1.5, y: rect.minY + 2, width: 3, height: rect.height - 4)
        ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(alpha).cgColor)
        ctx.fill(handle)
    }

    private func drawFadeWedge(ctx: CGContext, rect: CGRect, leftToRight: Bool, isSelected: Bool = false) {
        guard rect.width > 1 else { return }
        ctx.saveGState()
        let path = NSBezierPath()
        if leftToRight {
            // Triangle: opaque at left edge → vanishes to clip's center-line at right edge.
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.line(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.line(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.close()
        } else {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.line(to: CGPoint(x: rect.minX, y: rect.midY))
            path.close()
        }
        ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(isSelected ? 0.55 : 0.22).cgColor)
        path.fill()
        ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(isSelected ? 1.0 : 0.85).cgColor)
        ctx.setLineWidth(isSelected ? 2 : 1)
        path.stroke()
        ctx.restoreGState()
    }

    private func drawWaveform(ctx: CGContext, rect: CGRect, placed: PlacedClip) {
        guard let peaks = audioPeaks[placed.sourceClipID], !peaks.isEmpty else { return }
        guard let source = clipSources[placed.sourceClipID] else { return }
        let sourceDuration = source.duration.seconds
        guard sourceDuration > 0 else { return }

        // Slice [startFraction, endFraction] of the peaks array — the
        // PlacedClip's sourceRange in fractional form.
        let startFrac = max(0, placed.sourceRange.start.seconds / sourceDuration)
        let endFrac   = min(1, placed.sourceRange.end.seconds   / sourceDuration)
        guard endFrac > startFrac else { return }

        let n = peaks.count
        let startIdx = Int((startFrac * Double(n)).rounded(.down))
        let endIdx   = Int((endFrac   * Double(n)).rounded(.up))
        let slice = peaks[max(0, startIdx)..<min(n, max(startIdx + 1, endIdx))]
        guard !slice.isEmpty else { return }

        // Downsample (or stretch) the slice to one peak per ~1 pixel of rect width.
        let columnCount = max(1, Int(rect.width.rounded()))
        let denom = max(1, columnCount - 1)
        let centerY = rect.midY
        let halfH = (rect.height - 6) / 2

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.65).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineCap(.round)

        let sliceArray = Array(slice)
        for col in 0..<columnCount {
            let f = Double(col) / Double(denom)
            let idx = min(sliceArray.count - 1, Int((f * Double(sliceArray.count - 1)).rounded()))
            let peak = CGFloat(sliceArray[idx])
            let h = peak * halfH
            let x = rect.minX + CGFloat(col)
            ctx.move(to: CGPoint(x: x, y: centerY - h))
            ctx.addLine(to: CGPoint(x: x, y: centerY + h))
        }
        ctx.strokePath()

        // Center reference line (subtle)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: rect.minX, y: centerY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: centerY))
        ctx.strokePath()
    }

    private func drawThumbnails(ctx: CGContext, rect: CGRect, placed: PlacedClip) {
        guard let images = videoThumbnails[placed.sourceClipID], !images.isEmpty else { return }
        guard let source = clipSources[placed.sourceClipID] else { return }
        let sourceDuration = source.duration.seconds
        guard sourceDuration > 0 else { return }

        let startFrac = max(0, placed.sourceRange.start.seconds / sourceDuration)
        let endFrac   = min(1, placed.sourceRange.end.seconds   / sourceDuration)
        guard endFrac > startFrac else { return }

        // Aspect ratio from the first thumbnail.
        let sample = images[0]
        let imgAspect = CGFloat(sample.width) / max(1, CGFloat(sample.height))
        // Fit thumbnail height to clip height; width follows the aspect.
        let thumbHeight = max(0, rect.height - 2)
        let thumbWidth  = thumbHeight * imgAspect
        guard thumbWidth > 1 else { return }

        // Tile thumbnails left-to-right. Each tile shows the source frame
        // at the time corresponding to its center within [startFrac, endFrac].
        let tileCount = max(1, Int((rect.width / thumbWidth).rounded(.up)))
        let actualTileWidth = rect.width / CGFloat(tileCount)

        for i in 0..<tileCount {
            let centerX = rect.minX + (CGFloat(i) + 0.5) * actualTileWidth
            let frac = startFrac + (endFrac - startFrac) * Double((CGFloat(i) + 0.5) / CGFloat(tileCount))
            let imgIdx = min(images.count - 1, max(0, Int((frac * Double(images.count - 1)).rounded())))
            let image = images[imgIdx]

            let tileRect = CGRect(
                x: centerX - actualTileWidth / 2,
                y: rect.minY + 1,
                width: actualTileWidth,
                height: thumbHeight
            )
            // Draw the image cropped/scaled to tileRect, preserving aspect via
            // an aspect-fill (clipped to the tile).
            ctx.saveGState()
            ctx.addRect(tileRect)
            ctx.clip()

            let scale = max(tileRect.width / CGFloat(image.width), tileRect.height / CGFloat(image.height))
            let drawW = CGFloat(image.width) * scale
            let drawH = CGFloat(image.height) * scale
            let drawRect = CGRect(
                x: tileRect.midX - drawW / 2,
                y: tileRect.midY - drawH / 2,
                width: drawW,
                height: drawH
            )
            // CGContext draw() flips the image because we're in a flipped
            // NSView. Compensate with a transform around drawRect.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: drawRect.maxY + drawRect.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: drawRect)
            ctx.restoreGState()
            ctx.restoreGState()
        }

        // Slight darkening overlay so the clip label stays readable.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.fill(rect)
    }

    // MARK: - Lane enumeration

    private enum Lane {
        case video(VideoTrack)
        case audio(AudioTrack)
        case separator
    }

    private func enumeratedLanes(sequence: Sequence) -> [Lane] {
        var out: [Lane] = []
        out.append(contentsOf: sequence.videoTracks.reversed().map(Lane.video))   // V1 at top
        out.append(.separator)
        out.append(contentsOf: sequence.audioTracks.map(Lane.audio))               // A1 below separator
        return out
    }

    // MARK: - Time ↔ pixel

    private func xForTime(_ seconds: Double) -> CGFloat {
        CGFloat((seconds - scrollOffsetSeconds) * pixelsPerSecond) + Metrics.laneControlsWidth
    }

    private func timeForX(_ x: CGFloat) -> Double {
        let relX = max(0, Double(x - Metrics.laneControlsWidth))
        return relX / pixelsPerSecond + scrollOffsetSeconds
    }

    private func adaptiveTickInterval() -> Double {
        // Pick a tick spacing that fits ~60–120 px between ticks. At
        // high zoom we prefer frame-aligned intervals so the labels
        // round cleanly to whole frames; at low zoom we fall back to
        // seconds / minutes.
        let target: Double = 80
        let raw = target / pixelsPerSecond
        let fps = sequence?.settings.frameRate.fps ?? 30
        if fps > 0 {
            let frameCandidates: [Int] = [1, 2, 5, 10, 30]
            for fc in frameCandidates {
                let seconds = Double(fc) / fps
                if seconds >= raw { return seconds }
            }
        }
        let timeCandidates: [Double] = [1, 2, 5, 10, 30, 60, 300, 600]
        for c in timeCandidates where c >= raw { return c }
        return 600
    }

    private func formatRulerTime(_ seconds: Double) -> String {
        // Use the centralized SMPTE formatter so the ruler and the
        // viewer's TC display agree exactly, including drop-frame for
        // 29.97 / 59.94. Trim the leading "00:" for cleaner labels.
        let fr = sequence?.settings.frameRate ?? .thirty
        let full = Timecode.format(seconds: seconds, frameRate: fr)
        if full.hasPrefix("00:") {
            return String(full.dropFirst(3))
        }
        return full
    }

    // MARK: - Hit testing

    private enum ClipHit {
        case body(id: PlacedClipID, grabOffsetSeconds: Double, originalStart: Double)
        case trimLeft(id: PlacedClipID, originalStart: Double)
        case trimRight(id: PlacedClipID, originalEnd: Double)
    }

    /// Hit-test a click on an existing transition's left or right edge.
    /// Returns the cut + side (0=left, 1=right) if the click is within
    /// the edge handle's grip rect.
    private struct TransitionEdgeHit {
        var trackKind: Int
        var trackIndex: Int
        var cutSeconds: Double
        var leftClipID: PlacedClipID
        var rightClipID: PlacedClipID
        var side: Int  // 0 = left, 1 = right
    }
    private func transitionEdgeHitTest(_ point: CGPoint) -> TransitionEdgeHit? {
        for t in laidOutTransitions {
            if t.leftHandleRect.contains(point) {
                return TransitionEdgeHit(
                    trackKind: t.trackKind, trackIndex: t.trackIndex,
                    cutSeconds: t.cutSeconds,
                    leftClipID: t.leftClipID, rightClipID: t.rightClipID,
                    side: 0
                )
            }
            if t.rightHandleRect.contains(point) {
                return TransitionEdgeHit(
                    trackKind: t.trackKind, trackIndex: t.trackIndex,
                    cutSeconds: t.cutSeconds,
                    leftClipID: t.leftClipID, rightClipID: t.rightClipID,
                    side: 1
                )
            }
        }
        return nil
    }

    /// Hit-test the inner-tip handle of a solo fade triangle.
    private func soloFadeTipHitTest(_ point: CGPoint) -> LaidOutSoloFade? {
        for fade in laidOutSoloFades where fade.tipHandleRect.contains(point) {
            return fade
        }
        return nil
    }

    /// Hit-test the body of a solo fade wedge — full triangle area, so
    /// users can click anywhere on the fade to select it and hit
    /// Delete. Does NOT include the tip handle (that's the resize
    /// gesture; checked separately earlier).
    private func soloFadeBodyHitTest(_ point: CGPoint) -> LaidOutSoloFade? {
        for fade in laidOutSoloFades where fade.wedgeRect.contains(point) {
            return fade
        }
        return nil
    }

    /// Hit-test the body of a cross-dissolve wedge (the X-glyph
    /// rectangle between two clips). Does NOT include the L/R edge
    /// grips (those are the resize gestures; checked separately).
    private func transitionBodyHitTest(_ point: CGPoint) -> LaidOutTransition? {
        for t in laidOutTransitions where t.rect.contains(point) {
            return t
        }
        return nil
    }

    /// Hit-test the cut grip between two abutting clips (always laid
    /// out, transition or not).
    private func cutHitTest(_ point: CGPoint) -> CutSelection? {
        for cut in laidOutCuts where cut.rect.contains(point) {
            return CutSelection(
                trackKind: cut.trackKind, trackIndex: cut.trackIndex,
                cutSeconds: cut.cutSeconds,
                leftClipID: cut.leftClipID, rightClipID: cut.rightClipID
            )
        }
        return nil
    }

    /// Hit-test a click in empty space on a track row. Returns the gap
    /// the click landed in, or nil if the click is past the last clip
    /// on that track (the trailing-gap region) — that case falls back
    /// to the existing scrub behavior.
    private func gapHitTest(_ point: CGPoint) -> GapSelection? {
        guard let sequence else { return nil }
        guard let target = trackAtY(point.y) else { return nil }
        let pointTime = timeForX(point.x)
        guard pointTime >= 0 else { return nil }

        let clips: [PlacedClip]
        if target.kind == 0 {
            guard target.index < sequence.videoTracks.count else { return nil }
            clips = sequence.videoTracks[target.index].clips
        } else {
            guard target.index < sequence.audioTracks.count else { return nil }
            clips = sequence.audioTracks[target.index].clips
        }
        let sorted = clips.sorted { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }

        // Leading gap: between t=0 and the first clip's start.
        if let first = sorted.first, first.timelineRange.start.seconds > 0,
           pointTime < first.timelineRange.start.seconds {
            return GapSelection(
                trackKind: target.kind, trackIndex: target.index,
                startSeconds: 0, durationSeconds: first.timelineRange.start.seconds
            )
        }
        // Middle gap: between two consecutive clips.
        for i in 0..<(sorted.count - 1 < 0 ? 0 : sorted.count - 1) {
            let prevEnd = sorted[i].timelineRange.end.seconds
            let nextStart = sorted[i + 1].timelineRange.start.seconds
            if nextStart > prevEnd, pointTime >= prevEnd, pointTime < nextStart {
                return GapSelection(
                    trackKind: target.kind, trackIndex: target.index,
                    startSeconds: prevEnd, durationSeconds: nextStart - prevEnd
                )
            }
        }
        // Past the last clip → trailing region, not a selectable gap.
        return nil
    }

    private func clipHitTest(_ point: CGPoint) -> ClipHit? {
        for laid in laidOutClips.reversed() where laid.rect.contains(point) {
            if isClipLocked(laid.clipID) { return nil }
            if point.x - laid.rect.minX < Self.trimGripWidth {
                return .trimLeft(id: laid.clipID, originalStart: laid.startSeconds)
            }
            if laid.rect.maxX - point.x < Self.trimGripWidth {
                return .trimRight(id: laid.clipID, originalEnd: laid.endSeconds)
            }
            let pointTime = timeForX(point.x)
            return .body(
                id: laid.clipID,
                grabOffsetSeconds: pointTime - laid.startSeconds,
                originalStart: laid.startSeconds
            )
        }
        return nil
    }

    private func isClipLocked(_ id: PlacedClipID) -> Bool {
        guard let sequence else { return false }
        for v in sequence.videoTracks {
            if v.clips.contains(where: { $0.id == id }) { return v.isLocked }
        }
        for a in sequence.audioTracks {
            if a.clips.contains(where: { $0.id == id }) { return a.isLocked }
        }
        return false
    }

    private func snapTime(_ t: Double, excluding: PlacedClipID?) -> Double {
        guard snappingEnabled else { return t }
        let candidates = snapCandidates(excluding: excluding)
        let thresholdSeconds = Double(Self.snapThresholdPixels) / pixelsPerSecond
        if let nearest = candidates.min(by: { abs($0 - t) < abs($1 - t) }),
           abs(nearest - t) <= thresholdSeconds {
            return nearest
        }
        return t
    }

    private func snapCandidates(excluding: PlacedClipID?) -> [Double] {
        var out: [Double] = [0, playheadTime.seconds]
        for laid in laidOutClips where laid.clipID != excluding {
            out.append(laid.startSeconds)
            out.append(laid.endSeconds)
        }
        return out
    }

    // MARK: - Mouse events

    public override func mouseDown(with event: NSEvent) {
        callbacks.didReceiveFocus?()
        let p = convert(event.locationInWindow, from: nil)

        // Track-header button hit?
        if p.x < Metrics.laneControlsWidth {
            for btn in laidOutHeaderButtons where btn.rect.contains(p) {
                fireHeaderButton(btn)
                return
            }
            // Bare lane band → set target for that row.
            for row in laidOutHeaderRows where row.rect.contains(p) {
                if row.trackIsVideo {
                    callbacks.requestSetVideoTarget?(row.trackIndex)
                } else {
                    callbacks.requestSetAudioTarget?(row.trackIndex)
                }
                return
            }
            return
        }

        // Ruler band → scrub
        if p.y < Metrics.rulerHeight {
            interaction = .scrubbing
            applyScrub(at: p)
            return
        }

        // Blade tool: a click on a clip slices THAT clip (and its
        // linked siblings) at the click position. Click on empty
        // space does nothing — matches Premiere's razor.
        if activeTool == .blade {
            let t = timeForX(p.x)
            if t > 0, let laid = laidOutClips.reversed().first(where: { $0.rect.contains(p) }) {
                callbacks.bladeClip?(laid.clipID, t)
            }
            return
        }

        // Below ruler — check solo-fade tip handles first (overlay clips).
        if let fade = soloFadeTipHitTest(p) {
            callbacks.selectClipEdge?(fade.edge)
            callbacks.beginClipDragOrTrim?()
            interaction = .draggingSoloFadeTip(edge: fade.edge, clipStart: fade.clipStartSeconds, clipEnd: fade.clipEndSeconds)
            return
        }

        // Below ruler — check transition edges first (they overlay clip edges).
        if let edge = transitionEdgeHitTest(p) {
            let cut = CutSelection(
                trackKind: edge.trackKind,
                trackIndex: edge.trackIndex,
                cutSeconds: edge.cutSeconds,
                leftClipID: edge.leftClipID,
                rightClipID: edge.rightClipID
            )
            callbacks.selectCut?(cut)
            callbacks.beginClipDragOrTrim?()
            interaction = .draggingTransitionEdge(cut: cut, side: edge.side)
            return
        }
        if let cut = cutHitTest(p) {
            callbacks.selectCut?(cut)
            interaction = .idle
            return
        }

        // Clicking the body of a cross-dissolve wedge selects the cut
        // (after the edge-grip and narrow-cut-grip checks above, so
        // resize / cut-handle clicks still take precedence).
        if let t = transitionBodyHitTest(p) {
            let cut = CutSelection(
                trackKind: t.trackKind, trackIndex: t.trackIndex,
                cutSeconds: t.cutSeconds,
                leftClipID: t.leftClipID, rightClipID: t.rightClipID
            )
            callbacks.selectCut?(cut)
            interaction = .idle
            return
        }

        // Clicking the body of a solo fade triangle selects the edge.
        if let fade = soloFadeBodyHitTest(p) {
            callbacks.selectClipEdge?(fade.edge)
            interaction = .idle
            return
        }

        // Below ruler → maybe clip interaction, else clear selection + scrub
        if let hit = clipHitTest(p) {
            callbacks.beginClipDragOrTrim?()
            switch hit {
            case .body(let id, let grab, let originalStart):
                let additive = event.modifierFlags.contains(.shift)
                callbacks.selectClip?(id, additive)
                let origTrack = currentTrackOf(id)
                interaction = .draggingClip(
                    id: id,
                    grabOffsetSeconds: grab,
                    originalStartSeconds: originalStart,
                    originalTrack: origTrack,
                    currentTrack: origTrack
                )
                if let origTrack {
                    floatingDraggedClip = FloatingDraggedClip(
                        clipID: id,
                        targetTrack: origTrack,
                        originalTrack: origTrack
                    )
                }
            case .trimLeft(let id, let originalStart):
                callbacks.selectClip?(id, false)
                interaction = .trimmingLeft(id: id, originalStartSeconds: originalStart)
            case .trimRight(let id, let originalEnd):
                callbacks.selectClip?(id, false)
                interaction = .trimmingRight(id: id, originalEndSeconds: originalEnd)
            }
            return
        }

        // Empty space on a track row → maybe a gap.
        if let gap = gapHitTest(p) {
            callbacks.selectGap?(gap)
            interaction = .idle
            return
        }

        // Truly empty timeline area → start a rubber-band box select.
        // Drag-to-scrub on the timeline body is intentionally disabled
        // (only the ruler scrubs) so dragging in empty space can lasso
        // clips Premiere-style.
        callbacks.clearSelection?()
        interaction = .boxSelecting(startPoint: p, currentPoint: p)
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        switch interaction {
        case .scrubbing:
            applyScrub(at: p)
        case .draggingClip(let id, let grab, let origStart, let origTrack, _):
            let raw = max(0, timeForX(p.x) - grab)
            let snapped = snapTime(raw, excluding: id)
            // Horizontal move is live (model mutates each tick).
            callbacks.moveClip?(id, RationalTime(value: Int64(snapped * 1000), scale: 1000), nil)
            // Vertical move is preview only — we render the dragged
            // clip at the cursor's track row but don't commit to the
            // model until mouseUp. This avoids wiping out any clips
            // the dragged piece briefly passes over.
            //
            // Phantom-track extension: if the cursor is above V_top
            // (for a video clip) or below A_last (for an audio clip),
            // the target index goes one (or more) past the existing
            // count — workspace.moveSingleClipToTrack appends fresh
            // tracks to land the clip there, matching the original
            // bin drag-in behavior.
            let hoveredTrack: MoveTargetTrack? = {
                if let t = trackAtY(p.y) { return t }
                guard let seq = sequence, let oTrack = origTrack else { return origTrack }
                if oTrack.kind == 0 {
                    let depth = phantomTracksAbove(yInView: p.y)
                    if depth > 0 {
                        return MoveTargetTrack(kind: 0, index: seq.videoTracks.count + depth - 1)
                    }
                } else if oTrack.kind == 1 {
                    let depth = phantomAudioTracksBelow(yInView: p.y, in: seq)
                    if depth > 0 {
                        return MoveTargetTrack(kind: 1, index: seq.audioTracks.count + depth - 1)
                    }
                }
                return oTrack
            }()
            interaction = .draggingClip(
                id: id, grabOffsetSeconds: grab, originalStartSeconds: origStart,
                originalTrack: origTrack, currentTrack: hoveredTrack
            )
            if var floating = floatingDraggedClip, let hovered = hoveredTrack {
                if floating.targetTrack != hovered {
                    floating.targetTrack = hovered
                    floatingDraggedClip = floating
                    needsDisplay = true
                }
            }
        case .trimmingLeft(let id, _):
            let raw = max(0, timeForX(p.x))
            let snapped = snapTime(raw, excluding: id)
            callbacks.trimLeft?(id, RationalTime(value: Int64(snapped * 1000), scale: 1000))
        case .trimmingRight(let id, _):
            let raw = max(0, timeForX(p.x))
            let snapped = snapTime(raw, excluding: id)
            callbacks.trimRight?(id, RationalTime(value: Int64(snapped * 1000), scale: 1000))
        case .draggingTransitionEdge(let cut, let side):
            // Snap then derive — workspace frame-quantizes on its side.
            let snappedT = snapTime(timeForX(p.x), excluding: nil)
            let halfRaw: Double
            if side == 0 {
                halfRaw = max(0.05, cut.cutSeconds - snappedT)
            } else {
                halfRaw = max(0.05, snappedT - cut.cutSeconds)
            }
            callbacks.resizeTransitionEdge?(cut, side, halfRaw)
        case .boxSelecting(let startPoint, _):
            interaction = .boxSelecting(startPoint: startPoint, currentPoint: p)
            needsDisplay = true
        case .draggingSoloFadeTip(let edge, let clipStart, let clipEnd):
            // Snap the cursor time (honors the N toggle), then derive
            // the new duration. The workspace frame-quantizes on its
            // side using the active sequence's fps.
            let snappedT = snapTime(timeForX(p.x), excluding: nil)
            let dur: Double
            if edge.side == .left {
                dur = max(0.05, snappedT - clipStart)
            } else {
                dur = max(0.05, clipEnd - snappedT)
            }
            let maxDur = max(0.05, clipEnd - clipStart)
            callbacks.resizeSoloFade?(edge, min(dur, maxDur))
        case .idle:
            break
        }
    }

    public override func mouseUp(with event: NSEvent) {
        switch interaction {
        case .draggingClip(let id, let grab, _, let origTrack, let currentTrack):
            // If the cursor ended over a different track than the
            // dragged clip's origin, commit the track change now.
            // Must subtract the grab offset (same math as mouseDragged)
            // or the clip jumps forward by the cursor-to-clip-start
            // distance on release.
            if let target = currentTrack, target != origTrack {
                let p = convert(event.locationInWindow, from: nil)
                let raw = max(0, timeForX(p.x) - grab)
                let snapped = snapTime(raw, excluding: id)
                callbacks.moveClip?(id, RationalTime(value: Int64(snapped * 1000), scale: 1000), target)
            }
            callbacks.endClipDragOrTrim?(id)
        case .trimmingLeft(let id, _):
            callbacks.endClipDragOrTrim?(id)
        case .trimmingRight(let id, _):
            callbacks.endClipDragOrTrim?(id)
        case .draggingTransitionEdge:
            callbacks.endClipDragOrTrim?(nil)
        case .draggingSoloFadeTip:
            callbacks.endClipDragOrTrim?(nil)
        case .boxSelecting(let startPoint, let currentPoint):
            // Compute the bounding rect; select every clip whose
            // laid-out rect intersects it.
            let rect = CGRect(
                x: min(startPoint.x, currentPoint.x),
                y: min(startPoint.y, currentPoint.y),
                width: abs(currentPoint.x - startPoint.x),
                height: abs(currentPoint.y - startPoint.y)
            )
            if rect.width > 1, rect.height > 1 {
                var first = true
                for laid in laidOutClips where laid.rect.intersects(rect) {
                    callbacks.selectClip?(laid.clipID, !first)
                    first = false
                }
            }
        default:
            break
        }
        interaction = .idle
        floatingDraggedClip = nil
        needsDisplay = true
    }

    /// Hit-test a clip's left or right edge (the ~6 px trim grip).
    /// Returns the clip and which side. Used by right-click to surface
    /// the fade menu without disturbing the plain-left-click trim flow.
    private struct ClipEdgeHit {
        var clipID: PlacedClipID
        var side: ClipEdgeSelection.Side
        var trackKind: Int
        var trackIndex: Int
    }
    private func clipEdgeHitTest(_ point: CGPoint) -> ClipEdgeHit? {
        for laid in laidOutClips.reversed() where laid.rect.contains(point) {
            let trackKind: Int
            let trackIndex: Int
            if let tt = currentTrackOf(laid.clipID) {
                trackKind = tt.kind
                trackIndex = tt.index
            } else { continue }
            if point.x - laid.rect.minX < Self.trimGripWidth {
                return ClipEdgeHit(clipID: laid.clipID, side: .left, trackKind: trackKind, trackIndex: trackIndex)
            }
            if laid.rect.maxX - point.x < Self.trimGripWidth {
                return ClipEdgeHit(clipID: laid.clipID, side: .right, trackKind: trackKind, trackIndex: trackIndex)
            }
            return nil
        }
        return nil
    }

    public override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        // Cut grip / transition wedge → dedicated menu
        if let edge = transitionEdgeHitTest(p) {
            let cut = CutSelection(
                trackKind: edge.trackKind, trackIndex: edge.trackIndex,
                cutSeconds: edge.cutSeconds,
                leftClipID: edge.leftClipID, rightClipID: edge.rightClipID
            )
            callbacks.selectCut?(cut)
            menuCutContext = cut
            menuCutHasTransition = true
            showCutMenu(event: event, hasTransition: true)
            return
        }
        if let cut = cutHitTest(p) {
            callbacks.selectCut?(cut)
            menuCutContext = cut
            let hasTransition = laidOutCuts.first(where: {
                $0.trackKind == cut.trackKind
                && $0.trackIndex == cut.trackIndex
                && abs($0.cutSeconds - cut.cutSeconds) < 0.001
            })?.hasTransition ?? false
            menuCutHasTransition = hasTransition
            showCutMenu(event: event, hasTransition: hasTransition)
            return
        }

        // Clip's left/right edge → solo fade menu.
        if let edge = clipEdgeHitTest(p) {
            let sel = ClipEdgeSelection(
                clipID: edge.clipID, trackKind: edge.trackKind,
                trackIndex: edge.trackIndex, side: edge.side
            )
            callbacks.selectClipEdge?(sel)
            menuClipEdgeContext = sel
            // Existing transition on this side?
            let hasExisting: Bool = {
                guard let sequence = sequence else { return false }
                if edge.trackKind == 0, edge.trackIndex < sequence.videoTracks.count,
                   let clip = sequence.videoTracks[edge.trackIndex].clips.first(where: { $0.id == edge.clipID }) {
                    return edge.side == .left ? clip.transitionIn != nil : clip.transitionOut != nil
                }
                if edge.trackKind == 1, edge.trackIndex < sequence.audioTracks.count,
                   let clip = sequence.audioTracks[edge.trackIndex].clips.first(where: { $0.id == edge.clipID }) {
                    return edge.side == .left ? clip.transitionIn != nil : clip.transitionOut != nil
                }
                return false
            }()
            showClipEdgeMenu(event: event, side: edge.side, hasExisting: hasExisting)
            return
        }

        if let hit = clipHitTest(p) {
            let id: PlacedClipID
            switch hit {
            case .body(let i, _, _):        id = i
            case .trimLeft(let i, _):       id = i
            case .trimRight(let i, _):      id = i
            }
            // If the right-clicked clip isn't already selected, select it.
            if !selectedClipIDs.contains(id) {
                callbacks.selectClip?(id, false)
            }
        }
        let menu = NSMenu(title: "Clip")
        menu.addItem(makeMenuItem(title: "Toggle Link  ⌘L", action: #selector(menuToggleLink)))
        menu.addItem(makeMenuItem(title: "Unlink", action: #selector(menuUnlink)))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Delete  ⌫", action: #selector(menuDelete)))
        menu.addItem(makeMenuItem(title: "Ripple Delete  ⇧⌫", action: #selector(menuRippleDelete)))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private var menuClipEdgeContext: ClipEdgeSelection?

    private func showClipEdgeMenu(event: NSEvent, side: ClipEdgeSelection.Side, hasExisting: Bool) {
        let menu = NSMenu(title: "Edge")
        if hasExisting {
            menu.addItem(makeMenuItem(
                title: side == .left ? "Remove Fade In" : "Remove Fade Out",
                action: #selector(menuRemoveFade)
            ))
        } else {
            menu.addItem(makeMenuItem(
                title: side == .left ? "Add Fade In" : "Add Fade Out",
                action: #selector(menuAddFade)
            ))
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func menuAddFade() {
        guard let edge = menuClipEdgeContext else { return }
        callbacks.requestAddFade?(edge)
    }
    @objc private func menuRemoveFade() {
        guard let edge = menuClipEdgeContext else { return }
        callbacks.requestRemoveFade?(edge)
    }

    private var menuCutContext: CutSelection?
    private var menuCutHasTransition: Bool = false

    private func showCutMenu(event: NSEvent, hasTransition: Bool) {
        let menu = NSMenu(title: "Cut")
        if hasTransition {
            menu.addItem(makeMenuItem(title: "Remove Transition", action: #selector(menuRemoveTransition)))
        } else {
            menu.addItem(makeMenuItem(title: "Add Transition", action: #selector(menuAddTransition)))
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func menuAddTransition() {
        guard let cut = menuCutContext else { return }
        callbacks.requestAddTransition?(cut)
    }
    @objc private func menuRemoveTransition() {
        guard let cut = menuCutContext else { return }
        callbacks.requestRemoveTransition?(cut)
    }

    private func makeMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func menuToggleLink() { callbacks.requestToggleLink?() }
    @objc private func menuUnlink() { callbacks.requestUnlink?() }
    @objc private func menuDelete() { callbacks.requestDeleteSelected?() }
    @objc private func menuRippleDelete() { callbacks.requestRippleDeleteSelected?() }

    private func fireHeaderButton(_ btn: HeaderButton) {
        switch (btn.kind, btn.trackIsVideo) {
        case (.mute, true):  callbacks.requestToggleVideoEnabled?(btn.trackIndex)
        case (.lock, true):  callbacks.requestToggleVideoLocked?(btn.trackIndex)
        case (.mute, false): callbacks.requestToggleAudioMuted?(btn.trackIndex)
        case (.solo, false): callbacks.requestToggleAudioSolo?(btn.trackIndex)
        case (.lock, false): callbacks.requestToggleAudioLocked?(btn.trackIndex)
        default: break
        }
    }

    private func applyScrub(at point: CGPoint) {
        guard point.x >= Metrics.laneControlsWidth else { return }
        let t = max(0, timeForX(point.x))
        callbacks.setPlayhead?(RationalTime(value: Int64(t * 1000), scale: 1000))
    }

    public override func scrollWheel(with event: NSEvent) {
        scrollOffsetSeconds = max(0, scrollOffsetSeconds - Double(event.scrollingDeltaX) / pixelsPerSecond)
        if event.modifierFlags.contains(.command) {
            // Cmd-scroll = zoom. Route through the same callback + bounds
            // as pinch-zoom so the workspace and the zoom slider stay in sync.
            let factor = 1.0 + Double(event.scrollingDeltaY) * 0.005
            let target = max(Self.minPixelsPerSecond,
                             min(Self.maxPixelsPerSecond, pixelsPerSecond * factor))
            if target != pixelsPerSecond {
                callbacks.setPixelsPerSecond?(target)
            }
        }
        needsDisplay = true
    }

    // MARK: - Drag and drop accept

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateGhost(for: sender)
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateGhost(for: sender)
        return .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        if dragGhost != nil {
            dragGhost = nil
            needsDisplay = true
        }
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard let str = pasteboard.string(forType: .string),
              let payload = DragPayload.parse(str) else {
            dragGhost = nil; needsDisplay = true
            return false
        }

        let pointInView = convert(sender.draggingLocation, from: nil)
        guard pointInView.x >= Metrics.laneControlsWidth else {
            dragGhost = nil; needsDisplay = true
            return false
        }
        let t = max(0, timeForX(pointInView.x))
        let snapped = snapTime(t, excluding: nil)
        let dropTime = RationalTime(value: Int64(snapped * 1000), scale: 1000)

        // Compute target video track index: 0 for V1 (default), or the
        // phantom track count above when the user dragged above V1.
        // Existing video track count + phantom-above = absolute index.
        let phantomAbove = phantomTracksAbove(yInView: pointInView.y)
        let existingCount = sequence?.videoTracks.count ?? 1
        // V1 is at index 0; "1 phantom above" means V2 (= index existingCount).
        let targetIndex = phantomAbove == 0 ? 0 : (existingCount - 1) + phantomAbove

        if let start = payload.sourceStart, let dur = payload.sourceDuration {
            callbacks.insertClipFragment?(payload.clipID, start, dur, dropTime, targetIndex)
        } else {
            callbacks.insertClip?(payload.clipID, dropTime, targetIndex)
        }

        dragGhost = nil
        needsDisplay = true
        return true
    }

    private func updateGhost(for sender: NSDraggingInfo) {
        guard let str = sender.draggingPasteboard.string(forType: .string),
              let payload = DragPayload.parse(str) else {
            if dragGhost != nil { dragGhost = nil; needsDisplay = true }
            return
        }
        guard let source = callbacks.clipSourceForID?(payload.clipID) else {
            if dragGhost != nil { dragGhost = nil; needsDisplay = true }
            return
        }
        let pointInView = convert(sender.draggingLocation, from: nil)
        let t = max(0, timeForX(pointInView.x))
        let snapped = snapTime(t, excluding: nil)
        let dragDuration = payload.sourceDuration ?? source.duration.seconds

        // Detect phantom-track-above-V1 zone. If cursor Y is in the
        // ruler band OR above the top of V1's row, we're in "create
        // new video track" territory. Each `trackHeight + trackSpacing`
        // band above adds one more new track.
        let phantomCount = phantomTracksAbove(yInView: pointInView.y)

        let next = DragGhost(
            clipID: payload.clipID,
            source: source,
            startSeconds: snapped,
            durationSeconds: dragDuration,
            newVideoTracksAbove: phantomCount
        )
        if dragGhost?.startSeconds != next.startSeconds
            || dragGhost?.clipID != next.clipID
            || dragGhost?.durationSeconds != next.durationSeconds
            || dragGhost?.newVideoTracksAbove != next.newVideoTracksAbove {
            dragGhost = next
            needsDisplay = true
        }
    }

    /// Find which track in the active sequence holds the given clip.
    private func currentTrackOf(_ id: PlacedClipID) -> MoveTargetTrack? {
        guard let sequence else { return nil }
        for (vIdx, track) in sequence.videoTracks.enumerated() {
            if track.clips.contains(where: { $0.id == id }) {
                return MoveTargetTrack(kind: 0, index: vIdx)
            }
        }
        for (aIdx, track) in sequence.audioTracks.enumerated() {
            if track.clips.contains(where: { $0.id == id }) {
                return MoveTargetTrack(kind: 1, index: aIdx)
            }
        }
        return nil
    }

    /// Translate a Y-coordinate in the view to a (kind, index) of the
    /// track being hovered. Iterates the laid-out lane stack from top
    /// to bottom. Returns nil if Y is in the ruler band or outside any
    /// track lane.
    private func trackAtY(_ y: CGFloat) -> MoveTargetTrack? {
        guard let sequence else { return nil }
        var cursor = Metrics.rulerHeight
        // Video tracks are drawn top-down in reversed order.
        for v in sequence.videoTracks.reversed() {
            _ = v
            let band = Metrics.trackHeight + Metrics.trackSpacing
            if y >= cursor && y < cursor + band {
                // Find this video track's actual index in the
                // (non-reversed) array.
                let reversed = sequence.videoTracks.reversed().map(\.id)
                if let pos = reversed.firstIndex(of: v.id) {
                    // Reversed pos N → original index (count - 1 - N)
                    return MoveTargetTrack(kind: 0, index: sequence.videoTracks.count - 1 - pos)
                }
                return nil
            }
            cursor += band
        }
        cursor += Metrics.separatorHeight
        for (aIdx, _) in sequence.audioTracks.enumerated() {
            let band = Metrics.trackHeight + Metrics.trackSpacing
            if y >= cursor && y < cursor + band {
                return MoveTargetTrack(kind: 1, index: aIdx)
            }
            cursor += band
        }
        return nil
    }

    private func phantomTracksAbove(yInView y: CGFloat) -> Int {
        // Where does V_top start (the topmost-drawn video row)?
        // Y axis is flipped (top=0 because isFlipped=true).
        // Rows start at `Metrics.rulerHeight`.
        let v1Top = Metrics.rulerHeight
        if y >= v1Top { return 0 }
        // Within the ruler band: still count any phantom rows it could
        // accommodate above V_top. Each band is `trackHeight + trackSpacing`.
        let bandHeight = Metrics.trackHeight + Metrics.trackSpacing
        let above = v1Top - y
        // Cap phantom tracks at, say, 4 — anything higher is unrealistic
        return min(4, max(1, Int(ceil(above / bandHeight))))
    }

    /// Phantom audio tracks BELOW the bottommost audio row. Mirrors
    /// `phantomTracksAbove` but for the drag-existing-audio-clip-down
    /// flow that auto-creates new audio tracks.
    private func phantomAudioTracksBelow(yInView y: CGFloat, in sequence: Sequence) -> Int {
        let band = Metrics.trackHeight + Metrics.trackSpacing
        let audioBlockBottom = Metrics.rulerHeight
            + CGFloat(sequence.videoTracks.count) * band
            + Metrics.separatorHeight
            + CGFloat(sequence.audioTracks.count) * band
        if y <= audioBlockBottom { return 0 }
        let below = y - audioBlockBottom
        return min(4, max(1, Int(ceil(below / band))))
    }
}
