import ArgumentParser
import Darwin
import Foundation
import UpdateCore

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Output format: auto, json, ndjson, human, plain.")
    var format: String = OutputFormat.auto.rawValue

    @Option(name: .long, help: "Field mask for read commands.")
    var fields: String = ""

    @Option(name: .long, help: "Maximum number of items to emit.")
    var limit: Int?

    @Option(name: .long, help: "Opaque page cursor.")
    var cursor: String?

    @Flag(name: .long, help: "Continue fetching until exhaustion.")
    var allPages: Bool = false

    @Flag(name: [.customShort("q"), .long], help: "Suppress non-essential stderr.")
    var quiet: Bool = false

    @Flag(name: [.customShort("v"), .long], help: "Include diagnostics on stderr.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Shortcut for --format plain.")
    var plain: Bool = false

    @Flag(name: .long, help: "Shortcut for --format json.")
    var json: Bool = false

    @Flag(name: .long, help: "Shortcut for --format ndjson.")
    var ndjson: Bool = false

    @Flag(name: .long, help: "Disable color.")
    var noColor: Bool = false

    @Flag(name: .long, help: "Suppress interactive prompts.")
    var noInput: Bool = false

    @Option(name: [.customShort("c"), .long], help: "Alternate config file path.")
    var config: String?

    @Option(name: .long, help: "Timeout override.")
    var timeout: String?

    @Option(name: .long, help: "Trace id propagated into warnings and errors.")
    var traceId: String?

    var fieldList: [String] {
        fields.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var resolvedTraceId: String { traceId ?? IDGenerator.generateTraceId() }

    func resolvedFormat(isCollection: Bool) -> OutputFormat {
        if json { return .json }
        if ndjson { return .ndjson }
        if plain { return .plain }
        if let explicit = OutputFormat(rawValue: format), explicit != .auto { return explicit }
        if isatty(STDOUT_FILENO) != 0 {
            return .human
        }
        return isCollection ? .ndjson : .json
    }
}

enum CLIPrinter {
    static func printError(_ error: UpdateError, global: GlobalOptions) {
        let envelope = ErrorEnvelope(error.toDetail(traceId: global.resolvedTraceId))
        let resolvedFormat = global.resolvedFormat(isCollection: false)
        switch resolvedFormat {
        case .json, .ndjson, .plain:
            if let data = try? JSONCoders.encoder.encode(envelope),
               let string = String(data: data, encoding: .utf8) {
                Swift.print(string)
            }
        case .human, .auto:
            fputs("error: \(error.message)\n", stderr)
        }
    }

    static func emitItem<T: Encodable>(_ item: T, global: GlobalOptions, warnings: [WarningObject] = []) throws {
        let resolvedFormat = global.resolvedFormat(isCollection: false)
        let value = FieldMask.apply(fields: global.fieldList, to: try JSONValue.from(item))

        switch resolvedFormat {
        case .json:
            let envelope = ItemEnvelope(item: value, warnings: warnings)
            let data = try JSONCoders.encoder.encode(envelope)
            Swift.print(String(decoding: data, as: UTF8.self))
        case .plain:
            let values = plainFields(from: value, fields: global.fieldList)
            Swift.print(values.joined(separator: "\t"))
        case .human, .auto:
            renderHumanObject(value)
        case .ndjson:
            let data = try JSONCoders.encoder.encode(NDJSONEvent.item(value).toJSONValue())
            Swift.print(String(decoding: data, as: UTF8.self))
            let summary = try JSONCoders.encoder.encode(NDJSONEvent.summary(.init(returnedCount: 1)).toJSONValue())
            Swift.print(String(decoding: summary, as: UTF8.self))
        }
    }

    static func emitCollection<T: Encodable>(_ items: [T], global: GlobalOptions, warnings: [WarningObject] = []) throws {
        let resolvedFormat = global.resolvedFormat(isCollection: true)
        let encoded = try items.map { FieldMask.apply(fields: global.fieldList, to: try JSONValue.from($0)) }

        switch resolvedFormat {
        case .json:
            let envelope = CollectionEnvelope(items: encoded, appliedFields: global.fieldList.isEmpty ? nil : global.fieldList, warnings: warnings)
            let data = try JSONCoders.encoder.encode(envelope)
            Swift.print(String(decoding: data, as: UTF8.self))
        case .ndjson:
            for item in encoded {
                let data = try JSONCoders.encoder.encode(NDJSONEvent.item(item).toJSONValue())
                Swift.print(String(decoding: data, as: UTF8.self))
            }
            let summary = try JSONCoders.encoder.encode(NDJSONEvent.summary(.init(returnedCount: encoded.count)).toJSONValue())
            Swift.print(String(decoding: summary, as: UTF8.self))
        case .plain:
            for item in encoded {
                let values = plainFields(from: item, fields: global.fieldList)
                Swift.print(values.joined(separator: "\t"))
            }
        case .human, .auto:
            for item in encoded {
                renderHumanObject(item)
                Swift.print("")
            }
        }
    }

    static func emitMutation(_ envelope: MutationEnvelope, global: GlobalOptions) throws {
        let resolvedFormat = global.resolvedFormat(isCollection: false)
        switch resolvedFormat {
        case .json, .plain, .human, .auto:
            let data = try JSONCoders.encoder.encode(envelope)
            if resolvedFormat == .human || resolvedFormat == .auto {
                renderHumanObject(try JSONValue.from(envelope))
            } else {
                Swift.print(String(decoding: data, as: UTF8.self))
            }
        case .ndjson:
            if let plan = envelope.plan {
                let planData = try JSONCoders.encoder.encode(NDJSONEvent.plan(plan).toJSONValue())
                Swift.print(String(decoding: planData, as: UTF8.self))
            }
            for result in envelope.results {
                let data = try JSONCoders.encoder.encode(NDJSONEvent.result(result).toJSONValue())
                Swift.print(String(decoding: data, as: UTF8.self))
            }
            let summary = try JSONCoders.encoder.encode(NDJSONEvent.summary(.init(returnedCount: envelope.results.count)).toJSONValue())
            Swift.print(String(decoding: summary, as: UTF8.self))
        }
    }

    private static func plainFields(from value: JSONValue, fields: [String]) -> [String] {
        let selectedFields = fields.isEmpty ? defaultPlainKeys(from: value) : fields
        return selectedFields.map { field in
            let raw = extract(field: field, from: value)
            switch raw {
            case .string(let s): return Sanitizer.escapePlain(s)
            case .int(let i): return String(i)
            case .double(let d): return String(d)
            case .bool(let b): return b ? "true" : "false"
            case .null: return ""
            case .array, .object:
                return (try? raw.toJSONString()) ?? ""
            }
        }
    }

    private static func defaultPlainKeys(from value: JSONValue) -> [String] {
        guard case .object(let pairs) = value else { return [] }
        return pairs.map(\.key)
    }

    private static func extract(field: String, from value: JSONValue) -> JSONValue {
        let parts = field.split(separator: ".")
        var current = value
        for part in parts {
            current = current[String(part)] ?? .null
        }
        return current
    }

    private static func renderHumanObject(_ value: JSONValue, indent: Int = 0) {
        let prefix = String(repeating: "  ", count: indent)
        switch value {
        case .object(let pairs):
            for pair in pairs {
                switch pair.value {
                case .object, .array:
                    Swift.print("\(prefix)\(pair.key):")
                    renderHumanObject(pair.value, indent: indent + 1)
                case .string(let s):
                    Swift.print("\(prefix)\(pair.key): \(s)")
                case .int(let i):
                    Swift.print("\(prefix)\(pair.key): \(i)")
                case .double(let d):
                    Swift.print("\(prefix)\(pair.key): \(d)")
                case .bool(let b):
                    Swift.print("\(prefix)\(pair.key): \(b)")
                case .null:
                    Swift.print("\(prefix)\(pair.key):")
                }
            }
        case .array(let values):
            for value in values {
                Swift.print("\(prefix)-")
                renderHumanObject(value, indent: indent + 1)
            }
        case .string(let s): Swift.print("\(prefix)\(s)")
        case .int(let i): Swift.print("\(prefix)\(i)")
        case .double(let d): Swift.print("\(prefix)\(d)")
        case .bool(let b): Swift.print("\(prefix)\(b)")
        case .null: Swift.print("\(prefix)null")
        }
    }
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
@main
struct UpdateCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Agent-first macOS app update checker and installer.",
        version: "1.0.0",
        subcommands: [
            Apps.self,
            Ignores.self,
            Skips.self,
            Scan.self,
            Doctor.self,
            ConfigGroup.self,
            Schema.self,
            Completions.self,
            ListAlias.self,
            CheckAlias.self,
            SourcesAlias.self,
            UpdateAlias.self,
            AdoptAlias.self,
            IgnoreAlias.self,
            UnignoreAlias.self,
            SkipAlias.self,
            UnskipAlias.self,
        ]
    )

    mutating func run() async throws {
        throw CleanExit.helpRequest(self)
    }
}

