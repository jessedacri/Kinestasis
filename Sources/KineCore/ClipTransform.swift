import Foundation

/// Per-clip transform + crop. Stored in `PlacedClip.effects` as two
/// effect instances (`kine.transform` and `kine.crop`); this struct
/// is the typed view both the offline compositor and the Effect
/// Controls inspector read/write through.
///
/// **Position** is in normalized sequence-coordinate units — (0, 0) is
/// the sequence frame's center, (1, 0) is one sequence-width to the
/// right, (0, 1) is one sequence-height down. This is the same
/// convention Premiere/Resolve use; scaling and resolution changes
/// don't move the clip relative to the frame.
///
/// **Scale** is multiplicative; 1.0 = aspect-preserved fit (the default).
///
/// **Opacity** is 0…1 and stacks multiplicatively with transition fade
/// opacity computed by the compositor.
///
/// **Crop** is in source-pixel-space normalized units (0…1 of the
/// source frame). top=0 left=0 bottom=1 right=1 = no crop.
///
/// Rotation is parked on the schema for the next session — the offline
/// compositor's shader doesn't yet apply a full affine matrix.
public struct ClipTransform: Equatable {
    public var positionX: Double      // -1 … +1 normalized (typical)
    public var positionY: Double
    public var scaleX: Double         // 1.0 = aspect-fit (default)
    public var scaleY: Double         // 1.0 = aspect-fit (default)
    public var opacity: Double        // 0 … 1
    public var rotationDegrees: Double  // -360 … +360
    public var cropTop: Double        // 0 … 1
    public var cropRight: Double      // 0 … 1
    public var cropBottom: Double     // 0 … 1
    public var cropLeft: Double       // 0 … 1
    /// Soft-edge falloff width for the crop, as a 0…1 fraction of the
    /// picture's smaller pixel dimension. 0 = hard cut (default).
    public var cropFeather: Double
    public var stretchToFill: Bool    // true = ignore aspect, fill the dest rect

    public static let identity = ClipTransform(
        positionX: 0, positionY: 0,
        scaleX: 1, scaleY: 1,
        opacity: 1,
        rotationDegrees: 0,
        cropTop: 0, cropRight: 0, cropBottom: 0, cropLeft: 0,
        cropFeather: 0,
        stretchToFill: false
    )

    public init(
        positionX: Double = 0,
        positionY: Double = 0,
        scaleX: Double = 1,
        scaleY: Double = 1,
        opacity: Double = 1,
        rotationDegrees: Double = 0,
        cropTop: Double = 0,
        cropRight: Double = 0,
        cropBottom: Double = 0,
        cropLeft: Double = 0,
        cropFeather: Double = 0,
        stretchToFill: Bool = false
    ) {
        self.positionX = positionX
        self.positionY = positionY
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.opacity = opacity
        self.rotationDegrees = rotationDegrees
        self.cropTop = cropTop
        self.cropRight = cropRight
        self.cropBottom = cropBottom
        self.cropLeft = cropLeft
        self.cropFeather = cropFeather
        self.stretchToFill = stretchToFill
    }

    public var isIdentity: Bool { self == .identity }
}

/// Identifies one keyframable Transform/Crop parameter. Used by the
/// inspector to address the per-parameter stopwatch + keyframe strip,
/// and by `PlacedClip` helpers that read/write keyframes.
public enum TransformParameter: String, CaseIterable, Sendable {
    case positionX, positionY
    case scaleX, scaleY
    case opacity
    case rotation
    case cropTop, cropRight, cropBottom, cropLeft
    case cropFeather

    public var effectKey: String {
        switch self {
        case .positionX, .positionY, .scaleX, .scaleY, .opacity, .rotation:
            return "kine.transform"
        case .cropTop, .cropRight, .cropBottom, .cropLeft, .cropFeather:
            return "kine.crop"
        }
    }

    public var parameterName: String {
        switch self {
        case .positionX:   return "positionX"
        case .positionY:   return "positionY"
        case .scaleX:      return "scaleX"
        case .scaleY:      return "scaleY"
        case .opacity:     return "opacity"
        case .rotation:    return "rotation"
        case .cropTop:     return "top"
        case .cropRight:   return "right"
        case .cropBottom:  return "bottom"
        case .cropLeft:    return "left"
        case .cropFeather: return "feather"
        }
    }

