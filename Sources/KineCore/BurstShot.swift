import Foundation

public struct ShotID: KineID { public let rawValue: UUID; public init() { rawValue = UUID() }; public init(rawValue: UUID) { self.rawValue = rawValue } }

/// One still image inside a burst shot.
public struct StillFrame: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Primary file — the RAW when the camera wrote a RAW+JPEG pair.
    public var url: URL
    /// The JPEG twin of a RAW+JPEG pair, kept so the shot can switch its
    /// frame source between the two.
    public var pairedJpegURL: URL?
    /// EXIF DateTimeOriginal + SubSecTimeOriginal, as seconds since 1970.
    /// Sub-second precision is what makes as-shot cadence work.
    public var captureTime: TimeInterval
    public var pixelSize: PixelSize?

    public init(id: UUID = UUID(), url: URL, pairedJpegURL: URL? = nil, captureTime: TimeInterval, pixelSize: PixelSize? = nil) {
        self.id = id
        self.url = url
        self.pairedJpegURL = pairedJpegURL
        self.captureTime = captureTime
        self.pixelSize = pixelSize
    }

    private enum CodingKeys: String, CodingKey { case id, url, pairedJpegURL, captureTime, pixelSize }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        pairedJpegURL = try c.decodeIfPresent(URL.self, forKey: .pairedJpegURL)
        captureTime = try c.decode(TimeInterval.self, forKey: .captureTime)
        pixelSize = try c.decodeIfPresent(PixelSize.self, forKey: .pixelSize)
    }
}

/// Human-readable file-type labels for the formats Kinestasis ingests.
public enum CameraFileType {
    public static func label(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "raf":          return "Fujifilm RAF"
        case "arw":          return "Sony ARW"
        case "cr2":          return "Canon CR2"
        case "cr3":          return "Canon CR3"
        case "crw":          return "Canon CRW"
        case "nef", "nrw":   return "Nikon \(ext.uppercased())"
        case "orf":          return "Olympus ORF"
        case "rw2":          return "Panasonic RW2"
        case "pef":          return "Pentax PEF"
        case "srw":          return "Samsung SRW"
        case "erf":          return "Epson ERF"
        case "rwl":          return "Leica RWL"
        case "3fr", "fff":   return "Hasselblad \(ext.uppercased())"
        case "iiq":          return "Phase One IIQ"
        case "dng":          return "DNG"
        case "jpg", "jpeg":  return "JPEG"
        case "heic", "heif": return "HEIC"
        case "tif", "tiff":  return "TIFF"
        case "png":          return "PNG"
        default:             return ext.uppercased()
        }
    }
}

/// How a shot's stills map onto output frames.
public enum ShotTimingMode: Codable, Sendable, Hashable {
    /// Every still holds for a fixed number of timeline frames.
    case fixedFramesPerStill(frames: Int)
    /// Stills play at their capture cadence: display spans are proportional
    /// to the capture-time gaps, so buffer slowdowns and natural burst-rate
    /// deviations survive. `rate` scales wall-clock time (1.0 = real time,
    /// 2.0 = twice as fast).
    case asShot(rate: Double)
    /// Use every `every`-th still, each held for `frames` timeline frames
    /// (a 30 fps burst with every=4 reads as 7.5 fps capture cadence).
    case frameSkip(every: Int, frames: Int)

    public static let `default` = ShotTimingMode.fixedFramesPerStill(frames: 3)
}

/// Camera-raw-style grade applied to every still in a shot. All scalar
/// controls neutral at 0 (identity when untouched). RAW sources run
/// exposure/WB in the CIRAWFilter develop stage; JPEG gets an equivalent
/// Core Image chain.
public struct ShotGrade: Codable, Sendable, Hashable {
    public var exposure: Double      // stops, -5 … +5
    public var contrast: Double      // -100 … +100
    public var temperature: Double   // -100 (cool) … +100 (warm)
    public var tint: Double          // -100 (green) … +100 (magenta)
    public var highlights: Double    // -100 … +100
    public var shadows: Double       // -100 … +100
    public var saturation: Double    // -100 … +100
    public var blackAndWhite: Bool
    public var lutPath: String?
    public var lutIntensity: Double  // 0 … 100

