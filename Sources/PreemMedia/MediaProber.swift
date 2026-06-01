import Foundation
import AVFoundation
import CoreMedia
import PreemCore
import PolymergePlayback
import PolymergeIngest

/// Reads a file off disk and returns a `ClipSource` populated from
/// metadata. AVFoundation covers MOV/MP4/M4V/WAV; MXF (which AVFoundation
/// can't open) is probed via the native MXF demuxer + descriptor readers.
public struct MediaProber: Sendable {
    public init() {}

    public func probe(url: URL) async throws -> ClipSource {
        if url.pathExtension.lowercased() == "mxf" {
            return try await probeMXF(url: url)
        }
        return try await probeAVFoundation(url: url)
    }

    /// Probe an MXF (Canon XF-AVC, Sony XAVC, ARRI ProRes-in-MXF, …) using
    /// the native demuxer for video dimensions/frame-rate/duration and the
    /// sound-descriptor reader for audio. AVFoundation can't open MXF.
    private func probeMXF(url: URL) async throws -> ClipSource {
        let src = try await MXFFrameSource.load(url: url)
        defer { src.tearDown() }

        let fps = src.nominalFrameRate
        let dims = src.pixelDimensions
        let duration = RationalTime(value: Int64(src.durationSeconds * 1000), scale: 1000)
        let video = VideoTrackInfo(
            resolution: PixelSize(width: Int(dims.width), height: Int(dims.height)),
            frameRate: closestFrameRate(to: fps),
            pixelFormat: "unknown",
            colorSpace: .rec709
        )

        var audioInfos: [AudioTrackInfo] = []
        if let results = try? MXFSoundDescriptorReader.readAll(url: url), !results.isEmpty {
            // MXF often carries audio as several mono descriptors — sum the
            // channels into one track for the metadata view.
            let channels = results.reduce(0) { $0 + Int($1.channelCount) }
            let first = results[0]
            audioInfos.append(AudioTrackInfo(
                sampleRate: Int(first.sampleRate.rounded()),
                channelCount: max(1, channels),
                bitDepth: Int(first.quantizationBits)
            ))
        }

        PreemDebugLog.log("[MediaProber] MXF \(url.lastPathComponent): \(Int(dims.width))×\(Int(dims.height)) @ \(fps)fps dur=\(duration.seconds)s audio=\(audioInfos.first?.channelCount ?? 0)ch")

        return ClipSource(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            format: MediaFormat(container: "mxf", videoCodec: "mxf",
                                audioCodec: audioInfos.isEmpty ? nil : "pcm"),
            duration: duration,
            videoTracks: [video],
            audioTracks: audioInfos
        )
    }

    private func probeAVFoundation(url: URL) async throws -> ClipSource {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
        ])

        let (durationCM, videoTracks, audioTracks) = try await (
            asset.load(.duration),
            asset.loadTracks(withMediaType: .video),
            asset.loadTracks(withMediaType: .audio)
        )

        let durationSeconds = CMTimeGetSeconds(durationCM)
        let duration = RationalTime(value: Int64(durationSeconds * 1000), scale: 1000)
        PreemDebugLog.log("[MediaProber] \(url.lastPathComponent): asset.duration = \(durationSeconds)s — clip.duration = \(duration.seconds)s")

        var videoInfos: [VideoTrackInfo] = []
        for track in videoTracks {
            let size = try await track.load(.naturalSize)
            let fps = try await track.load(.nominalFrameRate)
            videoInfos.append(VideoTrackInfo(
                resolution: PixelSize(width: Int(size.width), height: Int(size.height)),
                frameRate: closestFrameRate(to: Double(fps)),
                pixelFormat: "unknown",
                colorSpace: .rec709
            ))
        }

        var audioInfos: [AudioTrackInfo] = []
        for track in audioTracks {
            let descriptions = try await track.load(.formatDescriptions)
            if let desc = descriptions.first {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee
                audioInfos.append(AudioTrackInfo(
                    sampleRate: Int(asbd?.mSampleRate ?? 48_000),
                    channelCount: Int(asbd?.mChannelsPerFrame ?? 2),
                    bitDepth: Int(asbd?.mBitsPerChannel ?? 16)
                ))
            }
        }

        return ClipSource(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            format: MediaFormat(
                container: url.pathExtension.lowercased(),
                videoCodec: videoInfos.isEmpty ? nil : "unknown",
                audioCodec: audioInfos.isEmpty ? nil : "unknown"
            ),
            duration: duration,
            videoTracks: videoInfos,
            audioTracks: audioInfos
        )
    }

    private func closestFrameRate(to fps: Double) -> FrameRate {
        FrameRate.allCases.min(by: { a, b in
            abs(Double(a.rationalRate) / Double(a.rationalScale) - fps) <
            abs(Double(b.rationalRate) / Double(b.rationalScale) - fps)
        }) ?? .twentyFour
    }
}
