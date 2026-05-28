import Foundation
import PreemCore

/// PreemML lives between PreemMedia and the rest of the app. It analyses
/// a `ClipSource` and returns `MLMetadata` (slate / shot type / transcript).
///
/// Three pipelines, all targeting the Neural Engine via `MLComputeUnits.all`:
///   - SlateOCR        — Vision.VNRecognizeTextRequest (M1)
///   - ShotClassifier  — Core ML image classifier (M1)
///   - Transcriber     — SFSpeechRecognizer offline, or whisper.cpp CoreML (M1)
///
/// All three are background-QoS, cached to `MyProject.preem/ml/`. Re-runs
/// are a cache hit.
public enum PreemML {
    public static let version = "0.1.0-m1-scaffold"
}
