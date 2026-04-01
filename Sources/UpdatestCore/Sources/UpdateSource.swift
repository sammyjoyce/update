import Foundation

/// Protocol for update providers.
public protocol UpdateSource: Sendable {
    var provider: Provider { get }
    func checkForUpdate(app: AppRecord, config: UpdatestConfig) async throws -> [UpdateCandidate]
}

/// Default cache TTLs per provider (in seconds).
public enum CacheTTL {
    public static func forProvider(_ provider: Provider) -> TimeInterval {
        switch provider {
        case .brew: return 3600        // 1h
        case .appstore: return 3600    // 1h
        case .sparkle: return 21600    // 6h
        case .github: return 21600     // 6h
        case .electron: return 21600   // 6h
        case .metadata: return 86400   // 24h
        }
    }
}