struct Apps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage tracked applications.",
        subcommands: [List.self, Get.self, Check.self, Sources.self, Update.self, Adopt.self]
    )

    mutating func run() async throws { throw CleanExit.helpRequest(self) }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List tracked apps from persisted state.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Optional selectors.") var selectors: [String] = []

        mutating func run() async throws {
            do {
                let state = StateService()
                try await state.load()
                let allowBare = isatty(STDIN_FILENO) != 0
                let parsed = try selectors.isEmpty ? [] : SelectorParser.parseMany(selectors, allowBare: allowBare).get()
                var apps = selectors.isEmpty ? await state.allApps() : try await state.resolveMany(selectors: parsed)
                if let limit = global.limit, limit >= 0 {
                    apps = Array(apps.prefix(limit))
                }

                var warnings: [WarningObject] = []
                if global.cursor != nil || global.allPages {
                    warnings.append(.init(code: "ignored_pagination", message: "apps list is not naturally paginated."))
                }
                try CLIPrinter.emitCollection(apps, global: global, warnings: warnings)
            } catch let error as UpdateError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get one app from persisted state.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Selector for the app.") var selector: String

        mutating func run() async throws {
            do {
                let state = StateService()
                try await state.load()
                let allowBare = isatty(STDIN_FILENO) != 0
                let parsed = try SelectorParser.parse(selector, allowBare: allowBare).get()
                let app = try await state.resolve(selector: parsed)
                try CLIPrinter.emitItem(app, global: global)
            } catch let error as UpdateError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }
    }

    struct Check: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check for updates and persist results.")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "Optional selectors.") var selectors: [String] = []
        @Option(name: .long, help: "Provider filter: brew, appstore, sparkle, github, electron, metadata, all.") var provider: String = "all"
        @Flag(name: .long, help: "Include ignored apps.") var includeIgnored: Bool = false
        @Flag(name: .long, help: "Bypass cache TTLs.") var refresh: Bool = false
        @Flag(name: .long, help: "Disable network fetches.") var offline: Bool = false
        @Flag(name: .long, help: "Skip brew index refresh.") var skipBrewUpdate: Bool = false

        mutating func run() async throws {
            do {
                let configService = ConfigService(configPath: global.config)
                var config = try await configService.effectiveConfig()
                if let timeout = global.timeout {
                    config.timeout = timeout
                }

                let parsedProvider: Provider?
                let providerValue = provider.lowercased()
                if providerValue == "all" {
                    parsedProvider = nil
                } else if let known = Provider(rawValue: providerValue) {
                    parsedProvider = known
                } else {
                    throw UpdateError.validation(
                        code: "invalid_input",
                        message: "Unknown provider '\(provider)'."
                    )
                }

                let state = StateService()
                try await state.load()
                let allowBare = isatty(STDIN_FILENO) != 0
                let parsedSelectors = try selectors.isEmpty ? [] : SelectorParser.parseMany(selectors, allowBare: allowBare).get()
                var apps = selectors.isEmpty ? await state.allApps() : try await state.resolveMany(selectors: parsedSelectors)
                if !includeIgnored {
                    apps = apps.filter { $0.trackingState == .active || $0.trackingState == .missing }
                }
                if let limit = global.limit, limit >= 0 {
                    apps = Array(apps.prefix(limit))
                }

                let timeoutSeconds = DurationParser.parseToSeconds(config.resolvedTimeout) ?? 30
                let coordinator = UpdateCoordinator(timeout: timeoutSeconds)
                var checkedApps: [AppRecord] = []
                var warnings: [WarningObject] = []

                if refresh {
                    warnings.append(.init(code: "uncached_check", message: "Refresh requested. Provider cache bypass is not yet persisted, so each source is queried live."))
                }
                if skipBrewUpdate {
                    warnings.append(.init(code: "ignored_flag", message: "skip_brew_update is reserved for brew index refresh behavior and is not used by the current check path."))
                }
                if global.cursor != nil || global.allPages {
                    warnings.append(.init(code: "ignored_pagination", message: "apps check is not naturally paginated."))
                }

                for app in apps {
                    let outcome = await coordinator.check(
                        app: app,
                        config: config,
                        providerFilter: parsedProvider,
                        offline: offline
                    )
                    checkedApps.append(outcome.record)
                    warnings.append(contentsOf: outcome.warnings)
                    await state.upsertApp(outcome.record)
                }

                try await state.save()
                try CLIPrinter.emitCollection(checkedApps, global: global, warnings: warnings)
            } catch let error as UpdateError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }
    }

    struct Sources: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show provider evidence and selection results for one app.")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "Selector for the app.") var selector: String
        @Flag(name: .long, help: "Refresh provider evidence before returning it.") var refresh: Bool = false
        @Flag(name: .long, help: "Disable network fetches.") var offline: Bool = false

        mutating func run() async throws {
            do {
                let state = StateService()
                try await state.load()
                let allowBare = isatty(STDIN_FILENO) != 0
                let parsed = try SelectorParser.parse(selector, allowBare: allowBare).get()
                var app = try await state.resolve(selector: parsed)
                var warnings: [WarningObject] = []

                if refresh || app.selectedCandidate == nil || app.candidates.isEmpty {
                    let configService = ConfigService(configPath: global.config)
                    var config = try await configService.effectiveConfig()
                    if let timeout = global.timeout {
                        config.timeout = timeout
                    }
                    let timeoutSeconds = DurationParser.parseToSeconds(config.resolvedTimeout) ?? 30
                    let coordinator = UpdateCoordinator(timeout: timeoutSeconds)
                    let outcome = await coordinator.check(app: app, config: config, offline: offline)
                    app = outcome.record
                    warnings.append(contentsOf: outcome.warnings)
                    await state.upsertApp(app)
                    try await state.save()
                }

                try CLIPrinter.emitItem(app, global: global, warnings: warnings)
            } catch let error as UpdateError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install updates for matching apps.")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "Optional selectors.") var selectors: [String] = []
        @Flag(name: .long, help: "Target all tracked apps.") var all: Bool = false
        @Option(name: .long, help: "Provider filter: brew, appstore, sparkle, github, electron, metadata, all.") var provider: String = "all"
        @Flag(name: .long, help: "Confirm execution without prompting.") var yes: Bool = false
        @Flag(name: .long, help: "Force reinstall where supported.") var reinstall: Bool = false
        @Flag(name: .long, help: "Disable quarantine where supported.") var noQuarantine: Bool = false
        @Flag(name: .long, help: "Permit sudo for privileged bundle replacement.") var allowSudo: Bool = false
        @Flag(name: .long, help: "Preview the update plan without executing it.") var dryRun: Bool = false
        @Option(name: .long, help: "Read a raw request or replayable plan from a file path or '-'.") var input: String?

        mutating func run() async throws {
            do {
                let configService = ConfigService(configPath: global.config)
                var config = try await configService.effectiveConfig()
                if let timeout = global.timeout {
                    config.timeout = timeout
                }

                try MutationSupport.ensureNoConflictingFlags(
                    hasInput: input != nil,
                    conflicting: !selectors.isEmpty || all || provider.lowercased() != "all",
                    message: "apps update accepts either positional flags or --input, not both."
                )

                let timeoutSeconds = DurationParser.parseToSeconds(config.resolvedTimeout) ?? 30
                let coordinator = UpdateCoordinator(timeout: timeoutSeconds)
                let executor = UpdateExecutor(timeout: timeoutSeconds)
                let state = StateService()
                try await state.load()

                let plan: MutationPlan
                let previewResults: [MutationResult]
                let effectiveDryRun: Bool
                let effectiveReinstall: Bool
                let effectiveNoQuarantine: Bool
                let effectiveAllowSudo: Bool

                if let input {
                    switch try MutationSupport.decodeRequestOrPlan(path: input, as: AppsUpdateRequest.self, command: "apps.update") {
                    case .plan(let existingPlan):
                        plan = existingPlan
                        previewResults = existingPlan.actions.compactMap { action in
                            guard let appId = action.appId else { return nil }
                            return MutationResult(appId: appId, selector: "id:\(appId)", status: .planned, message: "Planned update execution.")
                        }
                        effectiveDryRun = dryRun
                        effectiveReinstall = reinstall
                        effectiveNoQuarantine = noQuarantine
                        effectiveAllowSudo = allowSudo
                    case .request(let request):
                        let requestDryRun = request.dryRun ?? false
                        effectiveDryRun = dryRun || requestDryRun
                        effectiveReinstall = reinstall || (request.reinstall ?? false)
                        effectiveNoQuarantine = noQuarantine || (request.noQuarantine ?? false)
                        effectiveAllowSudo = allowSudo || (request.allowSudo ?? false)
                        let providerFilter = try MutationSupport.parseProvider(request.provider ?? provider)
                        let requestedSelectors = request.selectors ?? selectors
                        let requestAll = request.all ?? all
                        let apps = try await resolveApps(for: requestedSelectors, all: requestAll, state: state)
                        let refreshed = try await refreshAppsIfNeeded(apps, providerFilter: providerFilter, config: config, coordinator: coordinator, state: state)
                        (plan, previewResults) = try await buildPlan(for: refreshed, selectors: requestedSelectors, providerFilter: providerFilter, reinstall: effectiveReinstall, state: state)
                    }
                } else {
                    effectiveDryRun = dryRun
                    effectiveReinstall = reinstall
                    effectiveNoQuarantine = noQuarantine
                    effectiveAllowSudo = allowSudo
                    let providerFilter = try MutationSupport.parseProvider(provider)
                    let apps = try await resolveApps(for: selectors, all: all, state: state)
                    let refreshed = try await refreshAppsIfNeeded(apps, providerFilter: providerFilter, config: config, coordinator: coordinator, state: state)
                    (plan, previewResults) = try await buildPlan(for: refreshed, selectors: selectors, providerFilter: providerFilter, reinstall: effectiveReinstall, state: state)
                }

                if effectiveDryRun {
                    try CLIPrinter.emitMutation(
                        MutationEnvelope(command: "apps.update", dryRun: true, plan: try JSONValue.from(plan), results: previewResults),
                        global: global
                    )
                    return
                }

                if !plan.actions.isEmpty {
                    try MutationSupport.confirmIfNeeded(summary: "Update \(plan.actions.count) app(s)", yes: yes, noInput: global.noInput)
                }

                var results = previewResults.filter { $0.status != .planned }
                for action in plan.actions {
                    guard let appId = action.appId,
                          let current = await state.getApp(id: appId) else {
                        results.append(MutationResult(appId: action.appId ?? "unknown", selector: action.appId.map { "id:\($0)" } ?? "unknown", status: .runtime_failed, message: "App record not found for execution."))
                        continue
                    }

                    if let precondition = plan.preconditions.first(where: { $0.appId == appId }), !precondition.validate(against: current) {
                        results.append(MutationResult(appId: appId, selector: current.selectors.canonical, status: .precondition_failed, message: "Planned update preconditions no longer hold."))
                        continue
                    }

                    let outcome = await executor.executeUpdate(
                        action: action,
                        record: current,
                        config: config,
                        reinstall: effectiveReinstall,
                        noQuarantine: effectiveNoQuarantine,
                        allowSudo: effectiveAllowSudo
                    )
                    results.append(outcome.result)
                    if let updatedRecord = outcome.updatedRecord {
                        await state.upsertApp(updatedRecord)
                    }
                }

                try await state.save()
                try CLIPrinter.emitMutation(
                    MutationEnvelope(command: "apps.update", dryRun: false, plan: try JSONValue.from(plan), results: results),
                    global: global
                )
            } catch let error as UpdateError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }

        private func resolveApps(for selectors: [String], all: Bool, state: StateService) async throws -> [AppRecord] {
            if all {
                return await state.allApps().filter { $0.trackingState == .active || $0.trackingState == .missing }
            }
            guard !selectors.isEmpty else {
                throw UpdateError.validation(code: "invalid_input", message: "apps update requires selectors or --all.")
            }
            let allowBare = isatty(STDIN_FILENO) != 0
            let parsed = try SelectorParser.parseMany(selectors, allowBare: allowBare).get()
            return try await state.resolveMany(selectors: parsed)
        }

        private func refreshAppsIfNeeded(
            _ apps: [AppRecord],
            providerFilter: Provider?,
            config: UpdateConfig,
            coordinator: UpdateCoordinator,
            state: StateService
        ) async throws -> [AppRecord] {
            var refreshed: [AppRecord] = []
            for app in apps {
                let matchingCandidate = MutationSupport.selectedCandidate(for: app, providerFilter: providerFilter)
                if matchingCandidate == nil {
                    let outcome = await coordinator.check(app: app, config: config, providerFilter: providerFilter)
                    refreshed.append(outcome.record)
                    await state.upsertApp(outcome.record)
                } else {
                    refreshed.append(app)
                }
            }
            return refreshed
        }

        private func buildPlan(
            for apps: [AppRecord],
            selectors: [String],
            providerFilter: Provider?,
            reinstall: Bool,
            state: StateService
        ) async throws -> (MutationPlan, [MutationResult]) {
            var actions: [PlanAction] = []
            var preconditions: [PlanPrecondition] = []
            var results: [MutationResult] = []

            for app in apps {
                guard let candidate = MutationSupport.selectedCandidate(for: app, providerFilter: providerFilter) else {
                    results.append(MutationResult(appId: app.appId, selector: app.selectors.canonical, status: .validation_failed, message: "No update candidate available."))
                    continue
                }

                if let skip = await state.isSkipped(appId: app.appId), skip.version == candidate.availableVersion {
                    results.append(MutationResult(appId: app.appId, selector: app.selectors.canonical, status: .skipped, message: "Selected version is currently skipped."))
                    continue
                }

                if !reinstall,
                   let installedVersion = app.installedVersion,
                   !VersionCompare.isNewer(candidate.availableVersion, than: installedVersion) {
                    results.append(MutationResult(appId: app.appId, selector: app.selectors.canonical, status: .up_to_date, message: "App is already up to date."))
                    continue
                }

                guard let action = buildAction(for: app, candidate: candidate) else {
                    results.append(MutationResult(appId: app.appId, selector: app.selectors.canonical, status: .validation_failed, message: "Could not derive an executor action for the selected candidate."))
                    continue
                }

                actions.append(action)
                preconditions.append(PlanPrecondition(appId: app.appId, installedVersion: app.installedVersion, candidateVersion: candidate.availableVersion, provider: candidate.provider))
                results.append(MutationResult(appId: app.appId, selector: app.selectors.canonical, status: .planned, message: "Planned update via \(candidate.provider.rawValue)."))
            }

            let requestedSelectors = selectors.isEmpty ? apps.map(\.selectors.canonical) : selectors
            return (
                MutationPlan(command: "apps.update", dryRun: true, requestedSelectors: requestedSelectors, resolvedAppIds: apps.map(\.appId), preconditions: preconditions, actions: actions),
                results
            )
        }

        private func buildAction(for app: AppRecord, candidate: UpdateCandidate) -> PlanAction? {
            var details: [String: JSONValue] = [
                "candidate_version": .string(candidate.availableVersion),
                "provider": .string(candidate.provider.rawValue),
                "app_path": .string(app.path),
            ]
            if let bundleId = app.bundleId {
                details["bundle_id"] = .string(bundleId)
            }
            if let downloadURL = candidate.downloadUrl {
                details["download_url"] = .string(downloadURL)
            }

            switch candidate.executor {
            case .brew_cask:
                guard let token = MutationSupport.stringValue(candidate.details["cask_token"]) else { return nil }
                details["token"] = .string(token)
                return PlanAction(type: "brew_upgrade_cask", appId: app.appId, token: token, details: details)
            case .app_store:
                guard let trackID = MutationSupport.stringValue(candidate.details["track_id"]) else { return nil }
                details["track_id"] = .string(trackID)
                return PlanAction(type: "mas_upgrade", appId: app.appId, details: details)
            case .bundle_replace:
                guard candidate.downloadUrl != nil else { return nil }
                return PlanAction(type: "bundle_replace", appId: app.appId, details: details)
            }
        }
    }

    struct Adopt: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Adopt existing apps into Homebrew cask management.")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "Optional selectors.") var selectors: [String] = []
        @Flag(name: .long, help: "Target all tracked apps.") var all: Bool = false
        @Option(name: .long, help: "Explicit cask token to adopt into.") var cask: String?
        @Flag(name: .long, help: "Confirm execution without prompting.") var yes: Bool = false
        @Flag(name: .long, help: "Force reinstall where supported.") var reinstall: Bool = false
        @Flag(name: .long, help: "Preview the adoption plan without executing it.") var dryRun: Bool = false
        @Option(name: .long, help: "Read a raw request or replayable plan from a file path or '-'.") var input: String?

        mutating func run() async throws {
            do {
                let configService = ConfigService(configPath: global.config)
                var config = try await configService.effectiveConfig()
                if let timeout = global.timeout {
                    config.timeout = timeout
                }

                try MutationSupport.ensureNoConflictingFlags(
                    hasInput: input != nil,
                    conflicting: !selectors.isEmpty || all || cask != nil,
                    message: "apps adopt accepts either positional flags or --input, not both."
                )

                let timeoutSeconds = DurationParser.parseToSeconds(config.resolvedTimeout) ?? 30
                let state = StateService()
                try await state.load()
                let brewSource = BrewSource(processRunner: ProcessRunner(timeout: timeoutSeconds))
                let executor = UpdateExecutor(timeout: timeoutSeconds)

                let plan: MutationPlan
                let previewResults: [MutationResult]
                let effectiveDryRun: Bool
                let effectiveReinstall: Bool

                if let input {
                    switch try MutationSupport.decodeRequestOrPlan(path: input, as: AppsAdoptRequest.self, command: "apps.adopt") {
                    case .plan(let existingPlan):
                        plan = existingPlan
                        previewResults = existingPlan.actions.compactMap { action in
                            guard let appId = action.appId else { return nil }
                            return MutationResult(appId: appId, selector: "id:\(appId)", status: .planned, message: "Planned adoption execution.")
                        }
                        effectiveDryRun = dryRun
                        effectiveReinstall = reinstall
                    case .request(let request):
                        effectiveDryRun = dryRun || (request.dryRun ?? false)
                        effectiveReinstall = reinstall || (request.reinstall ?? false)
                        let requestedSelectors = request.selectors ?? selectors
                        let requestAll = request.all ?? all
                        let apps = try await resolveApps(for: requestedSelectors, all: requestAll, state: state)
                        (plan, previewResults) = try await buildPlan(for: apps, selectors: requestedSelectors, explicitCask: request.cask ?? cask, brewSource: brewSource, config: config)
                    }
                } else {
                    effectiveDryRun = dryRun
                    effectiveReinstall = reinstall
                    let apps = try await resolveApps(for: selectors, all: all, state: state)
                    (plan, previewResults) = try await buildPlan(for: apps, selectors: selectors, explicitCask: cask, brewSource: brewSource, config: config)
                }

                if effectiveDryRun {
                    try CLIPrinter.emitMutation(
                        MutationEnvelope(command: "apps.adopt", dryRun: true, plan: try JSONValue.from(plan), results: previewResults),
                        global: global
                    )
                    return
                }

                if !plan.actions.isEmpty {
                    try MutationSupport.confirmIfNeeded(summary: "Adopt \(plan.actions.count) app(s)", yes: yes, noInput: global.noInput)
                }

                var results = previewResults.filter { $0.status != .planned }
                for action in plan.actions {
                    guard let appId = action.appId,
                          let current = await state.getApp(id: appId) else {
                        results.append(MutationResult(appId: action.appId ?? "unknown", selector: action.appId.map { "id:\($0)" } ?? "unknown", status: .runtime_failed, message: "App record not found for execution."))
                        continue
                    }

                    if let precondition = plan.preconditions.first(where: { $0.appId == appId }), !precondition.validate(against: current) {
                        results.append(MutationResult(appId: appId, selector: current.selectors.canonical, status: .precondition_failed, message: "Planned adoption preconditions no longer hold."))
                        continue
                    }

                    let outcome = await executor.executeAdopt(action: action, record: current, config: config, reinstall: effectiveReinstall)
                    results.append(outcome.result)
                    if let updatedRecord = outcome.updatedRecord {
                        await state.upsertApp(updatedRecord)
                    }
                }

                try await state.save()
                try CLIPrinter.emitMutation(
                    MutationEnvelope(command: "apps.adopt", dryRun: false, plan: try JSONValue.from(plan), results: results),
                    global: global
                )
            } catch let error as UpdateError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }

        private func resolveApps(for selectors: [String], all: Bool, state: StateService) async throws -> [AppRecord] {
            if all {
                return await state.allApps().filter { $0.trackingState == .active || $0.trackingState == .missing }
            }
            guard !selectors.isEmpty else {
                throw UpdateError.validation(code: "invalid_input", message: "apps adopt requires selectors or --all.")
            }
            let allowBare = isatty(STDIN_FILENO) != 0
            let parsed = try SelectorParser.parseMany(selectors, allowBare: allowBare).get()
            return try await state.resolveMany(selectors: parsed)
        }

        private func buildPlan(
            for apps: [AppRecord],
            selectors: [String],
            explicitCask: String?,
            brewSource: BrewSource,
            config: UpdateConfig
        ) async throws -> (MutationPlan, [MutationResult]) {
            var actions: [PlanAction] = []
            var preconditions: [PlanPrecondition] = []
            var results: [MutationResult] = []

            for app in apps {
                let token: String?
                if let explicitCask {
                    token = explicitCask
                } else {
                    token = try await brewSource.findCaskToken(for: app, config: config)
                }
                guard let token else {
                    results.append(MutationResult(appId: app.appId, selector: app.selectors.canonical, status: .validation_failed, message: "No Homebrew cask token found for adoption."))
                    continue
                }

                let action = PlanAction(type: "brew_adopt_cask", appId: app.appId, token: token, details: ["token": .string(token)])
                actions.append(action)
                preconditions.append(PlanPrecondition(appId: app.appId, installedVersion: app.installedVersion, candidateVersion: nil, provider: nil))
                results.append(MutationResult(appId: app.appId, selector: app.selectors.canonical, status: .planned, message: "Planned adoption into cask '\(token)'."))
            }

            let requestedSelectors = selectors.isEmpty ? apps.map(\.selectors.canonical) : selectors
            return (
                MutationPlan(command: "apps.adopt", dryRun: true, requestedSelectors: requestedSelectors, resolvedAppIds: apps.map(\.appId), preconditions: preconditions, actions: actions),
                results
            )
        }
    }
}

