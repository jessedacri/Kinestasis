import Foundation

public struct Project: Codable, Sendable {
    /// Bumped when the on-disk shape of the project changes incompatibly.
    /// v1 was the legacy flat-JSON `.kine` file. v2 is a `.kine`
    /// directory containing `project.json` + cache subdirectories.
    public static let currentFormatVersion: Int = 2

    public var id: UUID
    public var formatVersion: Int
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var settings: ProjectSettings
    public var mediaPool: MediaPool
    public var sequences: [Sequence]

    public init(
        id: UUID = UUID(),
        name: String,
        formatVersion: Int = Project.currentFormatVersion,
        settings: ProjectSettings = .default,
        mediaPool: MediaPool = MediaPool(),
        sequences: [Sequence] = []
    ) {
        self.id = id
        self.formatVersion = formatVersion
        self.name = name
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.settings = settings
        self.mediaPool = mediaPool
        self.sequences = sequences
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self, forKey: .id)
        formatVersion   = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        name            = try c.decode(String.self, forKey: .name)
        createdAt       = try c.decode(Date.self, forKey: .createdAt)
        modifiedAt      = try c.decode(Date.self, forKey: .modifiedAt)
        settings        = try c.decode(ProjectSettings.self, forKey: .settings)
        mediaPool       = try c.decode(MediaPool.self, forKey: .mediaPool)
        sequences       = try c.decode([Sequence].self, forKey: .sequences)
    }
}

public struct ProjectSettings: Codable, Sendable {
    public var defaultFrameRate: FrameRate
    public var defaultResolution: PixelSize
    public var defaultColorSpace: ColorSpace
    public var burst: BurstDefaults

    public static let `default` = ProjectSettings(
        defaultFrameRate: .twentyThree976,
        defaultResolution: PixelSize(width: 1920, height: 1080),
        defaultColorSpace: .rec709
    )

    public init(defaultFrameRate: FrameRate, defaultResolution: PixelSize, defaultColorSpace: ColorSpace, burst: BurstDefaults = .default) {
        self.defaultFrameRate = defaultFrameRate
        self.defaultResolution = defaultResolution
        self.defaultColorSpace = defaultColorSpace
        self.burst = burst
    }

    private enum CodingKeys: String, CodingKey {
        case defaultFrameRate, defaultResolution, defaultColorSpace, burst
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultFrameRate = try c.decode(FrameRate.self, forKey: .defaultFrameRate)
        defaultResolution = try c.decode(PixelSize.self, forKey: .defaultResolution)
        defaultColorSpace = try c.decode(ColorSpace.self, forKey: .defaultColorSpace)
        burst = try c.decodeIfPresent(BurstDefaults.self, forKey: .burst) ?? .default
    }
}

public struct PixelSize: Hashable, Codable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public enum ColorSpace: String, Codable, Sendable {
    case rec709, rec2020, sRGB, displayP3, aces
}

public enum FrameRate: String, Codable, Sendable, CaseIterable {
    case twentyThree976 = "23.976"
    case twentyFour     = "24"
    case twentyFive     = "25"
    case twentyNine97   = "29.97"
    case thirty         = "30"
    case fifty          = "50"
    case fiftyNine94    = "59.94"
    case sixty          = "60"

    public var rationalScale: Int32 {
        switch self {
        case .twentyThree976, .twentyNine97, .fiftyNine94: return 1001
        default: return 1
        }
    }

    public var rationalRate: Int32 {
        switch self {
        case .twentyThree976: return 24000
        case .twentyFour:     return 24
        case .twentyFive:     return 25
        case .twentyNine97:   return 30000
        case .thirty:         return 30
        case .fifty:          return 50
        case .fiftyNine94:    return 60000
        case .sixty:          return 60
        }
    }

    public var fps: Double {
        Double(rationalRate) / Double(max(1, rationalScale))
    }
}
