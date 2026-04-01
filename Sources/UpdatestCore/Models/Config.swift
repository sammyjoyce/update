import Foundation

public struct ManualSourceMatch: Codable, Sendable {
    public var appId: String?
    public var bundleId: String?

    public init(appId: String? = nil, bundleId: String? = nil) {
        self.appId = appId
        self.bundleId = bundleId
    }
}

public struct ManualSourceRule: Codable, Sendable {
    public var match: ManualSourceMatch
    public var provider: Provider?
    public var repository: String?
    public var assetPattern: String?
    public var executor: Executor?
    public var teamId: String?

    public init(
        match: ManualSourceMatch,
        provider: Provider? = nil,
        repository: String? = nil,
        assetPattern: String? = nil,
        executor: Executor? = nil,
        teamId: String? = nil
    ) {
        self.match = match
        self.provider = provider
        self.repository = repository
        self.assetPattern = assetPattern
        self.executor = executor
        self.teamId = teamId
    }
}

public struct UpdatestConfig: Codable, Sendable {
    public var locations: [String]?
    public var brewPath: String?
    public var masPath: String?
    public var timeout: String?
    public var providerPriority: [String]?
    public var brewNoQuarantine: Bool?
    public var showUnverifiedUpdates: Bool?
    public var ignoreMacosCompat: Bool?
    public var proxy: String?
    public var metadataSyncEnabled: Bool?
    public var manualSources: [ManualSourceRule]?

    public init(
        locations: [String]? = nil,
        brewPath: String? = nil,
        masPath: String? = nil,
        timeout: String? = nil,
        providerPriority: [String]? = nil,
        brewNoQuarantine: Bool? = nil,
        showUnverifiedUpdates: Bool? = nil,
        ignoreMacosCompat: Bool? = nil,
        proxy: String? = nil,
        metadataSyncEnabled: Bool? = nil,
        manualSources: [ManualSourceRule]? = nil
    ) {
        self.locations = locations
        self.brewPath = brewPath
        self.masPath = masPath
        self.timeout = timeout
        self.providerPriority = providerPriority
        self.brewNoQuarantine = brewNoQuarantine
        self.showUnverifiedUpdates = showUnverifiedUpdates
        self.ignoreMacosCompat = ignoreMacosCompat
        self.proxy = proxy
        self.metadataSyncEnabled = metadataSyncEnabled
        self.manualSources = manualSources
    }

    public static let defaults = UpdatestConfig(
        locations: ["/Applications"],
        brewPath: nil,
        masPath: nil,
        timeout: "30s",
        providerPriority: ["appstore", "brew", "sparkle", "github", "electron", "metadata"],
        brewNoQuarantine: false,
        showUnverifiedUpdates: false,
        ignoreMacosCompat: false,
        proxy: nil,
        metadataSyncEnabled: false,
        manualSources: []
    )

    /// Merge another config on top of this one (other overrides self for non-nil values).
    public func merging(with other: UpdatestConfig) -> UpdatestConfig {
        var result = self
        if let v = other.locations { result.locations = v }
        if let v = other.brewPath { result.brewPath = v }
        if let v = other.masPath { result.masPath = v }
        if let v = other.timeout { result.timeout = v }
        if let v = other.providerPriority { result.providerPriority = v }
        if let v = other.brewNoQuarantine { result.brewNoQuarantine = v }
        if let v = other.showUnverifiedUpdates { result.showUnverifiedUpdates = v }
        if let v = other.ignoreMacosCompat { result.ignoreMacosCompat = v }
        if let v = other.proxy { result.proxy = v }
        if let v = other.metadataSyncEnabled { result.metadataSyncEnabled = v }
        if let v = other.manualSources { result.manualSources = v }
        return result
    }

    // Resolved accessors with defaults
    public var resolvedLocations: [String] { locations ?? ["/Applications"] }
    public var resolvedTimeout: String { timeout ?? "30s" }
    public var resolvedProviderPriority: [String] {
        providerPriority ?? ["appstore", "brew", "sparkle", "github", "electron", "metadata"]
    }
    public var resolvedBrewNoQuarantine: Bool { brewNoQuarantine ?? false }
    public var resolvedShowUnverifiedUpdates: Bool { showUnverifiedUpdates ?? false }
    public var resolvedIgnoreMacosCompat: Bool { ignoreMacosCompat ?? false }
    public var resolvedMetadataSyncEnabled: Bool { metadataSyncEnabled ?? false }
}

/// Describes a single config key for schema introspection.
public struct ConfigKeySpec: Sendable {
    public let key: String
    public let type: String
    public let defaultValue: String
    public let envVar: String?
    public let description: String
    public let mutable: Bool

    public init(
        key: String, type: String, defaultValue: String,
        envVar: String? = nil, description: String, mutable: Bool = true
    ) {
        self.key = key
        self.type = type
        self.defaultValue = defaultValue
        self.envVar = envVar
        self.description = description
        self.mutable = mutable
    }

    public static let all: [ConfigKeySpec] = [
        .init(key: "locations", type: "string[]", defaultValue: "[\"/Applications\"]",
              envVar: "UPDATEST_LOCATIONS", description: "App directories to scan"),
        .init(key: "brew_path", type: "string", defaultValue: "auto-detect",
              envVar: "UPDATEST_BREW_PATH", description: "Brew binary path"),
        .init(key: "mas_path", type: "string", defaultValue: "auto-detect",
              envVar: "UPDATEST_MAS_PATH", description: "mas binary path"),
        .init(key: "timeout", type: "duration", defaultValue: "30s",
              envVar: "UPDATEST_TIMEOUT", description: "Per-source timeout"),
        .init(key: "provider_priority", type: "string[]",
              defaultValue: "[\"appstore\",\"brew\",\"sparkle\",\"github\",\"electron\",\"metadata\"]",
              description: "Candidate selection priority"),
        .init(key: "brew_no_quarantine", type: "bool", defaultValue: "false",
              description: "Default quarantine behavior"),
        .init(key: "show_unverified_updates", type: "bool", defaultValue: "false",
              description: "Include low-confidence candidates"),
        .init(key: "ignore_macos_compat", type: "bool", defaultValue: "false",
              description: "Ignore brew/macOS compatibility checks"),
        .init(key: "proxy", type: "string?", defaultValue: "system",
              envVar: "HTTPS_PROXY", description: "HTTP proxy"),
        .init(key: "metadata_sync_enabled", type: "bool", defaultValue: "false",
              description: "Opt in to curated metadata lookups"),
        .init(key: "manual_sources", type: "ManualSourceRule[]", defaultValue: "[]",
              description: "User-defined provider and executor hints"),
    ]
}
