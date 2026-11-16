import Foundation
import os

/// Answers one root query at a time (docs/DESIGN.md §4.2.5): matches it against the index, asks
/// every source what it has for the query, and publishes both as `SearchResults`.
///
/// Every `update` is answered through `onResults` at least once with its generation, also when
/// nothing was found, a source failed or a source never returns. Only a newer `update` takes the
/// answer away. The launcher depends on that: a Return pressed ahead of the results waits for
/// them (§4.1.4).
@MainActor public final class SearchSession {
    private struct Request {
        var query: String
        var generation: UInt64
    }

    /// What the last ranking that ran to its end left for a query that extends its own.
    private struct Survivors {
        /// The normalised query that was ranked. Never empty.
        var query: String
        /// Indices into the entries of the registry's current snapshot.
        var entryIndices: [Int]
    }

    /// What the child tasks of one search report back.
    private enum SearchEvent: Sendable {
        /// nil when the search was cancelled before the matcher was done.
        case matcherFinished(RankedResults?)
        /// No rows when the source had nothing for the query, or failed.
        case sourceFinished(index: Int, rows: [ScoredItem])
        case inlineDeadlinePassed
        case sourcesAreOverdue
    }

    /// The most rows the ranked section shows. A one-letter query matches most of the index,
    /// and 200 rows is the list size the latency budget is measured at (§4.1.5).
    nonisolated static let rankedRowLimit = 200
    /// Sources that have not answered after this long are logged (§4.2.11).
    nonisolated private static let overdueSourceDelay: Duration = .seconds(2)

    /// Called with the results for the query of the latest `update`: once when the matcher and
    /// the inline sources have answered, and again whenever a slower source adds rows.
    public var onResults: (@MainActor (SearchResults) -> Void)?

    /// How long the first results for a query wait for the `.inline` sources. Tests change it.
    var inlineDeadline: Duration = .milliseconds(12)
    /// The search that is running, or the last one once it has ended. Readable so that tests can
    /// wait for a search to end.
    private(set) var searchTask: Task<Void, Never>?

    private let registry: CommandRegistry
    private let usage: any UsageStore
    private let now: @Sendable () -> Date
    /// What `update` was last asked for. An index change searches it again.
    private var lastRequest: Request?
    private var survivors: Survivors?

    /// - Parameter now: The time usage is judged at. Tests pass a fixed one.
    public init(
        registry: CommandRegistry, usage: any UsageStore, now: @escaping @Sendable () -> Date
    ) {
        self.registry = registry
        self.usage = usage
        self.now = now
        registry.onChange = { [weak self] in
            self?.indexDidChange()
        }
    }

    /// Starts the search for `query` and gives up the one that was running.
    ///
    /// - Parameter generation: Handed back with the results, so that the caller can tell which
    ///   query they answer.
    public func update(query: String, generation: UInt64) {
        searchTask?.cancel()
        lastRequest = Request(query: query, generation: generation)

        let parsedQuery = SearchQuery(query)
        // Taken together and now: the candidates are indices into this snapshot.
        let snapshot = registry.snapshot
        let candidates = candidates(for: parsedQuery)
        let sources = registry.sources
        let overrides = registry.overrides
        let isIndexReady = registry.isReady

        searchTask = Task {
            await run(
                query: parsedQuery, generation: generation, snapshot: snapshot,
                candidates: candidates, sources: sources, overrides: overrides,
                isIndexReady: isIndexReady)
        }
    }

    /// The index has new contents: searches the current query again and answers with the same
    /// generation, which the launcher takes as an update of the rows it shows. This is how the
    /// first search after launch fills in once the apps have been scanned, and how an app
    /// installed while the launcher is open appears.
    private func indexDidChange() {
        // They are indices into the snapshot that has just been replaced.
        survivors = nil
        guard let lastRequest else { return }
        update(query: lastRequest.query, generation: lastRequest.generation)
    }

    // MARK: Survivors