struct Ignores: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [List.self, Add.self, Remove.self])
    mutating func run() async throws { throw CleanExit.helpRequest(self) }

    struct List: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions

        mutating func run() async throws {
            do {
                let state = StateService()
                try await state.load()
                var entries = await state.allIgnores()
                if let limit = global.limit, limit >= 0 {
                    entries = Array(entries.prefix(limit))
                }
                var warnings: [WarningObject] = []
                if global.cursor != nil || global.allPages {
                    warnings.append(.init(code: "ignored_pagination", message: "ignores list is not naturally paginated."))
                }
                try CLIPrinter.emitCollection(entries, global: global, warnings: warnings)
            } catch let error as UpdateError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }
    }

    struct Add: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Selectors to ignore.") var selectors: [String] = []
        @Option(name: .long, help: "Ignore scope: updates, adoption, all.") var scope: String = IgnoreScope.all.rawValue
        @Option(name: .long, help: "Optional ignore reason.") var reason: String?
        @Flag(name: .long, help: "Preview the ignore plan without writing.") var dryRun: Bool = false
        @Option(name: .long, help: "Read a raw request from a file path or '-'.") var input: String?

        mutating func run() async throws {
            do {
                try MutationSupport.ensureNoConflictingFlags(hasInput: input != nil, conflicting: !selectors.isEmpty || scope.lowercased() != IgnoreScope.all.rawValue || reason != nil, message: "ignores add accepts either positional flags or --input, not both.")
                guard let parsedScope = IgnoreScope(rawValue: scope.lowercased()) else {
                    throw UpdateError.validation(code: "invalid_input", message: "Unknown ignore scope '\(scope)'.")
                }

                let request: IgnoreAddRequest?
                if let input {
                    request = try JSONCoders.decoder.decode(IgnoreAddRequest.self, from: MutationSupport.readInputData(path: input))
                } else {
                    request = nil
                }

                let effectiveDryRun = dryRun || (request?.dryRun ?? false)
                let effectiveSelectors = request?.selectors ?? selectors
                let effectiveReason = request?.reason ?? reason
                let effectiveScope = IgnoreScope(rawValue: request?.scope?.lowercased() ?? parsedScope.rawValue) ?? parsedScope

                guard !effectiveSelectors.isEmpty else {
                    throw UpdateError.validation(code: "invalid_input", message: "ignores add requires at least one selector.")
                }

                let state = StateService()
                try await state.load()
                let allowBare = isatty(STDIN_FILENO) != 0
                let parsed = try SelectorParser.parseMany(effectiveSelectors, allowBare: allowBare).get()
                let apps = try await state.resolveMany(selectors: parsed)
                let plan = MutationPlan(
                    command: "ignores.add",
                    dryRun: effectiveDryRun,
                    requestedSelectors: effectiveSelectors,
                    resolvedAppIds: apps.map(\.appId),
                    preconditions: [],
                    actions: apps.map { PlanAction(type: "ignore_add", appId: $0.appId, details: ["scope": .string(effectiveScope.rawValue), "reason": effectiveReason.map(JSONValue.string) ?? .null]) }
                )
                let results = apps.map { MutationResult(appId: $0.appId, selector: $0.selectors.canonical, status: effectiveDryRun ? .planned : .ignored, message: effectiveDryRun ? "Would add ignore rule." : "Added ignore rule.") }
                if !effectiveDryRun {
                    for app in apps {
                        await state.addIgnore(IgnoreEntry(appId: app.appId, scope: effectiveScope, reason: effectiveReason))
                    }
                    try await state.save()
                }
                try CLIPrinter.emitMutation(MutationEnvelope(command: "ignores.add", dryRun: effectiveDryRun, plan: try JSONValue.from(plan), results: results), global: global)
            } catch let error as UpdateError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Selectors to unignore.") var selectors: [String] = []
        @Flag(name: .long, help: "Preview the removal plan without writing.") var dryRun: Bool = false
        @Option(name: .long, help: "Read a raw request from a file path or '-'.") var input: String?

        mutating func run() async throws {
            do {
                try MutationSupport.ensureNoConflictingFlags(hasInput: input != nil, conflicting: !selectors.isEmpty, message: "ignores remove accepts either positional selectors or --input, not both.")
                let request: SelectorListRequest?
                if let input {
                    request = try JSONCoders.decoder.decode(SelectorListRequest.self, from: MutationSupport.readInputData(path: input))
                } else {
                    request = nil
                }
                let effectiveDryRun = dryRun || (request?.dryRun ?? false)
                let effectiveSelectors = request?.selectors ?? selectors
                guard !effectiveSelectors.isEmpty else {
                    throw UpdateError.validation(code: "invalid_input", message: "ignores remove requires at least one selector.")
                }

                let state = StateService()
                try await state.load()
                let allowBare = isatty(STDIN_FILENO) != 0
                let parsed = try SelectorParser.parseMany(effectiveSelectors, allowBare: allowBare).get()
                let apps = try await state.resolveMany(selectors: parsed)
                let plan = MutationPlan(command: "ignores.remove", dryRun: effectiveDryRun, requestedSelectors: effectiveSelectors, resolvedAppIds: apps.map(\.appId), preconditions: [], actions: apps.map { PlanAction(type: "ignore_remove", appId: $0.appId) })
                let results = apps.map { MutationResult(appId: $0.appId, selector: $0.selectors.canonical, status: effectiveDryRun ? .planned : .updated, message: effectiveDryRun ? "Would remove ignore rule." : "Removed ignore rule.") }
                if !effectiveDryRun {
                    for app in apps {
                        await state.removeIgnore(appId: app.appId)
                    }
                    try await state.save()
                }
                try CLIPrinter.emitMutation(MutationEnvelope(command: "ignores.remove", dryRun: effectiveDryRun, plan: try JSONValue.from(plan), results: results), global: global)
            } catch let error as UpdateError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }
    }
}

