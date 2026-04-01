import Foundation

public enum Sanitizer {
    /// Sanitize untrusted remote text (release notes, appcast descriptions, etc.).
    /// Strips control characters, excessive whitespace, and potential injection patterns.
    public static func sanitize(_ input: String, maxLength: Int = 4096) -> String {
        var result = input

        // Strip NUL and other control characters (keep newline, tab)
        result = result.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 || scalar == "\n" || scalar == "\t"
        }.map(String.init).joined()

        // Collapse multiple blank lines
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        // Truncate
        if result.count > maxLength {
            result = String(result.prefix(maxLength)) + "..."
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Escape a string for plain (tab-separated) output.
    public static func escapePlain(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
