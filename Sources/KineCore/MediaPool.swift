import Foundation

public struct MediaPool: Codable, Sendable {
    public var rootBin: Bin
    public var clips: [ClipID: ClipSource]
    public var shots: [ShotID: BurstShot]
    /// Stills identified at ingest as NOT part of a burst (group smaller
    /// than the min-burst threshold). Held for review / pruning to a
    /// separate folder rather than shown as shots.
    public var singles: [StillFrame]

    public init(rootBin: Bin = Bin(name: "Master"), clips: [ClipID: ClipSource] = [:], shots: [ShotID: BurstShot] = [:], singles: [StillFrame] = []) {
        self.rootBin = rootBin
        self.clips = clips
        self.shots = shots
        self.singles = singles
    }

    private enum CodingKeys: String, CodingKey { case rootBin, clips, shots, singles }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rootBin = try c.decode(Bin.self, forKey: .rootBin)
        clips = try c.decode([ClipID: ClipSource].self, forKey: .clips)
        shots = try c.decodeIfPresent([ShotID: BurstShot].self, forKey: .shots) ?? [:]
        singles = try c.decodeIfPresent([StillFrame].self, forKey: .singles) ?? []
    }
}

public struct Bin: Codable, Sendable, Identifiable {
    public var id: BinID
    public var name: String
    public var children: [BinItem]

    public init(id: BinID = BinID(), name: String, children: [BinItem] = []) {
        self.id = id; self.name = name; self.children = children
    }
}

public enum BinItem: Codable, Sendable {
    case bin(Bin)
    case clip(ClipID)
    case shot(ShotID)
}

/// A marked sub-range of a source clip — FCP-style "favorite" / "reject".
/// Many can be created from one `ClipSource` by marking In/Out and pressing
/// F (favorite). Favorites are filterable and draggable to the timeline like
/// a subclip; the parent `ClipSource` is unchanged.
public struct FavoriteRange: Codable, Sendable, Identifiable, Hashable {
    public enum Rating: String, Codable, Sendable { case favorite, rejected }

    public var id: UUID
    public var range: TimeRange       // start + duration within the source
    public var name: String?
    public var rating: Rating

    public init(id: UUID = UUID(), range: TimeRange, name: String? = nil, rating: Rating = .favorite) {
        self.id = id; self.range = range; self.name = name; self.rating = rating
    }
}

/// A source clip — the file on disk plus everything we know about it.
/// Distinct from a `PlacedClip` (which is a *use* of this source on a timeline).
public struct ClipSource: Codable, Sendable, Identifiable {
    public var id: ClipID
    public var url: URL
    public var name: String

    public var format: MediaFormat
    public var duration: RationalTime
    public var startTimecode: RationalTime?

    public var videoTracks: [VideoTrackInfo]
    public var audioTracks: [AudioTrackInfo]

    public var camera: CameraMetadata?
    public var scene: String?
    public var take: String?
    public var roll: String?

    public var proxyURL: URL?
    public var thumbnailURL: URL?

    public var ml: MLMetadata

    /// FCP-style favorite/reject sub-ranges marked in the bin. Empty for
    /// projects saved before favorites existed (see `init(from:)`).
    public var favorites: [FavoriteRange]

    public init(
        id: ClipID = ClipID(),
        url: URL,
        name: String,
        format: MediaFormat,
        duration: RationalTime,
        startTimecode: RationalTime? = nil,
        videoTracks: [VideoTrackInfo] = [],
        audioTracks: [AudioTrackInfo] = [],
        camera: CameraMetadata? = nil,
        scene: String? = nil,
        take: String? = nil,
        roll: String? = nil,
        proxyURL: URL? = nil,
        thumbnailURL: URL? = nil,
        ml: MLMetadata = MLMetadata(),
        favorites: [FavoriteRange] = []
    ) {
        self.id = id; self.url = url; self.name = name
        self.format = format; self.duration = duration; self.startTimecode = startTimecode
        self.videoTracks = videoTracks; self.audioTracks = audioTracks
        self.camera = camera; self.scene = scene; self.take = take; self.roll = roll
        self.proxyURL = proxyURL; self.thumbnailURL = thumbnailURL; self.ml = ml
        self.favorites = favorites
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, name, format, duration, startTimecode
        case videoTracks, audioTracks, camera, scene, take, roll
        case proxyURL, thumbnailURL, ml, favorites
    }

