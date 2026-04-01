import Foundation

/// Persistent state store for app records, ignores, and skips.
public actor StateService {
    private var apps: [String: AppRecord] = [:]
    private var ignores: [String: IgnoreEntry] = [:]
    private var skips: [String: SkipEntry] = [:]
    private let statePath: String

    public init(statePath: String? = nil) {
        let xdgData = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".local/share")
        self.statePath = statePath ?? (xdgData as NSString).appendingPathComponent("update/state.json")
    }

    // MARK: - Load / Save

    public func load() throws {
        let url = URL(fileURLWithPath: statePath)
        guard FileManager.default.fileExists(atPath: statePath) else { return }
        let data = try Data(contentsOf: url)
        let state = try JSONCoders.decoder.decode(PersistedState.self, from: data)
        self.apps = Dictionary(uniqueKeysWithValues: state.apps.map { ($0.appId, $0) })
        self.ignores = Dictionary(uniqueKeysWithValues: state.ignores.map { ($0.appId, $0) })
        self.skips = Dictionary(uniqueKeysWithValues: state.skips.map { ($0.appId, $0) })
    }

    public func save() throws {
        let dir = (statePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let state = PersistedState(
            apps: Array(apps.values),
            ignores: Array(ignores.values),
            skips: Array(skips.values)
        )
        let data = try JSONCoders.prettyEncoder.encode(state)
        try data.write(to: URL(fileURLWithPath: statePath))
    }

    // MARK: - App Records

    public func allApps() -> [AppRecord] {
        Array(apps.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func getApp(id: String) -> AppRecord? {
        apps[id]
    }

    public func resolve(selector: ParsedSelector) throws -> AppRecord {
        let matches = findApps(selector: selector)
        if matches.isEmpty {
            throw UpdateError.notFound(
                message: "No app found matching '\(selector.description)'.",
                details: ["selector": .string(selector.description)]
            )
        }
        if matches.count > 1 {
            throw UpdateError.ambiguous(
                message: "Selector '\(selector.description)' matches \(matches.count) apps.",
                details: [
                    "selector": .string(selector.description),
                    "matches": .array(matches.map { .string($0.appId) }),
                ]
            )
        }
        return matches[0]
    }

    public func resolveMany(selectors: [ParsedSelector]) throws -> [AppRecord] {
        var results: [AppRecord] = []
        for selector in selectors {
            let record = try resolve(selector: selector)
            if !results.contains(where: { $0.appId == record.appId }) {
                results.append(record)
            }
        }
        return results
    }

    public func findApps(selector: ParsedSelector) -> [AppRecord] {
        switch selector.kind {
        case .id:
            if let app = apps[selector.value] { return [app] }
            return []
        case .bundle:
            return apps.values.filter { $0.bundleId == selector.value }
        case .path:
            return apps.values.filter { $0.path == selector.value }
        case .name:
            return apps.values.filter {
                $0.name.localizedCaseInsensitiveCompare(selector.value) == .orderedSame
            }
        }
    }

    public func upsertApp(_ record: AppRecord) {
        apps[record.appId] = record
    }

    public func removeApp(id: String) {
        apps.removeValue(forKey: id)
    }

    // MARK: - Ignores

    public func allIgnores() -> [IgnoreEntry] {
        Array(ignores.values)
    }

    public func isIgnored(appId: String) -> IgnoreEntry? {
        ignores[appId]
    }

    public func addIgnore(_ entry: IgnoreEntry) {
        ignores[entry.appId] = entry
        // Update tracking state
        if var app = apps[entry.appId] {
            switch entry.scope {
            case .updates: app.trackingState = .ignored_updates
            case .adoption: app.trackingState = .ignored_adoption
            case .all: app.trackingState = .ignored_all
            }
            apps[entry.appId] = app
        }
    }

    public func removeIgnore(appId: String) {
        ignores.removeValue(forKey: appId)
        if var app = apps[appId] {
            app.trackingState = .active
            apps[appId] = app
        }
    }

    // MARK: - Skips

    public func allSkips() -> [SkipEntry] {
        Array(skips.values).filter { !$0.isExpired }
    }

    public func isSkipped(appId: String) -> SkipEntry? {
        guard let skip = skips[appId], !skip.isExpired else { return nil }
        return skip
    }

    public func addSkip(_ entry: SkipEntry) {
        skips[entry.appId] = entry
        if var app = apps[entry.appId] {
            app.updateState = .skipped
            apps[entry.appId] = app
        }
    }

    public func removeSkip(appId: String) {
        skips.removeValue(forKey: appId)
        if var app = apps[appId], app.updateState == .skipped {
            app.updateState = .unchecked
            apps[appId] = app
        }
    }

    // MARK: - Bulk operations

    public func importScannedApps(_ infos: [AppInfo]) -> (added: Int, updated: Int, removed: Int) {
        var added = 0
        var updated = 0
        let scannedPaths = Set(infos.map(\.path))

        for info in infos {
            let appId = IDGenerator.appId(forPath: info.path)
            if var existing = apps[appId] {
                // Update mutable fields
                existing.name = info.name
                existing.bundleId = info.bundleId
                existing.installedVersion = info.shortVersion ?? info.version
                existing.path = info.path
                existing.selectors = buildSelectors(appId: appId, bundleId: info.bundleId, path: info.path)
                apps[appId] = existing
                updated += 1
            } else {
                let record = AppRecord(
                    appId: appId,
                    name: info.name,
                    bundleId: info.bundleId,
                    path: info.path,
                    installedVersion: info.shortVersion ?? info.version,
                    selectors: buildSelectors(appId: appId, bundleId: info.bundleId, path: info.path)
                )
                apps[appId] = record
                added += 1
            }
        }

        // Mark apps whose paths no longer exist
        var removed = 0
        for (id, app) in apps {
            if !scannedPaths.contains(app.path) && app.trackingState != .missing {
                var updated = app
                updated.trackingState = .missing
                apps[id] = updated
                removed += 1
            }
        }

        return (added, updated, removed)
    }

    private func buildSelectors(appId: String, bundleId: String?, path: String) -> AppSelectors {
        var accepted: [String] = ["path:\(path)"]
        if let bid = bundleId { accepted.append("bundle:\(bid)") }
        return AppSelectors(canonical: "id:\(appId)", accepted: accepted)
    }
}

// MARK: - Persisted state shape

private struct PersistedState: Codable {
    var apps: [AppRecord]
    var ignores: [IgnoreEntry]
    var skips: [SkipEntry]
}