    public var defaultValue: Double {
        switch self {
        case .scaleX, .scaleY, .opacity: return 1
        default: return 0
        }
    }

    public var displayName: String {
        switch self {
        case .positionX:   return "Position X"
        case .positionY:   return "Position Y"
        case .scaleX:      return "Scale X"
        case .scaleY:      return "Scale Y"
        case .opacity:     return "Opacity"
        case .rotation:    return "Rotation"
        case .cropTop:     return "Crop Top"
        case .cropRight:   return "Crop Right"
        case .cropBottom:  return "Crop Bottom"
        case .cropLeft:    return "Crop Left"
        case .cropFeather: return "Crop Feather"
        }
    }
}

/// Evaluate a `ParameterValue` (constant or keyframed) to a Double at
/// the given clip-local time in seconds. Linear interpolation between
/// `.linear` keyframes; `.hold` jumps step-wise; `.bezier` is
/// linear-for-now (curve handles not in the schema yet). Times before
/// the first keyframe clamp to the first value; after the last,
/// clamp to the last.
public func sampleDouble(_ value: ParameterValue?, at clipLocalSeconds: Double, default defaultValue: Double) -> Double {
    guard let value else { return defaultValue }
    switch value {
    case .double(let v):
        return v
    case .keyframed(let kfs):
        guard !kfs.isEmpty else { return defaultValue }
        // Writers keep keyframes sorted by time; only re-sort (and
        // allocate) if that invariant is violated — e.g. a hand-edited
        // project file. Steady-state sampling is allocation-free.
        var isSorted = true
        if kfs.count > 1 {
            for k in 1..<kfs.count where kfs[k].time.seconds < kfs[k - 1].time.seconds {
                isSorted = false
                break
            }
        }
        let sorted = isSorted ? kfs : kfs.sorted { $0.time.seconds < $1.time.seconds }
        if clipLocalSeconds <= sorted.first!.time.seconds {
            if case .double(let v) = sorted.first!.value { return v }
            return defaultValue
        }
        if clipLocalSeconds >= sorted.last!.time.seconds {
            if case .double(let v) = sorted.last!.value { return v }
            return defaultValue
        }
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i]
            let b = sorted[i + 1]
            let aT = a.time.seconds
            let bT = b.time.seconds
            if clipLocalSeconds >= aT && clipLocalSeconds <= bT {
                guard case .double(let av) = a.value else { return defaultValue }
                guard case .double(let bv) = b.value else { return av }
                let span = bT - aT
                if span <= 0 { return bv }
                let u = (clipLocalSeconds - aT) / span
                let delta = bv - av

                // Hold is a property of the LEADING keyframe — if it's
                // held, the value stays at av for the whole segment.
                if a.interpolation == .hold {
                    return av
                }

                // Premiere / After Effects model: a keyframe's
                // `interpolation` describes BOTH the out-side leaving
                // it and the in-side arriving at it. For segment A→B:
                //
                //   - "slow start" (flat tangent at A) when A is
                //     easeOut or bezier — A "eases out" of itself.
                //   - "slow finish" (flat tangent at B) when B is
                //     easeIn or bezier — B "eases in" to itself.
                //
                // This matches user intuition: right-clicking the END
                // keyframe and picking "Ease In" makes the curve
                // decelerate INTO that keyframe.
                let slowStart = (a.interpolation == .easeOut || a.interpolation == .bezier)
                let slowEnd   = (b.interpolation == .easeIn  || b.interpolation == .bezier)

                if !slowStart && !slowEnd {
                    return av + delta * u
                }

                // Cubic Hermite: H(u) = h00·A + h10·m0 + h01·B + h11·m1
                let h00 =  2*u*u*u - 3*u*u + 1
                let h10 =    u*u*u - 2*u*u + u
                let h01 = -2*u*u*u + 3*u*u
                let h11 =    u*u*u -   u*u
                // Tangent at each endpoint: 0 (eased) or delta (linear slope).
                let m0 = slowStart ? 0.0 : delta
                let m1 = slowEnd   ? 0.0 : delta
                return av * h00 + m0 * h10 + bv * h01 + m1 * h11
            }
        }
        return defaultValue
    default:
        return defaultValue
    }
}