    /// The entries the matcher has to look at for `query`, or nil for all of them. When the
    /// query extends the one ranked last, only that query's survivors can still match (§4.2.6).
    private func candidates(for query: SearchQuery) -> [Int]? {
        guard let survivors else { return nil }
        // Scalar by scalar, which is how the matcher reads a query.
        let typed = query.normalized.unicodeScalars
        guard typed.starts(with: survivors.query.unicodeScalars) else { return nil }
        return survivors.entryIndices
    }

    private func rememberSurvivors(_ entryIndices: [Int], of query: SearchQuery) {
        // The suggestions for the empty field are not matches, and every query extends the
        // empty one.
        if query.normalized.isEmpty {
            survivors = nil
        } else {
            survivors = Survivors(query: query.normalized, entryIndices: entryIndices)
        }
    }

    // MARK: One search

    private func run(
        query: SearchQuery, generation: UInt64, snapshot: IndexSnapshot, candidates: [Int]?,
        sources: [any SearchSource], overrides: CommandOverrides, isIndexReady: Bool
    ) async {
        let usageSnapshot = await usage.snapshot()
        if Task.isCancelled { return }
        // The child tasks do not run on the main actor, so they get copies of what they need
        // from it.
        let now = now()
        let inlineDeadline = inlineDeadline

        await withTaskGroup(of: SearchEvent.self) { group in
            group.addTask {
                let ranked = await snapshot.rank(
                    query: query, usage: usageSnapshot, now: now, candidates: candidates)
                return .matcherFinished(ranked)
            }
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do {
                        let rows = try await source.results(for: query)
                        return .sourceFinished(index: index, rows: rows ?? [])
                    } catch {
                        // A source that honours cancellation throws when the next search
                        // cancels this one. Every search but the last ends that way, so it is
                        // not worth logging.
                        if !Task.isCancelled {
                            let name = source.id.rawValue
                            Log.search.error(
                                "The source \(name, privacy: .public) failed: \(error)")
                        }
                        return .sourceFinished(index: index, rows: [])
                    }
                }
            }
            // The two timers. When the search is cancelled their sleep ends early, and the loop
            // below has stopped listening by then.
            group.addTask {
                try? await Task.sleep(for: inlineDeadline)
                return .inlineDeadlinePassed
            }
            group.addTask {
                try? await Task.sleep(for: Self.overdueSourceDelay)
                return .sourcesAreOverdue
            }

            var progress = SearchProgress(
                query: query, sources: sources, overrides: overrides,
                isIndexReady: isIndexReady)
            for await event in group {
                // A newer `update` has cancelled this search. `update` runs on the main actor,
                // as this loop does, and nothing in the loop's body suspends. So a search that
                // gets past this check publishes before the newer one starts, never after it.
                if Task.isCancelled { return }

                switch event {
                case .matcherFinished(let ranked):
                    // The matcher only gives up when the search is cancelled.
                    guard let ranked else { return }
                    progress.matcherRows = ranked.rows
                    rememberSurvivors(ranked.survivors, of: query)

                case .sourceFinished(let index, let rows):
                    progress.setRows(rows, ofSourceAt: index)
                    if progress.hasPublished {
                        let source = sources[index]
                        if source.latency == .inline {
                            let name = source.id.rawValue
                            Log.search.error(
                                """
                                The source \(name, privacy: .public) says it is inline but \
                                missed the deadline for the first results
                                """)
                        }
                        if progress.hasRows(fromSourceAt: index) {
                            publish(progress, generation: generation)
                        }
                    }

                case .inlineDeadlinePassed:
                    progress.inlineDeadlineHasPassed = true

                case .sourcesAreOverdue:
                    logUnfinishedSources(of: progress)
                }

                if !progress.hasPublished && progress.isReadyForFirstPublish {
                    progress.settleRankedSection(usage: usageSnapshot, now: now)
                    publish(progress, generation: generation)
                }

                let isComplete = progress.matcherRows != nil && progress.unfinishedSources.isEmpty
                if isComplete {
                    // Only the timers are left, and nobody waits for them.
                    group.cancelAll()
                    return
                }
            }
        }
    }

    private func publish(_ progress: SearchProgress, generation: UInt64) {
        onResults?(SearchResults(sections: progress.sections(), generation: generation))
    }

    private func logUnfinishedSources(of progress: SearchProgress) {
        for index in progress.unfinishedSources {
            let name = progress.sources[index].id.rawValue
            Log.search.error("The source \(name, privacy: .public) still has not answered")
        }
    }
}

