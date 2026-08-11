import Foundation
import KineCore

public struct PendingMismatch: Identifiable {
    public let id = UUID()
    public let mismatch: SequenceMismatch
    public let dropTime: RationalTime

    public init(mismatch: SequenceMismatch, dropTime: RationalTime) {
        self.mismatch = mismatch
        self.dropTime = dropTime
    }
}

/// A description of how a clip differs from the active sequence. The
/// drop handler surfaces this to the user so they can decide between
/// modifying the sequence or accepting a mismatched clip.
public struct SequenceMismatch: Identifiable {
    public let id = UUID()
    public let clipID: ClipID
    public let fields: [Field]
    public let proposedSettings: SequenceSettings

    public enum Field {
        case resolution(PixelSize, PixelSize)        // clip, sequence
        case frameRate(FrameRate, FrameRate)
        case sampleRate(Int, Int)
        case channels(Int, Int)

        public var description: String {
            switch self {
            case .resolution(let c, let s):
                return "Resolution: clip \(c.width)×\(c.height) ≠ sequence \(s.width)×\(s.height)"
            case .frameRate(let c, let s):
                return "Frame rate: clip \(c.rawValue) fps ≠ sequence \(s.rawValue) fps"
            case .sampleRate(let c, let s):
                return "Audio rate: clip \(c) Hz ≠ sequence \(s) Hz"
            case .channels(let c, let s):
                return "Channels: clip \(c) ≠ sequence \(s)"
            }
        }
    }
}
