import Foundation

/// The quicklinks and fallback rows a new database starts with. The identifiers are fixed, so
/// that a later migration or a support answer can name these rows.
///
/// The migration `m3_commands` inserts these values. Like the migration, they are never
/// edited once they have shipped; a change to the seeds is a new migration.
enum CommandSeeds {
    static let google = Quicklink(
        id: UUID(uuidString: "1A47E6BE-FE88-4B7B-8351-8A31C8F89B17")!,
        name: "Google",
        template: "https://www.google.com/search?q={query}",
        icon: "sf:magnifyingglass",
        createdAt: Date(timeIntervalSince1970: 0))

    static let duckDuckGo = Quicklink(
        id: UUID(uuidString: "387E4923-C4DD-4185-A582-2C149037FD3F")!,
        name: "DuckDuckGo",
        template: "https://duckduckgo.com/?q={query}",
        icon: "sf:magnifyingglass",
        // One second after Google, which keeps the two in this order.
        createdAt: Date(timeIntervalSince1970: 1))

    /// "Search Files" arrives with file search in milestone 7. Its row waits in the list until
    /// then: an entry whose item no source provides is skipped.
    static let searchFiles = ItemID.command(FeatureID(rawValue: "files"), "search")

    static let quicklinks = [google, duckDuckGo]
    static let fallbackOrder = [google.itemID, duckDuckGo.itemID, searchFiles]
}
