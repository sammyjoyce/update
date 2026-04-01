import Foundation

public actor AppStoreSource: UpdateSource {
    public nonisolated let provider = Provider.appstore
    private let processRunner: ProcessRunner

    public init(processRunner: ProcessRunner) {
        self.processRunner = processRunner
    }

    public func checkForUpdate(app: AppRecord, config: UpdateConfig) async throws -> [UpdateCandidate] {
        guard let bundleId = app.bundleId else { return [] }

        // Query iTunes lookup API
        guard let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(bundleId)&country=us") else {
            return []
        }

        let (data, _) = try await URLSession.shared.data(from: url)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let result = results.first,
              let version = result["version"] as? String
        else { return [] }

        let trackViewUrl = result["trackViewUrl"] as? String
        let trackID = result["trackId"]
        let now = ISO8601DateFormatter().string(from: Date())

        let isNewer = app.installedVersion.map {
            VersionCompare.isNewer(version, than: $0)
        } ?? true

        var confidence: ConfidenceLevel = .medium

        // Try mas as secondary signal
        if let masResult = try? await checkMas(bundleId: bundleId, config: config) {
            if masResult { confidence = .high }
        }

        var details: [String: JSONValue] = trackViewUrl.map { ["track_url": .string($0)] } ?? [:]
        if let trackID = trackID as? Int {
            details["track_id"] = .int(trackID)
        } else if let trackID = trackID as? String {
            details["track_id"] = .string(trackID)
        }

        return [UpdateCandidate(
            provider: .appstore,
            executor: .app_store,
            discoveredBy: [.appstore_lookup],
            availableVersion: version,
            downloadUrl: trackViewUrl,
            requiresSudo: false,
            confidence: confidence,
            checkedAt: now,
            selectionReasonCodes: isNewer ? ["newer_version"] : ["up_to_date"],
            rejectionReasonCodes: isNewer ? [] : ["not_newer"],
            details: details
        )]
    }

    public func upgradeApp(trackID: String, config: UpdateConfig) async throws -> ProcessResult {
        let masPath = config.masPath ?? "mas"
        return try await processRunner.runCommand(masPath, arguments: ["upgrade", trackID])
    }

    private func checkMas(bundleId: String, config: UpdateConfig) async throws -> Bool {
        let masPath = config.masPath ?? "mas"
        let result = try await processRunner.runCommand(masPath, arguments: ["outdated"])
        guard result.succeeded else { return false }
        return result.stdout.contains(bundleId)
    }
}