struct Skips: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [List.self, Add.self, Remove.self])
    mutating func run() async throws { throw CleanExit.helpRequest(self) }

    struct List: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions

        mutating func run() async throws {
            do {
                let state = StateService()
                try await state.load()
                var entries = await state.allSkips()
                if let limit = global.limit, limit >= 0 {
                    entries = Array(entries.prefix(limit))
                }
                var warnings: [WarningObject] = []
                if global.cursor != nil || global.allPages {
                    warnings.append(.init(code: "ignored_pagination", message: "skips list is not naturally paginated."))
                }
                try CLIPrinter.emitCollection(entries, global: global, warnings: warnings)
            } catch let error as UpdateError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }
    }

    struct Add: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Selector to skip.") var selector: String?
        @Option(name: .long, help: "Version to skip. Defaults to the selected candidate version.") var version: String?
        @Option(name: .long, help: "Optional expiration duration.") var expiresIn: String?
        @Flag(name: .long, help: "Preview the skip plan without writing.") var dryRun: Bool = false
        @Option(name: .long, help: "Read a raw request from a file path or '-'.") var input: String?

        mutating func run() async throws {
            do {
                try MutationSupport.ensureNoConflictingFlags(hasInput: input != nil, conflicting: selector != nil || version != nil || expiresIn != nil, message: "skips add accepts either positional flags or --input, not both.")
                let request: SkipAddRequest?
                if let input {
                    request = try JSONCoders.decoder.decode(SkipAddRequest.self, from: MutationSupport.readInputData(path: input))
                } else {
                    request = nil
                }
                let effectiveDryRun = dryRun || (request?.dryRun ?? false)
                guard let effectiveSelector = request?.selector ?? selector else {
                    throw UpdateError.validation(code: "invalid_input", message: "skips add requires a selector.")
                }

                let state = StateService()
                try await state.load()
                let allowBare = isatty(STDIN_FILENO) != 0
                let parsed = try SelectorParser.parse(effectiveSelector, allowBare: allowBare).get()
                let app = try await state.resolve(selector: parsed)
                let effectiveVersion = request?.version ?? version ?? app.selectedCandidate?.availableVersion
                guard let effectiveVersion else {
                    throw UpdateError.validation(code: "invalid_input", message: "No version available to skip.")
                }
                let effectiveExpiresIn = request?.expiresIn ?? expiresIn
                let plan = MutationPlan(command: "skips.add", dryRun: effectiveDryRun, requestedSelectors: [effectiveSelector], resolvedAppIds: [app.appId], preconditions: [], actions: [PlanAction(type: "skip_add", appId: app.appId, details: ["version": .string(effectiveVersion), "expires_in": effectiveExpiresIn.map(JSONValue.string) ?? .null])])
                let result = MutationResult(appId: app.appId, selector: app.selectors.canonical, status: effectiveDryRun ? .planned : .skipped, message: effectiveDryRun ? "Would add version skip." : "Added version skip.")
                if !effectiveDryRun {
                    await state.addSkip(SkipEntry(appId: app.appId, version: effectiveVersion, expiresIn: effectiveExpiresIn))
                    try await state.save()
                }
                try CLIPrinter.emitMutation(MutationEnvelope(command: "skips.add", dryRun: effectiveDryRun, plan: try JSONValue.from(plan), results: [result]), global: global)
            } catch let error as UpdateError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Selectors to remove skips for.") var selectors: [String] = []
        @Flag(name: .long, help: "Preview the removal plan without writing.") var dryRun: Bool = false
        @Option(name: .long, help: "Read a raw request from a file path or '-'.") var input: String?

        mutating func run() async throws {
            do {
                try MutationSupport.ensureNoConflictingFlags(hasInput: input != nil, conflicting: !selectors.isEmpty, message: "skips remove accepts either positional selectors or --input, not both.")
                let request: SelectorListRequest?
                if let input {
                    request = try JSONCoders.decoder.decode(SelectorListRequest.self, from: MutationSupport.readInputData(path: input))
                } else {
                    request = nil
                }
                let effectiveDryRun = dryRun || (request?.dryRun ?? false)
                let effectiveSelectors = request?.selectors ?? selectors
                guard !effectiveSelectors.isEmpty else {
                    throw UpdateError.validation(code: "invalid_input", message: "skips remove requires at least one selector.")
                }

                let state = StateService()
                try await state.load()
                let allowBare = isatty(STDIN_FILENO) != 0
                let parsed = try SelectorParser.parseMany(effectiveSelectors, allowBare: allowBare).get()
                let apps = try await state.resolveMany(selectors: parsed)
                let plan = MutationPlan(command: "skips.remove", dryRun: effectiveDryRun, requestedSelectors: effectiveSelectors, resolvedAppIds: apps.map(\.appId), preconditions: [], actions: apps.map { PlanAction(type: "skip_remove", appId: $0.appId) })
                let results = apps.map { MutationResult(appId: $0.appId, selector: $0.selectors.canonical, status: effectiveDryRun ? .planned : .updated, message: effectiveDryRun ? "Would remove version skip." : "Removed version skip.") }
                if !effectiveDryRun {
                    for app in apps {
                        await state.removeSkip(appId: app.appId)
                    }
                    try await state.save()
                }
                try CLIPrinter.emitMutation(MutationEnvelope(command: "skips.remove", dryRun: effectiveDryRun, plan: try JSONValue.from(plan), results: results), global: global)
            } catch let error as UpdateError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }
    }
}

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Run.self], defaultSubcommand: Run.self)
    mutating func run() async throws { throw CleanExit.helpRequest(self) }

    struct Run: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Option(name: .long, help: "Comma-separated absolute paths to scan.") var locations: String?
        @Flag(name: .long, help: "Scan recursively.") var deep: Bool = false
        @Flag(name: .long, help: "Preview only.") var dryRun: Bool = false

        mutating func run() async throws {
            do {
                let configService = ConfigService(configPath: global.config)
                var config = try await configService.effectiveConfig()
                if let locations {
                    config.locations = locations.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                }

                let scanner = AppScanner()
                let scanned = await scanner.scan(locations: config.resolvedLocations, deep: deep)

                let plan = MutationPlan(
                    command: "scan.run",
                    dryRun: dryRun,
                    requestedSelectors: config.resolvedLocations.map { "path:\($0)" },
                    resolvedAppIds: scanned.map { IDGenerator.appId(forPath: $0.path) },
                    preconditions: [],
                    actions: scanned.map {
                        PlanAction(type: "scan_bundle", details: ["path": .string($0.path)])
                    }
                )

                var results: [MutationResult] = []
                if !dryRun {
                    let state = StateService()
                    try await state.load()
                    _ = await state.importScannedApps(scanned)
                    try await state.save()
                    results = scanned.map {
                        MutationResult(
                            appId: IDGenerator.appId(forPath: $0.path),
                            selector: "path:\($0.path)",
                            status: .updated,
                            message: "Scanned and persisted app record."
                        )
                    }
                }

                try CLIPrinter.emitMutation(
                    MutationEnvelope(
                        command: "scan.run",
                        dryRun: dryRun,
                        plan: try JSONValue.from(plan),
                        results: results
                    ),
                    global: global
                )
            } catch let error as UpdateError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Run.self], defaultSubcommand: Run.self)
    mutating func run() async throws { throw CleanExit.helpRequest(self) }

    struct Run: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Option(name: .long, help: "Checks to run.") var checks: String = "brew,mas,network,config,cache"

        struct CheckResult: Encodable {
            var name: String
            var status: String
            var details: String
        }

        struct DoctorReport: Encodable {
            var checks: [CheckResult]
        }

        mutating func run() async throws {
            let requested = Set(checks.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            let runner = ProcessRunner(timeout: 5)
            let configService = ConfigService(configPath: global.config)
            var output: [CheckResult] = []

            if requested.contains("brew") {
                let brewPath = await runner.which("brew")
                output.append(.init(name: "brew", status: brewPath == nil ? "warn" : "ok", details: brewPath ?? "not found"))
            }
            if requested.contains("mas") {
                let masPath = await runner.which("mas")
                output.append(.init(name: "mas", status: masPath == nil ? "warn" : "ok", details: masPath ?? "not found"))
            }
            if requested.contains("network") {
                let status: String
                let details: String
                do {
                    let (_, response) = try await URLSession.shared.data(from: URL(string: "https://itunes.apple.com")!)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    status = (200..<500).contains(code) ? "ok" : "warn"
                    details = "HTTP \(code)"
                } catch {
                    status = "warn"
                    details = error.localizedDescription
                }
                output.append(.init(name: "network", status: status, details: details))
            }
            if requested.contains("config") {
                do {
                    let effective = try await configService.effectiveConfig()
                    output.append(.init(name: "config", status: "ok", details: effective.resolvedLocations.joined(separator: ", ")))
                } catch {
                    output.append(.init(name: "config", status: "warn", details: error.localizedDescription))
                }
            }
            if requested.contains("cache") {
                let xdgData = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
                    ?? (NSHomeDirectory() as NSString).appendingPathComponent(".local/share")
                let cacheDir = (xdgData as NSString).appendingPathComponent("update")
                let exists = FileManager.default.fileExists(atPath: cacheDir)
                output.append(.init(name: "cache", status: exists ? "ok" : "warn", details: cacheDir))
            }

            try CLIPrinter.emitItem(DoctorReport(checks: output), global: global)
        }
    }
}

