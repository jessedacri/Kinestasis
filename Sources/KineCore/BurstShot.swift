import Foundation

public struct ShotID: KineID { public let rawValue: UUID; public init() { rawValue = UUID() }; public init(rawValue: UUID) { self.rawValue = rawValue } }

/// One still image inside a burst shot.
public struct StillFrame: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var url: URL
    /// EXIF DateTimeOriginal + SubSecTimeOriginal, as seconds since 1970.
    /// Sub-second precision is what makes as-shot cadence work.
    public var captureTime: TimeInterval
    public var pixelSize: PixelSize?

    public init(id: UUID = UUID(), url: URL, captureTime: TimeInterval, pixelSize: PixelSize? = nil) {
        self.id = id
        self.url = url
        self.captureTime = captureTime
        self.pixelSize = pixelSize
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

    public static let identity = ShotGrade()

    public init(exposure: Double = 0, contrast: Double = 0, temperature: Double = 0, tint: Double = 0,
                highlights: Double = 0, shadows: Double = 0, saturation: Double = 0,
                blackAndWhite: Bool = false, lutPath: String? = nil, lutIntensity: Double = 100) {
        self.exposure = exposure; self.contrast = contrast
        self.temperature = temperature; self.tint = tint
        self.highlights = highlights; self.shadows = shadows
        self.saturation = saturation; self.blackAndWhite = blackAndWhite
        self.lutPath = lutPath; self.lutIntensity = lutIntensity
    }

    public var isIdentity: Bool {
        exposure == 0 && contrast == 0 && temperature == 0 && tint == 0
            && highlights == 0 && shadows == 0 && saturation == 0
            && !blackAndWhite && (lutPath == nil || lutIntensity == 0)
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

    public init(id: ShotID = ShotID(), name: String, frames: [StillFrame], timingOverride: ShotTimingMode? = nil, grade: ShotGrade = .identity) {
        self.id = id
        self.name = name
        self.frames = frames
        self.timingOverride = timingOverride
        self.grade = grade
    }

    private enum CodingKeys: String, CodingKey { case id, name, frames, timingOverride, grade }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ShotID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        frames = try c.decode([StillFrame].self, forKey: .frames)
        timingOverride = try c.decodeIfPresent(ShotTimingMode.self, forKey: .timingOverride)
        grade = try c.decodeIfPresent(ShotGrade.self, forKey: .grade) ?? .identity
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

    public static let `default` = BurstDefaults(gapThreshold: 2.0, timing: .default)

    public init(gapThreshold: TimeInterval, timing: ShotTimingMode) {
        self.gapThreshold = gapThreshold
        self.timing = timing
    }
}

// MARK: - Grouping

public enum BurstGrouper {
    /// Split stills into shots wherever the capture-time gap exceeds
    /// `gapThreshold`. Input order doesn't matter; output shots and the
    /// frames within them are sorted by capture time.
    public static func group(_ frames: [StillFrame], gapThreshold: TimeInterval) -> [[StillFrame]] {
        guard !frames.isEmpty else { return [] }
        let sorted = frames.sorted { ($0.captureTime, $0.url.path) < ($1.captureTime, $1.url.path) }
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
