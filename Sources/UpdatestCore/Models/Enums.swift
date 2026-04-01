import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case brew
    case appstore
    case sparkle
    case github
    case electron
    case metadata
}

public enum Executor: String, Codable, CaseIterable, Sendable {
    case brew_cask
    case app_store
    case bundle_replace
}

public enum DiscoveryMethod: String, Codable, CaseIterable, Sendable {
    case bundle_scan
    case brew_inspection
    case sparkle_feed
    case appstore_lookup
    case github_release
    case electron_hint
    case metadata_lookup
    case manual_mapping
}

public enum ConfidenceLevel: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low
}

public enum TrackingState: String, Codable, CaseIterable, Sendable {
    case active
    case ignored_updates
    case ignored_adoption
    case ignored_all
    case missing
}

public enum UpdateState: String, Codable, CaseIterable, Sendable {
    case unchecked
    case up_to_date
    case available
    case skipped
    case blocked
    case unsupported
}

public enum AdoptionState: String, Codable, CaseIterable, Sendable {
    case unmanaged
    case adopted
    case adoptable
    case not_adoptable
}

public enum ItemStatus: String, Codable, CaseIterable, Sendable {
    case planned
    case updated
    case up_to_date
    case adopted
    case ignored
    case skipped
    case permission_denied
    case tool_missing
    case download_failed
    case validation_failed
    case precondition_failed
    case runtime_failed
}

public enum SummaryStatus: String, Codable, Sendable {
    case success
    case partial
    case failed
}

public enum IgnoreScope: String, Codable, CaseIterable, Sendable {
    case updates
    case adoption
    case all
}

public enum OutputFormat: String, Sendable, CaseIterable {
    case auto
    case json
    case ndjson
    case human
    case plain
}

public enum ConfigScope: String, Codable, CaseIterable, Sendable {
    case user
    case project
    case effective
}

public enum Stability: String, Codable, Sendable {
    case stable
    case experimental
    case deprecated
}

public enum ExitCode: Int32, Sendable {
    case success = 0
    case runtimeFailure = 1
    case invalidUsage = 2
    case partialSuccess = 3
    case confirmationRequired = 4
    case unsafeInput = 5
}