    // Texture (K3). Grain rides along with looks/copy-paste on purpose —
    // a "look" that includes its grain travels as one unit.
    public var grainAmount: Double     // 0 (off) … 100
    public var grainSize: Double       // 0.5 … 4, 1 = native noise scale
    public var grainResponse: Double   // -100 (shadows) … +100 (highlights), 0 = uniform
    public var wobbleIntensity: Double // 0 (off) … 100 → up to ±0.3 EV
    public var wobbleRate: Double      // Hz, 0.5 … 12

    public static let identity = ShotGrade()

    public init(exposure: Double = 0, contrast: Double = 0, temperature: Double = 0, tint: Double = 0,
                highlights: Double = 0, shadows: Double = 0, saturation: Double = 0,
                blackAndWhite: Bool = false, lutPath: String? = nil, lutIntensity: Double = 100,
                grainAmount: Double = 0, grainSize: Double = 1, grainResponse: Double = 0,
                wobbleIntensity: Double = 0, wobbleRate: Double = 4) {
        self.exposure = exposure; self.contrast = contrast
        self.temperature = temperature; self.tint = tint
        self.highlights = highlights; self.shadows = shadows
        self.saturation = saturation; self.blackAndWhite = blackAndWhite
        self.lutPath = lutPath; self.lutIntensity = lutIntensity
        self.grainAmount = grainAmount; self.grainSize = grainSize; self.grainResponse = grainResponse
        self.wobbleIntensity = wobbleIntensity; self.wobbleRate = wobbleRate
    }

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, temperature, tint, highlights, shadows, saturation
        case blackAndWhite, lutPath, lutIntensity
        case grainAmount, grainSize, grainResponse, wobbleIntensity, wobbleRate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        blackAndWhite = try c.decodeIfPresent(Bool.self, forKey: .blackAndWhite) ?? false
        lutPath = try c.decodeIfPresent(String.self, forKey: .lutPath)
        lutIntensity = try c.decodeIfPresent(Double.self, forKey: .lutIntensity) ?? 100
        grainAmount = try c.decodeIfPresent(Double.self, forKey: .grainAmount) ?? 0
        grainSize = try c.decodeIfPresent(Double.self, forKey: .grainSize) ?? 1
        grainResponse = try c.decodeIfPresent(Double.self, forKey: .grainResponse) ?? 0
        wobbleIntensity = try c.decodeIfPresent(Double.self, forKey: .wobbleIntensity) ?? 0
        wobbleRate = try c.decodeIfPresent(Double.self, forKey: .wobbleRate) ?? 4
    }

    public var isIdentity: Bool {
        exposure == 0 && contrast == 0 && temperature == 0 && tint == 0
            && highlights == 0 && shadows == 0 && saturation == 0
            && !blackAndWhite && (lutPath == nil || lutIntensity == 0)
            && grainAmount == 0 && wobbleIntensity == 0
    }
}

/// A group of stills captured in one burst, playable as a clip.
public struct BurstShot: Codable, Sendable, Identifiable {
    public var id: ShotID
    public var name: String
    /// Sorted by captureTime ascending.
    public var frames: [StillFrame]
    /// nil → the project-wide default timing applies.
    public var timingOverride: ShotTimingMode?
    public var grade: ShotGrade
    /// Monotone time-remap curve (x: output progress, y: source progress),
    /// 0…1 both axes. Empty or < 2 points = no ramp. Total duration is
    /// preserved; the curve redistributes it.
    public var speedRamp: [CurvePoint]
    /// When the camera wrote RAW+JPEG pairs, use the JPEG as the frame
    /// source instead of the RAW.
    public var useJpegSource: Bool
    /// One-click exclusion from batch export / assembly without removing
    /// the shot.
    public var includeInExport: Bool
    /// Stills trimmed off the head / tail. Playback, stats, and export
    /// all use `effectiveFrames`; the underlying frames stay so trims are
    /// non-destructive and re-adjustable.
    public var trimIn: Int
    public var trimOut: Int

