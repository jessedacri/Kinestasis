import Foundation

public protocol PreemID: Hashable, Codable, Sendable, RawRepresentable where RawValue == UUID {}

public struct ClipID: PreemID { public let rawValue: UUID; public init() { rawValue = UUID() }; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct PlacedClipID: PreemID { public let rawValue: UUID; public init() { rawValue = UUID() }; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct TrackID: PreemID { public let rawValue: UUID; public init() { rawValue = UUID() }; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct SequenceID: PreemID { public let rawValue: UUID; public init() { rawValue = UUID() }; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct BinID: PreemID { public let rawValue: UUID; public init() { rawValue = UUID() }; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct EffectInstanceID: PreemID { public let rawValue: UUID; public init() { rawValue = UUID() }; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct MarkerID: PreemID { public let rawValue: UUID; public init() { rawValue = UUID() }; public init(rawValue: UUID) { self.rawValue = rawValue } }
