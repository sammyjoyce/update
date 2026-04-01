import Foundation

public struct CheckOutcome: Sendable {
    public var record: AppRecord
    public var warnings: [WarningObject]

    public init(record: AppRecord, warnings: [WarningObject] = []) {
        self.record = record
        self.warnings = warnings
    }
}

public actor UpdateCoordinator {
    private let brewSource: BrewSource
    private let appStoreSource: AppStoreSource
    private let sparkleSource: SparkleSource
    private let gitHubSource: GitHubSource
    private let electronSource: ElectronSource
    private let metadataSource: MetadataSource

    public init(timeout: TimeInterval = 30) {
        let runner = ProcessRunner(timeout: timeout)
        self.brewSource = BrewSource(processRunner: runner)
        self.appStoreSource = AppStoreSource(processRunner: runner)
        self.sparkleSource = SparkleSource()
        self.gitHubSource = GitHubSource()
        self.electronSource = ElectronSource()
        self.metadataSource = MetadataSource()
    }

    public func check(
        app: AppRecord,
        config: UpdateConfig,
        providerFilter: Provider? = nil,
        offline: Bool = false
    ) async -> CheckOutcome {
        var warnings: [WarningObject] = []
        var candidates: [UpdateCandidate] = []

        let requestedProviders = configuredProviders(
            priority: config.resolvedProviderPriority,
            providerFilter: providerFilter,
            offline: offline
        )

        for provider in requestedProviders {
            do {
                let discovered: [UpdateCandidate]
                switch provider {
                case .brew:
                    discovered = try await brewSource.checkForUpdate(app: app, config: config)
                case .appstore:
                    discovered = try await appStoreSource.checkForUpdate(app: app, config: config)
                case .sparkle:
                    discovered = try await sparkleSource.checkForUpdate(app: app, config: config)
                case .github:
                    discovered = try await gitHubSource.checkForUpdate(app: app, config: config)
                case .electron:
                    discovered = try await electronSource.checkForUpdate(app: app, config: config)
                case .metadata:
                    discovered = try await metadataSource.checkForUpdate(app: app, config: config)
                }
                candidates.append(contentsOf: discovered)
            } catch let error as UpdateError {
                warnings.append(.init(code: error.code, message: error.message))
            } catch {
                warnings.append(.init(code: "runtime_failed", message: error.localizedDescription))
            }
        }

        let visibleCandidates = config.resolvedShowUnverifiedUpdates
            ? candidates
            : candidates.filter { $0.confidence != .low }

        let sortedCandidates = visibleCandidates.sorted { lhs, rhs in
            compareCandidates(lhs, rhs, priority: config.resolvedProviderPriority)
        }

        var selected = sortedCandidates.first
        if var candidate = selected {
            if candidate.selectionReasonCodes.isEmpty {
                candidate.selectionReasonCodes = ["provider_priority"]
            }
            selected = candidate
        }

        let rejected = Array(sortedCandidates.dropFirst()).map { candidate -> UpdateCandidate in
            var updated = candidate
            if !updated.rejectionReasonCodes.contains("lower_priority") {
                updated.rejectionReasonCodes.append("lower_priority")
            }
            return updated
        }

        var updatedRecord = app
        updatedRecord.selectedCandidate = selected
        updatedRecord.candidates = selected.map { [$0] + rejected } ?? []
        updatedRecord.lastCheckedAt = ISO8601DateFormatter().string(from: Date())
        updatedRecord.stale = selected?.stale ?? false

        if let selected {
            if let installedVersion = app.installedVersion,
               VersionCompare.isNewer(selected.availableVersion, than: installedVersion) {
                updatedRecord.updateState = .available
            } else {
                updatedRecord.updateState = .up_to_date
            }
        } else {
            updatedRecord.updateState = .unsupported
        }

        return CheckOutcome(record: updatedRecord, warnings: warnings)
    }

    private func configuredProviders(
        priority: [String],
        providerFilter: Provider?,
        offline: Bool
    ) -> [Provider] {
        var providers = priority.compactMap(Provider.init(rawValue:))
        if providers.isEmpty {
            providers = Provider.allCases
        }
        if let providerFilter {
            providers = providers.filter { $0 == providerFilter }
        }
        if offline {
            providers = providers.filter { $0 == .brew }
        }
        return providers
    }

    private func compareCandidates(_ lhs: UpdateCandidate, _ rhs: UpdateCandidate, priority: [String]) -> Bool {
        let providerOrder = Dictionary(uniqueKeysWithValues: priority.enumerated().map { ($1, $0) })
        let lhsPriority = providerOrder[lhs.provider.rawValue] ?? Int.max
        let rhsPriority = providerOrder[rhs.provider.rawValue] ?? Int.max
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        let versionOrder = VersionCompare.compare(lhs.availableVersion, rhs.availableVersion)
        if versionOrder != 0 {
            return versionOrder > 0
        }

        let executorRank: [Executor: Int] = [
            .app_store: 0,
            .brew_cask: 1,
            .bundle_replace: 2,
        ]
        return (executorRank[lhs.executor] ?? Int.max) < (executorRank[rhs.executor] ?? Int.max)
    }
}