public extension PlacedClip {
    /// Decoded `ClipTransform` for this clip, sampled at the given
    /// clip-local time (seconds since the clip's `timelineRange.start`).
    /// Parameters can be stored as a constant `.double(...)` or as
    /// `.keyframed([Keyframe])`; keyframed parameters are interpolated
    /// per their `Interpolation` mode. Keyframe times are stored in
    /// clip-local seconds so they stay welded to the clip when it slips
    /// or ripples on the timeline.
    ///
    /// Cheap to call per-frame on the compositor's render path — the
    /// keyframe arrays for one clip are tiny (handfuls, not thousands).
    func transform(at clipLocalSeconds: Double) -> ClipTransform {
        var t = ClipTransform.identity
        for eff in effects where !eff.isBypassed {
            switch eff.effectKey {
            case "kine.transform":
                t.positionX = sampleDouble(eff.parameters["positionX"], at: clipLocalSeconds, default: 0)
                t.positionY = sampleDouble(eff.parameters["positionY"], at: clipLocalSeconds, default: 0)
                t.scaleX    = sampleDouble(eff.parameters["scaleX"],    at: clipLocalSeconds, default: 1)
                t.scaleY    = sampleDouble(eff.parameters["scaleY"],    at: clipLocalSeconds, default: 1)
                t.opacity   = sampleDouble(eff.parameters["opacity"],   at: clipLocalSeconds, default: 1)
                t.rotationDegrees = sampleDouble(eff.parameters["rotation"], at: clipLocalSeconds, default: 0)
                if case .bool(let v) = eff.parameters["stretchToFill"] ?? .bool(false) { t.stretchToFill = v }
            case "kine.crop":
                t.cropTop     = sampleDouble(eff.parameters["top"],     at: clipLocalSeconds, default: 0)
                t.cropRight   = sampleDouble(eff.parameters["right"],   at: clipLocalSeconds, default: 0)
                t.cropBottom  = sampleDouble(eff.parameters["bottom"],  at: clipLocalSeconds, default: 0)
                t.cropLeft    = sampleDouble(eff.parameters["left"],    at: clipLocalSeconds, default: 0)
                t.cropFeather = sampleDouble(eff.parameters["feather"], at: clipLocalSeconds, default: 0)
            default:
                break
            }
        }
        return t
    }

    /// Whether the given Transform/Crop parameter has any keyframes
    /// set. Used by the inspector to render the stopwatch icon as
    /// active and to decide whether a value edit at the playhead
    /// should write a keyframe vs. mutate the constant.
    func hasKeyframes(for parameter: TransformParameter) -> Bool {
        let key = parameter.effectKey
        let name = parameter.parameterName
        for eff in effects where eff.effectKey == key {
            if case .keyframed = eff.parameters[name] { return true }
        }
        return false
    }

    /// Raw keyframe list for one Transform/Crop parameter (in clip-local
    /// time). Empty if the parameter is constant or unset. Used by the
    /// inspector's keyframe strip.
    func keyframes(for parameter: TransformParameter) -> [Keyframe] {
        let key = parameter.effectKey
        let name = parameter.parameterName
        for eff in effects where eff.effectKey == key {
            if case .keyframed(let kfs) = eff.parameters[name] { return kfs }
        }
        return []
    }