    public init(id: ShotID = ShotID(), name: String, frames: [StillFrame], timingOverride: ShotTimingMode? = nil, grade: ShotGrade = .identity, speedRamp: [CurvePoint] = [], useJpegSource: Bool = false, includeInExport: Bool = true, trimIn: Int = 0, trimOut: Int = 0) {
        self.id = id
        self.name = name
        self.frames = frames
        self.timingOverride = timingOverride
        self.grade = grade
        self.speedRamp = speedRamp
        self.useJpegSource = useJpegSource
        self.includeInExport = includeInExport
        self.trimIn = trimIn
        self.trimOut = trimOut
    }

    private enum CodingKeys: String, CodingKey { case id, name, frames, timingOverride, grade, speedRamp, useJpegSource, includeInExport, trimIn, trimOut }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ShotID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        frames = try c.decode([StillFrame].self, forKey: .frames)
        timingOverride = try c.decodeIfPresent(ShotTimingMode.self, forKey: .timingOverride)
        grade = try c.decodeIfPresent(ShotGrade.self, forKey: .grade) ?? .identity
        speedRamp = try c.decodeIfPresent([CurvePoint].self, forKey: .speedRamp) ?? []
        useJpegSource = try c.decodeIfPresent(Bool.self, forKey: .useJpegSource) ?? false
        includeInExport = try c.decodeIfPresent(Bool.self, forKey: .includeInExport) ?? true
        trimIn = try c.decodeIfPresent(Int.self, forKey: .trimIn) ?? 0
        trimOut = try c.decodeIfPresent(Int.self, forKey: .trimOut) ?? 0
    }

    /// The stills that actually play/export after head/tail trims. Always
    /// keeps at least one still.
    public var effectiveFrames: [StillFrame] {
        let lo = min(max(0, trimIn), max(0, frames.count - 1))
        let hi = max(lo + 1, frames.count - max(0, trimOut))
        return Array(frames[lo..<min(hi, frames.count)])
    }

    public var isTrimmed: Bool { trimIn > 0 || trimOut > 0 }

    /// The file to decode for a frame, honoring the RAW/JPEG source toggle.
    public func sourceURL(for frame: StillFrame) -> URL {
        if useJpegSource, let jpeg = frame.pairedJpegURL { return jpeg }
        return frame.url
    }

    /// True when any frame carries a RAW+JPEG pair (source toggle applies).
    public var hasRawJpegPairs: Bool {
        frames.contains { $0.pairedJpegURL != nil }
    }

    /// Display label like "Fujifilm RAF" / "JPEG", or "RAF + JPEG" when
    /// pairs exist (with the active source first).
    public var fileTypeLabel: String {
        guard let first = frames.first else { return "" }
        if hasRawJpegPairs {
            let raw = CameraFileType.label(forExtension: first.url.pathExtension)
            return useJpegSource ? "JPEG (+\(raw.split(separator: " ").last.map(String.init) ?? "RAW"))" : "\(raw) (+JPEG)"
        }
        return CameraFileType.label(forExtension: sourceURL(for: first).pathExtension)
    }

    public func timing(projectDefault: ShotTimingMode) -> ShotTimingMode {
        timingOverride ?? projectDefault
    }

    /// Wall-clock capture span, first shutter to last.
    public var captureSpan: TimeInterval {
        guard let first = frames.first, let last = frames.last else { return 0 }
        return last.captureTime - first.captureTime
    }
}

/// Project-wide burst defaults, adjustable in the UI.
public struct BurstDefaults: Codable, Sendable, Hashable {
    /// Capture-gap threshold (seconds) that splits a folder of stills into
    /// separate shots.
    public var gapThreshold: TimeInterval
    public var timing: ShotTimingMode
    /// A capture-gap group needs at least this many stills to count as a
    /// burst; smaller groups are singles (one-offs), kept aside for
    /// pruning rather than becoming shots.
    public var minBurstCount: Int

    public static let `default` = BurstDefaults(gapThreshold: 2.0, timing: .default, minBurstCount: 3)

