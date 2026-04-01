import Foundation

public struct MutationPlan: Codable, Sendable {
    public var planId: String
    public var command: String
    public var createdAt: String
    public var dryRun: Bool
    public var requestedSelectors: [String]
    public var resolvedAppIds: [String]
    public var preconditions: [PlanPrecondition]
    public var actions: [PlanAction]

    public init(
        command: String,
        dryRun: Bool,
        requestedSelectors: [String],
        resolvedAppIds: [String],
        preconditions: [PlanPrecondition],
        actions: [PlanAction]
    ) {
        self.planId = IDGenerator.generatePlanId()
        self.command = command
        self.createdAt = ISO8601DateFormatter().string(from: Date())
        self.dryRun = dryRun
        self.requestedSelectors = requestedSelectors
        self.resolvedAppIds = resolvedAppIds
        self.preconditions = preconditions
        self.actions = actions
    }
}

public struct PlanPrecondition: Codable, Sendable {
    public var appId: String
    public var installedVersion: String?
    public var candidateVersion: String?
    public var provider: Provider?

    public init(appId: String, installedVersion: String? = nil, candidateVersion: String? = nil, provider: Provider? = nil) {
        self.appId = appId
        self.installedVersion = installedVersion
        self.candidateVersion = candidateVersion
        self.provider = provider
    }

    /// Check whether this precondition still holds against the current state.
    public func validate(against record: AppRecord) -> Bool {
        if let expected = installedVersion, record.installedVersion != expected { return false }
        if let expected = candidateVersion,
           record.selectedCandidate?.availableVersion != expected { return false }
        if let expected = provider,
           record.selectedCandidate?.provider != expected { return false }
        return true
    }
}

public struct PlanAction: Codable, Sendable {
    public var type: String
    public var appId: String?
    public var token: String?
    public var details: [String: JSONValue]?

    public init(type: String, appId: String? = nil, token: String? = nil, details: [String: JSONValue]? = nil) {
        self.type = type
        self.appId = appId
        self.token = token
        self.details = details
    }
}
