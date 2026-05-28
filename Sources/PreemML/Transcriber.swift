import Foundation
import AVFoundation
import Speech
import PreemCore

/// Transcribes a clip's audio to text with segment-level timestamps.
///
/// v0.1 uses Apple's `SFSpeechRecognizer` in on-device mode:
///   - No model files to ship.
///   - ANE/CPU accelerated by Apple.
///   - Requires `NSSpeechRecognitionUsageDescription` in Info.plist.
///   - First call triggers a system permission dialog; subsequent calls
///     get the stored authorization status.
///
/// On permission denial, returns nil rather than throwing — the rest of
/// the ingest pipeline keeps working without transcripts.
///
/// Quality limitations of `SFSpeechRecognizer` (vs Whisper):
///   - Weaker on noisy / overlapping dialogue
///   - Single-language at a time (we set Locale to current)
///   - Some platform versions cap per-request length
///
/// A whisper.cpp Core ML backend can swap in behind the same public
/// interface when quality matters.
public struct Transcriber: Sendable {

    public struct Configuration: Sendable {
        public var locale: Locale = .current
        public var requireOnDeviceRecognition: Bool = true
        public var maxDurationSeconds: TimeInterval = 600   // hard cap for v0.1
        public init() {}
    }

    public enum TranscribeError: Error, Sendable {
        case permissionDenied
        case noAudioTrack
        case recognizerUnavailable
        case recognitionFailed(String)
        case clipTooLong(seconds: TimeInterval)
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func transcribe(clip: ClipSource) async throws -> TranscriptData? {
        guard !clip.audioTracks.isEmpty else { throw TranscribeError.noAudioTrack }

        if clip.duration.seconds > configuration.maxDurationSeconds {
            throw TranscribeError.clipTooLong(seconds: clip.duration.seconds)
        }

        let authorization = await requestAuthorization()
        switch authorization {
        case .authorized: break
        case .denied, .restricted, .notDetermined:
            return nil
        @unknown default:
            return nil
        }

        guard let recognizer = SFSpeechRecognizer(locale: configuration.locale), recognizer.isAvailable else {
            throw TranscribeError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: clip.url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        if configuration.requireOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let result = try await runRecognition(recognizer: recognizer, request: request)
        return convert(result: result, locale: configuration.locale)
    }

    private func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    private func runRecognition(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechURLRecognitionRequest
    ) async throws -> SFSpeechRecognitionResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SFSpeechRecognitionResult, Error>) in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    cont.resume(throwing: TranscribeError.recognitionFailed(error.localizedDescription))
                    return
                }
                guard let result, result.isFinal else { return }
                cont.resume(returning: result)
            }
        }
    }

    private func convert(result: SFSpeechRecognitionResult, locale: Locale) -> TranscriptData {
        let segments = result.bestTranscription.segments.map { seg in
            TranscriptSegment(
                start: RationalTime(value: Int64(seg.timestamp * 1000), scale: 1000),
                end: RationalTime(value: Int64((seg.timestamp + seg.duration) * 1000), scale: 1000),
                text: seg.substring,
                confidence: Double(seg.confidence)
            )
        }
        return TranscriptData(segments: segments, language: locale.identifier)
    }
}