    /// Set one Transform/Crop parameter. If the parameter is currently
    /// keyframed AND `at` is non-nil, upsert a keyframe at that
    /// clip-local time. Otherwise replace the constant value. Routes
    /// through the per-effect parameter dictionaries so the value
    /// flows through `PlacedClip.transform(at:)` next render.
    mutating func setParameter(
        _ parameter: TransformParameter,
        value: Double,
        at clipLocalTime: Double? = nil
    ) {
        let key = parameter.effectKey
        let name = parameter.parameterName

        // Find (or insert) the effect instance.
        var idx = effects.firstIndex { $0.effectKey == key }
        if idx == nil {
            let inst = EffectInstance(effectKey: key, parameters: [:])
            effects.append(inst)
            idx = effects.count - 1
        }
        let i = idx!

        let existing = effects[i].parameters[name]
        if case .keyframed(let kfs) = existing, let t = clipLocalTime {
            // Upsert a keyframe at `t`.
            var updated = kfs
            let tol: Double = 0.001
            if let j = updated.firstIndex(where: { abs($0.time.seconds - t) < tol }) {
                updated[j].value = .double(value)
            } else {
                let kf = Keyframe(
                    time: RationalTime(value: Int64((t * 1000).rounded()), scale: 1000),
                    value: .double(value),
                    interpolation: .linear
                )
                updated.append(kf)
                updated.sort { $0.time.seconds < $1.time.seconds }
            }
            effects[i].parameters[name] = .keyframed(updated)
        } else {
            effects[i].parameters[name] = .double(value)
        }
    }

    /// Flip a Transform/Crop parameter between "constant" and
    /// "keyframed" mode. Going ON converts the current constant into
    /// a single keyframe at `clipLocalTime`. Going OFF collapses all
    /// keyframes to a constant at the value evaluated at `clipLocalTime`
    /// (so the picture doesn't jump when the stopwatch is toggled).
    mutating func toggleKeyframing(
        _ parameter: TransformParameter,
        at clipLocalTime: Double
    ) {
        let key = parameter.effectKey
        let name = parameter.parameterName

        var idx = effects.firstIndex { $0.effectKey == key }
        if idx == nil {
            let inst = EffectInstance(effectKey: key, parameters: [:])
            effects.append(inst)
            idx = effects.count - 1
        }
        let i = idx!

        let existing = effects[i].parameters[name] ?? .double(parameter.defaultValue)
        switch existing {
        case .keyframed:
            let v = sampleDouble(existing, at: clipLocalTime, default: parameter.defaultValue)
            effects[i].parameters[name] = .double(v)
        default:
            let v: Double
            if case .double(let dv) = existing { v = dv } else { v = parameter.defaultValue }
            let kf = Keyframe(
                time: RationalTime(value: Int64((clipLocalTime * 1000).rounded()), scale: 1000),
                value: .double(v),
                interpolation: .linear
            )
            effects[i].parameters[name] = .keyframed([kf])
        }
    }

    /// Remove the keyframe nearest to `clipLocalTime` (within `tolerance`
    /// seconds). If the parameter has no remaining keyframes, collapse
    /// it back to a constant at its default value. No-op if the
    /// parameter is constant or unset.
    mutating func removeKeyframe(
        _ parameter: TransformParameter,
        at clipLocalTime: Double,
        tolerance: Double = 0.01
    ) {
        let key = parameter.effectKey
        let name = parameter.parameterName
        guard let i = effects.firstIndex(where: { $0.effectKey == key }),
              case .keyframed(let kfs) = effects[i].parameters[name] else { return }

        let target = kfs.enumerated().min { lhs, rhs in
            abs(lhs.element.time.seconds - clipLocalTime) < abs(rhs.element.time.seconds - clipLocalTime)
        }
        guard let (idxToRemove, kf) = target,
              abs(kf.time.seconds - clipLocalTime) <= tolerance else { return }

        var updated = kfs
        updated.remove(at: idxToRemove)
        if updated.isEmpty {
            effects[i].parameters[name] = .double(parameter.defaultValue)
        } else {
            effects[i].parameters[name] = .keyframed(updated)
        }
    }

