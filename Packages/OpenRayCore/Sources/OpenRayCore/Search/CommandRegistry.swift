import os

/// Collects the indexed items of every source into the `IndexSnapshot` that root search matches
/// against, with the user's overrides applied (docs/DESIGN.md §4.2.4).
@MainActor public final class CommandRegistry {
    public let sources: [any SearchSource]

    /// Everything the sources have yielded so far, as the sources gave it: hidden and disabled
    /// items included, and before aliases. Of items that share an ID only the first is here.
    /// Settings lists these, so that an item the user hid can be brought back.
    public var items: [SearchItem] {
        var items: [SearchItem] = []
        var seenIDs: Set<ItemID> = []
        for sourceItems in itemsBySource {
            for item in sourceItems {
                let isNewID = seenIDs.insert(item.id).inserted
                if isNewID {
                    items.append(item)
                }
            }
        }
        return items
    }

    /// The user's aliases, overrides and fallback order, as last read from the store. Empty
    /// without a store.
    public private(set) var overrides = CommandOverrides()

    /// What root search matches against. Empty until every source has reported and, with a
    /// store, the overrides have been read (`isReady`).
    private(set) var snapshot = IndexSnapshot.empty
    /// Whether `snapshot` has been built at least once. Until then the index is not empty
    /// because nothing matches but because it is not there yet, and the search session shows
    /// no fallback rows: a Return typed right after launch must not turn "saf" into a web
    /// search because the apps had not been scanned.
    private(set) var isReady = false
    /// Called after `snapshot` or `overrides` has changed.
    var onChange: (@MainActor () -> Void)?

    /// The latest items of each source, in the order of `sources`.
    private var itemsBySource: [[SearchItem]]
    /// The sources that have neither yielded yet nor ended their stream, by index. No snapshot
    /// is built while there are any. One built from half the sources would put "Quit Safari"
    /// where Safari is about to be, under a Return that was meant for the app.
    private var sourcesYetToReport: Set<Int>
    /// True while a store was given and has not answered yet. No snapshot is built before
    /// then: it would show the items the user has hidden until the overrides arrive.
    private var isWaitingForOverrides: Bool
    private var listeners: [Task<Void, Never>] = []
    private var snapshotBuild: Task<Void, Never>?

    /// - Parameter commands: Where the user's overrides are kept. The registry follows its
    ///   changes. nil applies none, for tests.
    public init(sources: [any SearchSource], commands: CommandStore? = nil) {
        self.sources = sources
        itemsBySource = Array(repeating: [], count: sources.count)
        sourcesYetToReport = Set(sources.indices)
        isWaitingForOverrides = commands != nil

        for (index, source) in sources.enumerated() {
            // A source without indexed items has a stream that ends at once, and its listener
            // with it.
            let itemSets = source.indexedItems()
            let listener = Task { [weak self] in
                for await items in itemSets {
                    self?.replaceItems(ofSourceAt: index, with: items)
                }
                // A stream that ends without an element is how a source says it has no
                // indexed items.
                self?.sourceDidEnd(at: index)
            }
            listeners.append(listener)
        }

        if let commands {
            let changes = commands.changes()
            let listener = Task { [weak self] in
                do {
                    for try await overrides in changes {
                        self?.replaceOverrides(with: overrides)
                    }
                } catch {
                    Log.storage.error("Cannot read the command overrides: \(error)")
                    // Search goes on with the overrides read so far, or with none.
                    self?.overridesBecameUnavailable()
                }
            }
            listeners.append(listener)
        }
    }

    deinit {
        // Ending a listener ends its stream, which is what tells a source to stop producing.
        for listener in listeners {
            listener.cancel()
        }
    }

    private func replaceItems(ofSourceAt index: Int, with items: [SearchItem]) {
        itemsBySource[index] = items
        sourcesYetToReport.remove(index)
        rebuildSnapshot()
    }

    private func sourceDidEnd(at index: Int) {
        let wasAwaited = sourcesYetToReport.remove(index) != nil
        // The last source to report may be one that has nothing to report.
        if wasAwaited {
            rebuildSnapshot()
        }
    }

    private func replaceOverrides(with newOverrides: CommandOverrides) {
        overrides = newOverrides
        isWaitingForOverrides = false
        rebuildSnapshot()
    }

    private func overridesBecameUnavailable() {
        if !isWaitingForOverrides { return }
        isWaitingForOverrides = false
        rebuildSnapshot()
    }

    private func rebuildSnapshot() {
        if isWaitingForOverrides || !sourcesYetToReport.isEmpty { return }

        // In the order of the sources: of two items with the same ID the snapshot keeps the
        // first.
        var allItems: [SearchItem] = []
        for sourceItems in itemsBySource {
            allItems.append(contentsOf: sourceItems)
        }
        let overrides = overrides

        // A build that is still running is for a list that is out of date by now. It is
        // cancelled here and checks for that on the main actor before it publishes, so an older
        // snapshot can never replace a newer one.
        snapshotBuild?.cancel()
        snapshotBuild = Task { [weak self] in
            let snapshot = await IndexSnapshot.build(from: allItems, overrides: overrides)
            if Task.isCancelled { return }
            self?.publish(snapshot)
        }
    }

    private func publish(_ snapshot: IndexSnapshot) {
        // Two items with one ID are a mistake in a source, or two sources that disagree about
        // who owns an item.
        let duplicateCount = snapshot.duplicateIDCount
        if duplicateCount > 0 {
            Log.search.error(
                "Left out \(duplicateCount, privacy: .public) items whose ID was already taken")
        }
        // A mistake in a source as well: the launcher uses the chord itself.
        let reservedShortcutCount = snapshot.reservedShortcutCount
        if reservedShortcutCount > 0 {
            Log.search.error(
                """
                Removed \(reservedShortcutCount, privacy: .public) action shortcuts that \
                collide with the launcher's own keys
                """)
        }
        self.snapshot = snapshot
        isReady = true
        onChange?()
    }
}
