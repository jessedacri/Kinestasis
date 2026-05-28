import Foundation
import SwiftUI
import PreemCore
import PolymergeMediaModel

/// Bridge that converts Preem's `ClipSource` into Polymerge's `VideoFile`
/// (the model type PPE expects). Cached by ClipID so PPE sees a stable
/// identity per clip — important because `CustomVideoPlayer` rebuilds
/// its decoder whenever the video identity changes.
public actor VideoFileBridge {
    private var cache: [ClipID: VideoFile] = [:]

    public init() {}

    public func videoFile(for clip: ClipSource) -> VideoFile? {
        if let cached = cache[clip.id] { return cached }
        guard !clip.videoTracks.isEmpty, let v = clip.videoTracks.first else { return nil }

        let frameRate: Double = {
            let n = Double(v.frameRate.rationalRate)
            let d = Double(v.frameRate.rationalScale)
            return d > 0 ? n / d : 24.0
        }()

        let video = VideoFile(
            url: clip.url,
            duration: clip.duration.seconds,
            videoWidth: v.resolution.width,
            videoHeight: v.resolution.height,
            videoFrameRate: frameRate,
            videoCodec: clip.format.videoCodec ?? "unknown",
            audioTrackCount: clip.audioTracks.count,
            audioSampleRate: clip.audioTracks.first?.sampleRate,
            audioChannelCount: clip.audioTracks.first?.channelCount ?? 0,
            color: .accentColor
        )
        cache[clip.id] = video
        return video
    }
}
