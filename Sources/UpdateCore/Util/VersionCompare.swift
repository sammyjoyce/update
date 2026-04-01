import Foundation

public enum VersionCompare {
    /// Compare two version strings using numeric component comparison.
    /// Returns: negative if a < b, zero if equal, positive if a > b.
    public static func compare(_ a: String, _ b: String) -> Int {
        let partsA = normalize(a)
        let partsB = normalize(b)
        let maxLen = max(partsA.count, partsB.count)

        for i in 0..<maxLen {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va != vb { return va < vb ? -1 : 1 }
        }
        return 0
    }

    /// Returns true if `available` is newer than `installed`.
    public static func isNewer(_ available: String, than installed: String) -> Bool {
        compare(available, installed) > 0
    }

    /// Normalize a version string to an array of numeric components.
    /// Strips leading 'v', handles pre-release suffixes by treating them as sub-zero.
    private static func normalize(_ version: String) -> [Int] {
        var v = version
        if v.hasPrefix("v") || v.hasPrefix("V") {
            v = String(v.dropFirst())
        }

        // Split on dots and dashes
        let components = v.split(whereSeparator: { $0 == "." || $0 == "-" })
        return components.map { component in
            if let num = Int(component) {
                return num
            }
            // Try to extract leading number from mixed strings like "1rc2"
            let digits = component.prefix(while: \.isNumber)
            return Int(digits) ?? 0
        }
    }
}
