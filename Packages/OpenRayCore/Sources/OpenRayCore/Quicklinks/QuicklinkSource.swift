import Foundation
import Synchronization

/// The user's quicklinks as items for root search (docs/DESIGN.md §4.2.9).
///
/// A quicklink shows up in three ways. It is an indexed item, found by its name. When the first
/// word of the query is its name or alias, it is pinned with the rest of the query as its
/// argument: "g giraffes". And it offers itself for the fallback section, where it takes the
/// whole query.
public final class QuicklinkSource: SearchSource {
    public static let feature = FeatureID(rawValue: "quicklinks")
    /// The screen that asks for a quicklink's argument. Its argument is the quicklink's UUID.
    public static let argumentScreen = "argument"

    public let id = SourceID(rawValue: "quicklinks")
    public let latency = SourceLatency.inline

    private let commands: CommandStore
    private let opener: any QuicklinkOpening
    /// The quicklinks and aliases as the store last reported them. `indexedItems()` keeps the
    /// copy current, and the registry reads that stream for as long as the launcher lives.
    /// `results(for:)` answers from the copy, because it runs on every keystroke and must not
    /// wait for the database.
    private let latestOverrides = Mutex(CommandOverrides())

    public init(commands: CommandStore, opener: any QuicklinkOpening) {
        self.commands = commands
        self.opener = opener
    }

    /// The quicklink with this ID, if the store has reported it.
    public func quicklink(withID id: UUID) -> Quicklink? {
        let quicklinks = latestOverrides.withLock { overrides in overrides.quicklinks }
        return quicklinks.first { $0.id == id }
    }

    public static func argumentScreenRequest(for quicklink: Quicklink) -> ScreenRequest {
        ScreenRequest(feature: feature, screen: argumentScreen, argument: quicklink.id.uuidString)
    }

    // MARK: Indexed items

    public func indexedItems() -> AsyncStream<[SearchItem]> {
        // Every element is the full list, so a consumer that falls behind needs only the newest.
        let (items, continuation) = AsyncStream.makeStream(
            of: [SearchItem].self, bufferingPolicy: .bufferingNewest(1))
        let changes = commands.changes()

        let following = Task {
            do {
                for try await overrides in changes {
                    latestOverrides.withLock { latest in latest = overrides }

                    var items: [SearchItem] = []
                    for quicklink in overrides.quicklinks {
                        items.append(indexedItem(for: quicklink))
                    }
                    continuation.yield(items)
                }
            } catch {
                // The quicklinks read so far stay in the index.
                Log.storage.error("Cannot read the quicklinks: \(error)")
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            following.cancel()
        }
        return items
    }

    /// The quicklink as it is found by name. One that takes an argument has none yet, so
    /// Return and Tab lead to the screen that asks for it.
    private func indexedItem(for quicklink: Quicklink) -> SearchItem {
        if QuicklinkTemplate.takesArgument(quicklink.template) {
            let argumentScreen = Self.argumentScreenRequest(for: quicklink)
            let enterArgument = ActionDescriptor(
                id: ActionID(rawValue: "open"), title: Self.openTitle
            ) { _ in
                .push(argumentScreen)
            }
            var item = searchItem(for: quicklink, subtitle: nil, action: enterArgument)
            item.tabTarget = argumentScreen
            return item
        }
        return searchItem(
            for: quicklink, subtitle: nil, action: openAction(for: quicklink, argument: ""))
    }

    // MARK: Results for a query

    public func results(for query: SearchQuery) async throws -> [ScoredItem]? {
        let overrides = latestOverrides.withLock { latest in latest }

        var rows: [ScoredItem] = []
        for quicklink in quicklinksNamed(byHeadOf: query, in: overrides) {
            let item = searchItem(
                for: quicklink, subtitle: query.tail,
                action: openAction(for: quicklink, argument: query.tail))
            rows.append(ScoredItem(item: item, quality: 1, placement: .pinnedTop))
        }

        let wholeQuery = query.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wholeQuery.isEmpty {
            // Every quicklink that can take the query offers itself. The session shows the ones
            // on the user's fallback list, and only when the search found nothing.
            for quicklink in overrides.quicklinks
            where QuicklinkTemplate.takesArgument(quicklink.template) {
                let item = searchItem(
                    for: quicklink, subtitle: nil,
                    action: openAction(for: quicklink, argument: wholeQuery))
                rows.append(ScoredItem(item: item, quality: 0, placement: .fallback))
            }
        }
        return rows.isEmpty ? nil : rows
    }

    /// The quicklinks the query addresses by its first word, when more words follow: by name,
    /// or by an alias. Only quicklinks that take an argument can be addressed this way.
    private func quicklinksNamed(
        byHeadOf query: SearchQuery, in overrides: CommandOverrides
    ) -> [Quicklink] {
        if query.tail.isEmpty { return [] }
        // Folded like an alias and like a name below, so that "G" finds "g".
        let head = SearchQuery(query.head).normalized
        let aliasedItem = overrides.aliases[head]

        var named: [Quicklink] = []
        for quicklink in overrides.quicklinks {
            guard QuicklinkTemplate.takesArgument(quicklink.template) else { continue }
            let hasThatName = SearchQuery(quicklink.name).normalized == head
            let hasThatAlias = aliasedItem == quicklink.itemID
            if hasThatName || hasThatAlias {
                named.append(quicklink)
            }
        }
        return named
    }

    // MARK: Building items

    static var openTitle: String {
        String(
            localized: "Open", bundle: .module,
            comment: "The action that opens the selected app or quicklink.")
    }

    private func searchItem(
        for quicklink: Quicklink, subtitle: String?, action: ActionDescriptor
    ) -> SearchItem {
        let kindLabel = String(
            localized: "Quicklink", bundle: .module,
            comment: "The kind of a search result that is a quicklink, shown at the end of its row."
        )
        return SearchItem(
            id: quicklink.itemID, title: quicklink.name, subtitle: subtitle,
            icon: Self.icon(of: quicklink), kindLabel: kindLabel, actions: [action])
    }

    /// The stored icon text as an icon: `sf:` and a symbol name, or an emoji.
    public static func icon(of quicklink: Quicklink) -> IconSource {
        let symbolPrefix = "sf:"
        guard let text = quicklink.icon, !text.isEmpty else { return .symbol("link") }
        if text.hasPrefix(symbolPrefix) {
            return .symbol(String(text.dropFirst(symbolPrefix.count)))
        }
        return .emoji(text)
    }

    private func openAction(for quicklink: Quicklink, argument: String) -> ActionDescriptor {
        let opener = opener
        return ActionDescriptor(id: ActionID(rawValue: "open"), title: Self.openTitle) { context in
            try await Self.open(quicklink, argument: argument, opener: opener, context: context)
            return .closeLauncher
        }
    }

    /// Opens the quicklink's URL for `argument`. A template that does not make a URL throws
    /// before the launcher is closed, so the error is shown with the launcher still open.
    @MainActor static func open(
        _ quicklink: Quicklink, argument: String, opener: any QuicklinkOpening,
        context: any ActionContext
    ) async throws {
        let url = try QuicklinkTemplate.url(for: quicklink, argument: argument)
        // The browser's window must not come up behind the panel.
        context.closeLauncher()
        try await opener.open(url, withAppBundleID: quicklink.openWith)
    }
}
