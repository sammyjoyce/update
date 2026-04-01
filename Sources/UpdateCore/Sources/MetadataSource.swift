import Foundation

/// Curated metadata provider. Disabled by default per the privacy contract.
public actor MetadataSource: UpdateSource {
    public nonisolated let provider = Provider.metadata

    public init() {}

    public func checkForUpdate(app: AppRecord, config: UpdateConfig) async throws -> [UpdateCandidate] {
        // Metadata sync must be explicitly enabled
        guard config.resolvedMetadataSyncEnabled else { return [] }
        guard let bundleId = app.bundleId else { return [] }

        // This is a stub. A real implementation would query a curated metadata service
        // sending only bundle IDs and client version, per the privacy contract.
        // The CLI MUST NOT send paths, usernames, or release-note text.

        _ = bundleId // Would be sent to lookup service
        return []
    }
}
