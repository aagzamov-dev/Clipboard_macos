import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var version = 1
    public var onboardingComplete = false
    public var startMonitoring = true
    public var retentionDays: Int? = 30
    public var maximumCount: Int?
    public var weeklyCleanup = false
    public var lastCleanup: Date?
    public var pinnedFirst = false
    public var appearance = "System"
    public var activeDisplay = true
    public var automaticPaste = false
    public var pollingInterval = 0.5
    public var excludedApps: [String] = []
    public var mergeSeparator = "\n\n"
    public var shortcutKeyCode: UInt32 = 9
    public var shortcutModifiers: UInt32 = 2304
    public init() {}
    public func validate() throws {
        guard version == 1 else { throw CoreError.unsupportedVersion }
        guard retentionDays.map({ (1...36500).contains($0) }) ?? true,
              maximumCount.map({ (1...1_000_000).contains($0) }) ?? true,
              ["System", "Light", "Dark"].contains(appearance), (0.25...2).contains(pollingInterval),
              excludedApps.count <= 100, excludedApps.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }),
              mergeSeparator.utf8.count <= 256, shortcutKeyCode <= 127,
              shortcutModifiers & ~UInt32(256 | 512 | 2048 | 4096) == 0,
              shortcutModifiers & UInt32(256 | 2048 | 4096) != 0 else { throw CoreError.invalidData }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1024 * 1024 else { throw CoreError.tooLarge }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate(); return result
    }
}
