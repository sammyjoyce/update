import Foundation

public enum DurationParser {
    /// Parse a duration string like "30s", "45m", "12h", "7d" to seconds.
    public static func parseToSeconds(_ input: String) -> TimeInterval? {
        let trimmed = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let suffix = trimmed.last!
        guard let number = Double(trimmed.dropLast()) else { return nil }

        switch suffix {
        case "s": return number
        case "m": return number * 60
        case "h": return number * 3600
        case "d": return number * 86400
        default:
            // Try parsing as pure seconds
            return Double(trimmed)
        }
    }

    /// Format seconds to a human-readable duration string.
    public static func format(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }
}