/// What one search has gathered so far, and how that is laid out in sections.
private struct SearchProgress {
    /// "Ask AI" leads the fallback section, whether or not the user's list names it (§4.2.9).
    private static let askAI = QuickAISource.askItemID

    let query: SearchQuery
    let sources: [any SearchSource]
    /// The user's overrides as they were when the search began.
    let overrides: CommandOverrides
    /// False while the registry has not built its first snapshot. "Nothing found" then only
    /// means that the index is not there yet, which is no reason to offer a web search.
    let isIndexReady: Bool

    /// The matcher's rows, best first. nil until the matcher is done.
    var matcherRows: [RankedRow]?
    /// What each source returned, by its index in `sources`, without the rows the user's
    /// overrides take away. nil while the source has not finished.
    private(set) var rowsBySource: [[ScoredItem]?]
    var inlineDeadlineHasPassed = false

    /// The rows of the ranked section. The first publish settles them, and every later publish
    /// for the query repeats them as they are: what a source adds afterwards goes below, so the
    /// rows the user is already looking at never move.
    private var rankedSectionRows: [ScoredItem]?
    /// The sources whose `.ranked` rows are among `rankedSectionRows`: the inline sources that
    /// had finished by the first publish. Every other source gets a section of its own.
    private var sourcesInRankedSection: Set<Int> = []

    init(
        query: SearchQuery, sources: [any SearchSource], overrides: CommandOverrides,
        isIndexReady: Bool
    ) {
        self.query = query
        self.sources = sources
        self.overrides = overrides
        self.isIndexReady = isIndexReady
        rowsBySource = Array(repeating: nil, count: sources.count)
    }

    /// Takes what a source returned. The registry keeps hidden and disabled items out of the
    /// index; rows that a source computes for the query get the same treatment here.
    mutating func setRows(_ rows: [ScoredItem], ofSourceAt index: Int) {
        var allowedRows: [ScoredItem] = []
        for scored in rows {
            let id = scored.item.id
            let isAllowed: Bool
            if scored.placement == .fallback {
                // A hidden item is only out of root search. It still serves in the fallback
                // list, where the user put it by name.
                isAllowed = !overrides.isDisabled(id)
            } else {
                isAllowed = overrides.isSearchable(id)
            }
            if isAllowed {
                allowedRows.append(scored)
            }
        }
        rowsBySource[index] = allowedRows
    }

    /// Whether the source has finished with rows that are left to show.
    func hasRows(fromSourceAt index: Int) -> Bool {
        guard let rows = rowsBySource[index] else { return false }
        return !rows.isEmpty
    }

    var hasPublished: Bool { rankedSectionRows != nil }

    var unfinishedSources: [Int] {
        var unfinished: [Int] = []
        for index in sources.indices where rowsBySource[index] == nil {
            unfinished.append(index)
        }
        return unfinished
    }

    var isReadyForFirstPublish: Bool {
        // Never without the matcher's rows, however long they take. The first results for a
        // query are what a waiting Return acts on (§4.1.4), and without these it would act on
        // nothing.
        if matcherRows == nil { return false }
        // The deadline is for the inline sources only: a slow source is never waited for.
        if inlineDeadlineHasPassed { return true }
        for index in unfinishedSources {
            if sources[index].latency == .inline { return false }
        }
        return true
    }

    /// Fixes the rows of the ranked section: the matcher's rows, and in one order with them the
    /// `.ranked` rows of the inline sources that have finished.
    mutating func settleRankedSection(usage: UsageSnapshot, now: Date) {
        // The matcher pins the item whose alias was typed; that row goes to the pinned section.
        var rows: [RankedRow] = []
        for row in matcherRows ?? [] where row.scored.placement == .ranked {
            rows.append(row)
        }
        var hasRowsFromSources = false

        for (index, source) in sources.enumerated() where source.latency == .inline {
            guard let sourceRows = rowsBySource[index] else { continue }
            sourcesInRankedSection.insert(index)
            for scored in sourceRows where scored.placement == .ranked {
                rows.append(RankedRow.ranked(scored, query: query, usage: usage, now: now))
                hasRowsFromSources = true
            }
        }
        // The matcher's rows come in order.
        if hasRowsFromSources {
            rows.sort(by: RankedRow.isOrderedBefore)
        }

        var shownRows: [ScoredItem] = []
        for row in rows.prefix(SearchSession.rankedRowLimit) {
            shownRows.append(row.scored)
        }
        rankedSectionRows = shownRows
    }

