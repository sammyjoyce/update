import Foundation

public actor AppScanner {
    public init() {}

    /// Scan directories for .app bundles and read their info.
    public func scan(locations: [String], deep: Bool = false) -> [AppInfo] {
        var results: [AppInfo] = []
        let fm = FileManager.default

        for location in locations {
            guard fm.fileExists(atPath: location) else { continue }

            if deep {
                results.append(contentsOf: scanDeep(location))
            } else {
                results.append(contentsOf: scanShallow(location))
            }
        }

        return results
    }

    private func scanShallow(_ directory: String) -> [AppInfo] {
        let fm = FileManager.default
        var results: [AppInfo] = []

        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return [] }

        for entry in entries where entry.hasSuffix(".app") {
            let fullPath = (directory as NSString).appendingPathComponent(entry)
            if let info = PlistReader.readAppInfo(atPath: fullPath) {
                results.append(info)
            }
        }

        return results
    }

    private func scanDeep(_ directory: String) -> [AppInfo] {
        let fm = FileManager.default
        var results: [AppInfo] = []

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            if url.pathExtension == "app" {
                if let info = PlistReader.readAppInfo(atPath: url.path) {
                    results.append(info)
                }
                enumerator.skipDescendants()
            }
        }

        return results
    }
}