    // Custom decode so projects saved before `favorites` existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ClipID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        name = try c.decode(String.self, forKey: .name)
        format = try c.decode(MediaFormat.self, forKey: .format)
        duration = try c.decode(RationalTime.self, forKey: .duration)
        startTimecode = try c.decodeIfPresent(RationalTime.self, forKey: .startTimecode)
        videoTracks = try c.decode([VideoTrackInfo].self, forKey: .videoTracks)
        audioTracks = try c.decode([AudioTrackInfo].self, forKey: .audioTracks)
        camera = try c.decodeIfPresent(CameraMetadata.self, forKey: .camera)
        scene = try c.decodeIfPresent(String.self, forKey: .scene)
        take = try c.decodeIfPresent(String.self, forKey: .take)
        roll = try c.decodeIfPresent(String.self, forKey: .roll)
        proxyURL = try c.decodeIfPresent(URL.self, forKey: .proxyURL)
        thumbnailURL = try c.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        ml = try c.decode(MLMetadata.self, forKey: .ml)
        favorites = try c.decodeIfPresent([FavoriteRange].self, forKey: .favorites) ?? []
    }
}

public struct MediaFormat: Codable, Sendable {
    public var container: String       // mov, mp4, wav, …
    public var videoCodec: String?     // h264, hevc, prores, …
    public var audioCodec: String?     // pcm_s24le, aac, …

    public init(container: String, videoCodec: String? = nil, audioCodec: String? = nil) {
        self.container = container; self.videoCodec = videoCodec; self.audioCodec = audioCodec
    }
}

public struct VideoTrackInfo: Codable, Sendable {
    public var resolution: PixelSize
    public var frameRate: FrameRate
    public var pixelFormat: String
    public var colorSpace: ColorSpace

    public init(resolution: PixelSize, frameRate: FrameRate, pixelFormat: String, colorSpace: ColorSpace) {
        self.resolution = resolution; self.frameRate = frameRate
        self.pixelFormat = pixelFormat; self.colorSpace = colorSpace
    }
}

public struct AudioTrackInfo: Codable, Sendable {
    public var sampleRate: Int
    public var channelCount: Int
    public var bitDepth: Int
    public var trackName: String?

    public init(sampleRate: Int, channelCount: Int, bitDepth: Int, trackName: String? = nil) {
        self.sampleRate = sampleRate; self.channelCount = channelCount
        self.bitDepth = bitDepth; self.trackName = trackName
    }
}

public struct CameraMetadata: Codable, Sendable {
    public var make: String?
    public var model: String?
    public var reel: String?
    public var lens: String?

    public init(make: String? = nil, model: String? = nil, reel: String? = nil, lens: String? = nil) {
        self.make = make; self.model = model; self.reel = reel; self.lens = lens
    }
}

public struct MLMetadata: Codable, Sendable {
    public var slate: SlateData?
    public var shotType: ShotType?
    public var transcript: TranscriptData?

    public init(slate: SlateData? = nil, shotType: ShotType? = nil, transcript: TranscriptData? = nil) {
        self.slate = slate; self.shotType = shotType; self.transcript = transcript
    }
}

public struct SlateData: Codable, Sendable {
    public var scene: String?
    public var take: String?
    public var roll: String?
    public var rawText: String
    public var confidence: Double

    public init(scene: String? = nil, take: String? = nil, roll: String? = nil, rawText: String, confidence: Double) {
        self.scene = scene; self.take = take; self.roll = roll
        self.rawText = rawText; self.confidence = confidence
    }
}

public enum ShotType: String, Codable, Sendable {
    case extremeWide, wide, medium, mediumCloseUp, closeUp, extremeCloseUp, insert, unknown
}

public struct TranscriptData: Codable, Sendable {
    public var segments: [TranscriptSegment]
    public var language: String

    public init(segments: [TranscriptSegment], language: String) {
        self.segments = segments; self.language = language
    }
}

public struct TranscriptSegment: Codable, Sendable {
    public var start: RationalTime
    public var end: RationalTime
    public var text: String
    public var confidence: Double

    public init(start: RationalTime, end: RationalTime, text: String, confidence: Double) {
        self.start = start; self.end = end; self.text = text; self.confidence = confidence
    }
}
