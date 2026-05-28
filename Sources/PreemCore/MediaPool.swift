import Foundation

public struct MediaPool: Codable, Sendable {
    public var rootBin: Bin
    public var clips: [ClipID: ClipSource]

    public init(rootBin: Bin = Bin(name: "Master"), clips: [ClipID: ClipSource] = [:]) {
        self.rootBin = rootBin
        self.clips = clips
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
        ml: MLMetadata = MLMetadata()
    ) {
        self.id = id; self.url = url; self.name = name
        self.format = format; self.duration = duration; self.startTimecode = startTimecode
        self.videoTracks = videoTracks; self.audioTracks = audioTracks
        self.camera = camera; self.scene = scene; self.take = take; self.roll = roll
        self.proxyURL = proxyURL; self.thumbnailURL = thumbnailURL; self.ml = ml
    }
}

public struct MediaFormat: Codable, Sendable {
    public var container: String       // mov, mp4, mxf, wav, mkv, …
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
