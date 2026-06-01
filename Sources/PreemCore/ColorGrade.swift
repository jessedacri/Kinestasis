import Foundation

/// How a clip's encoded pixels should be interpreted on the way into the
/// linear working space. The transfer-function + primaries math lives in
/// the compositor shader, keyed by `shaderID`; Swift only carries the tag.
public enum ColorTransferSpace: String, Codable, Sendable, CaseIterable {
    case rec709          // BT.709 primaries, ~2.4 gamma (standard video)
    case sRGB            // sRGB primaries + piecewise EOTF
    case linear          // already scene-linear, Rec.709 primaries
    case rec2020         // BT.2020 primaries, 2.4 gamma
    case arriLogC3       // ARRI LogC3 / Wide Gamut 3
    case sonySLog3       // Sony S-Log3 / S-Gamut3.Cine
    case canonCLog3      // Canon C-Log3 / Cinema Gamut
    case panasonicVLog   // Panasonic V-Log / V-Gamut
    case canonCLog2      // Canon C-Log2 / Cinema Gamut

    public var shaderID: Int32 {
        switch self {
        case .rec709:        return 0
        case .sRGB:          return 1
        case .linear:        return 2
        case .rec2020:       return 3
        case .arriLogC3:     return 4
        case .sonySLog3:     return 5
        case .canonCLog3:    return 6
        case .panasonicVLog: return 7
        case .canonCLog2:    return 8
        }
    }

    public var displayName: String {
        switch self {
        case .rec709:        return "Rec. 709"
        case .sRGB:          return "sRGB"
        case .linear:        return "Linear"
        case .rec2020:       return "Rec. 2020"
        case .arriLogC3:     return "ARRI LogC3"
        case .sonySLog3:     return "Sony S-Log3"
        case .canonCLog3:    return "Canon C-Log3"
        case .panasonicVLog: return "Panasonic V-Log"
        case .canonCLog2:    return "Canon C-Log2"
        }
    }
}

/// Output / display transform applied once at the end of compositing
/// (linear working space → display-encoded). HDR variants are wired into
/// the same shader path; SDR Rec.709 is the v1 default.
public enum OutputColorSpace: String, Codable, Sendable, CaseIterable {
    case rec709          // SDR, 2.4 gamma
    case sRGB            // SDR, sRGB EOTF (preview on a Mac display)
    case rec2020PQ       // HDR10 / PQ
    case rec2020HLG      // HLG

    public var shaderID: Int32 {
        switch self {
        case .rec709:     return 0
        case .sRGB:       return 1
        case .rec2020PQ:  return 2
        case .rec2020HLG: return 3
        }
    }

    public var displayName: String {
        switch self {
        case .rec709:     return "Rec. 709 (SDR)"
        case .sRGB:       return "sRGB (Display)"
        case .rec2020PQ:  return "Rec. 2020 PQ (HDR)"
        case .rec2020HLG: return "Rec. 2020 HLG (HDR)"
        }
    }
}

/// Per-clip color grade — the typed view of the `preem.color` effect that
/// the compositor and the Color inspector read/write through. All scalar
/// controls are neutral at 0 (so an untouched grade is identity), keyed
/// like Lumetri. Grading happens in the linear working space; the
/// compositor builds shader uniforms + curve LUTs from this struct.
public struct ColorGrade: Equatable {
    /// How to interpret the source pixels (log/gamma/primaries).
    public var inputSpace: ColorTransferSpace

    // Basic Correction — all neutral at 0.
    public var temperature: Double   // -100 (cool) … +100 (warm)
    public var tint: Double          // -100 (green) … +100 (magenta)
    public var exposure: Double      // stops, -5 … +5
    public var contrast: Double      // -100 … +100
    public var highlights: Double    // -100 … +100
    public var shadows: Double       // -100 … +100
    public var whites: Double        // -100 … +100
    public var blacks: Double        // -100 … +100
    public var saturation: Double    // -100 (gray) … +100 (2×); 0 = neutral
    public var vibrance: Double      // -100 … +100

    // Curves — control points in 0…1 (input→output). Empty = identity.
    public var curveMaster: [CurvePoint]
    public var curveRed: [CurvePoint]
    public var curveGreen: [CurvePoint]
    public var curveBlue: [CurvePoint]

    // LUT (creative / input look).
    public var lutPath: String?
    public var lutIntensity: Double  // 0 … 100

