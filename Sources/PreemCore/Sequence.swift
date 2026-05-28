import Foundation

public struct Sequence: Codable, Sendable, Identifiable {
    public var id: SequenceID
    public var name: String
    public var settings: SequenceSettings
    public var videoTracks: [VideoTrack]
    public var audioTracks: [AudioTrack]
    public var markers: [Marker]
    /// Sequence-level In point — separate from source-viewer marks.
    /// Drives "Render In to Out" and "Play In to Out". Persists with
    /// the project. nil = unset.
    public var inMark: RationalTime?
    public var outMark: RationalTime?

    public init(
        id: SequenceID = SequenceID(),
        name: String,
        settings: SequenceSettings,
        videoTracks: [VideoTrack] = [VideoTrack(name: "V1", isTargeted: true)],
        audioTracks: [AudioTrack] = [AudioTrack(name: "A1", isTargeted: true), AudioTrack(name: "A2")],
        markers: [Marker] = [],
        inMark: RationalTime? = nil,
        outMark: RationalTime? = nil
    ) {
        self.id = id; self.name = name; self.settings = settings
        self.videoTracks = videoTracks; self.audioTracks = audioTracks
        self.markers = markers
        self.inMark = inMark; self.outMark = outMark
    }
}

public struct SequenceSettings: Codable, Sendable {
    public var frameRate: FrameRate
    public var resolution: PixelSize
    public var colorSpace: ColorSpace
    public var pixelAspectRatio: PixelAspectRatio
    public var audioSampleRate: Int
    public var audioChannelCount: Int          // 1 = mono, 2 = stereo (5.1 / 7.1 later)

    public init(
        frameRate: FrameRate,
        resolution: PixelSize,
        colorSpace: ColorSpace = .rec709,
        pixelAspectRatio: PixelAspectRatio = .square,
        audioSampleRate: Int = 48_000,
        audioChannelCount: Int = 2
    ) {
        self.frameRate = frameRate; self.resolution = resolution
        self.colorSpace = colorSpace; self.pixelAspectRatio = pixelAspectRatio
        self.audioSampleRate = audioSampleRate; self.audioChannelCount = audioChannelCount
    }
}

public enum PixelAspectRatio: String, Codable, Sendable, CaseIterable {
    case square                                // 1.0 — almost everything modern
    case d1NTSC                                // 0.9091 — D1/DV NTSC
    case d1PAL                                 // 1.0940 — D1/DV PAL
    case hdAnamorphic                          // 1.3333 — HD 1080 anamorphic

    public var ratio: Double {
        switch self {
        case .square:        return 1.0
        case .d1NTSC:        return 10.0 / 11.0
        case .d1PAL:         return 12.0 / 11.0
        case .hdAnamorphic:  return 4.0 / 3.0
        }
    }

    public var displayLabel: String {
        switch self {
        case .square:       return "Square Pixels (1.0)"
        case .d1NTSC:       return "D1/DV NTSC (0.9091)"
        case .d1PAL:        return "D1/DV PAL (1.0940)"
        case .hdAnamorphic: return "HD Anamorphic 1080 (1.333)"
        }
    }
}

public struct VideoTrack: Codable, Sendable, Identifiable {
    public var id: TrackID
    public var name: String
    public var isEnabled: Bool
    public var isLocked: Bool
    /// Source-targeted for 3-point insert/overwrite from the source
    /// viewer. The first targeted V receives the source clip's video.
    /// Premiere-style; defaults to true on V1 only.
    public var isTargeted: Bool
    public var heightPx: Int
    public var clips: [PlacedClip]

    public init(
        id: TrackID = TrackID(),
        name: String = "V1",
        isEnabled: Bool = true,
        isLocked: Bool = false,
        isTargeted: Bool = false,
        heightPx: Int = 64,
        clips: [PlacedClip] = []
    ) {
        self.id = id; self.name = name; self.isEnabled = isEnabled
        self.isLocked = isLocked; self.isTargeted = isTargeted
        self.heightPx = heightPx; self.clips = clips
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(TrackID.self, forKey: .id)
        name        = try c.decode(String.self, forKey: .name)
        isEnabled   = try c.decode(Bool.self, forKey: .isEnabled)
        isLocked    = try c.decode(Bool.self, forKey: .isLocked)
        isTargeted  = try c.decodeIfPresent(Bool.self, forKey: .isTargeted) ?? false
        heightPx    = try c.decode(Int.self, forKey: .heightPx)
        clips       = try c.decode([PlacedClip].self, forKey: .clips)
    }
}

public struct AudioTrack: Codable, Sendable, Identifiable {
    public var id: TrackID
    public var name: String
    public var isEnabled: Bool
    public var isLocked: Bool
    public var isMuted: Bool
    public var isSolo: Bool
    /// Source-targeted for 3-point insert/overwrite. The first targeted
    /// A receives the source clip's audio. Defaults to true on A1 only.
    public var isTargeted: Bool
    public var heightPx: Int
    public var clips: [PlacedClip]

