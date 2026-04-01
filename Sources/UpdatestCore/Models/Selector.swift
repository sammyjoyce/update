import Foundation

public enum SelectorKind: String, Sendable {
    case id
    case bundle
    case path
    case name
}

public struct ParsedSelector: Sendable, Equatable {
    public let kind: SelectorKind
    public let value: String

    public init(kind: SelectorKind, value: String) {
        self.kind = kind
        self.value = value
    }

    public var description: String { "\(kind.rawValue):\(value)" }
}

public enum SelectorParser {
    /// Parse a typed selector string like `id:abc`, `bundle:com.example`, `path:/Applications/X.app`, `name:Firefox`.
    /// Returns a structured error for invalid input.
    public static func parse(_ input: String, allowBare: Bool = false) -> Result<ParsedSelector, UpdatestError> {
        let trimmed = input.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            return .failure(.validation(
                code: "empty_selector",
                message: "Selector must not be empty."
            ))
        }

        // Reject unsafe characters
        if trimmed.contains("\0") || trimmed.unicodeScalars.contains(where: { $0.value < 0x20 && $0.value != 0x09 }) {
            return .failure(.validation(
                code: "unsafe_selector",
                message: "Selector contains control characters.",
                details: ["selector": .string(trimmed)]
            ))
        }

        // Reject percent-encoded traversal
        if trimmed.contains("%") {
            return .failure(.validation(
                code: "unsafe_selector",
                message: "Percent-encoding is not allowed in selectors.",
                details: ["selector": .string(trimmed)]
            ))
        }

        // Try typed form
        if let colonIdx = trimmed.firstIndex(of: ":") {
            let prefix = String(trimmed[trimmed.startIndex..<colonIdx]).lowercased()
            let value = String(trimmed[trimmed.index(after: colonIdx)...])

            guard !value.isEmpty else {
                return .failure(.validation(
                    code: "empty_selector_value",
                    message: "Selector value must not be empty after prefix.",
                    details: ["selector": .string(trimmed)]
                ))
            }

            switch prefix {
            case "id":
                return .success(ParsedSelector(kind: .id, value: value))

            case "bundle":
                return .success(ParsedSelector(kind: .bundle, value: value))

            case "path":
                return validatePathSelector(value)

            case "name":
                return .success(ParsedSelector(kind: .name, value: value))

            default:
                return .failure(.validation(
                    code: "invalid_selector",
                    message: "Unknown selector prefix '\(prefix)'. Use id:, bundle:, path:, or name:.",
                    details: ["selector": .string(trimmed)]
                ))
            }
        }

        // Bare name (human convenience)
        if allowBare {
            return .success(ParsedSelector(kind: .name, value: trimmed))
        }

        return .failure(.validation(
            code: "invalid_selector",
            message: "Selector must use id:, name:, bundle:, or path: form.",
            hint: "Run `update schema command apps.get` for selector rules.",
            details: ["selector": .string(trimmed)]
        ))
    }

    /// Parse multiple selectors.
    public static func parseMany(
        _ inputs: [String], allowBare: Bool = false
    ) -> Result<[ParsedSelector], UpdatestError> {
        var results: [ParsedSelector] = []
        for input in inputs {
            switch parse(input, allowBare: allowBare) {
            case .success(let s): results.append(s)
            case .failure(let e): return .failure(e)
            }
        }
        return .success(results)
    }

    private static func validatePathSelector(_ value: String) -> Result<ParsedSelector, UpdatestError> {
        guard value.hasPrefix("/") else {
            return .failure(.validation(
                code: "invalid_path_selector",
                message: "Path selector must be an absolute path starting with '/'.",
                details: ["path": .string(value)]
            ))
        }

        guard value.hasSuffix(".app") else {
            return .failure(.validation(
                code: "invalid_path_selector",
                message: "Path selector must end in '.app'.",
                details: ["path": .string(value)]
            ))
        }

        if value.contains("..") {
            return .failure(.validation(
                code: "unsafe_selector",
                message: "Path selector must not contain '..' traversal.",
                details: ["path": .string(value)]
            ))
        }

        if value.contains("?") || value.contains("#") {
            return .failure(.validation(
                code: "unsafe_selector",
                message: "Path selector must not contain query strings or fragments.",
                details: ["path": .string(value)]
            ))
        }

        return .success(ParsedSelector(kind: .path, value: value))
    }
}