    /// Set the interpolation mode on the keyframe nearest
    /// `clipLocalTime`. No-op if the parameter isn't keyframed or no
    /// keyframe sits within `tolerance` seconds.
    mutating func setKeyframeInterpolation(
        _ parameter: TransformParameter,
        at clipLocalTime: Double,
        _ interpolation: Interpolation,
        tolerance: Double = 0.05
    ) {
        let key = parameter.effectKey
        let name = parameter.parameterName
        guard let i = effects.firstIndex(where: { $0.effectKey == key }),
              case .keyframed(let kfs) = effects[i].parameters[name] else { return }

        guard let (idx, kf) = kfs.enumerated().min(by: { lhs, rhs in
            abs(lhs.element.time.seconds - clipLocalTime)
              < abs(rhs.element.time.seconds - clipLocalTime)
        }) else { return }
        guard abs(kf.time.seconds - clipLocalTime) <= tolerance else { return }

        var updated = kfs
        updated[idx].interpolation = interpolation
        effects[i].parameters[name] = .keyframed(updated)
    }

    /// Move the keyframe at `fromClipLocalTime` to `toClipLocalTime`.
    /// Finds the closest keyframe within `tolerance` and retimes it.
    /// No-op if nothing matches.
    mutating func moveKeyframe(
        _ parameter: TransformParameter,
        from fromClipLocalTime: Double,
        to toClipLocalTime: Double,
        tolerance: Double = 0.05
    ) {
        let key = parameter.effectKey
        let name = parameter.parameterName
        guard let i = effects.firstIndex(where: { $0.effectKey == key }),
              case .keyframed(let kfs) = effects[i].parameters[name] else { return }

        guard let (idxToMove, _) = kfs.enumerated().min(by: { lhs, rhs in
            abs(lhs.element.time.seconds - fromClipLocalTime)
              < abs(rhs.element.time.seconds - fromClipLocalTime)
        }) else { return }
        guard abs(kfs[idxToMove].time.seconds - fromClipLocalTime) <= tolerance else { return }

        let newTime = RationalTime(value: Int64((toClipLocalTime * 1000).rounded()), scale: 1000)
        var moved = kfs[idxToMove]
        moved.time = newTime
        var updated = kfs
        updated.remove(at: idxToMove)
        // Drop any keyframe the move would land on top of, so retiming
        // can't leave two keyframes at the same time.
        updated.removeAll { abs($0.time.seconds - newTime.seconds) < 0.001 }
        updated.append(moved)
        updated.sort { $0.time.seconds < $1.time.seconds }
        effects[i].parameters[name] = .keyframed(updated)
    }

    /// Write a `ClipTransform` into this clip's effects array. Replaces
    /// any existing `kine.transform` / `kine.crop` instances with
    /// the new values. Skipped entirely when `transform == .identity`
    /// so untouched clips don't carry empty effect rows in their JSON.
    /// Used by the legacy whole-transform write path; per-parameter
    /// edits should prefer `setParameter(_:value:at:)` so keyframes
    /// survive.
    mutating func setTransform(_ transform: ClipTransform) {
        effects.removeAll { $0.effectKey == "kine.transform" || $0.effectKey == "kine.crop" }
        if transform == .identity { return }

        // kine.transform — only write if something differs from identity
        let needsTransform =
            transform.positionX != 0 || transform.positionY != 0
            || transform.scaleX != 1 || transform.scaleY != 1
            || transform.opacity != 1
            || transform.rotationDegrees != 0
            || transform.stretchToFill
        if needsTransform {
            effects.append(EffectInstance(
                effectKey: "kine.transform",
                parameters: [
                    "positionX": .double(transform.positionX),
                    "positionY": .double(transform.positionY),
                    "scaleX":    .double(transform.scaleX),
                    "scaleY":    .double(transform.scaleY),
                    "opacity":   .double(transform.opacity),
                    "rotation":  .double(transform.rotationDegrees),
                    "stretchToFill": .bool(transform.stretchToFill),
                ]
            ))
        }

        let needsCrop =
            transform.cropTop != 0 || transform.cropRight != 0
            || transform.cropBottom != 0 || transform.cropLeft != 0
            || transform.cropFeather != 0
        if needsCrop {
            effects.append(EffectInstance(
                effectKey: "kine.crop",
                parameters: [
                    "top":     .double(transform.cropTop),
                    "right":   .double(transform.cropRight),
                    "bottom":  .double(transform.cropBottom),
                    "left":    .double(transform.cropLeft),
                    "feather": .double(transform.cropFeather),
                ]
            ))
        }
    }
}