    public static let identity = ColorGrade(
        inputSpace: .rec709,
        temperature: 0, tint: 0, exposure: 0, contrast: 0,
        highlights: 0, shadows: 0, whites: 0, blacks: 0,
        saturation: 0, vibrance: 0,
        curveMaster: [], curveRed: [], curveGreen: [], curveBlue: [],
        lutPath: nil, lutIntensity: 100
    )

    public init(
        inputSpace: ColorTransferSpace = .rec709,
        temperature: Double = 0, tint: Double = 0, exposure: Double = 0, contrast: Double = 0,
        highlights: Double = 0, shadows: Double = 0, whites: Double = 0, blacks: Double = 0,
        saturation: Double = 0, vibrance: Double = 0,
        curveMaster: [CurvePoint] = [], curveRed: [CurvePoint] = [],
        curveGreen: [CurvePoint] = [], curveBlue: [CurvePoint] = [],
        lutPath: String? = nil, lutIntensity: Double = 100
    ) {
        self.inputSpace = inputSpace
        self.temperature = temperature; self.tint = tint
        self.exposure = exposure; self.contrast = contrast
        self.highlights = highlights; self.shadows = shadows
        self.whites = whites; self.blacks = blacks
        self.saturation = saturation; self.vibrance = vibrance
        self.curveMaster = curveMaster; self.curveRed = curveRed
        self.curveGreen = curveGreen; self.curveBlue = curveBlue
        self.lutPath = lutPath; self.lutIntensity = lutIntensity
    }

    /// True when nothing in the grade would change the picture (and the
    /// input is plain Rec.709). Lets the compositor skip the color pass.
    public var isIdentity: Bool {
        inputSpace == .rec709
            && temperature == 0 && tint == 0 && exposure == 0 && contrast == 0
            && highlights == 0 && shadows == 0 && whites == 0 && blacks == 0
            && saturation == 0 && vibrance == 0
            && curveMaster.isEmpty && curveRed.isEmpty
            && curveGreen.isEmpty && curveBlue.isEmpty
            && (lutPath == nil || lutIntensity == 0)
    }
}

/// One keyframable scalar of the color grade. Curves, the input space, and
/// the LUT path are NOT keyframable (stored on the same `preem.color`
/// effect as `.curve` / `.string` params).
public enum ColorGradeParameter: String, CaseIterable, Sendable {
    case temperature, tint, exposure, contrast
    case highlights, shadows, whites, blacks
    case saturation, vibrance
    case lutIntensity

    public var effectKey: String { "preem.color" }
    public var parameterName: String { rawValue }

    public var defaultValue: Double {
        self == .lutIntensity ? 100 : 0
    }

    public var range: ClosedRange<Double> {
        switch self {
        case .exposure:     return -5...5
        case .lutIntensity: return 0...100
        default:            return -100...100
        }
    }

    public var displayName: String {
        switch self {
        case .temperature:  return "Temperature"
        case .tint:         return "Tint"
        case .exposure:     return "Exposure"
        case .contrast:     return "Contrast"
        case .highlights:   return "Highlights"
        case .shadows:      return "Shadows"
        case .whites:       return "Whites"
        case .blacks:       return "Blacks"
        case .saturation:   return "Saturation"
        case .vibrance:     return "Vibrance"
        case .lutIntensity: return "LUT Intensity"
        }
    }
}

// MARK: - Tone curve evaluation

/// Evaluates a tone curve (list of control points, input→output in 0…1)
/// with monotone cubic interpolation (Fritsch–Carlson), so dragging a
/// point can't introduce overshoot wiggles. Fewer than 2 points = identity.
public struct ToneCurve {
    public let points: [CurvePoint]

    public init(_ points: [CurvePoint]) {
        // Sort by x and de-dupe identical x positions.
        var p = points.sorted { $0.x < $1.x }
        var out: [CurvePoint] = []
        for pt in p where out.last.map({ abs($0.x - pt.x) > 1e-6 }) ?? true { out.append(pt) }
        p = out
        self.points = p
    }

    public var isIdentity: Bool { points.count < 2 }

