import Foundation

/// File search in root search (docs/DESIGN.md §4.8). The files themselves are never root
/// results: they are found on the "Search Files" screen. What root search has is the way
/// there, as a command found by its name and as a row of the fallback section that takes
/// what was typed along.
public struct FileSearchSource: SearchSource {
    public static let feature = FeatureID(rawValue: "files")
    /// The list of files.
    public static let searchScreen = "search"
    /// The list of apps that can open one file. The request's argument is the file's path.
    public static let openWithScreen = "openWith"
    /// The "Search Files" item. A new database has it on the fallback list already, under
    /// this ID (`CommandSeeds.searchFiles`).
    public static let searchItemID = ItemID.command(feature, "search")

    public let id = SourceID(rawValue: "files")
    public let latency = SourceLatency.inline

    public init() {}

    /// The "Search Files" command, which never changes. Being indexed is what lets the user
    /// find it by name, give it an alias or turn it off in Settings.
    public func indexedItems() -> AsyncStream<[SearchItem]> {
        let command = Self.searchItem(searchingFor: nil)
        return AsyncStream { continuation in
            continuation.yield([command])
            continuation.finish()
        }
    }

    public func results(for query: SearchQuery) async throws -> [ScoredItem]? {
        let text = query.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        // The session shows this row when the search found nothing else, and where the
        // user's fallback list has it (§4.2.9).
        let item = Self.searchItem(searchingFor: text)
        return [ScoredItem(item: item, quality: 0, placement: .fallback)]
    }

    /// "Search Files", as the command that opens the screen or as the fallback row that
    /// searches for `text` there. Both are the same item to the usage and override tables.
    private static func searchItem(searchingFor text: String?) -> SearchItem {
        let title = String(
            localized: "Search Files", bundle: .module,
            comment:
                "The command that opens the list where files are searched by name. It is also a row shown when a search finds nothing, where it searches for what was typed."
        )
        let kindLabel = String(
            localized: "Command", bundle: .module,
            comment: "The kind of a search result that is a command, shown at the end of its row."
        )
        let keywords = [
            String(
                localized: "Find File", bundle: .module,
                comment: "Another name the Search Files command is found by."),
            String(
                localized: "File Search", bundle: .module,
                comment: "Another name the Search Files command is found by."),
        ]
        var alternateNames: [NameVariant] = []
        for keyword in keywords {
            alternateNames.append(.keyword(keyword))
        }

        let screen = ScreenRequest(feature: feature, screen: searchScreen, argument: text)
        let search = ActionDescriptor(id: ActionID(rawValue: "search"), title: title) { _ in
            .push(screen)
        }
        return SearchItem(
            id: searchItemID, title: title, alternateNames: alternateNames,
            icon: .symbol("doc.text.magnifyingglass"), kindLabel: kindLabel, tabTarget: screen,
            actions: [search])
    }
}
