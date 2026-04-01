import Foundation

public enum FieldMask {
    /// Apply a field mask to a JSONValue object.
    /// Only top-level and dot-path fields in the mask are retained.
    /// Fields whose values are unknown/absent serialize as null.
    /// Omitted fields are removed entirely.
    public static func apply(fields: [String], to value: JSONValue) -> JSONValue {
        guard !fields.isEmpty else { return value }
        guard case .object(let pairs) = value else { return value }

        var result: [(key: String, value: JSONValue)] = []

        for field in fields {
            if field.contains(".") {
                // Dot path: e.g. "selected_candidate.provider"
                let parts = field.split(separator: ".", maxSplits: 1)
                let topKey = String(parts[0])
                let subKey = String(parts[1])

                if let existing = pairs.first(where: { $0.key == topKey }) {
                    let subValue = extractDotPath(subKey, from: existing.value)
                    // Nest it back
                    if let existingIdx = result.firstIndex(where: { $0.key == topKey }) {
                        // Merge into existing nested object
                        if case .object(var nested) = result[existingIdx].value {
                            nested.append((key: subKey, value: subValue))
                            result[existingIdx] = (key: topKey, value: .object(nested))
                        }
                    } else {
                        result.append((key: topKey, value: .object([(key: subKey, value: subValue)])))
                    }
                } else {
                    // Field not present, serialize as null at the nested path
                    if let existingIdx = result.firstIndex(where: { $0.key == topKey }) {
                        if case .object(var nested) = result[existingIdx].value {
                            nested.append((key: subKey, value: .null))
                            result[existingIdx] = (key: topKey, value: .object(nested))
                        }
                    } else {
                        result.append((key: topKey, value: .object([(key: subKey, value: .null)])))
                    }
                }
            } else {
                // Simple field
                if let pair = pairs.first(where: { $0.key == field }) {
                    result.append(pair)
                } else {
                    result.append((key: field, value: .null))
                }
            }
        }

        return .object(result)
    }

    /// Apply a field mask to each item in a collection.
    public static func applyToCollection(fields: [String], items: [JSONValue]) -> [JSONValue] {
        guard !fields.isEmpty else { return items }
        return items.map { apply(fields: fields, to: $0) }
    }

    private static func extractDotPath(_ path: String, from value: JSONValue) -> JSONValue {
        guard case .object(let pairs) = value else { return .null }
        let parts = path.split(separator: ".", maxSplits: 1)
        let key = String(parts[0])
        guard let found = pairs.first(where: { $0.key == key }) else { return .null }
        if parts.count > 1 {
            return extractDotPath(String(parts[1]), from: found.value)
        }
        return found.value
    }
}