    public func evaluate(_ x: Double) -> Double {
        let n = points.count
        if n == 0 { return x }
        if n == 1 { return points[0].y }
        if x <= points[0].x { return points[0].y }
        if x >= points[n - 1].x { return points[n - 1].y }

        // Locate the segment.
        var i = 0
        while i < n - 1 && x > points[i + 1].x { i += 1 }
        let p0 = points[i], p1 = points[i + 1]
        let h = p1.x - p0.x
        if h <= 0 { return p1.y }

        // Fritsch–Carlson tangents for monotonicity.
        func slope(_ a: Int, _ b: Int) -> Double {
            let dx = points[b].x - points[a].x
            return dx == 0 ? 0 : (points[b].y - points[a].y) / dx
        }
        let d0 = slope(i, i + 1)
        let m0: Double = i == 0 ? d0 : tangent(slope(i - 1, i), d0)
        let m1: Double = i + 1 == n - 1 ? d0 : tangent(d0, slope(i + 1, i + 2))

        let t = (x - p0.x) / h
        let t2 = t * t, t3 = t2 * t
        let h00 =  2*t3 - 3*t2 + 1
        let h10 =      t3 - 2*t2 + t
        let h01 = -2*t3 + 3*t2
        let h11 =      t3 -   t2
        let y = h00 * p0.y + h10 * h * m0 + h01 * p1.y + h11 * h * m1
        return min(1, max(0, y))
    }

    private func tangent(_ a: Double, _ b: Double) -> Double {
        if a * b <= 0 { return 0 }                 // local extremum → flat
        return 2 / (1 / a + 1 / b)                 // harmonic mean (monotone)
    }

    /// Sample the curve into `count` evenly-spaced entries across [0,1].
    public func bake(_ count: Int) -> [Float] {
        guard count > 1 else { return [0] }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = Float(evaluate(Double(i) / Double(count - 1)))
        }
        return out
    }
}

// MARK: - Read / write on a placed clip

public extension PlacedClip {
    /// Decoded `ColorGrade`, sampled at the given clip-local time.
    func colorGrade(at clipLocalSeconds: Double) -> ColorGrade {
        var g = ColorGrade.identity
        for eff in effects where !eff.isBypassed && eff.effectKey == "preem.color" {
            let p = eff.parameters
            g.exposure    = sampleDouble(p["exposure"],    at: clipLocalSeconds, default: 0)
            g.contrast    = sampleDouble(p["contrast"],    at: clipLocalSeconds, default: 0)
            g.temperature = sampleDouble(p["temperature"], at: clipLocalSeconds, default: 0)
            g.tint        = sampleDouble(p["tint"],        at: clipLocalSeconds, default: 0)
            g.highlights  = sampleDouble(p["highlights"],  at: clipLocalSeconds, default: 0)
            g.shadows     = sampleDouble(p["shadows"],     at: clipLocalSeconds, default: 0)
            g.whites      = sampleDouble(p["whites"],      at: clipLocalSeconds, default: 0)
            g.blacks      = sampleDouble(p["blacks"],      at: clipLocalSeconds, default: 0)
            g.saturation  = sampleDouble(p["saturation"],  at: clipLocalSeconds, default: 0)
            g.vibrance    = sampleDouble(p["vibrance"],    at: clipLocalSeconds, default: 0)
            g.lutIntensity = sampleDouble(p["lutIntensity"], at: clipLocalSeconds, default: 100)
            g.curveMaster = Self.curve(p["curveMaster"])
            g.curveRed    = Self.curve(p["curveRed"])
            g.curveGreen  = Self.curve(p["curveGreen"])
            g.curveBlue   = Self.curve(p["curveBlue"])
            if case .string(let s)? = p["inputSpace"], let sp = ColorTransferSpace(rawValue: s) {
                g.inputSpace = sp
            }
            if case .string(let s)? = p["lutPath"], !s.isEmpty { g.lutPath = s }
        }
        return g
    }

    private static func curve(_ v: ParameterValue?) -> [CurvePoint] {
        if case .curve(let pts)? = v { return pts }
        return []
    }

    func hasKeyframes(for parameter: ColorGradeParameter) -> Bool {
        for eff in effects where eff.effectKey == "preem.color" {
            if case .keyframed = eff.parameters[parameter.parameterName] { return true }
        }
        return false
    }

    func keyframes(for parameter: ColorGradeParameter) -> [Keyframe] {
        for eff in effects where eff.effectKey == "preem.color" {
            if case .keyframed(let kfs) = eff.parameters[parameter.parameterName] { return kfs }
        }
        return []
    }

    /// Index of the `preem.color` effect, creating one if needed.
    private mutating func colorEffectIndex() -> Int {
        if let i = effects.firstIndex(where: { $0.effectKey == "preem.color" }) { return i }
        effects.append(EffectInstance(effectKey: "preem.color", parameters: [:]))
        return effects.count - 1
    }

