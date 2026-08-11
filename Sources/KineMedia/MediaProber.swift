import Foundation
import AVFoundation
import CoreMedia
import KineCore

/// Reads a file off disk and returns a `ClipSource` populated from
/// metadata via AVFoundation (MOV/MP4/M4V/WAV).
public struct MediaProber: Sendable {
    public init() {}

    public func probe(url: URL) async throws -> ClipSource {
        return try await probeAVFoundation(url: url)
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
        KineDebugLog.log("[MediaProber] \(url.lastPathComponent): asset.duration = \(durationSeconds)s — clip.duration = \(duration.seconds)s")

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
