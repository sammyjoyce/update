import Darwin
import Foundation
import UpdateCore

enum MutationInput<T> {
    case request(T)
    case plan(MutationPlan)
}

struct AppsUpdateRequest: Codable {
    var selectors: [String]?
    var all: Bool?
    var provider: String?
    var reinstall: Bool?
    var dryRun: Bool?
    var noQuarantine: Bool?
    var allowSudo: Bool?
}

struct AppsAdoptRequest: Codable {
    var selectors: [String]?
    var all: Bool?
    var cask: String?
    var reinstall: Bool?
    var dryRun: Bool?
}

struct IgnoreAddRequest: Codable {
    var selectors: [String]?
    var scope: String?
    var reason: String?
    var dryRun: Bool?
}

struct SelectorListRequest: Codable {
    var selectors: [String]?
    var dryRun: Bool?
}

struct SkipAddRequest: Codable {
    var selector: String?
    var version: String?
    var expiresIn: String?
    var dryRun: Bool?
}

enum MutationSupport {
    static func readInputData(path: String) throws -> Data {
        if path == "-" {
            return FileHandle.standardInput.readDataToEndOfFile()
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    static func decodeRequestOrPlan<T: Decodable>(path: String, as type: T.Type, command: String) throws -> MutationInput<T> {
        let data = try readInputData(path: path)
        if let plan = try? JSONCoders.decoder.decode(MutationPlan.self, from: data), plan.command == command {
            return .plan(plan)
        }
        return .request(try JSONCoders.decoder.decode(T.self, from: data))
    }

    static func confirmIfNeeded(summary: String, yes: Bool, noInput: Bool) throws {
        guard !yes else { return }

        if noInput || isatty(STDIN_FILENO) == 0 {
            throw UpdateError.confirmationRequired()
        }

        fputs("\(summary) [y/N]: ", stderr)
        guard let reply = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              ["y", "yes"].contains(reply) else {
            throw UpdateError.confirmationRequired(message: "Confirmation declined.")
        }
    }

    static func parseProvider(_ raw: String?) throws -> Provider? {
        guard let raw else { return nil }
        let normalized = raw.lowercased()
        if normalized == "all" { return nil }
        guard let provider = Provider(rawValue: normalized) else {
            throw UpdateError.validation(code: "invalid_input", message: "Unknown provider '\(raw)'.")
        }
        return provider
    }

    static func ensureNoConflictingFlags(hasInput: Bool, conflicting: Bool, message: String) throws {
        if hasInput && conflicting {
            throw UpdateError.validation(code: "conflicting_input", message: message)
        }
    }

    static func selectedCandidate(for app: AppRecord, providerFilter: Provider?) -> UpdateCandidate? {
        if let providerFilter {
            return app.candidates.first(where: { $0.provider == providerFilter })
                ?? (app.selectedCandidate?.provider == providerFilter ? app.selectedCandidate : nil)
        }
        return app.selectedCandidate
    }

    static func stringValue(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double):
            let intValue = Int(double)
            return double == Double(intValue) ? String(intValue) : String(double)
        default: return nil
        }
    }
}
