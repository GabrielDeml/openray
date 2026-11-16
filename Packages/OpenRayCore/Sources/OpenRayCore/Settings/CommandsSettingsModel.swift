import Foundation
import Observation

/// What Settings › Commands shows and changes: which items are hidden or disabled, their
/// aliases, the quicklinks, and the order of the fallback list (docs/DESIGN.md §4.3.5).
@MainActor @Observable public final class CommandsSettingsModel {
    /// Which of the launcher's items the list shows. Apps are by far the most and are rarely
    /// what someone comes here for, so they have a list of their own.
    public enum Scope: Sendable, Hashable {
        case commands
        case applications
    }

    /// One item with what the user has changed about it.
    public struct Row: Identifiable, Equatable, Sendable {
        public var id: ItemID
        public var title: String
        public var kindLabel: String
        public var icon: IconSource
        /// The item's aliases, joined with commas, as the row's text field shows them.
        public var aliasText: String
        public var isHidden: Bool
        public var isEnabled: Bool
    }

    /// One entry of the fallback list.
    public struct FallbackRow: Identifiable, Equatable, Sendable {
        public var id: ItemID
        /// nil for an entry whose item no feature provides yet, such as "Search Files" before
        /// file search exists. The entry keeps its place for when it does.
        public var title: String?
    }

    public var scope = Scope.commands
    /// The text of the pane's search field.
    public var filter = ""
    /// The item whose alias field should take the keyboard, set when the pane is opened for
    /// one item. The view clears it once it has moved the focus.
    public var itemToFocus: ItemID?
    /// Why the last change could not be stored.
    public private(set) var errorMessage: String?

    private var overrides = CommandOverrides()
    private var items: [SearchItem] = []

    @ObservationIgnored private let commands: CommandStore
    @ObservationIgnored private let currentItems: @MainActor () -> [SearchItem]
    @ObservationIgnored private var following: Task<Void, Never>?

    /// - Parameter currentItems: Everything the launcher's sources have yielded, hidden and
    ///   disabled items included (`CommandRegistry.items`).
    public init(commands: CommandStore, currentItems: @escaping @MainActor () -> [SearchItem]) {
        self.commands = commands
        self.currentItems = currentItems
    }

    deinit {
        following?.cancel()
    }

    /// Reads the items as they are now and begins to follow the store. The pane calls this
    /// every time it appears.
    public func start() {
        reloadItems()
        if following != nil { return }

        let changes = commands.changes()
        following = Task { [weak self] in
            do {
                for try await overrides in changes {
                    self?.overrides = overrides
                }
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            // The stream has ended. The next time the pane appears, `start` follows a new one.
            self?.following = nil
        }
    }

    /// Reads the launcher's items again. They are not followed like the store: the list of
    /// items calls this when it appears, and an app installed or a quicklink added since is
    /// then in it.
    public func reloadItems() {
        items = currentItems()
    }

    /// Shows the pane's list on one item, for "Add Alias…" in the launcher.
    public func focus(on id: ItemID) {
        reloadItems()
        scope = id.namespace == .app ? .applications : .commands
        // The item's title as the filter leaves it as the only row, or nearly.
        filter = items.first { $0.id == id }?.title ?? ""
        itemToFocus = id
    }

    // MARK: Items

    /// The items of the current scope that match the filter, by title.
    public var rows: [Row] {
        let foldedFilter = Array(SearchQuery(filter).normalized.unicodeScalars)

        var rows: [Row] = []
        for item in items {
            let isApplication = item.id.namespace == .app
            let isInScope = isApplication == (scope == .applications)
            if !isInScope { continue }

            if !foldedFilter.isEmpty {
                let title = NormalizedName(item.title)
                if FuzzyMatcher.match(foldedFilter, in: title) == nil { continue }
            }

            let override = overrides.overrides[item.id] ?? ItemOverride()
            let row = Row(
                id: item.id, title: item.title, kindLabel: item.kindLabel, icon: item.icon,
                aliasText: overrides.aliases(of: item.id).joined(separator: ", "),
                isHidden: override.hidden, isEnabled: !override.disabled)
            rows.append(row)
        }
        rows.sort { first, second in
            first.title.localizedStandardCompare(second.title) == .orderedAscending
        }
        return rows
    }

    /// Makes the item's aliases the ones in `text`, which separates them with commas.
    public func setAliases(_ text: String, for id: ItemID) async {
        var aliases: [String] = []
        for part in text.split(separator: ",") {
            aliases.append(String(part))
        }
        await write { try await self.commands.setAliases(aliases, for: id) }
    }

    public func setHidden(_ isHidden: Bool, for id: ItemID) async {
        await write {
            try await self.commands.updateOverride(for: id) { override in
                override.hidden = isHidden
            }
        }
    }

    public func setEnabled(_ isEnabled: Bool, for id: ItemID) async {
        await write {
            try await self.commands.updateOverride(for: id) { override in
                override.disabled = !isEnabled
            }
        }
    }

    // MARK: Quicklinks

    public var quicklinks: [Quicklink] {
        overrides.quicklinks
    }

    /// What is wrong with a quicklink the user is editing, or nil when it can be saved.
    public func problem(with quicklink: Quicklink) -> String? {
        let name = quicklink.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return String(
                localized: "Give the quicklink a name.", bundle: .module,
                comment: "Shown in the quicklink editor while the name is empty.")
        }
        // Tried with an argument, because the placeholder itself is not valid in a URL.
        let makesAURL = (try? QuicklinkTemplate.url(for: quicklink, argument: "test")) != nil
        if !makesAURL {
            return String(
                localized:
                    "The link has to be a URL, such as https://example.com/search?q={query}.",
                bundle: .module,
                comment: "Shown in the quicklink editor while the URL template is not a valid URL.")
        }
        return nil
    }

