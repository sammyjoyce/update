import Foundation

public actor ElectronSource: UpdateSource {
    public nonisolated let provider = Provider.electron

    public init() {}

    public func checkForUpdate(app: AppRecord, config: UpdateConfig) async throws -> [UpdateCandidate] {
        // Check if the app is an Electron app
        guard let info = PlistReader.readAppInfo(atPath: app.path), info.isElectron else {
            return []
        }

        // Try to read update URL from app resources
        guard let updateInfo = readElectronUpdateInfo(appPath: app.path) else {
            return []
        }

        // Fetch update manifest
        guard let url = URL(string: updateInfo.updateUrl) else { return [] }

        let (data, _) = try await URLSession.shared.data(from: url)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String
        else {
            // Try YAML-like format (latest-mac.yml)
            if let yamlVersion = parseSimpleYAMLVersion(data) {
                return [makeCandidate(version: yamlVersion, app: app, updateUrl: updateInfo.updateUrl)]
            }
            return []
        }

        return [makeCandidate(version: version, app: app, updateUrl: updateInfo.updateUrl)]
    }

    private func makeCandidate(version: String, app: AppRecord, updateUrl: String) -> UpdateCandidate {
        let now = ISO8601DateFormatter().string(from: Date())
        let isNewer = app.installedVersion.map {
            VersionCompare.isNewer(version, than: $0)
        } ?? true

        return UpdateCandidate(
            provider: .electron,
            executor: .bundle_replace,
            discoveredBy: [.electron_hint],
            availableVersion: version,
            requiresSudo: false,
            confidence: .medium,
            checkedAt: now,
            selectionReasonCodes: isNewer ? ["newer_version"] : ["up_to_date"],
            rejectionReasonCodes: isNewer ? [] : ["not_newer"],
            details: ["update_url": .string(updateUrl)]
        )
    }

    private struct ElectronUpdateInfo {
        var updateUrl: String
    }

    private func readElectronUpdateInfo(appPath: String) -> ElectronUpdateInfo? {
        let resourcesPath = (appPath as NSString).appendingPathComponent("Contents/Resources")

        // Try app-update.yml
        let ymlPath = (resourcesPath as NSString).appendingPathComponent("app-update.yml")
        if let content = try? String(contentsOfFile: ymlPath, encoding: .utf8),
           let url = parseUpdateUrl(from: content) {
            return ElectronUpdateInfo(updateUrl: url)
        }

        // Try package.json in app.asar.unpacked or resources/app
        let appDir = (resourcesPath as NSString).appendingPathComponent("app")
        let pkgPath = (appDir as NSString).appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: pkgPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let build = json["build"] as? [String: Any],
           let publish = build["publish"] as? [String: Any],
           let url = publish["url"] as? String {
            return ElectronUpdateInfo(updateUrl: url)
        }

        return nil
    }

    private func parseUpdateUrl(from yaml: String) -> String? {
        // Simple key: value YAML parsing for the url field
        for line in yaml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("url:") {
                let value = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private func parseSimpleYAMLVersion(_ data: Data) -> String? {
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("version:") {
                return trimmed.dropFirst(8).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