    public init(gapThreshold: TimeInterval, timing: ShotTimingMode, minBurstCount: Int = 3) {
        self.gapThreshold = gapThreshold
        self.timing = timing
        self.minBurstCount = minBurstCount
    }

    private enum CodingKeys: String, CodingKey { case gapThreshold, timing, minBurstCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gapThreshold = try c.decode(TimeInterval.self, forKey: .gapThreshold)
        timing = try c.decode(ShotTimingMode.self, forKey: .timing)
        minBurstCount = try c.decodeIfPresent(Int.self, forKey: .minBurstCount) ?? 3
    }
}

// MARK: - Grouping

public enum BurstGrouper {
    /// Cameras without sub-second EXIF (X-Pro2 and other older bodies)
    /// stamp whole seconds, so an 8 fps burst reads as piles of identical
    /// timestamps — which would make as-shot cadence collapse them.
    /// Spread each run of equal timestamps evenly across its second so
    /// cadence still means something. Input must be sorted by time.
    public static func spreadEqualTimestamps(_ frames: [StillFrame]) -> [StillFrame] {
        guard frames.count > 1 else { return frames }
        var out = frames
        var runStart = 0
        for i in 1...frames.count {
            if i == frames.count || frames[i].captureTime != frames[runStart].captureTime {
                let runLength = i - runStart
                if runLength > 1 {
                    for k in 0..<runLength {
                        out[runStart + k].captureTime += Double(k) / Double(runLength)
                    }
                }
                runStart = i
            }
        }
        return out
    }

    /// Split stills into shots wherever the capture-time gap exceeds
    /// `gapThreshold`. Input order doesn't matter; output shots and the
    /// frames within them are sorted by capture time. Runs of identical
    /// whole-second timestamps are spread (see `spreadEqualTimestamps`).
    public static func group(_ frames: [StillFrame], gapThreshold: TimeInterval) -> [[StillFrame]] {
        guard !frames.isEmpty else { return [] }
        let sorted = spreadEqualTimestamps(
            frames.sorted { ($0.captureTime, $0.url.path) < ($1.captureTime, $1.url.path) })
        var shots: [[StillFrame]] = []
        var current: [StillFrame] = [sorted[0]]
        for frame in sorted.dropFirst() {
            if frame.captureTime - current[current.count - 1].captureTime > gapThreshold {
                shots.append(current)
                current = []
            }
            current.append(frame)
        }
        shots.append(current)
        return shots
    }
}

// MARK: - Timing engine

/// One still's placement on the output timeline.
public struct StillEvent: Sendable, Equatable {
    /// Index into `BurstShot.frames`.
    public let frameIndex: Int
    /// Start position in output frames.
    public let startFrame: Int64
    /// Display span in output frames (≥ 1).
    public let frameCount: Int64

    public init(frameIndex: Int, startFrame: Int64, frameCount: Int64) {
        self.frameIndex = frameIndex
        self.startFrame = startFrame
        self.frameCount = frameCount
    }
}

public enum ShotTimingEngine {
    /// Compute the output-frame schedule for a shot. Events are contiguous
    /// (no gaps), start at frame 0, and every event spans ≥ 1 frame. In
    /// as-shot mode, stills whose capture interval quantizes to zero output
    /// frames are dropped (burst faster than the timeline rate).
    public static func schedule(frames: [StillFrame], mode: ShotTimingMode, rate: FrameRate) -> [StillEvent] {
        guard !frames.isEmpty else { return [] }
        switch mode {
        case .fixedFramesPerStill(let k):
            let k64 = Int64(max(1, k))
            return frames.indices.map {
                StillEvent(frameIndex: $0, startFrame: Int64($0) * k64, frameCount: k64)
            }

        case .frameSkip(let every, let k):
            let n = max(1, every)
            let k64 = Int64(max(1, k))
            let kept = stride(from: 0, to: frames.count, by: n)
            return kept.enumerated().map { (slot, frameIndex) in
                StillEvent(frameIndex: frameIndex, startFrame: Int64(slot) * k64, frameCount: k64)
            }

        case .asShot(let rate_):
            return asShotSchedule(frames: frames, rate: max(0.001, rate_), fps: rate.fps)
        }
    }