    public func save(_ quicklink: Quicklink) async {
        var trimmed = quicklink
        trimmed.name = quicklink.name.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.template = quicklink.template.trimmingCharacters(in: .whitespacesAndNewlines)
        await write { try await self.commands.saveQuicklink(trimmed) }
    }

    public func deleteQuicklink(_ id: UUID) async {
        await write { try await self.commands.deleteQuicklink(id) }
    }

    // MARK: Fallback list

    public var fallbackRows: [FallbackRow] {
        var rows: [FallbackRow] = []
        for id in overrides.fallbackOrder {
            rows.append(FallbackRow(id: id, title: title(of: id)))
        }
        return rows
    }

    /// The quicklinks that could be added to the fallback list: those that take the query as
    /// their argument and are not on the list yet.
    public var fallbackCandidates: [Quicklink] {
        overrides.quicklinks.filter { quicklink in
            let takesTheQuery = QuicklinkTemplate.takesArgument(quicklink.template)
            let isListed = overrides.fallbackOrder.contains(quicklink.itemID)
            return takesTheQuery && !isListed
        }
    }

    // The three changes below name the entries they are about by ID and are applied to the
    // list as the store holds it. The rows on screen can be a moment behind the store, and a
    // change worked out from their positions could bring back an entry that was just removed.

    public func addFallback(_ id: ItemID) async {
        await write {
            try await self.commands.updateFallbackOrder { order in
                order.append(id)
            }
        }
    }

    public func removeFallback(_ id: ItemID) async {
        await write {
            try await self.commands.updateFallbackOrder { order in
                order.removeAll { listed in listed == id }
            }
        }
    }

    /// Moves entries of the fallback list, with the arguments of SwiftUI's `onMove`.
    ///
    /// - Parameter destination: The position among the rows as they were before the move.
    public func moveFallback(fromOffsets source: IndexSet, toOffset destination: Int) async {
        let shownOrder = overrides.fallbackOrder
        var movedIDs: [ItemID] = []
        for index in source where shownOrder.indices.contains(index) {
            movedIDs.append(shownOrder[index])
        }
        // The entry the moved ones go in front of: the first one at or after the destination
        // that stays where it is. Without one they go to the end.
        var nextID: ItemID?
        for index in shownOrder.indices where index >= destination && !source.contains(index) {
            nextID = shownOrder[index]
            break
        }

        await write {
            try await self.commands.updateFallbackOrder { [movedIDs, nextID] order in
                order.removeAll { listed in movedIDs.contains(listed) }
                var insertionIndex = order.endIndex
                if let nextID, let index = order.firstIndex(of: nextID) {
                    insertionIndex = index
                }
                order.insert(contentsOf: movedIDs, at: insertionIndex)
            }
        }
    }

    private func title(of id: ItemID) -> String? {
        if let quicklink = overrides.quicklinks.first(where: { $0.itemID == id }) {
            return quicklink.name
        }
        return items.first { $0.id == id }?.title
    }

    // MARK: Writing

    /// Runs one change to the store and keeps its error for the pane to show. What the change
    /// did reaches the pane through `following`, like every other change to the tables.
    private func write(_ change: () async throws -> Void) async {
        do {
            try await change()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
