import Foundation

/// Result of a successful LTC file scan. Produced by `LTCDetector.detect`
/// in the engine target and stored on `AudioFile.ltcDetection` for the
/// UI to render. Carries the TC at sample 0 of the file plus the raw
/// decoder result for diagnostics (frames decoded, detected rate).
///
/// Extracted from the engine's `LTCDetector` struct into the media-model
/// library so it can be a stored property type on `AudioFile` (Swift
/// extensions in other modules can't add stored properties).
public struct LTCDetection {
    /// The TC at the START of the file (sample 0). Computed by
    /// extrapolating backwards from the first decoded frame.
    public let timecodeAtStart: TimecodeValue
    /// Which channel of the file contained the LTC stripe.
    public let channel: Int
    /// Underlying decoder result with diagnostics.
    public let decoderResult: LTCDecoder.Result

    public init(timecodeAtStart: TimecodeValue, channel: Int, decoderResult: LTCDecoder.Result) {
        self.timecodeAtStart = timecodeAtStart
        self.channel = channel
        self.decoderResult = decoderResult
    }
}
