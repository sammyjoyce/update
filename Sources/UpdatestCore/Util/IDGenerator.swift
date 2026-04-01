import Foundation

public enum IDGenerator {
    /// Generate a stable app_id from a bundle path.
    /// Uses a hash of the path for determinism across rescans.
    public static func appId(forPath path: String) -> String {
        let hash = stableHash(path)
        return "app_\(hash)"
    }

    /// Generate a unique plan ID.
    public static func generatePlanId() -> String {
        "plan_\(compactUUID())"
    }

    /// Generate a unique trace ID.
    public static func generateTraceId() -> String {
        "trace_\(compactUUID())"
    }

    private static func compactUUID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24).description
    }

    private static func stableHash(_ input: String) -> String {
        var hasher = Hasher()
        hasher.combine(input)
        let hash = abs(hasher.finalize())
        return String(hash, radix: 36).padding(toLength: 16, withPad: "0", startingAt: 0)
    }
}
