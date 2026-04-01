import Foundation

public enum UpdatestError: Error, Sendable {
    case validation(code: String, message: String, hint: String? = nil, details: [String: JSONValue]? = nil)
    case runtime(code: String, message: String, hint: String? = nil, details: [String: JSONValue]? = nil)
    case notFound(code: String = "not_found", message: String, details: [String: JSONValue]? = nil)
    case ambiguous(code: String = "ambiguous_selector", message: String, details: [String: JSONValue]? = nil)
    case confirmationRequired(message: String = "Confirmation required. Use --yes to proceed without prompting.")
    case unsafeInput(code: String, message: String, details: [String: JSONValue]? = nil)

    public var exitCode: ExitCode {
        switch self {
        case .validation: return .invalidUsage
        case .runtime: return .runtimeFailure
        case .notFound: return .runtimeFailure
        case .ambiguous: return .invalidUsage
        case .confirmationRequired: return .confirmationRequired
        case .unsafeInput: return .unsafeInput
        }
    }

    public var code: String {
        switch self {
        case .validation(let c, _, _, _): return c
        case .runtime(let c, _, _, _): return c
        case .notFound(let c, _, _): return c
        case .ambiguous(let c, _, _): return c
        case .confirmationRequired: return "confirmation_required"
        case .unsafeInput(let c, _, _): return c
        }
    }

    public var message: String {
        switch self {
        case .validation(_, let m, _, _): return m
        case .runtime(_, let m, _, _): return m
        case .notFound(_, let m, _): return m
        case .ambiguous(_, let m, _): return m
        case .confirmationRequired(let m): return m
        case .unsafeInput(_, let m, _): return m
        }
    }

    public func toDetail(traceId: String? = nil) -> ErrorDetail {
        let hint: String?
        let details: [String: JSONValue]?
        switch self {
        case .validation(_, _, let h, let d):
            hint = h; details = d
        case .runtime(_, _, let h, let d):
            hint = h; details = d
        case .notFound(_, _, let d):
            hint = nil; details = d
        case .ambiguous(_, _, let d):
            hint = "Use a more specific selector (id: or path:)."; details = d
        case .confirmationRequired:
            hint = "Use --yes to suppress confirmation."; details = nil
        case .unsafeInput(_, _, let d):
            hint = nil; details = d
        }
        return ErrorDetail(
            code: code, message: message, hint: hint,
            details: details, traceId: traceId
        )
    }
}

/// All stable error codes for schema introspection.
public struct ErrorCatalog: Sendable {
    public struct Entry: Sendable {
        public let code: String
        public let message: String
        public let category: String
    }

    public static let entries: [Entry] = [
        .init(code: "invalid_selector", message: "Selector must use id:, name:, bundle:, or path: form.", category: "validation"),
        .init(code: "empty_selector", message: "Selector must not be empty.", category: "validation"),
        .init(code: "empty_selector_value", message: "Selector value must not be empty after prefix.", category: "validation"),
        .init(code: "unsafe_selector", message: "Selector contains unsafe characters or patterns.", category: "safety"),
        .init(code: "invalid_path_selector", message: "Path selector is not a valid absolute .app path.", category: "validation"),
        .init(code: "not_found", message: "No matching app record found.", category: "runtime"),
        .init(code: "ambiguous_selector", message: "Selector matches multiple records.", category: "validation"),
        .init(code: "confirmation_required", message: "Interactive confirmation required but suppressed.", category: "safety"),
        .init(code: "invalid_config_key", message: "Config key is not recognized.", category: "validation"),
        .init(code: "invalid_config_value", message: "Config value failed validation.", category: "validation"),
        .init(code: "invalid_scope", message: "Config scope is not valid for this operation.", category: "validation"),
        .init(code: "config_not_found", message: "Config file not found at the specified path.", category: "runtime"),
        .init(code: "invalid_input", message: "Input payload failed validation.", category: "validation"),
        .init(code: "precondition_failed", message: "Plan precondition no longer holds.", category: "runtime"),
        .init(code: "permission_denied", message: "Operation requires elevated privileges.", category: "runtime"),
        .init(code: "tool_missing", message: "Required tool is not installed or not found.", category: "runtime"),
        .init(code: "download_failed", message: "Failed to download update artifact.", category: "runtime"),
        .init(code: "validation_failed", message: "Downloaded artifact failed validation.", category: "runtime"),
        .init(code: "runtime_failed", message: "Update execution failed.", category: "runtime"),
        .init(code: "network_error", message: "Network request failed.", category: "runtime"),
        .init(code: "parse_error", message: "Failed to parse response data.", category: "runtime"),
        .init(code: "stale_cache", message: "Using cached provider data past TTL.", category: "warning"),
        .init(code: "unknown_command", message: "Command not found.", category: "validation"),
        .init(code: "conflicting_input", message: "Flags and --input payload disagree.", category: "validation"),
    ]
}
