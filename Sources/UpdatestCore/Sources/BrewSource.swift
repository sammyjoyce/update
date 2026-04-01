import Foundation

public actor BrewSource: UpdateSource {
    public nonisolated let provider = Provider.brew
    private let processRunner: ProcessRunner
    private var caskCache: [BrewCaskInfo]?

    public init(processRunner: ProcessRunner) {
        self.processRunner = processRunner
    }

    public func checkForUpdate(app: AppRecord, config: UpdatestConfig) async throws -> [UpdateCandidate] {
        let casks = try await loadCasks(config: config)

        // Match by bundle ID first, then by name
        let match = casks.first(where: { cask in
            if let bundleId = app.bundleId {
                return cask.bundleId == bundleId
            }
            return false
        }) ?? casks.first(where: { cask in
            cask.name.localizedCaseInsensitiveCompare(app.name) == .orderedSame ||
            cask.appNames.contains(where: { $0.localizedCaseInsensitiveCompare(app.name) == .orderedSame })
        })

        guard let match else { return [] }

        let now = ISO8601DateFormatter().string(from: Date())
        let isNewer = app.installedVersion.map {
            VersionCompare.isNewer(match.version, than: $0)
        } ?? true

        return [UpdateCandidate(
            provider: .brew,
            executor: .brew_cask,
            discoveredBy: [.brew_inspection],
            availableVersion: match.version,
            downloadUrl: match.url,
            requiresSudo: false,
            confidence: .high,
            checkedAt: now,
            selectionReasonCodes: isNewer ? ["newer_version"] : ["up_to_date"],
            rejectionReasonCodes: isNewer ? [] : ["not_newer"],
            details: ["cask_token": .string(match.token)]
        )]
    }

    /// Check if a cask token exists for a given app.
    public func findCaskToken(for app: AppRecord, config: UpdatestConfig) async throws -> String? {
        let casks = try await loadCasks(config: config)
        let match = casks.first(where: { cask in
            if let bundleId = app.bundleId { return cask.bundleId == bundleId }
            return cask.appNames.contains(where: {
                $0.localizedCaseInsensitiveCompare(app.name) == .orderedSame
            })
        })
        return match?.token
    }

    private func loadCasks(config: UpdatestConfig, forceRefresh: Bool = false) async throws -> [BrewCaskInfo] {
        if let cached = caskCache, !forceRefresh { return cached }

        let brewPath = config.brewPath ?? "/opt/homebrew/bin/brew"

        // Get list of installed casks with info
        let result = try await processRunner.run(
            brewPath, arguments: ["info", "--cask", "--json=v2", "--installed"]
        )

        guard result.succeeded else {
            throw UpdatestError.runtime(
                code: "tool_missing",
                message: "Homebrew not available or failed: \(result.stderr.prefix(200))"
            )
        }

        let casks = parseCaskJSON(result.stdout)
        caskCache = casks
        return casks
    }

    /// Get outdated casks from brew.
    public func getOutdated(config: UpdatestConfig, skipUpdate: Bool = false) async throws -> [BrewOutdatedCask] {
        let brewPath = config.brewPath ?? "/opt/homebrew/bin/brew"

        if !skipUpdate {
            _ = try? await processRunner.run(brewPath, arguments: ["update", "--quiet"])
        }

        let result = try await processRunner.run(
            brewPath, arguments: ["outdated", "--cask", "--json"]
        )

        guard result.succeeded else { return [] }

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]]
        else { return [] }

        return casks.compactMap { cask in
            guard let name = cask["name"] as? String,
                  let installedVersions = cask["installed_versions"] as? String,
                  let currentVersion = cask["current_version"] as? String
            else { return nil }
            return BrewOutdatedCask(
                token: name,
                installedVersion: installedVersions,
                currentVersion: currentVersion
            )
        }
    }

    /// Run brew upgrade for a cask.
    public func upgradeCask(
        token: String, config: UpdatestConfig, reinstall: Bool = false, noQuarantine: Bool = false
    ) async throws -> ProcessResult {
        let brewPath = config.brewPath ?? "/opt/homebrew/bin/brew"
        var args = [reinstall ? "reinstall" : "upgrade", "--cask", token]
        if noQuarantine || config.resolvedBrewNoQuarantine {
            args.append("--no-quarantine")
        }
        return try await processRunner.run(brewPath, arguments: args)
    }

    /// Run brew install --adopt for a cask.
    public func adoptCask(
        token: String, config: UpdatestConfig, reinstall: Bool = false
    ) async throws -> ProcessResult {
        let brewPath = config.brewPath ?? "/opt/homebrew/bin/brew"
        var args = ["install", "--cask", "--adopt", token]
        if reinstall { args.append("--force") }
        return try await processRunner.run(brewPath, arguments: args)
    }

    private func parseCaskJSON(_ jsonString: String) -> [BrewCaskInfo] {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]]
        else { return [] }

        return casks.compactMap { cask -> BrewCaskInfo? in
            guard let token = cask["token"] as? String,
                  let version = cask["version"] as? String
            else { return nil }

            let name = (cask["name"] as? [String])?.first ?? token
            let bundleId = extractBundleId(from: cask)
            let appNames = (cask["artifacts"] as? [[String: Any]])?.compactMap { artifact -> String? in
                if let apps = artifact["app"] as? [String] { return apps.first }
                return nil
            } ?? []
            let url = cask["url"] as? String

            return BrewCaskInfo(
                token: token, name: name, version: version,
                bundleId: bundleId, appNames: appNames, url: url
            )
        }
    }

    private func extractBundleId(from cask: [String: Any]) -> String? {
        // Try to find bundle ID in cask artifacts
        if let artifacts = cask["artifacts"] as? [[String: Any]] {
            for artifact in artifacts {
                if let uninstall = artifact["uninstall"] as? [[String: Any]] {
                    for entry in uninstall {
                        if let bundleId = entry["pkgutil"] as? String { return bundleId }
                    }
                }
            }
        }
        return nil
    }
}

public struct BrewCaskInfo: Sendable {
    public let token: String
    public let name: String
    public let version: String
    public let bundleId: String?
    public let appNames: [String]
    public let url: String?
}

public struct BrewOutdatedCask: Sendable {
    public let token: String
    public let installedVersion: String
    public let currentVersion: String
}