struct ConfigGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config", subcommands: [Show.self, Get.self, Set.self, Unset.self, Reset.self])
    mutating func run() async throws { throw CleanExit.helpRequest(self) }

    struct OriginEntry: Encodable {
        var key: String
        var value: JSONValue
        var origin: String
    }

    struct KeyValueEntry: Encodable {
        var key: String
        var value: JSONValue
        var scope: String
        var origin: String?
    }

    struct Show: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Option(name: .long, help: "Config scope: user, project, effective.") var scope: String = ConfigScope.effective.rawValue
        @Flag(name: .long, help: "Include origin metadata for effective config values.") var origin: Bool = false

        mutating func run() async throws {
            do {
                guard let parsedScope = ConfigScope(rawValue: scope.lowercased()) else {
                    throw UpdateError.validation(code: "invalid_scope", message: "Unknown scope '\(scope)'.")
                }
                let service = ConfigService(configPath: global.config)
                if origin && parsedScope == .effective {
                    let items = try await service.effectiveConfigWithOrigins().map {
                        OriginEntry(key: $0.key, value: $0.value, origin: $0.origin)
                    }
                    try CLIPrinter.emitCollection(items, global: global)
                } else {
                    let config = try await service.loadConfig(scope: parsedScope)
                    try CLIPrinter.emitItem(config, global: global)
                }
            } catch let error as UpdateError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }
    }

    struct Get: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Config key.") var key: String
        @Option(name: .long, help: "Config scope: user, project, effective.") var scope: String = ConfigScope.effective.rawValue
        @Flag(name: .long, help: "Include origin metadata for effective config values.") var origin: Bool = false

        mutating func run() async throws {
            do {
                guard ConfigKeySpec.all.contains(where: { $0.key == key }) else {
                    throw UpdateError.validation(code: "invalid_config_key", message: "Unknown config key '\(key)'.")
                }
                guard let parsedScope = ConfigScope(rawValue: scope.lowercased()) else {
                    throw UpdateError.validation(code: "invalid_scope", message: "Unknown scope '\(scope)'.")
                }
                let service = ConfigService(configPath: global.config)
                if origin && parsedScope == .effective {
                    let entries = try await service.effectiveConfigWithOrigins()
                    guard let match = entries.first(where: { $0.key == key }) else {
                        throw UpdateError.notFound(message: "No effective config value found for '\(key)'.")
                    }
                    try CLIPrinter.emitItem(
                        KeyValueEntry(key: match.key, value: match.value, scope: parsedScope.rawValue, origin: match.origin),
                        global: global
                    )
                } else {
                    let config = try await service.loadConfig(scope: parsedScope)
                    let jsonValue = try JSONValue.from(config)
                    try CLIPrinter.emitItem(
                        KeyValueEntry(key: key, value: jsonValue[key] ?? .null, scope: parsedScope.rawValue, origin: nil),
                        global: global
                    )
                }
            } catch let error as UpdateError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }
    }

    struct Set: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Config key.") var key: String?
        @Argument(help: "Config value.") var value: String?
        @Option(name: .long, help: "Config scope: user or project.") var scope: String = ConfigScope.user.rawValue
        @Option(name: .long, help: "Read a raw JSON payload from a file path or '-'.") var input: String?
        @Flag(name: .long, help: "Preview the change without writing.") var dryRun: Bool = false

        mutating func run() async throws {
            do {
                guard let parsedScope = ConfigScope(rawValue: scope.lowercased()), parsedScope != .effective else {
                    throw UpdateError.validation(code: "invalid_scope", message: "config set requires --scope user or --scope project.")
                }
                let service = ConfigService(configPath: global.config)
                let plan = MutationPlan(
                    command: "config.set",
                    dryRun: dryRun,
                    requestedSelectors: [parsedScope.rawValue],
                    resolvedAppIds: [],
                    preconditions: [],
                    actions: [
                        PlanAction(type: input == nil ? "config_set_key" : "config_set_json", details: [
                            "scope": .string(parsedScope.rawValue),
                            "key": key.map(JSONValue.string) ?? .null,
                            "value": value.map(JSONValue.string) ?? .null,
                            "input": input.map(JSONValue.string) ?? .null,
                        ])
                    ]
                )

                var result = MutationResult(appId: "config", selector: key ?? parsedScope.rawValue, status: .planned, message: "Would update config.")
                if !dryRun {
                    if let input {
                        guard key == nil && value == nil else {
                            throw UpdateError.validation(code: "conflicting_input", message: "config set accepts either <key> <value> or --input, not both.")
                        }
                        let data: Data
                        if input == "-" {
                            data = FileHandle.standardInput.readDataToEndOfFile()
                        } else {
                            data = try Data(contentsOf: URL(fileURLWithPath: input))
                        }
                        try await service.setFromJSON(data, scope: parsedScope)
                    } else {
                        guard let key, let value else {
                            throw UpdateError.validation(code: "invalid_input", message: "config set requires either <key> <value> or --input.")
                        }
                        try await service.setValue(key, value: value, scope: parsedScope)
                    }
                    result = MutationResult(appId: "config", selector: key ?? parsedScope.rawValue, status: .updated, message: "Updated config.")
                }

                try CLIPrinter.emitMutation(
                    MutationEnvelope(command: "config.set", dryRun: dryRun, plan: try JSONValue.from(plan), results: [result]),
                    global: global
                )
            } catch let error as UpdateError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }
    }

    struct Unset: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Config key.") var key: String
        @Option(name: .long, help: "Config scope: user or project.") var scope: String = ConfigScope.user.rawValue
        @Flag(name: .long, help: "Preview the change without writing.") var dryRun: Bool = false

        mutating func run() async throws {
            do {
                guard let parsedScope = ConfigScope(rawValue: scope.lowercased()), parsedScope != .effective else {
                    throw UpdateError.validation(code: "invalid_scope", message: "config unset requires --scope user or --scope project.")
                }
                let service = ConfigService(configPath: global.config)
                let plan = MutationPlan(
                    command: "config.unset",
                    dryRun: dryRun,
                    requestedSelectors: [key],
                    resolvedAppIds: [],
                    preconditions: [],
                    actions: [PlanAction(type: "config_unset", details: ["scope": .string(parsedScope.rawValue), "key": .string(key)])]
                )

                var result = MutationResult(appId: "config", selector: key, status: .planned, message: "Would unset config key.")
                if !dryRun {
                    try await service.unsetValue(key, scope: parsedScope)
                    result = MutationResult(appId: "config", selector: key, status: .updated, message: "Unset config key.")
                }

                try CLIPrinter.emitMutation(
                    MutationEnvelope(command: "config.unset", dryRun: dryRun, plan: try JSONValue.from(plan), results: [result]),
                    global: global
                )
            } catch let error as UpdateError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }
    }

    struct Reset: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Optional config key.") var key: String?
        @Option(name: .long, help: "Config scope: user or project.") var scope: String = ConfigScope.user.rawValue
        @Flag(name: .long, help: "Confirm full reset when no key is provided.") var yes: Bool = false
        @Flag(name: .long, help: "Preview the change without writing.") var dryRun: Bool = false

        mutating func run() async throws {
            do {
                guard let parsedScope = ConfigScope(rawValue: scope.lowercased()), parsedScope != .effective else {
                    throw UpdateError.validation(code: "invalid_scope", message: "config reset requires --scope user or --scope project.")
                }
                if key == nil && !yes {
                    throw UpdateError.confirmationRequired(message: "Full config reset requires --yes.")
                }

                let service = ConfigService(configPath: global.config)
                let plan = MutationPlan(
                    command: "config.reset",
                    dryRun: dryRun,
                    requestedSelectors: [key ?? "all"],
                    resolvedAppIds: [],
                    preconditions: [],
                    actions: [PlanAction(type: "config_reset", details: ["scope": .string(parsedScope.rawValue), "key": key.map(JSONValue.string) ?? .null])]
                )

                var result = MutationResult(appId: "config", selector: key ?? "all", status: .planned, message: key == nil ? "Would reset config scope." : "Would reset config key.")
                if !dryRun {
                    try await service.reset(key: key, scope: parsedScope)
                    result = MutationResult(appId: "config", selector: key ?? "all", status: .updated, message: key == nil ? "Reset config scope." : "Reset config key.")
                }

                try CLIPrinter.emitMutation(
                    MutationEnvelope(command: "config.reset", dryRun: dryRun, plan: try JSONValue.from(plan), results: [result]),
                    global: global
                )
            } catch let error as UpdateError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }
    }
}

