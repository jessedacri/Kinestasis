import Foundation

public protocol KineID: Hashable, Codable, Sendable, RawRepresentable where RawValue == UUID {}

public struct ClipID: KineID { public let rawValue: UUID; public init() { rawValue = UUID() }; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct PlacedClipID: KineID { public let rawValue: UUID; public init() { rawValue = UUID() }; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct TrackID: KineID { public let rawValue: UUID; public init() { rawValue = UUID() }; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct SequenceID: KineID { public let rawValue: UUID; public init() { rawValue = UUID() }; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct BinID: KineID { public let rawValue: UUID; public init() { rawValue = UUID() }; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct EffectInstanceID: KineID { public let rawValue: UUID; public init() { rawValue = UUID() }; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct MarkerID: KineID { public let rawValue: UUID; public init() { rawValue = UUID() }; public init(rawValue: UUID) { self.rawValue = rawValue } }
