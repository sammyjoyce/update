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
    static func printError(_ error: UpdatestError, global: GlobalOptions) {
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

struct PhasePendingError: LocalizedError {
    let command: String
    var errorDescription: String? { "\(command) is not implemented yet." }
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
@main
struct UpdateCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Agent-first macOS app update checker and installer.",
        version: "1.0.0",
        subcommands: [Apps.self, Ignores.self, Skips.self, Scan.self, Doctor.self, ConfigGroup.self, Schema.self, Completions.self]
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
            } catch let error as UpdatestError {
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
            } catch let error as UpdatestError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }
    }

    struct Check: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        mutating func run() async throws { throw PhasePendingError(command: "apps check") }
    }

    struct Sources: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        mutating func run() async throws { throw PhasePendingError(command: "apps sources") }
    }

    struct Update: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        mutating func run() async throws { throw PhasePendingError(command: "apps update") }
    }

    struct Adopt: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        mutating func run() async throws { throw PhasePendingError(command: "apps adopt") }
    }
}

struct Ignores: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [List.self, Add.self, Remove.self])
    mutating func run() async throws { throw CleanExit.helpRequest(self) }

    struct List: AsyncParsableCommand { mutating func run() async throws { throw PhasePendingError(command: "ignores list") } }
    struct Add: AsyncParsableCommand { mutating func run() async throws { throw PhasePendingError(command: "ignores add") } }
    struct Remove: AsyncParsableCommand { mutating func run() async throws { throw PhasePendingError(command: "ignores remove") } }
}

struct Skips: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [List.self, Add.self, Remove.self])
    mutating func run() async throws { throw CleanExit.helpRequest(self) }

    struct List: AsyncParsableCommand { mutating func run() async throws { throw PhasePendingError(command: "skips list") } }
    struct Add: AsyncParsableCommand { mutating func run() async throws { throw PhasePendingError(command: "skips add") } }
    struct Remove: AsyncParsableCommand { mutating func run() async throws { throw PhasePendingError(command: "skips remove") } }
}

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Run.self])
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
            } catch let error as UpdatestError {
                CLIPrinter.printError(error, global: global)
                throw ExitCode(error.exitCode.rawValue)
            }
        }
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Run.self])
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

    struct Show: AsyncParsableCommand { mutating func run() async throws { throw PhasePendingError(command: "config show") } }
    struct Get: AsyncParsableCommand { mutating func run() async throws { throw PhasePendingError(command: "config get") } }
    struct Set: AsyncParsableCommand { mutating func run() async throws { throw PhasePendingError(command: "config set") } }
    struct Unset: AsyncParsableCommand { mutating func run() async throws { throw PhasePendingError(command: "config unset") } }
    struct Reset: AsyncParsableCommand { mutating func run() async throws { throw PhasePendingError(command: "config reset") } }
}

struct Schema: AsyncParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Commands.self, Command.self, Config.self, Errors.self, Examples.self])
    mutating func run() async throws { throw CleanExit.helpRequest(self) }

    struct Commands: AsyncParsableCommand { mutating func run() async throws { throw PhasePendingError(command: "schema commands") } }
    struct Command: AsyncParsableCommand { mutating func run() async throws { throw PhasePendingError(command: "schema command") } }
    struct Config: AsyncParsableCommand { mutating func run() async throws { throw PhasePendingError(command: "schema config") } }
    struct Errors: AsyncParsableCommand { mutating func run() async throws { throw PhasePendingError(command: "schema errors") } }
    struct Examples: AsyncParsableCommand { mutating func run() async throws { throw PhasePendingError(command: "schema examples") } }
}

struct Completions: AsyncParsableCommand {
    @Argument(help: "Target shell.") var shell: String
    mutating func run() async throws { throw PhasePendingError(command: "completions") }
}
