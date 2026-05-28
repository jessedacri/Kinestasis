import SwiftUI
import AppKit
import PreemCore

/// Effect Controls — Premiere-style inline inspector that lives as a
/// tab in the Source pane. Edits the selected clip's `ClipTransform`
/// (position, scale, opacity, crop). Updates flow per-parameter through
/// `WorkspaceModel.setTransformParameterOnSelection` so undo + render-
/// cache invalidation behave normally, and the Program viewer reacts
/// live because both views observe the same `WorkspaceModel`.
///
/// Each keyframable parameter has a stopwatch icon (Premiere's
/// convention). When on, value edits write keyframes at the program
/// playhead instead of mutating a constant. The keyframe strip at the
/// bottom shows diamond markers in clip-local time; click-to-add at
/// the playhead, drag a diamond to retime, double-click to delete.
struct EffectControlsContent: View {
    @ObservedObject var workspace: WorkspaceModel
    @State private var scaleLocked: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            if workspace.selectedVideoClipIDs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        transformSection
                        cropSection
                    }
                    .padding(16)
                }
                Divider()
                keyframeStrip
            }
            Divider()
            footer
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Select a clip on the timeline to edit its transform.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var footer: some View {
        HStack {
            Button("Reset") {
                workspace.setSelectedClipsTransform(.identity)
            }
            .disabled(workspace.selectedVideoClipIDs.isEmpty)
            Spacer()
            if workspace.selectedVideoClipIDs.count > 1 {
                Text("\(workspace.selectedVideoClipIDs.count) clips")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Live read at playhead

    /// Single-source read of the current transform — re-runs every time
    /// the workspace publishes (playhead, undo, direct-manipulation).
    private var currentTransform: ClipTransform {
        if let first = workspace.selectedClipIDs.first,
           let t = workspace.clipTransform(first) {
            return t
        }
        return .identity
    }

    /// The "lead" placed clip ID — drives the keyframe-strip rendering.
    /// Only video clips can carry Transform/Crop, so audio-linked
    /// siblings of a selected video clip are not "leads."
    private var leadClipID: PlacedClipID? {
        workspace.selectedVideoClipIDs.first
    }

    // MARK: - Transform section

    private var transformSection: some View {
        section(title: "Transform") {
            paramPair(label: "Position", a: .positionX, b: .positionY, format: "%.3f", step: 0.01)
            scaleRow
            paramSlider(label: "Opacity", parameter: .opacity, in: 0...1) { v in
                Text(String(format: "%.0f%%", v * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            rotationRow
            row(label: "Fill Mode", stopwatch: { Color.clear.frame(width: 11, height: 11) }) {
                Picker("", selection: Binding(
                    get: { currentTransform.stretchToFill },
                    set: { newValue in
                        var t = currentTransform
                        t.stretchToFill = newValue
                        workspace.setSelectedClipsTransform(t)
                    }
                )) {
                    Text("Aspect Fit").tag(false)
                    Text("Stretch to Fill").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
        }
    }

    // MARK: - Scale row (percent display + lock toggle)

    /// Scale display is in percent (100% = unity multiplier of 1.0).
    /// When the lock toggle is on, editing X also updates Y by the
    /// same ratio so the picture stays proportional.
    @ViewBuilder
    private var scaleRow: some View {
        let isKeyed = paramKeyed(.scaleX) || paramKeyed(.scaleY)
        row(label: "Scale", stopwatch: { stopwatchButton(active: isKeyed) { toggleKeyframingPair(.scaleX, .scaleY) } }) {
            HStack(spacing: 6) {
                Button {
                    scaleLocked.toggle()
                } label: {
                    Image(systemName: scaleLocked ? "link" : "link.badge.plus")
                        .font(.system(size: 11))
                        .foregroundStyle(scaleLocked ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(scaleLocked ? "X/Y linked — drag X or Y to scale uniformly" : "X/Y independent — drag each axis separately")

                numericLabel("X", widthHint: 14)
                percentField(parameter: .scaleX, link: scaleLocked ? .scaleY : nil, range: 1...1000)
                Spacer().frame(width: 6)
                numericLabel("Y", widthHint: 14)
                percentField(parameter: .scaleY, link: scaleLocked ? .scaleX : nil, range: 1...1000)

                Button {
                    workspace.setTransformParameterOnSelection(.scaleX, 1)
                    workspace.setTransformParameterOnSelection(.scaleY, 1)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset scale to 100%")
            }
        }
    }

    /// Numeric field that displays a value as a percentage. Underlying
    /// param is a multiplier (1.0 = 100%). If `link` is provided, the
    /// linked param is scaled by the same ratio to keep uniform scale.
    @ViewBuilder
    private func percentField(
        parameter: TransformParameter,
        link: TransformParameter?,
        range: ClosedRange<Double>
    ) -> some View {
        let fmt: NumberFormatter = {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.minimumFractionDigits = 0
            f.maximumFractionDigits = 2
            return f
        }()
        let bind = Binding<Double>(
            get: { currentValue(parameter) * 100 },
            set: { percent in
                let clamped = max(range.lowerBound, min(range.upperBound, percent))
                let newVal = clamped / 100.0
                let oldVal = currentValue(parameter)
                workspace.setTransformParameterOnSelection(parameter, newVal)
                if let link {
                    // Keep the linked axis proportional. If old was 0,
                    // mirror to the new value to avoid divide-by-zero.
                    let linkedOld = currentValue(link)
                    if oldVal > 0.0001 {
                        let ratio = newVal / oldVal
                        workspace.setTransformParameterOnSelection(link, linkedOld * ratio)
                    } else {
                        workspace.setTransformParameterOnSelection(link, newVal)
                    }
                }
            }
        )
        HStack(spacing: 2) {
            TextField("", value: bind, formatter: fmt)
                .font(.system(size: 11, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
            Text("%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Rotation row (slider + degrees field + reset)

    @ViewBuilder
    private var rotationRow: some View {
        row(label: "Rotation", stopwatch: { stopwatchButton(active: paramKeyed(.rotation)) { workspace.toggleKeyframingOnSelection(.rotation) } }) {
            HStack(spacing: 8) {
                ThinSlider(
                    value: Binding(
                        get: { currentValue(.rotation) },
                        set: { workspace.setTransformParameterOnSelection(.rotation, $0) }
                    ),
                    range: -180...180
                )
                HStack(spacing: 2) {
                    rotationField
                    Text("°")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Button {
                    workspace.setTransformParameterOnSelection(.rotation, 0)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset rotation to 0°")
            }
        }
    }

    private var rotationField: some View {
        let fmt: NumberFormatter = {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.minimumFractionDigits = 0
            f.maximumFractionDigits = 2
            // Accept negative and positive numbers, and bare "0".
            f.allowsFloats = true
            return f
        }()
        let bind = Binding<Double>(
            get: { currentValue(.rotation) },
            set: { newVal in
                let clamped = max(-360, min(360, newVal))
                workspace.setTransformParameterOnSelection(.rotation, clamped)
            }
        )
        return TextField("", value: bind, formatter: fmt)
            .font(.system(size: 11, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .frame(width: 56)
    }

    // MARK: - Crop section

    private var cropSection: some View {
        section(title: "Crop") {
            paramSlider(label: "Top",     parameter: .cropTop,     in: 0...0.9, percent: true)
            paramSlider(label: "Right",   parameter: .cropRight,   in: 0...0.9, percent: true)
            paramSlider(label: "Bottom",  parameter: .cropBottom,  in: 0...0.9, percent: true)
            paramSlider(label: "Left",    parameter: .cropLeft,    in: 0...0.9, percent: true)
            paramSlider(label: "Feather", parameter: .cropFeather, in: 0...0.5, percent: true)
        }
    }

    // MARK: - Row builders

    /// A row showing two X/Y numeric fields side-by-side. Stopwatch
    /// reflects whichever of the two is keyframed (toggling flips both
    /// to stay in sync — Position/Scale are conceptually paired).
    @ViewBuilder
    private func paramPair(
        label: String,
        a: TransformParameter, b: TransformParameter,
        format: String,
        step: Double,
        range: ClosedRange<Double>? = nil
    ) -> some View {
        let isKeyed = paramKeyed(a) || paramKeyed(b)
        row(label: label, stopwatch: { stopwatchButton(active: isKeyed) { toggleKeyframingPair(a, b) } }) {
            HStack(spacing: 6) {
                numericLabel("X", widthHint: 14)
                numericField(parameter: a, format: format, step: step, range: range)
                Spacer().frame(width: 8)
                numericLabel("Y", widthHint: 14)
                numericField(parameter: b, format: format, step: step, range: range)
            }
        }
    }

    @ViewBuilder
    private func paramSlider<Trailing: View>(
        label: String,
        parameter: TransformParameter,
        in range: ClosedRange<Double>,
        percent: Bool = false,
        @ViewBuilder trailing: (Double) -> Trailing
    ) -> some View {
        row(label: label, stopwatch: { stopwatchButton(active: paramKeyed(parameter)) { workspace.toggleKeyframingOnSelection(parameter) } }) {
            HStack(spacing: 8) {
                ThinSlider(
                    value: Binding(
                        get: { currentValue(parameter) },
                        set: { newVal in workspace.setTransformParameterOnSelection(parameter, newVal) }
                    ),
                    range: range
                )
                trailing(currentValue(parameter))
            }
        }
    }

    @ViewBuilder
    private func paramSlider(
        label: String,
        parameter: TransformParameter,
        in range: ClosedRange<Double>,
        percent: Bool = false
    ) -> some View {
        paramSlider(label: label, parameter: parameter, in: range, percent: percent) { v in
            Text(percent ? String(format: "%.1f%%", v * 100) : String(format: "%.3f", v))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func paramRow<Content: View>(
        label: String,
        parameter: TransformParameter,
        @ViewBuilder content: () -> Content
    ) -> some View {
        row(label: label, stopwatch: { stopwatchButton(active: paramKeyed(parameter)) { workspace.toggleKeyframingOnSelection(parameter) } }) {
            content()
        }
    }

    // MARK: - Reusable widgets

    @ViewBuilder
    private func numericField(
        parameter: TransformParameter,
        format: String,
        step: Double,
        range: ClosedRange<Double>? = nil
    ) -> some View {
        let fmt: NumberFormatter = {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.minimumFractionDigits = 0
            f.maximumFractionDigits = 4
            return f
        }()
        let bind = Binding<Double>(
            get: { currentValue(parameter) },
            set: { newValue in
                let clamped = range.map { max($0.lowerBound, min($0.upperBound, newValue)) } ?? newValue
                workspace.setTransformParameterOnSelection(parameter, clamped)
            }
        )
        TextField("", value: bind, formatter: fmt)
            .font(.system(size: 11, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
    }

    @ViewBuilder
    private func stopwatchButton(active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: active ? "stopwatch.fill" : "stopwatch")
                .font(.system(size: 11))
                .foregroundStyle(active ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(active ? "Disable keyframing — collapses to constant at the playhead value" : "Enable keyframing — value edits write a keyframe at the playhead")
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            VStack(spacing: 8) {
                content()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
            )
        }
    }

    @ViewBuilder
    private func row<Stopwatch: View, Content: View>(
        label: String,
        @ViewBuilder stopwatch: () -> Stopwatch,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            stopwatch()
                .frame(width: 18)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    private func numericLabel(_ s: String, widthHint: CGFloat) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: widthHint, alignment: .trailing)
    }

    // MARK: - Reads

    private func currentValue(_ p: TransformParameter) -> Double {
        let t = currentTransform
        switch p {
        case .positionX:   return t.positionX
        case .positionY:   return t.positionY
        case .scaleX:      return t.scaleX
        case .scaleY:      return t.scaleY
        case .opacity:     return t.opacity
        case .rotation:    return t.rotationDegrees
        case .cropTop:     return t.cropTop
        case .cropRight:   return t.cropRight
        case .cropBottom:  return t.cropBottom
        case .cropLeft:    return t.cropLeft
        case .cropFeather: return t.cropFeather
        }
    }

    private func paramKeyed(_ p: TransformParameter) -> Bool {
        guard let id = leadClipID, let clip = workspace.findPlacedClip(id) else { return false }
        return clip.hasKeyframes(for: p)
    }

    private func toggleKeyframingPair(_ a: TransformParameter, _ b: TransformParameter) {
        // Pair behavior: if EITHER is keyed, flip BOTH off; else flip both on.
        let anyOn = paramKeyed(a) || paramKeyed(b)
        if anyOn {
            if paramKeyed(a) { workspace.toggleKeyframingOnSelection(a) }
            if paramKeyed(b) { workspace.toggleKeyframingOnSelection(b) }
        } else {
            workspace.toggleKeyframingOnSelection(a)
            workspace.toggleKeyframingOnSelection(b)
        }
    }

    // MARK: - Keyframe strip

    @ViewBuilder
    private var keyframeStrip: some View {
        if let id = leadClipID, let clip = workspace.findPlacedClip(id) {
            let keyedParams = TransformParameter.allCases.filter { clip.hasKeyframes(for: $0) }
            if keyedParams.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "diamond")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("No keyframes — toggle a stopwatch to start keyframing")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.2))
            } else {
                KeyframeStripView(
                    workspace: workspace,
                    clipID: id,
                    clip: clip,
                    parameters: keyedParams
                )
            }
        }
    }
}

// MARK: - Keyframe strip

/// Per-parameter horizontal timeline showing diamond markers for the
/// clip's keyframes (in clip-local seconds). Playhead overlay tracks
/// `workspace.playheadTime - clip.timelineRange.start`. Click anywhere
/// on a parameter's row to add a keyframe at that x; drag a diamond
/// to retime; double-click to delete.
private struct KeyframeStripView: View {
    @ObservedObject var workspace: WorkspaceModel
    let clipID: PlacedClipID
    let clip: PlacedClip
    let parameters: [TransformParameter]

    @State private var dragging: (param: TransformParameter, originalTime: Double)?
    @State private var stripZoom: Double = 1.0

    var body: some View {
        let clipDuration = clip.timelineRange.duration.seconds
        let videoCount = workspace.selectedVideoClipIDs.count
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if videoCount > 1 {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").font(.system(size: 9))
                        Text("Showing lead clip · \(videoCount) selected · strip edits apply to lead only, slider edits apply to all")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer()
                zoomControls
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            // Horizontal scroll so the user can zoom into dense
            // keyframe regions and grab tightly-spaced diamonds. The
            // strip content width = visible container × stripZoom.
            // ThinScrollView gives us a slim overlay scrollbar that
            // ignores macOS's "Show scroll bars" system preference.
            GeometryReader { containerGeo in
                ThinScrollView(axis: .horizontal) {
                    VStack(spacing: 0) {
                        ForEach(parameters, id: \.self) { param in
                            paramRow(param: param, clipDuration: clipDuration, rowWidth: containerGeo.size.width * CGFloat(stripZoom))
                        }
                    }
                }
            }
            .frame(height: CGFloat(parameters.count) * 22)
        }
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.25))
    }

    @ViewBuilder
    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button {
                stripZoom = max(0.5, stripZoom / 1.5)
            } label: {
                Image(systemName: "minus.magnifyingglass").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Zoom out")

            Text(stripZoom >= 1 ? "\(Int(stripZoom))×" : String(format: "%.1f×", stripZoom))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .center)

            Button {
                stripZoom = min(50.0, stripZoom * 1.5)
            } label: {
                Image(systemName: "plus.magnifyingglass").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Zoom in")

            Button("Fit") { stripZoom = 1.0 }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help("Reset to clip-fit")
        }
    }

    @ViewBuilder
    private func paramRow(param: TransformParameter, clipDuration: Double, rowWidth: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(param.displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)

            let width = max(40, rowWidth - 124)  // 100 label + 24 padding/spacing
            let playheadLocal = playheadClipLocal()
            let kfs = clip.keyframes(for: param)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
                    .position(x: width / 2, y: 11)

                if let p = playheadLocal, clipDuration > 0 {
                    let x = (p / clipDuration) * width
                    if x >= 0 && x <= width {
                        Rectangle()
                            .fill(Color.white.opacity(0.4))
                            .frame(width: 1, height: 22)
                            .position(x: x, y: 11)
                    }
                }

                ForEach(kfs.indices, id: \.self) { i in
                    let kf = kfs[i]
                    let x = clipDuration > 0
                        ? CGFloat(kf.time.seconds / clipDuration) * width
                        : 0
                    if x >= -10 && x <= width + 10 {
                        ZStack {
                            // Larger transparent hit shape so the
                            // diamond is easy to grab even when zoomed
                            // out and visually small.
                            Rectangle()
                                .fill(Color.clear)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                            keyframeMarker(for: kf)
                                .frame(width: 10, height: 10)
                        }
                        .position(x: x, y: 11)
                        .onTapGesture(count: 2) {
                            workspace.removeKeyframeAt(clipID, param, atClipLocal: kf.time.seconds)
                        }
                        .gesture(diamondDragGesture(param: param, original: kf.time.seconds, width: width, duration: clipDuration))
                        .contextMenu {
                            Section("Interpolation") {
                                interpolationButton("Linear",      param, kf, .linear)
                                interpolationButton("Hold (Step)", param, kf, .hold)
                                interpolationButton("Ease In",     param, kf, .easeIn)
                                interpolationButton("Ease Out",    param, kf, .easeOut)
                                interpolationButton("Ease In/Out", param, kf, .bezier)
                            }
                            Divider()
                            Button("Delete Keyframe") {
                                workspace.removeKeyframeAt(clipID, param, atClipLocal: kf.time.seconds)
                            }
                        }
                    }
                }
            }
            .frame(width: width, height: 22)
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard clipDuration > 0 else { return }
                let frac = max(0, min(1, location.x / width))
                let t = frac * clipDuration
                let v = sampleDouble(
                    clip.effects.first(where: { $0.effectKey == param.effectKey })?
                        .parameters[param.parameterName],
                    at: t,
                    default: param.defaultValue
                )
                workspace.addKeyframe(clipID, param, atClipLocal: t, value: v)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 0)
    }

    private func diamondDragGesture(
        param: TransformParameter,
        original: Double,
        width: CGFloat,
        duration: Double
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragging == nil {
                    dragging = (param, original)
                    workspace.beginUndoBatch()
                }
                guard let d = dragging, duration > 0 else { return }
                let frac = max(0, min(1, value.location.x / width))
                let newT = frac * duration
                // Light path during drag — no cache/audio invalidation
                // until the user lets go.
                workspace.moveKeyframeLight(clipID, param, from: d.originalTime, to: newT)
                dragging = (param, newT)
            }
            .onEnded { _ in
                if let d = dragging {
                    // No actual move — just trigger a single proper
                    // update so cache + audio invalidate once at the
                    // end of the drag.
                    workspace.moveKeyframe(clipID, param, from: d.originalTime, to: d.originalTime)
                }
                dragging = nil
                workspace.endUndoBatch()
            }
    }

    private func playheadClipLocal() -> Double? {
        let p = workspace.playheadTime.seconds - clip.timelineRange.start.seconds
        return p
    }

    @ViewBuilder
    private func keyframeMarker(for kf: Keyframe) -> some View {
        switch kf.interpolation {
        case .linear:
            DiamondShape().fill(Color.orange)
        case .hold:
            // Square = "value is held until the next keyframe" — same
            // shorthand Premiere / After Effects / Resolve use.
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.orange)
        case .easeIn:
            // Half-filled — solid on the left (constant entry) and
            // dimmed on the right (the ease-out side of this segment).
            ZStack {
                DiamondShape().fill(Color.orange.opacity(0.35))
                HalfDiamondShape(leftFilled: true).fill(Color.orange)
            }
        case .easeOut:
            ZStack {
                DiamondShape().fill(Color.orange.opacity(0.35))
                HalfDiamondShape(leftFilled: false).fill(Color.orange)
            }
        case .bezier:
            // Outlined diamond with a soft inner fill = "eased on
            // both ends" — the most subtle/smooth interpolation.
            ZStack {
                DiamondShape().stroke(Color.orange, lineWidth: 1.5)
                DiamondShape().fill(Color.orange.opacity(0.35))
            }
        }
    }

    @ViewBuilder
    private func interpolationButton(
        _ title: String,
        _ param: TransformParameter,
        _ kf: Keyframe,
        _ mode: Interpolation
    ) -> some View {
        Button(action: {
            workspace.setKeyframeInterpolation(clipID, param, atClipLocal: kf.time.seconds, mode)
        }) {
            HStack {
                if kf.interpolation == mode {
                    Image(systemName: "checkmark")
                }
                Text(title)
            }
        }
    }
}

/// Half-diamond used to visualize ease-in / ease-out keyframes — one
/// side shows the "fast" (linear) entry/exit, the other side renders
/// dimmed to indicate the eased side of the curve.
private struct HalfDiamondShape: Shape {
    let leftFilled: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        if leftFilled {
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        } else {
            p.move(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}

private struct DiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.closeSubpath()
        return p
    }
}
