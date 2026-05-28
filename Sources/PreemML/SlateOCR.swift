import Foundation
import AVFoundation
import Vision
import CoreImage
import PreemCore

/// Runs slate OCR over the head and tail of a clip and emits a parsed
/// `SlateData` (scene/take/roll + raw OCR text + confidence) when it
/// finds something credible.
///
/// Strategy:
///   * Sample frames at `samplesPerSecond` fps over the first and last
///     `headTailSeconds` of the clip. Defaults: 2 fps × 5 s × 2 ends = 20 frames.
///   * Run `VNRecognizeTextRequest` in `.accurate` mode (ANE-accelerated).
///   * Concatenate observed text per frame.
///   * Hand off to `SlateParser` for structured extraction.
///   * Pick the best parse (highest confidence × most filled fields).
///
/// Runs on background QoS. Idempotent: cache hits in `MLMetadata.slate`
/// short-circuit before any decode.
public struct SlateOCR: Sendable {

    public struct Configuration: Sendable {
        public var headTailSeconds: Double = 5.0
        public var samplesPerSecond: Double = 2.0
        public var maxObservationsPerFrame: Int = 32
        public var minTextHeightFraction: Float = 0.02
        public init() {}
    }

    public enum OCRError: Error, Sendable {
        case noVideoTrack
        case decoderFailed(String)
        case cancelled
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Run OCR over a clip and return parsed slate data if any was found.
    /// Returns nil when no credible slate text was detected.
    public func recognize(clip: ClipSource) async throws -> SlateData? {
        let asset = AVURLAsset(url: clip.url)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw OCRError.noVideoTrack }

        let durationCM = try await asset.load(.duration)
        let durationSec = CMTimeGetSeconds(durationCM)

        let sampleTimes = buildSampleTimes(durationSec: durationSec)
        guard !sampleTimes.isEmpty else { return nil }

        let frames = try await extractFrames(from: asset, at: sampleTimes)

        var allObservations: [SlateParser.Observation] = []
        allObservations.reserveCapacity(frames.count * 8)

        for frame in frames {
            let observations = try await runOCR(on: frame)
            allObservations.append(contentsOf: observations)
        }

        return SlateParser.parse(allObservations)
    }

    private func buildSampleTimes(durationSec: Double) -> [CMTime] {
        let head = min(configuration.headTailSeconds, durationSec)
        let tailStart = max(0, durationSec - configuration.headTailSeconds)
        let step = 1.0 / max(0.1, configuration.samplesPerSecond)

        var times: [CMTime] = []

        var t = 0.0
        while t < head {
            times.append(CMTime(seconds: t, preferredTimescale: 600))
            t += step
        }

        if tailStart > head {
            var u = tailStart
            while u < durationSec {
                times.append(CMTime(seconds: u, preferredTimescale: 600))
                u += step
            }
        }

        return times
    }

    private func extractFrames(from asset: AVAsset, at times: [CMTime]) async throws -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1920, height: 1080)

        var frames: [CGImage] = []
        frames.reserveCapacity(times.count)

        for time in times {
            do {
                let (image, _) = try await generator.image(at: time)
                frames.append(image)
            } catch {
                continue
            }
        }
        return frames
    }

    private func runOCR(on image: CGImage) async throws -> [SlateParser.Observation] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let results = (request.results as? [VNRecognizedTextObservation]) ?? []
                let observations: [SlateParser.Observation] = results.prefix(self.configuration.maxObservationsPerFrame).compactMap { obs in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return SlateParser.Observation(
                        text: candidate.string,
                        confidence: candidate.confidence,
                        boundingBox: obs.boundingBox
                    )
                }
                continuation.resume(returning: observations)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = self.configuration.minTextHeightFraction

            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
