import Foundation

public enum PlistReader {
    /// Read app info from an .app bundle's Info.plist.
    public static func readAppInfo(atPath bundlePath: String) -> AppInfo? {
        let plistPath = (bundlePath as NSString).appendingPathComponent("Contents/Info.plist")
        let url = URL(fileURLWithPath: plistPath)

        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        let name = appName(from: plist, bundlePath: bundlePath)
        let bundleId = plist["CFBundleIdentifier"] as? String
        let shortVersion = plist["CFBundleShortVersionString"] as? String
        let version = plist["CFBundleVersion"] as? String
        let sparkleFeedUrl = plist["SUFeedURL"] as? String

        // Detect Electron by checking for Electron framework
        let electronFramework = (bundlePath as NSString).appendingPathComponent(
            "Contents/Frameworks/Electron Framework.framework"
        )
        let squirrelFramework = (bundlePath as NSString).appendingPathComponent(
            "Contents/Frameworks/Squirrel.framework"
        )
        let isElectron = FileManager.default.fileExists(atPath: electronFramework) ||
                         FileManager.default.fileExists(atPath: squirrelFramework)

        let teamId = plist["TeamIdentifier"] as? String

        return AppInfo(
            name: name,
            bundleId: bundleId,
            version: version,
            shortVersion: shortVersion,
            path: bundlePath,
            sparkleFeedUrl: sparkleFeedUrl,
            isElectron: isElectron,
            teamId: teamId
        )
    }

    private static func appName(from plist: [String: Any], bundlePath: String) -> String {
        if let displayName = plist["CFBundleDisplayName"] as? String, !displayName.isEmpty {
            return displayName
        }
        if let name = plist["CFBundleName"] as? String, !name.isEmpty {
            return name
        }
        // Fall back to filename
        let url = URL(fileURLWithPath: bundlePath)
        return url.deletingPathExtension().lastPathComponent
    }
}