struct Schema: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Commands.self, Command.self, Config.self, Errors.self, Examples.self])
    mutating func run() async throws { throw CleanExit.helpRequest(self) }

    struct CommandEntry: Encodable {
        var command: String
        var aliases: [String]
        var stability: String
    }

    struct ConfigEntry: Encodable {
        var key: String
        var type: String
        var defaultValue: String
        var envVar: String?
        var description: String
        var mutable: Bool
    }

    struct ErrorEntry: Encodable {
        var code: String
        var message: String
        var category: String
    }

    struct ExampleEntry: Encodable {
        var title: String
        var command: String
        var mode: String
    }

    struct DescriptorEntry: Encodable {
        var contractVersion: String
        var command: String
        var stability: String
        var description: String
        var positionals: [String]
        var flags: [String]
        var inputSchema: JSONValue?
        var outputSchema: JSONValue
        var errorCodes: [String]
        var examples: [ExampleEntry]
        var supportsFields: Bool
        var supportsPagination: Bool
        var plainFormat: String?
    }

    static let catalog: [String: (aliases: [String], descriptor: DescriptorEntry)] = {
        func descriptor(
            command: String,
            aliases: [String] = [],
            description: String,
            positionals: [String] = [],
            flags: [String] = [],
            inputSchema: JSONValue? = nil,
            outputKind: String,
            errorCodes: [String] = ["invalid_input", "runtime_failed"],
            examples: [ExampleEntry] = [],
            supportsFields: Bool = false,
            supportsPagination: Bool = false,
            plainFormat: String? = nil
        ) -> (aliases: [String], descriptor: DescriptorEntry) {
            (
                aliases,
                DescriptorEntry(
                    contractVersion: "1.0",
                    command: command,
                    stability: "stable",
                    description: description,
                    positionals: positionals,
                    flags: flags,
                    inputSchema: inputSchema,
                    outputSchema: .object(["kind": .string(outputKind)]),
                    errorCodes: errorCodes,
                    examples: examples,
                    supportsFields: supportsFields,
                    supportsPagination: supportsPagination,
                    plainFormat: plainFormat
                )
            )
        }

        return [
            "apps.list": descriptor(command: "apps.list", aliases: ["list"], description: "List tracked apps from persisted state.", positionals: ["selectors..."], flags: ["--fields", "--limit", "--cursor", "--all-pages"], outputKind: "collection", examples: [.init(title: "List apps", command: "update apps list --format json", mode: "machine")], supportsFields: true, supportsPagination: true, plainFormat: "tab-separated rows"),
            "apps.get": descriptor(command: "apps.get", description: "Get one tracked app from persisted state.", positionals: ["selector"], flags: ["--fields"], outputKind: "item", examples: [.init(title: "Get an app", command: "update apps get id:app_123 --format json", mode: "machine")], supportsFields: true),
            "apps.check": descriptor(command: "apps.check", aliases: ["check"], description: "Check for updates and persist provider evidence.", positionals: ["selectors..."], flags: ["--provider", "--include-ignored", "--refresh", "--offline", "--skip-brew-update", "--fields", "--limit"], outputKind: "collection", examples: [.init(title: "Check one app", command: "update apps check name:Firefox --provider brew --format json", mode: "machine")], supportsFields: true, supportsPagination: true),
            "apps.sources": descriptor(command: "apps.sources", aliases: ["sources"], description: "Show provider candidates and selected evidence for one app.", positionals: ["selector"], flags: ["--refresh", "--offline", "--fields"], outputKind: "item", examples: [.init(title: "Show sources", command: "update apps sources id:app_123 --format json", mode: "machine")], supportsFields: true),
            "apps.update": descriptor(command: "apps.update", aliases: ["update"], description: "Install updates for matching apps.", positionals: ["selectors..."], flags: ["--all", "--provider", "--yes", "--reinstall", "--no-quarantine", "--allow-sudo", "--dry-run", "--input"], inputSchema: .object(["type": .string("object")]), outputKind: "mutation"),
            "apps.adopt": descriptor(command: "apps.adopt", aliases: ["adopt"], description: "Adopt existing apps into Homebrew cask management.", positionals: ["selectors..."], flags: ["--all", "--cask", "--yes", "--reinstall", "--dry-run", "--input"], inputSchema: .object(["type": .string("object")]), outputKind: "mutation"),
            "ignores.list": descriptor(command: "ignores.list", description: "List ignored apps.", flags: ["--fields", "--limit"], outputKind: "collection", supportsFields: true, supportsPagination: true),
            "ignores.add": descriptor(command: "ignores.add", aliases: ["ignore"], description: "Add apps to the ignore list.", positionals: ["selectors..."], flags: ["--scope", "--reason", "--dry-run", "--input"], inputSchema: .object(["type": .string("object")]), outputKind: "mutation"),
            "ignores.remove": descriptor(command: "ignores.remove", aliases: ["unignore"], description: "Remove apps from the ignore list.", positionals: ["selectors..."], flags: ["--dry-run", "--input"], inputSchema: .object(["type": .string("object")]), outputKind: "mutation"),
            "skips.list": descriptor(command: "skips.list", description: "List skipped versions.", flags: ["--fields", "--limit"], outputKind: "collection", supportsFields: true, supportsPagination: true),
            "skips.add": descriptor(command: "skips.add", aliases: ["skip"], description: "Skip one version for one app.", positionals: ["selector"], flags: ["--version", "--expires-in", "--dry-run", "--input"], inputSchema: .object(["type": .string("object")]), outputKind: "mutation"),
            "skips.remove": descriptor(command: "skips.remove", aliases: ["unskip"], description: "Remove version skips.", positionals: ["selectors..."], flags: ["--dry-run", "--input"], inputSchema: .object(["type": .string("object")]), outputKind: "mutation"),
            "scan.run": descriptor(command: "scan.run", aliases: ["scan"], description: "Rescan configured locations and persist app state.", flags: ["--locations", "--deep", "--dry-run"], inputSchema: .object(["type": .string("object")]), outputKind: "mutation", examples: [.init(title: "Dry-run scan", command: "update scan run --dry-run --format json", mode: "machine")]),
            "doctor.run": descriptor(command: "doctor.run", aliases: ["doctor"], description: "Check environment health.", flags: ["--checks", "--fields"], outputKind: "item", examples: [.init(title: "Doctor", command: "update doctor run --format json", mode: "machine")], supportsFields: true),
            "config.show": descriptor(command: "config.show", description: "Show configuration for a scope.", flags: ["--scope", "--origin", "--fields"], outputKind: "item", examples: [.init(title: "Show effective config", command: "update config show --scope effective --format json", mode: "machine")], supportsFields: true),
            "config.get": descriptor(command: "config.get", description: "Get one config value.", positionals: ["key"], flags: ["--scope", "--origin", "--fields"], outputKind: "item", examples: [.init(title: "Get a config key", command: "update config get timeout --scope effective --format json", mode: "machine")], supportsFields: true),
            "config.set": descriptor(command: "config.set", description: "Set config values in user or project scope.", positionals: ["key", "value"], flags: ["--scope", "--input", "--dry-run"], inputSchema: .object(["type": .string("object")]), outputKind: "mutation", examples: [.init(title: "Set a config key", command: "update config set timeout 45s --scope project --format json", mode: "machine")]),
            "config.unset": descriptor(command: "config.unset", description: "Unset a config value in user or project scope.", positionals: ["key"], flags: ["--scope", "--dry-run"], outputKind: "mutation"),
            "config.reset": descriptor(command: "config.reset", description: "Reset a config key or scope.", positionals: ["key?"], flags: ["--scope", "--yes", "--dry-run"], outputKind: "mutation"),
            "schema.commands": descriptor(command: "schema.commands", description: "List documented commands and aliases.", flags: ["--fields"], outputKind: "collection", supportsFields: true, supportsPagination: true),
            "schema.command": descriptor(command: "schema.command", description: "Return the descriptor for one command.", positionals: ["group.command"], flags: ["--fields"], outputKind: "item", supportsFields: true),
            "schema.config": descriptor(command: "schema.config", description: "Return config key schemas and defaults.", flags: ["--fields"], outputKind: "collection", supportsFields: true, supportsPagination: true),
            "schema.errors": descriptor(command: "schema.errors", description: "Return stable error codes.", flags: ["--fields"], outputKind: "collection", supportsFields: true, supportsPagination: true),
            "schema.examples": descriptor(command: "schema.examples", description: "Return canonical examples for one command.", positionals: ["group.command"], flags: ["--fields"], outputKind: "item", supportsFields: true),
            "completions": descriptor(command: "completions", description: "Write shell completions to stdout.", positionals: ["shell"], outputKind: "item"),
        ]
    }()

    struct Commands: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions

        mutating func run() async throws {
            let commands = Schema.catalog.keys.sorted().compactMap { key -> CommandEntry? in
                guard let entry = Schema.catalog[key] else { return nil }
                return CommandEntry(command: key, aliases: entry.aliases, stability: entry.descriptor.stability)
            }
            try CLIPrinter.emitCollection(commands, global: global)
        }
    }

    struct Command: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Canonical command name.") var command: String

        mutating func run() async throws {
            guard let entry = Schema.catalog[command] else {
                CLIPrinter.printError(.validation(code: "unknown_command", message: "Unknown command '\(command)'."), global: global)
                throw ExitCode(ExitCode.invalidUsage.rawValue)
            }
            try CLIPrinter.emitItem(entry.descriptor, global: global)
        }
    }

    struct Config: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions

        mutating func run() async throws {
            let entries = ConfigKeySpec.all.map {
                ConfigEntry(
                    key: $0.key,
                    type: $0.type,
                    defaultValue: $0.defaultValue,
                    envVar: $0.envVar,
                    description: $0.description,
                    mutable: $0.mutable
                )
            }
            try CLIPrinter.emitCollection(entries, global: global)
        }
    }

    struct Errors: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions

        mutating func run() async throws {
            let entries = ErrorCatalog.entries.map {
                ErrorEntry(code: $0.code, message: $0.message, category: $0.category)
            }
            try CLIPrinter.emitCollection(entries, global: global)
        }
    }

    struct Examples: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Canonical command name.") var command: String

        struct ExampleCollection: Encodable {
            var command: String
            var examples: [ExampleEntry]
        }

        mutating func run() async throws {
            guard let entry = Schema.catalog[command] else {
                CLIPrinter.printError(.validation(code: "unknown_command", message: "Unknown command '\(command)'."), global: global)
                throw ExitCode(ExitCode.invalidUsage.rawValue)
            }
            try CLIPrinter.emitItem(ExampleCollection(command: command, examples: entry.descriptor.examples), global: global)
        }
    }
}

struct Completions: AsyncParsableCommand {
    @Argument(help: "Target shell.") var shell: String

    mutating func run() async throws {
        guard let completionShell = CompletionShell(rawValue: shell) else {
            CLIPrinter.printError(.validation(code: "invalid_input", message: "Unsupported shell '\(shell)'. Use one of: bash, zsh, fish."), global: GlobalOptions())
            throw ExitCode(ExitCode.invalidUsage.rawValue)
        }
        Swift.print(UpdateCLI.completionScript(for: completionShell))
    }
}
