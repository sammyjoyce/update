import Foundation

public struct AppSelectors: Codable, Sendable {
    public var canonical: String
    public var accepted: [String]

    public init(canonical: String, accepted: [String] = []) {
        self.canonical = canonical
        self.accepted = accepted
    }
}

public struct UpdateCandidate: Codable, Sendable {
    public var provider: Provider
    public var executor: Executor
    public var discoveredBy: [DiscoveryMethod]
    public var availableVersion: String
    public var downloadUrl: String?
    public var releaseNotesUrl: String?
    public var requiresSudo: Bool
    public var releaseDate: String?
    public var confidence: ConfidenceLevel
    public var checkedAt: String?
    public var stale: Bool
    public var selectionReasonCodes: [String]
    public var rejectionReasonCodes: [String]
    public var details: [String: JSONValue]

    public init(
        provider: Provider,
        executor: Executor,
        discoveredBy: [DiscoveryMethod] = [],
        availableVersion: String,
        downloadUrl: String? = nil,
        releaseNotesUrl: String? = nil,
        requiresSudo: Bool = false,
        releaseDate: String? = nil,
        confidence: ConfidenceLevel = .high,
        checkedAt: String? = nil,
        stale: Bool = false,
        selectionReasonCodes: [String] = [],
        rejectionReasonCodes: [String] = [],
        details: [String: JSONValue] = [:]
    ) {
        self.provider = provider
        self.executor = executor
        self.discoveredBy = discoveredBy
        self.availableVersion = availableVersion
        self.downloadUrl = downloadUrl
        self.releaseNotesUrl = releaseNotesUrl
        self.requiresSudo = requiresSudo
        self.releaseDate = releaseDate
        self.confidence = confidence
        self.checkedAt = checkedAt
        self.stale = stale
        self.selectionReasonCodes = selectionReasonCodes
        self.rejectionReasonCodes = rejectionReasonCodes
        self.details = details
    }
}

public struct AppRecord: Codable, Sendable {
    public var appId: String
    public var name: String
    public var bundleId: String?
    public var path: String
    public var installedVersion: String?
    public var selectors: AppSelectors
    public var trackingState: TrackingState
    public var adoptionState: AdoptionState
    public var updateState: UpdateState
    public var selectedCandidate: UpdateCandidate?
    public var candidates: [UpdateCandidate]
    public var lastCheckedAt: String?
    public var stale: Bool

    public init(
        appId: String,
        name: String,
        bundleId: String? = nil,
        path: String,
        installedVersion: String? = nil,
        selectors: AppSelectors? = nil,
        trackingState: TrackingState = .active,
        adoptionState: AdoptionState = .unmanaged,
        updateState: UpdateState = .unchecked,
        selectedCandidate: UpdateCandidate? = nil,
        candidates: [UpdateCandidate] = [],
        lastCheckedAt: String? = nil,
        stale: Bool = false
    ) {
        self.appId = appId
        self.name = name
        self.bundleId = bundleId
        self.path = path
        self.installedVersion = installedVersion
        self.selectors = selectors ?? AppSelectors(canonical: "id:\(appId)")
        self.trackingState = trackingState
        self.adoptionState = adoptionState
        self.updateState = updateState
        self.selectedCandidate = selectedCandidate
        self.candidates = candidates
        self.lastCheckedAt = lastCheckedAt
        self.stale = stale
    }
}

public struct IgnoreEntry: Codable, Sendable {
    public var appId: String
    public var scope: IgnoreScope
    public var reason: String?
    public var createdAt: String

    public init(appId: String, scope: IgnoreScope = .all, reason: String? = nil) {
        self.appId = appId
        self.scope = scope
        self.reason = reason
        self.createdAt = ISO8601DateFormatter().string(from: Date())
    }
}

public struct SkipEntry: Codable, Sendable {
    public var appId: String
    public var version: String
    public var expiresAt: String?
    public var createdAt: String

    public init(appId: String, version: String, expiresIn: String? = nil) {
        self.appId = appId
        self.version = version
        self.createdAt = ISO8601DateFormatter().string(from: Date())
        if let dur = expiresIn, let seconds = DurationParser.parseToSeconds(dur) {
            self.expiresAt = ISO8601DateFormatter().string(
                from: Date().addingTimeInterval(seconds)
            )
        } else {
            self.expiresAt = nil
        }
    }

    public var isExpired: Bool {
        guard let expiresAt,
              let date = ISO8601DateFormatter().date(from: expiresAt)
        else { return false }
        return date < Date()
    }
}

/// Information read from a .app bundle during scanning.
public struct AppInfo: Sendable {
    public var name: String
    public var bundleId: String?
    public var version: String?
    public var shortVersion: String?
    public var path: String
    public var sparkleFeedUrl: String?
    public var isElectron: Bool
    public var teamId: String?

    public init(
        name: String,
        bundleId: String? = nil,
        version: String? = nil,
        shortVersion: String? = nil,
        path: String,
        sparkleFeedUrl: String? = nil,
        isElectron: Bool = false,
        teamId: String? = nil
    ) {
        self.name = name
        self.bundleId = bundleId
        self.version = version
        self.shortVersion = shortVersion
        self.path = path
        self.sparkleFeedUrl = sparkleFeedUrl
        self.isElectron = isElectron
        self.teamId = teamId
    }
}
