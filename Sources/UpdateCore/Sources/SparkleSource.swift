import Foundation

public actor SparkleSource: UpdateSource {
    public nonisolated let provider = Provider.sparkle

    public init() {}

    public func checkForUpdate(app: AppRecord, config: UpdateConfig) async throws -> [UpdateCandidate] {
        // Read SUFeedURL from the app bundle
        guard let info = PlistReader.readAppInfo(atPath: app.path),
              let feedUrl = info.sparkleFeedUrl,
              let url = URL(string: feedUrl)
        else { return [] }

        // Fetch the appcast
        let (data, _) = try await URLSession.shared.data(from: url)
        let items = parseAppcast(data)

        guard let latest = items.first else { return [] }

        let now = ISO8601DateFormatter().string(from: Date())
        let isNewer = app.installedVersion.map {
            VersionCompare.isNewer(latest.version, than: $0)
        } ?? true

        return [UpdateCandidate(
            provider: .sparkle,
            executor: .bundle_replace,
            discoveredBy: [.sparkle_feed],
            availableVersion: latest.version,
            downloadUrl: latest.downloadUrl,
            releaseNotesUrl: latest.releaseNotesUrl,
            requiresSudo: false,
            releaseDate: latest.pubDate,
            confidence: .high,
            checkedAt: now,
            selectionReasonCodes: isNewer ? ["newer_version"] : ["up_to_date"],
            rejectionReasonCodes: isNewer ? [] : ["not_newer"],
            details: ["feed_url": .string(feedUrl)]
        )]
    }

    private func parseAppcast(_ data: Data) -> [AppcastItem] {
        let parser = AppcastXMLParser(data: data)
        return parser.parse()
    }
}

struct AppcastItem: Sendable {
    var version: String
    var shortVersion: String?
    var downloadUrl: String?
    var releaseNotesUrl: String?
    var pubDate: String?
    var minimumSystemVersion: String?
}

/// Minimal appcast XML parser.
final class AppcastXMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private let data: Data
    private var items: [AppcastItem] = []
    private var currentElement = ""
    private var currentText = ""
    private var currentItem: AppcastItem?
    private var inItem = false

    init(data: Data) {
        self.data = data
    }

    func parse() -> [AppcastItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        // Sort by version descending
        return items.sorted { VersionCompare.compare($0.version, $1.version) > 0 }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        if elementName == "item" {
            inItem = true
            currentItem = AppcastItem(version: "")
        } else if elementName == "enclosure", inItem {
            if let url = attributes["url"] {
                currentItem?.downloadUrl = url
            }
            if let version = attributes["sparkle:shortVersionString"] {
                currentItem?.shortVersion = version
                currentItem?.version = version
            }
            if let version = attributes["sparkle:version"], currentItem?.shortVersion == nil {
                currentItem?.version = version
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if inItem {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "sparkle:releaseNotesLink":
                currentItem?.releaseNotesUrl = text
            case "pubDate":
                currentItem?.pubDate = text
            case "sparkle:minimumSystemVersion":
                currentItem?.minimumSystemVersion = text
            case "item":
                if let item = currentItem, !item.version.isEmpty {
                    items.append(item)
                }
                currentItem = nil
                inItem = false
            default:
                break
            }
        }
    }
}
