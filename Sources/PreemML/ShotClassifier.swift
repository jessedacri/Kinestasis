import Foundation
import AVFoundation
import Vision
import CoreImage
import PreemCore

/// Classifies the shot type (wide / medium / close-up / etc.) of a clip
/// by face-size heuristics.
///
/// v0.1 approach (no shipped model file):
///   * Sample frames from the middle 60% of the clip (avoids slates,
///     fades, title cards at head/tail).
///   * Run `VNDetectFaceRectanglesRequest` on each frame.
///   * Measure the tallest detected face's height as a fraction of the
///     frame height.
///   * Map the size to a `ShotType` band.
///   * If no faces in any frame, also try `VNDetectHumanRectanglesRequest`
///     (catches profiles / back-of-head shots) — its presence + small
///     bbox means wide; absence means `.unknown`.
///   * Take the median classification across samples for robustness.
///
/// This is the right v0.1 shape: no model files, ANE-accelerated, and
/// honest about what it doesn't know (insert shots of objects → unknown).
/// A fine-tuned classifier can swap in behind the same public interface.
public struct ShotClassifier: Sendable {

    public struct Configuration: Sendable {
        public var samplesAcrossMiddle: Int = 3
        public var middleRatio: Double = 0.6
        public init() {}
    }

    public enum ClassifyError: Error, Sendable {
        case noVideoTrack
        case cancelled
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func classify(clip: ClipSource) async throws -> ShotType {
        let asset = AVURLAsset(url: clip.url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw ClassifyError.noVideoTrack }

        let durationCM = try await asset.load(.duration)
        let durationSec = CMTimeGetSeconds(durationCM)
        let times = sampleTimes(durationSec: durationSec)

        guard !times.isEmpty else { return .unknown }

        let frames = try await extractFrames(from: asset, at: times)

        var classifications: [ShotType] = []
        classifications.reserveCapacity(frames.count)

        for frame in frames {
            let frameSize = CGSize(width: frame.width, height: frame.height)
            let faceFraction = try await detectLargestFaceHeightFraction(in: frame, frameSize: frameSize)

            if let f = faceFraction {
                classifications.append(shotType(forFaceHeightFraction: f))
                continue
            }

            // No face: try human detection. A detected human with small
            // bbox is a wide shot; nothing detected is unknown.
            let humanFraction = try await detectLargestHumanHeightFraction(in: frame, frameSize: frameSize)
            if let h = humanFraction {
                if h > 0.55 {
                    classifications.append(.closeUp)
                } else if h > 0.30 {
                    classifications.append(.medium)
                } else {
                    classifications.append(.wide)
                }
            } else {
                classifications.append(.unknown)
            }
        }

        return median(classifications)
    }

    // MARK: - Internals

    private func sampleTimes(durationSec: Double) -> [CMTime] {
        guard durationSec > 0 else { return [] }
        let pad = (1.0 - configuration.middleRatio) / 2.0
        let lo = durationSec * pad
        let hi = durationSec * (1.0 - pad)
        let n = max(1, configuration.samplesAcrossMiddle)

        guard hi > lo else {
            return [CMTime(seconds: durationSec / 2, preferredTimescale: 600)]
        }

        let step = (hi - lo) / Double(n + 1)
        return (1...n).map { i in
            CMTime(seconds: lo + step * Double(i), preferredTimescale: 600)
        }
    }

    private func extractFrames(from asset: AVAsset, at times: [CMTime]) async throws -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1920, height: 1080)

        var frames: [CGImage] = []
        for time in times {
            if let (image, _) = try? await generator.image(at: time) {
                frames.append(image)
            }
        }
        return frames
    }

    private func detectLargestFaceHeightFraction(in image: CGImage, frameSize: CGSize) async throws -> Double? {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectFaceRectanglesRequest { req, err in
                if let err {
                    continuation.resume(throwing: err)
                    return
                }
                let observations = (req.results as? [VNFaceObservation]) ?? []
                let maxHeight = observations.map(\.boundingBox.height).max()
                continuation.resume(returning: maxHeight.map(Double.init))
            }
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func detectLargestHumanHeightFraction(in image: CGImage, frameSize: CGSize) async throws -> Double? {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectHumanRectanglesRequest { req, err in
                if let err {
                    continuation.resume(throwing: err)
                    return
                }
                let observations = (req.results as? [VNHumanObservation]) ?? []
                let maxHeight = observations.map(\.boundingBox.height).max()
                continuation.resume(returning: maxHeight.map(Double.init))
            }
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Face height (as a fraction of frame height) → shot type. Bands tuned
    /// against the standard cinematography taxonomy. Calibrate against
    /// real footage when we have a corpus.
    private func shotType(forFaceHeightFraction f: Double) -> ShotType {
        switch f {
        case 0.55...: return .extremeCloseUp
        case 0.32..<0.55: return .closeUp
        case 0.18..<0.32: return .mediumCloseUp
        case 0.08..<0.18: return .medium
        case 0.03..<0.08: return .wide
        case 0..<0.03:    return .extremeWide
        default:          return .unknown
        }
    }

    private func median(_ shots: [ShotType]) -> ShotType {
        guard !shots.isEmpty else { return .unknown }
        let nonUnknown = shots.filter { $0 != .unknown }
        guard !nonUnknown.isEmpty else { return .unknown }
        let ordered: [ShotType] = [
            .extremeWide, .wide, .medium, .mediumCloseUp, .closeUp, .extremeCloseUp, .insert
        ]
        let sorted = nonUnknown.sorted {
            (ordered.firstIndex(of: $0) ?? 99) < (ordered.firstIndex(of: $1) ?? 99)
        }
        return sorted[sorted.count / 2]
    }
}
