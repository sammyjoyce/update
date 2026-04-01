import Foundation

public actor GitHubSource: UpdateSource {
    public nonisolated let provider = Provider.github

    public init() {}

    public func checkForUpdate(app: AppRecord, config: UpdatestConfig) async throws -> [UpdateCandidate] {
        // GitHub requires a manual_sources mapping to know the repository
        guard let rule = config.manualSources?.first(where: { rule in
            if let ruleAppId = rule.match.appId, ruleAppId == app.appId { return true }
            if let ruleBundleId = rule.match.bundleId, ruleBundleId == app.bundleId { return true }
            return false
        }), let repo = rule.repository else {
            return []
        }

        guard rule.provider == .github || rule.provider == nil else { return [] }

        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return []
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String
        else { return [] }

        // Normalize version from tag
        var version = tagName
        if version.hasPrefix("v") { version = String(version.dropFirst()) }

        let now = ISO8601DateFormatter().string(from: Date())
        let isNewer = app.installedVersion.map {
            VersionCompare.isNewer(version, than: $0)
        } ?? true

        let htmlUrl = json["html_url"] as? String
        let publishedAt = json["published_at"] as? String

        return [UpdateCandidate(
            provider: .github,
            executor: rule.executor ?? .bundle_replace,
            discoveredBy: [.github_release, .manual_mapping],
            availableVersion: version,
            downloadUrl: htmlUrl,
            releaseNotesUrl: htmlUrl,
            requiresSudo: false,
            releaseDate: publishedAt,
            confidence: .medium,
            checkedAt: now,
            selectionReasonCodes: isNewer ? ["newer_version"] : ["up_to_date"],
            rejectionReasonCodes: isNewer ? [] : ["not_newer"],
            details: ["repository": .string(repo), "tag": .string(tagName)]
        )]
    }
}
