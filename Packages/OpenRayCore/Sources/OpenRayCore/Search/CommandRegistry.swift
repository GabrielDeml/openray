import os

/// Collects the indexed items of every source into the `IndexSnapshot` that root search matches
/// against (docs/DESIGN.md §4.2.4).
@MainActor public final class CommandRegistry {
    public let sources: [any SearchSource]

    /// Everything the sources have yielded so far. Empty until the first of them has.
    private(set) var snapshot = IndexSnapshot.empty
    /// Called after `snapshot` has changed.
    var onChange: (@MainActor () -> Void)?

    /// The latest items of each source, in the order of `sources`.
    private var itemsBySource: [[SearchItem]]
    private var listeners: [Task<Void, Never>] = []
    private var snapshotBuild: Task<Void, Never>?

    public init(sources: [any SearchSource]) {
        self.sources = sources
        itemsBySource = Array(repeating: [], count: sources.count)

        for (index, source) in sources.enumerated() {
            // A source without indexed items has a stream that ends at once, and its listener
            // with it.
            let itemSets = source.indexedItems()
            let listener = Task { [weak self] in
                for await items in itemSets {
                    self?.replaceItems(ofSourceAt: index, with: items)
                }
            }
            listeners.append(listener)
        }
    }

    deinit {
        // Ending a listener ends its source's stream, which is what tells the source to stop
        // producing.
        for listener in listeners {
            listener.cancel()
        }
    }

    private func replaceItems(ofSourceAt index: Int, with items: [SearchItem]) {
        itemsBySource[index] = items

        // In the order of the sources: of two items with the same ID the snapshot keeps the
        // first.
        var allItems: [SearchItem] = []
        for sourceItems in itemsBySource {
            allItems.append(contentsOf: sourceItems)
        }

        // A build that is still running is for a list that is out of date by now. It is
        // cancelled here and checks for that on the main actor before it publishes, so an older
        // snapshot can never replace a newer one.
        snapshotBuild?.cancel()
        snapshotBuild = Task { [weak self] in
            let snapshot = await IndexSnapshot.build(from: allItems)
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
        self.snapshot = snapshot
        onChange?()
    }
}
