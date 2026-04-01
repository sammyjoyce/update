import Darwin
import Foundation

public struct ExecutionOutcome: Sendable {
    public var result: MutationResult
    public var updatedRecord: AppRecord?

    public init(result: MutationResult, updatedRecord: AppRecord? = nil) {
        self.result = result
        self.updatedRecord = updatedRecord
    }
}

public actor UpdateExecutor {
    private let processRunner: ProcessRunner
    private let brewSource: BrewSource
    private let appStoreSource: AppStoreSource

    public init(timeout: TimeInterval = 30) {
        let runner = ProcessRunner(timeout: timeout)
        self.processRunner = runner
        self.brewSource = BrewSource(processRunner: runner)
        self.appStoreSource = AppStoreSource(processRunner: runner)
    }

    public func executeUpdate(
        action: PlanAction,
        record: AppRecord,
        config: UpdateConfig,
        reinstall: Bool,
        noQuarantine: Bool,
        allowSudo: Bool
    ) async -> ExecutionOutcome {
        switch action.type {
        case "brew_upgrade_cask":
            return await executeBrewUpgrade(action: action, record: record, config: config, reinstall: reinstall, noQuarantine: noQuarantine)
        case "mas_upgrade":
            return await executeMasUpgrade(action: action, record: record, config: config)
        case "bundle_replace":
            return await executeBundleReplace(action: action, record: record, allowSudo: allowSudo)
        default:
            return failure(record: record, status: .validation_failed, message: "Unknown update action '\(action.type)'.")
        }
    }

    public func executeAdopt(
        action: PlanAction,
        record: AppRecord,
        config: UpdateConfig,
        reinstall: Bool
    ) async -> ExecutionOutcome {
        guard action.type == "brew_adopt_cask" else {
            return failure(record: record, status: .validation_failed, message: "Unknown adopt action '\(action.type)'.")
        }

        let token = action.token ?? stringDetail(action, key: "token")
        guard let token else {
            return failure(record: record, status: .validation_failed, message: "Missing Homebrew cask token for adoption.")
        }

        do {
            let result = try await brewSource.adoptCask(token: token, config: config, reinstall: reinstall)
            guard result.succeeded else {
                return failure(record: record, status: classifyProcessFailure(result), message: nonEmptyMessage(result.stderr, fallback: "Homebrew adopt failed."))
            }

            var updated = record
            updated.adoptionState = .adopted
            updated.lastCheckedAt = ISO8601DateFormatter().string(from: Date())
            return ExecutionOutcome(
                result: MutationResult(appId: record.appId, selector: record.selectors.canonical, status: .adopted, message: "Adopted into Homebrew cask management."),
                updatedRecord: updated
            )
        } catch let error as UpdateError {
            return failure(record: record, status: map(error: error), message: error.message)
        } catch {
            return failure(record: record, status: .runtime_failed, message: error.localizedDescription)
        }
    }

    private func executeBrewUpgrade(
        action: PlanAction,
        record: AppRecord,
        config: UpdateConfig,
        reinstall: Bool,
        noQuarantine: Bool
    ) async -> ExecutionOutcome {
        let token = action.token ?? stringDetail(action, key: "token")
        guard let token else {
            return failure(record: record, status: .validation_failed, message: "Missing Homebrew cask token for update.")
        }

        do {
            let result = try await brewSource.upgradeCask(
                token: token,
                config: config,
                reinstall: reinstall,
                noQuarantine: noQuarantine
            )
            guard result.succeeded else {
                return failure(record: record, status: classifyProcessFailure(result), message: nonEmptyMessage(result.stderr, fallback: "Homebrew upgrade failed."))
            }

            return successUpdate(record: record, action: action, message: "Updated with Homebrew.")
        } catch let error as UpdateError {
            return failure(record: record, status: map(error: error), message: error.message)
        } catch {
            return failure(record: record, status: .runtime_failed, message: error.localizedDescription)
        }
    }

    private func executeMasUpgrade(
        action: PlanAction,
        record: AppRecord,
        config: UpdateConfig
    ) async -> ExecutionOutcome {
        let trackID = stringDetail(action, key: "track_id")
        guard let trackID else {
            return failure(record: record, status: .validation_failed, message: "Missing App Store track id for update.")
        }

        do {
            let result = try await appStoreSource.upgradeApp(trackID: trackID, config: config)
            guard result.succeeded else {
                return failure(record: record, status: classifyProcessFailure(result), message: nonEmptyMessage(result.stderr, fallback: "App Store upgrade failed."))
            }

            return successUpdate(record: record, action: action, message: "Updated with the App Store.")
        } catch let error as UpdateError {
            return failure(record: record, status: map(error: error), message: error.message)
        } catch {
            return failure(record: record, status: .runtime_failed, message: error.localizedDescription)
        }
    }

    private func executeBundleReplace(
        action: PlanAction,
        record: AppRecord,
        allowSudo: Bool
    ) async -> ExecutionOutcome {
        guard let downloadURLString = stringDetail(action, key: "download_url"),
              let downloadURL = URL(string: downloadURLString) else {
            return failure(record: record, status: .validation_failed, message: "Missing download URL for bundle replacement.")
        }

        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString)", isDirectory: true)
        var mountedVolume: String?

        let outcome: ExecutionOutcome
        do {
            try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)

            let (downloadedFile, _) = try await URLSession.shared.download(from: downloadURL)
            let localArtifact = workspace.appendingPathComponent(downloadURL.lastPathComponent.isEmpty ? "downloaded-artifact" : downloadURL.lastPathComponent)
            try fileManager.copyItem(at: downloadedFile, to: localArtifact)

            let replacementApp: URL
            switch localArtifact.pathExtension.lowercased() {
            case "app":
                replacementApp = localArtifact
            case "zip":
                let extractDir = workspace.appendingPathComponent("unzipped", isDirectory: true)
                try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)
                let unzip = try await processRunner.run("/usr/bin/ditto", arguments: ["-x", "-k", localArtifact.path, extractDir.path])
                guard unzip.succeeded else {
                    outcome = failure(record: record, status: .validation_failed, message: nonEmptyMessage(unzip.stderr, fallback: "Could not extract ZIP archive."))
                    if let mountedVolume {
                        _ = try? await processRunner.run("/usr/bin/hdiutil", arguments: ["detach", mountedVolume])
                    }
                    try? fileManager.removeItem(at: workspace)
                    return outcome
                }
                guard let found = findReplacementApp(in: extractDir, matching: record) else {
                    outcome = failure(record: record, status: .validation_failed, message: "No replacement .app found in ZIP archive.")
                    try? fileManager.removeItem(at: workspace)
                    return outcome
                }
                replacementApp = found
            case "dmg":
                let attach = try await processRunner.run("/usr/bin/hdiutil", arguments: ["attach", localArtifact.path, "-nobrowse", "-readonly"])
                guard attach.succeeded else {
                    outcome = failure(record: record, status: .download_failed, message: nonEmptyMessage(attach.stderr, fallback: "Could not mount DMG."))
                    try? fileManager.removeItem(at: workspace)
                    return outcome
                }
                mountedVolume = parseMountedVolume(from: attach.stdout)
                guard let mountedVolume,
                      let found = findReplacementApp(in: URL(fileURLWithPath: mountedVolume), matching: record) else {
                    outcome = failure(record: record, status: .validation_failed, message: "No replacement .app found in DMG.")
                    if let mountedVolume {
                        _ = try? await processRunner.run("/usr/bin/hdiutil", arguments: ["detach", mountedVolume])
                    }
                    try? fileManager.removeItem(at: workspace)
                    return outcome
                }
                replacementApp = found
            default:
                outcome = failure(record: record, status: .validation_failed, message: "Unsupported bundle replacement artifact '\(localArtifact.lastPathComponent)'.")
                try? fileManager.removeItem(at: workspace)
                return outcome
            }

            if let expectedBundleID = record.bundleId,
               let replacementInfo = PlistReader.readAppInfo(atPath: replacementApp.path),
               let bundleID = replacementInfo.bundleId,
               bundleID != expectedBundleID {
                outcome = failure(record: record, status: .validation_failed, message: "Replacement app bundle id '\(bundleID)' does not match '\(expectedBundleID)'.")
                if let mountedVolume {
                    _ = try? await processRunner.run("/usr/bin/hdiutil", arguments: ["detach", mountedVolume])
                }
                try? fileManager.removeItem(at: workspace)
                return outcome
            }

            let attributes = try fileManager.attributesOfItem(atPath: record.path)
            let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
            let currentUID = getuid()
            let requiresSudo = ownerID != nil && ownerID != currentUID
            if requiresSudo && !allowSudo {
                outcome = failure(record: record, status: .permission_denied, message: "App bundle is not writable by the current user. Re-run with --allow-sudo.")
                if let mountedVolume {
                    _ = try? await processRunner.run("/usr/bin/hdiutil", arguments: ["detach", mountedVolume])
                }
                try? fileManager.removeItem(at: workspace)
                return outcome
            }

            let backupPath = workspace.appendingPathComponent(URL(fileURLWithPath: record.path).lastPathComponent + ".backup")
            let copyArgs = [replacementApp.path, record.path]

            if requiresSudo {
                let moveOut = try await processRunner.run("/usr/bin/sudo", arguments: ["/bin/mv", record.path, backupPath.path])
                guard moveOut.succeeded else {
                    outcome = failure(record: record, status: .permission_denied, message: nonEmptyMessage(moveOut.stderr, fallback: "Could not move existing app bundle with sudo."))
                    if let mountedVolume {
                        _ = try? await processRunner.run("/usr/bin/hdiutil", arguments: ["detach", mountedVolume])
                    }
                    try? fileManager.removeItem(at: workspace)
                    return outcome
                }

                let copyIn = try await processRunner.run("/usr/bin/sudo", arguments: ["/usr/bin/ditto"] + copyArgs)
                if !copyIn.succeeded {
                    _ = try? await processRunner.run("/usr/bin/sudo", arguments: ["/bin/mv", backupPath.path, record.path])
                    outcome = failure(record: record, status: .runtime_failed, message: nonEmptyMessage(copyIn.stderr, fallback: "Could not copy replacement app with sudo."))
                    if let mountedVolume {
                        _ = try? await processRunner.run("/usr/bin/hdiutil", arguments: ["detach", mountedVolume])
                    }
                    try? fileManager.removeItem(at: workspace)
                    return outcome
                }
                _ = try? await processRunner.run("/usr/bin/sudo", arguments: ["/bin/rm", "-rf", backupPath.path])
            } else {
                try fileManager.moveItem(atPath: record.path, toPath: backupPath.path)
                let copyIn = try await processRunner.run("/usr/bin/ditto", arguments: copyArgs)
                if !copyIn.succeeded {
                    try? fileManager.removeItem(atPath: record.path)
                    try? fileManager.moveItem(atPath: backupPath.path, toPath: record.path)
                    outcome = failure(record: record, status: .runtime_failed, message: nonEmptyMessage(copyIn.stderr, fallback: "Could not copy replacement app."))
                    if let mountedVolume {
                        _ = try? await processRunner.run("/usr/bin/hdiutil", arguments: ["detach", mountedVolume])
                    }
                    try? fileManager.removeItem(at: workspace)
                    return outcome
                }
                try? fileManager.removeItem(at: backupPath)
            }

            outcome = successUpdate(record: record, action: action, message: "Updated by replacing the application bundle.")
        } catch let error as UpdateError {
            outcome = failure(record: record, status: map(error: error), message: error.message)
        } catch {
            outcome = failure(record: record, status: .runtime_failed, message: error.localizedDescription)
        }

        if let mountedVolume {
            _ = try? await processRunner.run("/usr/bin/hdiutil", arguments: ["detach", mountedVolume])
        }
        try? fileManager.removeItem(at: workspace)
        return outcome
    }

    private func findReplacementApp(in root: URL, matching record: AppRecord) -> URL? {
        let fileManager = FileManager.default
        if root.pathExtension.lowercased() == "app" {
            return root
        }
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }

        var matches: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
            matches.append(url)
        }

        if let bundleID = record.bundleId,
           let exact = matches.first(where: { PlistReader.readAppInfo(atPath: $0.path)?.bundleId == bundleID }) {
            return exact
        }

        if let nameMatch = matches.first(where: { $0.deletingPathExtension().lastPathComponent == record.name }) {
            return nameMatch
        }

        return matches.count == 1 ? matches.first : matches.first
    }

    private func parseMountedVolume(from output: String) -> String? {
        output
            .split(separator: "\n")
            .compactMap { line -> String? in
                let fields = line.split(separator: "\t")
                guard let last = fields.last, last.hasPrefix("/Volumes/") else { return nil }
                return String(last)
            }
            .last
    }

    private func successUpdate(record: AppRecord, action: PlanAction, message: String) -> ExecutionOutcome {
        var updated = record
        let candidateVersion = stringDetail(action, key: "candidate_version") ?? record.selectedCandidate?.availableVersion
        updated.installedVersion = candidateVersion ?? updated.installedVersion
        updated.updateState = .up_to_date
        updated.lastCheckedAt = ISO8601DateFormatter().string(from: Date())
        if let selected = updated.selectedCandidate, let candidateVersion {
            var newSelected = selected
            newSelected.availableVersion = candidateVersion
            updated.selectedCandidate = newSelected
        }
        return ExecutionOutcome(
            result: MutationResult(appId: record.appId, selector: record.selectors.canonical, status: .updated, message: message),
            updatedRecord: updated
        )
    }

    private func failure(record: AppRecord, status: ItemStatus, message: String) -> ExecutionOutcome {
        ExecutionOutcome(result: MutationResult(appId: record.appId, selector: record.selectors.canonical, status: status, message: message), updatedRecord: nil)
    }

    private func map(error: UpdateError) -> ItemStatus {
        switch error.code {
        case "tool_missing": return .tool_missing
        case "permission_denied": return .permission_denied
        case "download_failed": return .download_failed
        case "validation_failed": return .validation_failed
        case "precondition_failed": return .precondition_failed
        default: return .runtime_failed
        }
    }

    private func classifyProcessFailure(_ result: ProcessResult) -> ItemStatus {
        let stderr = result.stderr.lowercased()
        if stderr.contains("not found") || stderr.contains("no such file") {
            return .tool_missing
        }
        if stderr.contains("permission") || stderr.contains("not permitted") || stderr.contains("operation not permitted") {
            return .permission_denied
        }
        return .runtime_failed
    }

    private func stringDetail(_ action: PlanAction, key: String) -> String? {
        guard let value = action.details?[key] else { return nil }
        switch value {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        default: return nil
        }
    }

    private func nonEmptyMessage(_ message: String, fallback: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
