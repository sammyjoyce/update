import Foundation

public actor ConfigService {
    private let overridePath: String?

    public init(configPath: String? = nil) {
        self.overridePath = configPath
    }

    // MARK: - Paths

    public var userConfigPath: String {
        if let override = overridePath { return override }
        if let envPath = ProcessInfo.processInfo.environment["UPDATEST_CONFIG"] {
            return envPath
        }
        let xdgConfig = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
        return (xdgConfig as NSString).appendingPathComponent("update/config.json")
    }

    public var projectConfigPath: String {
        (FileManager.default.currentDirectoryPath as NSString)
            .appendingPathComponent(".update/config.json")
    }

    // MARK: - Load

    public func loadConfig(scope: ConfigScope) throws -> UpdatestConfig {
        switch scope {
        case .user:
            return try loadFile(at: userConfigPath) ?? UpdatestConfig()
        case .project:
            return try loadFile(at: projectConfigPath) ?? UpdatestConfig()
        case .effective:
            return try effectiveConfig()
        }
    }

    public func effectiveConfig() throws -> UpdatestConfig {
        var config = UpdatestConfig.defaults

        // Layer 1: user config
        if let user = try loadFile(at: userConfigPath) {
            config = config.merging(with: user)
        }

        // Layer 2: project config
        if let project = try loadFile(at: projectConfigPath) {
            config = config.merging(with: project)
        }

        // Layer 3: environment variables
        config = applyEnvironment(to: config)

        return config
    }

    /// Get the effective value and its origin for each key.
    public func effectiveConfigWithOrigins() throws -> [(key: String, value: JSONValue, origin: String)] {
        let user = try loadFile(at: userConfigPath)
        let project = try loadFile(at: projectConfigPath)

        let effective = try effectiveConfig()
        let effectiveJSON = try JSONValue.from(effective)

        var results: [(key: String, value: JSONValue, origin: String)] = []

        for spec in ConfigKeySpec.all {
            let origin: String
            // Check environment first
            if let envVar = spec.envVar,
               ProcessInfo.processInfo.environment[envVar] != nil {
                origin = "environment"
            } else if let proj = project,
                      let projJSON = try? JSONValue.from(proj),
                      projJSON[spec.key] != nil && projJSON[spec.key] != .null {
                origin = "project"
            } else if let usr = user,
                      let usrJSON = try? JSONValue.from(usr),
                      usrJSON[spec.key] != nil && usrJSON[spec.key] != .null {
                origin = "user"
            } else {
                origin = "default"
            }

            let value = effectiveJSON[spec.key] ?? .null
            results.append((key: spec.key, value: value, origin: origin))
        }
        return results
    }

    // MARK: - Write

    public func setValue(_ key: String, value: String, scope: ConfigScope) throws {
        guard scope != .effective else {
            throw UpdatestError.validation(
                code: "invalid_scope",
                message: "Cannot write to 'effective' scope. Use 'user' or 'project'."
            )
        }

        let path = scope == .user ? userConfigPath : projectConfigPath
        var config = try loadFile(at: path) ?? UpdatestConfig()
        try setConfigKey(&config, key: key, value: value)
        try saveFile(config, at: path)
    }

    public func setFromJSON(_ jsonData: Data, scope: ConfigScope) throws {
        guard scope != .effective else {
            throw UpdatestError.validation(
                code: "invalid_scope",
                message: "Cannot write to 'effective' scope. Use 'user' or 'project'."
            )
        }

        let path = scope == .user ? userConfigPath : projectConfigPath
        var existing = try loadFile(at: path) ?? UpdatestConfig()
        let overlay = try JSONCoders.decoder.decode(UpdatestConfig.self, from: jsonData)
        existing = existing.merging(with: overlay)
        try saveFile(existing, at: path)
    }

    public func unsetValue(_ key: String, scope: ConfigScope) throws {
        guard scope != .effective else {
            throw UpdatestError.validation(
                code: "invalid_scope",
                message: "Cannot unset from 'effective' scope. Use 'user' or 'project'."
            )
        }

        let path = scope == .user ? userConfigPath : projectConfigPath
        var config = try loadFile(at: path) ?? UpdatestConfig()
        try unsetConfigKey(&config, key: key)
        try saveFile(config, at: path)
    }

    public func reset(key: String?, scope: ConfigScope) throws {
        guard scope != .effective else {
            throw UpdatestError.validation(
                code: "invalid_scope",
                message: "Cannot reset 'effective' scope. Use 'user' or 'project'."
            )
        }

        let path = scope == .user ? userConfigPath : projectConfigPath

        if let key {
            var config = try loadFile(at: path) ?? UpdatestConfig()
            try unsetConfigKey(&config, key: key)
            try saveFile(config, at: path)
        } else {
            try saveFile(UpdatestConfig(), at: path)
        }
    }

    // MARK: - Private

    private func loadFile(at path: String) throws -> UpdatestConfig? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONCoders.decoder.decode(UpdatestConfig.self, from: data)
    }

    private func saveFile(_ config: UpdatestConfig, at path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let data = try JSONCoders.prettyEncoder.encode(config)
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func applyEnvironment(to config: UpdatestConfig) -> UpdatestConfig {
        var c = config
        let env = ProcessInfo.processInfo.environment
        if let v = env["UPDATEST_LOCATIONS"] {
            c.locations = v.split(separator: ":").map(String.init)
        }
        if let v = env["UPDATEST_BREW_PATH"] { c.brewPath = v }
        if let v = env["UPDATEST_MAS_PATH"] { c.masPath = v }
        if let v = env["UPDATEST_TIMEOUT"] { c.timeout = v }
        if let v = env["HTTPS_PROXY"] ?? env["HTTP_PROXY"] { c.proxy = v }
        return c
    }

    private func setConfigKey(_ config: inout UpdatestConfig, key: String, value: String) throws {
        switch key {
        case "locations":
            config.locations = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case "brew_path": config.brewPath = value
        case "mas_path": config.masPath = value
        case "timeout": config.timeout = value
        case "provider_priority":
            config.providerPriority = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case "brew_no_quarantine": config.brewNoQuarantine = (value == "true")
        case "show_unverified_updates": config.showUnverifiedUpdates = (value == "true")
        case "ignore_macos_compat": config.ignoreMacosCompat = (value == "true")
        case "proxy": config.proxy = value
        case "metadata_sync_enabled": config.metadataSyncEnabled = (value == "true")
        default:
            throw UpdatestError.validation(
                code: "invalid_config_key",
                message: "Unknown config key '\(key)'.",
                hint: "Run `update schema config` to see available keys."
            )
        }
    }

    private func unsetConfigKey(_ config: inout UpdatestConfig, key: String) throws {
        switch key {
        case "locations": config.locations = nil
        case "brew_path": config.brewPath = nil
        case "mas_path": config.masPath = nil
        case "timeout": config.timeout = nil
        case "provider_priority": config.providerPriority = nil
        case "brew_no_quarantine": config.brewNoQuarantine = nil
        case "show_unverified_updates": config.showUnverifiedUpdates = nil
        case "ignore_macos_compat": config.ignoreMacosCompat = nil
        case "proxy": config.proxy = nil
        case "metadata_sync_enabled": config.metadataSyncEnabled = nil
        case "manual_sources": config.manualSources = nil
        default:
            throw UpdatestError.validation(
                code: "invalid_config_key",
                message: "Unknown config key '\(key)'."
            )
        }
    }
}