    mutating func setColorParameter(_ parameter: ColorGradeParameter, value: Double, at clipLocalTime: Double? = nil) {
        let i = colorEffectIndex()
        let name = parameter.parameterName
        if case .keyframed(let kfs)? = effects[i].parameters[name], let t = clipLocalTime {
            var updated = kfs
            if let j = updated.firstIndex(where: { abs($0.time.seconds - t) < 0.001 }) {
                updated[j].value = .double(value)
            } else {
                updated.append(Keyframe(
                    time: RationalTime(value: Int64((t * 1000).rounded()), scale: 1000),
                    value: .double(value), interpolation: .linear))
                updated.sort { $0.time.seconds < $1.time.seconds }
            }
            effects[i].parameters[name] = .keyframed(updated)
        } else {
            effects[i].parameters[name] = .double(value)
        }
    }

    mutating func setColorCurve(_ name: String, _ points: [CurvePoint]) {
        let i = colorEffectIndex()
        if points.count < 2 {
            effects[i].parameters[name] = nil
        } else {
            effects[i].parameters[name] = .curve(points)
        }
    }

    mutating func setColorInputSpace(_ space: ColorTransferSpace) {
        let i = colorEffectIndex()
        effects[i].parameters["inputSpace"] = .string(space.rawValue)
    }

    mutating func setColorLUT(path: String?) {
        let i = colorEffectIndex()
        if let path, !path.isEmpty {
            effects[i].parameters["lutPath"] = .string(path)
        } else {
            effects[i].parameters["lutPath"] = nil
        }
    }

    mutating func toggleColorKeyframing(_ parameter: ColorGradeParameter, at clipLocalTime: Double) {
        let i = colorEffectIndex()
        let name = parameter.parameterName
        let existing = effects[i].parameters[name] ?? .double(parameter.defaultValue)
        switch existing {
        case .keyframed:
            let v = sampleDouble(existing, at: clipLocalTime, default: parameter.defaultValue)
            effects[i].parameters[name] = .double(v)
        default:
            let v: Double = { if case .double(let dv) = existing { return dv }; return parameter.defaultValue }()
            effects[i].parameters[name] = .keyframed([Keyframe(
                time: RationalTime(value: Int64((clipLocalTime * 1000).rounded()), scale: 1000),
                value: .double(v), interpolation: .linear)])
        }
    }

    mutating func removeColorKeyframe(_ parameter: ColorGradeParameter, at clipLocalTime: Double, tolerance: Double = 0.01) {
        guard let i = effects.firstIndex(where: { $0.effectKey == "preem.color" }),
              case .keyframed(let kfs) = effects[i].parameters[parameter.parameterName] else { return }
        guard let (idx, kf) = kfs.enumerated().min(by: {
            abs($0.element.time.seconds - clipLocalTime) < abs($1.element.time.seconds - clipLocalTime)
        }), abs(kf.time.seconds - clipLocalTime) <= tolerance else { return }
        var updated = kfs
        updated.remove(at: idx)
        effects[i].parameters[parameter.parameterName] = updated.isEmpty
            ? .double(parameter.defaultValue) : .keyframed(updated)
    }

    mutating func setColorKeyframeInterpolation(_ parameter: ColorGradeParameter, at clipLocalTime: Double, _ interp: Interpolation, tolerance: Double = 0.05) {
        guard let i = effects.firstIndex(where: { $0.effectKey == "preem.color" }),
              case .keyframed(let kfs) = effects[i].parameters[parameter.parameterName] else { return }
        guard let (idx, kf) = kfs.enumerated().min(by: {
            abs($0.element.time.seconds - clipLocalTime) < abs($1.element.time.seconds - clipLocalTime)
        }), abs(kf.time.seconds - clipLocalTime) <= tolerance else { return }
        var updated = kfs
        updated[idx].interpolation = interp
        effects[i].parameters[parameter.parameterName] = .keyframed(updated)
    }

    mutating func moveColorKeyframe(_ parameter: ColorGradeParameter, from: Double, to: Double, tolerance: Double = 0.05) {
        guard let i = effects.firstIndex(where: { $0.effectKey == "preem.color" }),
              case .keyframed(let kfs) = effects[i].parameters[parameter.parameterName] else { return }
        guard let (idx, _) = kfs.enumerated().min(by: {
            abs($0.element.time.seconds - from) < abs($1.element.time.seconds - from)
        }), abs(kfs[idx].time.seconds - from) <= tolerance else { return }
        let newTime = RationalTime(value: Int64((to * 1000).rounded()), scale: 1000)
        var moved = kfs[idx]; moved.time = newTime
        var updated = kfs
        updated.remove(at: idx)
        updated.removeAll { abs($0.time.seconds - newTime.seconds) < 0.001 }
        updated.append(moved)
        updated.sort { $0.time.seconds < $1.time.seconds }
        effects[i].parameters[parameter.parameterName] = .keyframed(updated)
    }
}