    private static func asShotSchedule(frames: [StillFrame], rate: Double, fps: Double) -> [StillEvent] {
        guard frames.count > 1 else {
            return [StillEvent(frameIndex: 0, startFrame: 0, frameCount: 1)]
        }
        let t0 = frames[0].captureTime
        // Quantized output-frame boundary for each still's start.
        var boundaries: [Int64] = frames.map {
            Int64((($0.captureTime - t0) / rate * fps).rounded())
        }
        // The last still holds for the median capture interval (robust
        // against a trailing straggler), at least one frame.
        let intervals = zip(frames.dropFirst(), frames).map { $0.captureTime - $1.captureTime }
        let median = intervals.sorted(by: <)[intervals.count / 2]
        boundaries.append(boundaries[boundaries.count - 1] + max(1, Int64((median / rate * fps).rounded())))

        var events: [StillEvent] = []
        for i in frames.indices {
            let span = boundaries[i + 1] - boundaries[i]
            guard span >= 1 else { continue }   // sub-frame still — dropped
            // Keep events contiguous even after drops.
            let start = events.last.map { $0.startFrame + $0.frameCount } ?? 0
            events.append(StillEvent(frameIndex: i, startFrame: start, frameCount: span))
        }
        if events.isEmpty {
            events.append(StillEvent(frameIndex: 0, startFrame: 0, frameCount: 1))
        }
        return events
    }

    /// Total output length in frames for a schedule.
    public static func totalFrames(_ schedule: [StillEvent]) -> Int64 {
        guard let last = schedule.last else { return 0 }
        return last.startFrame + last.frameCount
    }

    /// Apply a monotone time-remap curve (x: output progress → y: source
    /// progress) to a schedule. Total duration is preserved; screen time is
    /// redistributed — a flat curve segment lingers, a steep one rushes.
    /// Fewer than 2 points = unchanged.
    public static func applyRamp(_ schedule: [StillEvent], ramp: [CurvePoint]) -> [StillEvent] {
        let total = totalFrames(schedule)
        guard schedule.count > 0, ramp.count >= 2, total > 1 else { return schedule }
        let curve = ToneCurve(ramp)
        var events: [StillEvent] = []
        var maxSourceFrame: Int64 = 0   // guards against time reversal if points cross
        for f in 0..<total {
            let progress = Double(f) / Double(total - 1)
            let sourcePos = curve.evaluate(progress)
            let sourceFrame = max(maxSourceFrame, Int64((sourcePos * Double(total - 1)).rounded()))
            maxSourceFrame = sourceFrame
            let idx = event(at: sourceFrame, in: schedule)?.frameIndex ?? schedule[0].frameIndex
            if let last = events.last, last.frameIndex == idx {
                events[events.count - 1] = StillEvent(
                    frameIndex: idx, startFrame: last.startFrame, frameCount: last.frameCount + 1)
            } else {
                events.append(StillEvent(frameIndex: idx, startFrame: Int64(f), frameCount: 1))
            }
        }
        return events
    }

    /// Full schedule for a shot: head/tail trim, timing mode, then the
    /// speed ramp. Event `frameIndex` values index `shot.effectiveFrames`.
    public static func schedule(for shot: BurstShot, projectDefault: ShotTimingMode, rate: FrameRate) -> [StillEvent] {
        let base = schedule(frames: shot.effectiveFrames, mode: shot.timing(projectDefault: projectDefault), rate: rate)
        return applyRamp(base, ramp: shot.speedRamp)
    }

    /// The still on screen at `frame`, or the last one past the end.
    public static func event(at frame: Int64, in schedule: [StillEvent]) -> StillEvent? {
        guard !schedule.isEmpty else { return nil }
        if frame < 0 { return schedule[0] }
        // Binary search: last event whose startFrame ≤ frame.
        var lo = 0, hi = schedule.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if schedule[mid].startFrame <= frame { lo = mid } else { hi = mid - 1 }
        }
        return schedule[lo]
    }
}