    public init(
        id: TrackID = TrackID(),
        name: String = "A1",
        isEnabled: Bool = true,
        isLocked: Bool = false,
        isMuted: Bool = false,
        isSolo: Bool = false,
        isTargeted: Bool = false,
        heightPx: Int = 48,
        clips: [PlacedClip] = []
    ) {
        self.id = id; self.name = name
        self.isEnabled = isEnabled; self.isLocked = isLocked
        self.isMuted = isMuted; self.isSolo = isSolo
        self.isTargeted = isTargeted
        self.heightPx = heightPx; self.clips = clips
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(TrackID.self, forKey: .id)
        name        = try c.decode(String.self, forKey: .name)
        isEnabled   = try c.decode(Bool.self, forKey: .isEnabled)
        isLocked    = try c.decode(Bool.self, forKey: .isLocked)
        isMuted     = try c.decode(Bool.self, forKey: .isMuted)
        isSolo      = try c.decode(Bool.self, forKey: .isSolo)
        isTargeted  = try c.decodeIfPresent(Bool.self, forKey: .isTargeted) ?? false
        heightPx    = try c.decode(Int.self, forKey: .heightPx)
        clips       = try c.decode([PlacedClip].self, forKey: .clips)
    }
}

public struct PlacedClip: Codable, Sendable, Identifiable {
    public var id: PlacedClipID
    public var sourceClipID: ClipID
    public var sourceRange: TimeRange       // in:out within the source media
    public var timelineRange: TimeRange     // in:out on the sequence timeline
    public var isEnabled: Bool
    public var effects: [EffectInstance]
    public var transitionIn: Transition?
    public var transitionOut: Transition?

    /// Sibling clips that share the same `linkID` move, trim, split,
    /// and delete together. Typically the V+A halves of an A/V source
    /// clip. nil = standalone.
    public var linkID: UUID?

    public init(
        id: PlacedClipID = PlacedClipID(),
        sourceClipID: ClipID,
        sourceRange: TimeRange,
        timelineRange: TimeRange,
        isEnabled: Bool = true,
        effects: [EffectInstance] = [],
        transitionIn: Transition? = nil,
        transitionOut: Transition? = nil,
        linkID: UUID? = nil
    ) {
        self.id = id; self.sourceClipID = sourceClipID
        self.sourceRange = sourceRange; self.timelineRange = timelineRange
        self.isEnabled = isEnabled; self.effects = effects
        self.transitionIn = transitionIn; self.transitionOut = transitionOut
        self.linkID = linkID
    }
}

public struct EffectInstance: Codable, Sendable, Identifiable {
    public var id: EffectInstanceID
    public var effectKey: String            // e.g. "preem.transform", "preem.opacity"
    public var parameters: [String: ParameterValue]
    public var isBypassed: Bool

    public init(
        id: EffectInstanceID = EffectInstanceID(),
        effectKey: String,
        parameters: [String: ParameterValue] = [:],
        isBypassed: Bool = false
    ) {
        self.id = id; self.effectKey = effectKey
        self.parameters = parameters; self.isBypassed = isBypassed
    }
}

public enum ParameterValue: Codable, Sendable {
    case double(Double)
    case int(Int)
    case bool(Bool)
    case string(String)
    case point(x: Double, y: Double)
    case color(r: Double, g: Double, b: Double, a: Double)
    case keyframed([Keyframe])
}

public struct Keyframe: Codable, Sendable {
    public var time: RationalTime
    public var value: ParameterValue
    public var interpolation: Interpolation
}

public enum Interpolation: String, Codable, Sendable {
    /// Step: value holds A through the segment, snaps to B at the boundary.
    case hold
    /// Straight line A → B.
    case linear
    /// Flat tangent on the IN side: motion decelerates as it arrives at
    /// this keyframe (the segment ending here "eases in").
    case easeIn
    /// Flat tangent on the OUT side: motion accelerates slowly as it
    /// leaves this keyframe (the segment starting here "eases out").
    case easeOut
    /// Cubic ease with slow start AND slow finish — smoothstep S-curve.
    /// Stored as `bezier` for backward compat with already-saved projects.
    case bezier
}

public struct Transition: Codable, Sendable {
    public var kind: String                  // "crossDissolve", "dipToColor", "audioXfade", …
    public var duration: RationalTime
    public var parameters: [String: ParameterValue]

    public init(kind: String, duration: RationalTime, parameters: [String: ParameterValue] = [:]) {
        self.kind = kind
        self.duration = duration
        self.parameters = parameters
    }
}

public struct Marker: Codable, Sendable, Identifiable {
    public var id: MarkerID
    public var time: RationalTime
    public var name: String
    public var color: String                 // e.g. "blue", "red"; UI maps to NSColor

    public init(id: MarkerID = MarkerID(), time: RationalTime, name: String, color: String = "blue") {
        self.id = id; self.time = time; self.name = name; self.color = color
    }
}