    /// The sections in displayed order. A section without rows is left out: the launcher takes
    /// "no sections" for "nothing found", and the list would draw a header with nothing under it.
    ///
    /// An item is listed once. The list tells its rows apart by ID, and the same item can come
    /// in twice: a quicklink that the matcher finds by its name and that its source pins for
    /// the same query. The first row in displayed order stays.
    func sections() -> [ResultSection] {
        var sections: [ResultSection] = []
        var listedIDs: Set<ItemID> = []

        /// Appends the section with the rows whose item is not listed yet, if any are left.
        func add(id: String, title: String? = nil, rows: [ScoredItem]) {
            var newRows: [ScoredItem] = []
            for scored in rows {
                let isNewItem = listedIDs.insert(scored.item.id).inserted
                if isNewItem {
                    newRows.append(scored)
                }
            }
            if !newRows.isEmpty {
                sections.append(ResultSection(id: id, title: title, rows: newRows))
            }
        }

        add(id: "pinned", rows: pinnedRows())
        add(id: "results", title: rankedSectionTitle, rows: rankedSectionRows ?? [])

        // Slow sources, and inline sources that were too late for the ranked section.
        for (index, source) in sources.enumerated() {
            if sourcesInRankedSection.contains(index) { continue }
            var rows: [ScoredItem] = []
            for scored in rowsBySource[index] ?? [] where scored.placement == .ranked {
                rows.append(scored)
            }
            add(id: source.id.rawValue, rows: rows)
        }

        add(id: "fallback", title: fallbackSectionTitle, rows: fallbackRows())
        return sections
    }

    /// The item whose alias is the query, then what the sources pin, in source order.
    private func pinnedRows() -> [ScoredItem] {
        var rows: [ScoredItem] = []
        for row in matcherRows ?? [] where row.scored.placement == .pinnedTop {
            rows.append(row.scored)
        }
        for sourceRows in rowsBySource {
            for scored in sourceRows ?? [] where scored.placement == .pinnedTop {
                rows.append(scored)
            }
        }
        return rows
    }

    /// The rows the sources offer for "nothing found", in the order of the user's fallback
    /// list. A row whose item is not on the list is left out. No rows while something was
    /// found, and none for the empty field, where there is no query to act on.
    private func fallbackRows() -> [ScoredItem] {
        guard let rankedSectionRows, rankedSectionRows.isEmpty else { return [] }
        if query.normalized.isEmpty || !isIndexReady { return [] }

        var offeredRows: [ItemID: ScoredItem] = [:]
        for sourceRows in rowsBySource {
            for scored in sourceRows ?? [] where scored.placement == .fallback {
                // Of two sources that offer the same item, the earlier one wins.
                if offeredRows[scored.item.id] == nil {
                    offeredRows[scored.item.id] = scored
                }
            }
        }

        var order = overrides.fallbackOrder
        order.removeAll { id in id == Self.askAI }
        order.insert(Self.askAI, at: 0)

        var rows: [ScoredItem] = []
        for id in order {
            if let scored = offeredRows[id] {
                rows.append(scored)
            }
        }
        return rows
    }

    private var fallbackSectionTitle: String {
        let typed = query.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(
            localized: "Use “\(typed)” with", bundle: .module,
            comment: "The heading over the fallback commands, shown when a search finds nothing.")
    }

    private var rankedSectionTitle: String {
        if query.normalized.isEmpty {
            return String(
                localized: "Suggestions", bundle: .module,
                comment: "The heading over the most used items, shown while nothing is typed.")
        }
        return String(
            localized: "Results", bundle: .module,
            comment: "The heading over the search results.")
    }
}
