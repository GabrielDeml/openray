import Foundation
import Testing

@testable import OpenRayCore

// No test sleeps to let a search settle. A test either waits for the search's task to end, after
// which nothing more can be published, or takes the publishes one by one as they come. The time
// limits only stop a test that would otherwise wait forever.
@MainActor @Suite(.timeLimit(.minutes(1))) struct SearchSessionTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// The source of the indexed items. It yields what the test tells it to.
    private final class IndexSource: SearchSource {
        let id = SourceID(rawValue: "index")
        let latency = SourceLatency.inline

        private let itemSets: AsyncStream<[SearchItem]>
        private let continuation: AsyncStream<[SearchItem]>.Continuation

        init() {
            (itemSets, continuation) = AsyncStream.makeStream(of: [SearchItem].self)
        }

        func indexedItems() -> AsyncStream<[SearchItem]> {
            itemSets
        }

        func yield(_ items: [SearchItem]) {
            continuation.yield(items)
        }
    }

    /// A source that answers a query with whatever the test's closure does.
    private struct QuerySource: SearchSource {
        let id: SourceID
        let latency: SourceLatency
        let answer: @Sendable (SearchQuery) async throws -> [ScoredItem]?

        init(
            _ name: String, latency: SourceLatency,
            answer: @escaping @Sendable (SearchQuery) async throws -> [ScoredItem]?
        ) {
            id = SourceID(rawValue: name)
            self.latency = latency
            self.answer = answer
        }

        func results(for query: SearchQuery) async throws -> [ScoredItem]? {
            try await answer(query)
        }
    }

    /// Holds a fake source or store back until the test opens it.
    private final class Gate: Sendable {
        private let opened: AsyncStream<Void>
        private let openedContinuation: AsyncStream<Void>.Continuation
        private let arrivals: AsyncStream<Void>
        private let arrivalContinuation: AsyncStream<Void>.Continuation

        init() {
            (opened, openedContinuation) = AsyncStream.makeStream(of: Void.self)
            (arrivals, arrivalContinuation) = AsyncStream.makeStream(of: Void.self)
        }

        /// Returns once the gate is open, or once the waiting task has been cancelled.
        func wait() async {
            arrivalContinuation.yield()
            for await _ in opened {}
        }

        func open() {
            openedContinuation.finish()
        }

        /// Returns once somebody waits at the gate.
        func waitForArrival() async {
            for await _ in arrivals {
                return
            }
        }
    }

    /// A usage store without picks that hands out its snapshot only once the gate is open.
    private struct HeldUsageStore: UsageStore {
        let gate: Gate

        func record(pick: ItemID, query: String, at: Date) async throws {}

        func snapshot() async -> UsageSnapshot {
            await gate.wait()
            return UsageSnapshot()
        }
    }

    /// Everything a session publishes, in order.
    @MainActor private final class Published {
        private(set) var all: [SearchResults] = []

        private let stream: AsyncStream<SearchResults>
        private let continuation: AsyncStream<SearchResults>.Continuation

        init(by session: SearchSession) {
            (stream, continuation) = AsyncStream.makeStream(of: SearchResults.self)
            session.onResults = { [self] results in
                // Holds for every publish of every test: the launcher reads "no sections" as
                // "nothing found".
                for section in results.sections {
                    #expect(!section.rows.isEmpty, "The section \(section.id) is empty")
                }
                all.append(results)
                continuation.yield(results)
            }
        }

        /// The oldest publish that `next()` has not handed out yet. Waits for one if need be.
        func next() async throws -> SearchResults {
            for await results in stream {
                return results
            }
            // The stream never ends, so the loop only gets here when the test was cancelled.
            throw CancellationError()
        }
    }

    // MARK: Helpers

    /// An app whose ID is its title.
    private func app(_ title: String) -> SearchItem {
        SearchItem(
            id: .app(bundleID: title), title: title, icon: .symbol("app"), kindLabel: "Application")
    }

    private func apps(_ titles: String...) -> [SearchItem] {
        var items: [SearchItem] = []
        for title in titles {
            items.append(app(title))
        }
        return items
    }

    /// A session whose index already holds `items`. The index source is the first source of its
    /// registry; `sources` follow it.
    private func makeSession(
        items: [SearchItem], sources: [any SearchSource] = [],
        usage: any UsageStore = InMemoryUsageStore(), commands: CommandStore? = nil
    ) async -> (session: SearchSession, index: IndexSource) {
        let index = IndexSource()
        let registry = CommandRegistry(sources: [index] + sources, commands: commands)

        // The registry builds its snapshot in a task. This waits for it through `onChange`,
        // which the session takes over afterwards. With a store the registry may publish once
        // before the items are in, so the wait is for the snapshot that holds them.
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self)
        registry.onChange = {
            continuation.yield()
        }
        index.yield(items)
        for await _ in changes {
            if registry.snapshot.entries.count == items.count { break }
        }

        let now = now
        let session = SearchSession(registry: registry, usage: usage, now: { now })
        return (session, index)
    }

    /// Searches and waits until the search has ended, so that everything it publishes is in.
    private func search(_ query: String, generation: UInt64, in session: SearchSession) async {
        session.update(query: query, generation: generation)
        await session.searchTask?.value
    }

    private func sectionIDs(of results: SearchResults) -> [String] {
        var ids: [String] = []
        for section in results.sections {
            ids.append(section.id)
        }
        return ids
    }

    /// The titles of the rows in the section with this ID; empty when there is no such section.
    private func titles(in results: SearchResults, section id: String) -> [String] {
        var titles: [String] = []
        for section in results.sections where section.id == id {
            for row in section.rows {
                titles.append(row.item.title)
            }
        }
        return titles
    }

    /// The rows of every section in displayed order, as the launcher hands them to its state.
    private func navigationRows(of results: SearchResults) -> [LauncherState.Row] {
        var rows: [LauncherState.Row] = []
        for section in results.sections {
            for row in section.rows {
                rows.append(LauncherState.Row(row.item))
            }
        }
        return rows
    }

    // MARK: Every search is answered

    @Test func queryIsAnsweredWithTheRankedSectionAndItsGeneration() async throws {
        let (session, _) = await makeSession(items: apps("Safari", "Notes", "Sage"))
        let published = Published(by: session)

        await search("sa", generation: 7, in: session)

        #expect(published.all.count == 1)
        let results = try #require(published.all.first)
        #expect(results.generation == 7)
        #expect(sectionIDs(of: results) == ["results"])
        #expect(results.sections.first?.title == "Results")
        // Both start with the query, and it covers more of the shorter name.
        #expect(titles(in: results, section: "results") == ["Sage", "Safari"])
    }

    @Test func emptyIndexIsAnsweredWithNoSections() async throws {
        let (session, _) = await makeSession(items: [])
        let published = Published(by: session)

        await search("sa", generation: 1, in: session)

        #expect(published.all.count == 1)
        let results = try #require(published.all.first)
        #expect(results.generation == 1)
        #expect(results.sections.isEmpty)
    }

    @Test func queryThatMatchesNothingIsAnsweredWithNoSections() async throws {
        let (session, _) = await makeSession(items: apps("Safari", "Notes"))
        let published = Published(by: session)

        await search("xyz", generation: 3, in: session)

        #expect(published.all.count == 1)
        let results = try #require(published.all.first)
        #expect(results.generation == 3)
        #expect(results.sections.isEmpty)
    }

    @Test func sourceThatThrowsLeavesTheOtherResultsStanding() async throws {
        struct SourceFailure: Error {}
        let failing = QuerySource("failing", latency: .inline) { _ in
            throw SourceFailure()
        }
        let (session, _) = await makeSession(items: apps("Safari"), sources: [failing])
        let published = Published(by: session)

        await search("saf", generation: 1, in: session)

        #expect(published.all.count == 1)
        let results = try #require(published.all.first)
        #expect(sectionIDs(of: results) == ["results"])
        #expect(titles(in: results, section: "results") == ["Safari"])
    }

    @Test func slowUsageStoreDelaysTheAnswerAndDoesNotLoseIt() async throws {
        let gate = Gate()
        let (session, _) = await makeSession(
            items: apps("Safari"), usage: HeldUsageStore(gate: gate))
        let published = Published(by: session)

        session.update(query: "saf", generation: 1)
        await gate.waitForArrival()
        #expect(published.all.isEmpty)

        gate.open()
        await session.searchTask?.value

        #expect(published.all.count == 1)
        let results = try #require(published.all.first)
        #expect(titles(in: results, section: "results") == ["Safari"])
    }

    // A Return pressed ahead of the results acts on the first answer to the query (§4.1.4), so
    // that answer must not go out before the matcher has had its say.
    @Test func firstResultsWaitForTheMatcherPastTheDeadline() async throws {
        var items: [SearchItem] = []
        for number in 1...2_000 {
            items.append(app("Sample App \(number)"))
        }
        let (session, _) = await makeSession(items: items)
        let published = Published(by: session)
        // The deadline has passed before the matcher has looked at the first of the items.
        session.inlineDeadline = .zero

        await search("sample app 1999", generation: 1, in: session)

        #expect(published.all.count == 1)
        let results = try #require(published.all.first)
        #expect(titles(in: results, section: "results") == ["Sample App 1999"])
    }

    // MARK: Cancellation

    @Test func searchThatWasReplacedNeverPublishes() async throws {
        let gate = Gate()
        let (cancellations, cancellationContinuation) = AsyncStream.makeStream(of: Void.self)
        // Holds the search for "s" until it is cancelled, and has nothing for other queries.
        let holding = QuerySource("holding", latency: .inline) { query in
            if query.raw != "s" { return nil }
            await gate.wait()
            if Task.isCancelled {
                cancellationContinuation.yield()
                throw CancellationError()
            }
            return nil
        }
        let (session, _) = await makeSession(items: apps("Safari", "Notes"), sources: [holding])
        let published = Published(by: session)
        // So long that only the source can let the first results out.
        session.inlineDeadline = .seconds(60)

        session.update(query: "s", generation: 1)
        let replacedSearch = try #require(session.searchTask)
        await gate.waitForArrival()
        await search("sa", generation: 2, in: session)

        for await _ in cancellations {
            break
        }
        // Once its task has ended, the first search has had every chance to publish.
        await replacedSearch.value
        #expect(published.all.count == 1)
        let results = try #require(published.all.first)
        #expect(results.generation == 2)
        #expect(titles(in: results, section: "results") == ["Safari"])
    }

    // MARK: Sources

    @Test func firstResultsDoNotWaitForAnInlineSourcePastTheDeadline() async throws {
        let gate = Gate()
        let answer = ScoredItem(item: app("Sample Answer"), quality: 1)
        let late = QuerySource("late", latency: .inline) { _ in
            await gate.wait()
            return [answer]
        }
        let (session, _) = await makeSession(items: apps("Safari"), sources: [late])
        let published = Published(by: session)

        session.update(query: "saf", generation: 4)

        let first = try await published.next()
        #expect(first.generation == 4)
        #expect(sectionIDs(of: first) == ["results"])
        #expect(titles(in: first, section: "results") == ["Safari"])

        gate.open()
        let second = try await published.next()
        #expect(second.generation == 4)
        // Too late for the ranked section, however good its match: it goes below.
        #expect(sectionIDs(of: second) == ["results", "late"])
        #expect(titles(in: second, section: "results") == ["Safari"])
        #expect(titles(in: second, section: "late") == ["Sample Answer"])

        await session.searchTask?.value
        #expect(published.all.count == 2)
    }

    @Test func inlineSourceThatAnswersInTimeIsPartOfTheFirstResults() async throws {
        let ranked = ScoredItem(item: app("Sample Ranked"), quality: 0.6)
        let pinned = ScoredItem(item: app("Sample Pinned"), quality: 0.1, placement: .pinnedTop)
        let inline = QuerySource("inline", latency: .inline) { _ in
            [ranked, pinned]
        }
        let (session, _) = await makeSession(items: apps("Messages", "Safari"), sources: [inline])
        let published = Published(by: session)
        // The source answers at once, so the deadline plays no part.
        session.inlineDeadline = .seconds(60)

        await search("sa", generation: 1, in: session)

        #expect(published.all.count == 1)
        let results = try #require(published.all.first)
        #expect(sectionIDs(of: results) == ["pinned", "results"])
        #expect(results.sections.first?.title == nil)
        #expect(titles(in: results, section: "pinned") == ["Sample Pinned"])
        // By rank: Safari starts with the query, and Messages only has it inside a word.
        #expect(titles(in: results, section: "results") == ["Safari", "Sample Ranked", "Messages"])
    }

    @Test func slowSourceGetsASectionBelowAndTheSelectionStaysWhereItWas() async throws {
        let gate = Gate()
        let webResult = ScoredItem(item: app("Sample Web Result"), quality: 1)
        let slow = QuerySource("web", latency: .slow) { _ in
            await gate.wait()
            return [webResult]
        }
        let (session, _) = await makeSession(items: apps("Safari", "Sage"), sources: [slow])
        let published = Published(by: session)
        // Nothing waits for a slow source, not even with all the time in the world.
        session.inlineDeadline = .seconds(60)

        var state = LauncherState()
        _ = state.apply(.queryChanged("sa"))
        session.update(query: "sa", generation: state.generation)

        let first = try await published.next()
        #expect(sectionIDs(of: first) == ["results"])
        #expect(titles(in: first, section: "results") == ["Sage", "Safari"])
        _ = state.apply(
            .resultsArrived(rows: navigationRows(of: first), generation: first.generation))
        _ = state.apply(.moveSelection(1))
        #expect(state.top.selection == .app(bundleID: "Safari"))

        gate.open()
        let second = try await published.next()
        #expect(second.generation == first.generation)
        #expect(sectionIDs(of: second) == ["results", "web"])
        #expect(second.sections.last?.title == nil)
        #expect(titles(in: second, section: "results") == ["Sage", "Safari"])
        #expect(titles(in: second, section: "web") == ["Sample Web Result"])

        _ = state.apply(
            .resultsArrived(rows: navigationRows(of: second), generation: second.generation))
        #expect(state.top.selection == .app(bundleID: "Safari"))
        #expect(state.top.rows.count == 3)
    }

    @Test func slowSourceWithNothingToAddIsNotPublishedAgain() async throws {
        let slow = QuerySource("web", latency: .slow) { _ in nil }
        let (session, _) = await makeSession(items: apps("Safari"), sources: [slow])
        let published = Published(by: session)

        await search("saf", generation: 1, in: session)

        #expect(published.all.count == 1)
        let results = try #require(published.all.first)
        #expect(sectionIDs(of: results) == ["results"])
    }

    // MARK: Usage

    @Test func emptyQuerySuggestsTheMostUsedItems() async throws {
        let usage = InMemoryUsageStore()
        await usage.record(pick: .app(bundleID: "Notes"), query: "", at: now)
        await usage.record(pick: .app(bundleID: "Notes"), query: "", at: now)
        await usage.record(pick: .app(bundleID: "Safari"), query: "", at: now)
        let (session, _) = await makeSession(items: apps("Mail", "Safari", "Notes"), usage: usage)
        let published = Published(by: session)

        await search("", generation: 1, in: session)

        #expect(published.all.count == 1)
        let results = try #require(published.all.first)
        #expect(sectionIDs(of: results) == ["results"])
        #expect(results.sections.first?.title == "Suggestions")
        #expect(titles(in: results, section: "results") == ["Notes", "Safari"])
    }

    @Test func emptyQuerySuggestsNothingBeforeAnythingWasPicked() async throws {
        let (session, _) = await makeSession(items: apps("Mail", "Safari", "Notes"))
        let published = Published(by: session)

        await search("", generation: 1, in: session)

        #expect(published.all.count == 1)
        let results = try #require(published.all.first)
        #expect(results.sections.isEmpty)
    }

    @Test func pickChangesTheOrderOfTheNextSearch() async throws {
        let usage = InMemoryUsageStore()
        let (session, _) = await makeSession(items: apps("Safari", "Slack"), usage: usage)
        let published = Published(by: session)

        await search("s", generation: 1, in: session)
        let before = try await published.next()
        #expect(titles(in: before, section: "results") == ["Slack", "Safari"])

        for _ in 0..<3 {
            await usage.record(pick: .app(bundleID: "Safari"), query: "saf", at: now)
        }
        await search("s", generation: 2, in: session)
        let after = try await published.next()
        #expect(titles(in: after, section: "results") == ["Safari", "Slack"])
    }

    // MARK: Index changes

    @Test func indexChangeAnswersTheCurrentQueryAgainWithTheSameGeneration() async throws {
        let (session, index) = await makeSession(items: apps("Safari"))
        let published = Published(by: session)

        await search("saf", generation: 5, in: session)
        let before = try await published.next()
        #expect(titles(in: before, section: "results") == ["Safari"])

        index.yield(apps("Safari", "Safari Technology Preview"))
        let after = try await published.next()
        #expect(after.generation == 5)
        #expect(
            titles(in: after, section: "results") == ["Safari", "Safari Technology Preview"])
    }

    // MARK: Survivors

    @Test func extendedQueryFindsWhatAFreshSearchFinds() async throws {
        let items = apps(
            "Safari", "Sage", "Slack", "Disk Safety", "Self Addressed Files", "Messages",
            "System Audio Folder", "Notes")

        let (typingSession, _) = await makeSession(items: items)
        let typingPublished = Published(by: typingSession)
        await search("sa", generation: 1, in: typingSession)
        await search("saf", generation: 2, in: typingSession)

        let (freshSession, _) = await makeSession(items: items)
        let freshPublished = Published(by: freshSession)
        await search("saf", generation: 1, in: freshSession)

        let rowsAfterTyping = try #require(typingPublished.all.last?.sections.first).rows
        let rowsOfFreshSearch = try #require(freshPublished.all.last?.sections.first).rows
        #expect(rowsAfterTyping.count == rowsOfFreshSearch.count)
        #expect(!rowsOfFreshSearch.isEmpty)
        for (typedRow, freshRow) in zip(rowsAfterTyping, rowsOfFreshSearch) {
            #expect(typedRow.item.id == freshRow.item.id)
            #expect(typedRow.quality == freshRow.quality)
            #expect(typedRow.highlights == freshRow.highlights)
        }
    }

    // Survivors only narrow the search for a query that extends the one they came from. The
    // empty field leaves none behind, and a query that starts differently looks at every entry.
    @Test func queryThatDoesNotExtendTheLastOneIsSearchedInTheWholeIndex() async throws {
        let (session, _) = await makeSession(items: apps("Safari", "Notes"))
        let published = Published(by: session)

        await search("", generation: 1, in: session)
        await search("sa", generation: 2, in: session)
        await search("no", generation: 3, in: session)

        try #require(published.all.count == 3)
        #expect(published.all[0].sections.isEmpty)
        #expect(titles(in: published.all[1], section: "results") == ["Safari"])
        #expect(titles(in: published.all[2], section: "results") == ["Notes"])
    }

    @Test func survivorsOfTheOldIndexAreNotUsedOnTheNewOne() async throws {
        let (session, index) = await makeSession(items: apps("Safari"))
        let published = Published(by: session)

        await search("sa", generation: 1, in: session)
        let before = try await published.next()
        #expect(titles(in: before, section: "results") == ["Safari"])

        // The survivors of "sa" name the first entry of the old index. In the new index that is
        // Sage, and Safari has moved to the second place.
        index.yield(apps("Sage", "Safari"))
        let rerun = try await published.next()
        #expect(titles(in: rerun, section: "results") == ["Sage", "Safari"])

        await search("saf", generation: 2, in: session)
        let extended = try await published.next()
        #expect(titles(in: extended, section: "results") == ["Safari"])
    }

    // MARK: Overrides

    private func makeStore() throws -> CommandStore {
        CommandStore(database: try AppDatabase.inMemory())
    }

    @Test func itemWhoseAliasIsTheQueryIsPinnedAboveWhatSourcesPin() async throws {
        let store = try makeStore()
        try await store.setAliases(["s"], for: .app(bundleID: "Notes"))
        let answer = ScoredItem(item: app("Sum"), quality: 1, placement: .pinnedTop)
        let calculator = QuerySource("calculator", latency: .inline) { _ in [answer] }
        let (session, _) = await makeSession(
            items: apps("Safari", "Notes"), sources: [calculator], commands: store)
        let published = Published(by: session)

        await search("s", generation: 1, in: session)

        let results = try #require(published.all.first)
        #expect(sectionIDs(of: results) == ["pinned", "results"])
        #expect(titles(in: results, section: "pinned") == ["Notes", "Sum"])
        // The pinned item is not listed a second time among the ranked rows.
        #expect(titles(in: results, section: "results") == ["Safari"])
    }

    @Test func rowsOfHiddenAndDisabledItemsAreDroppedFromWhatSourcesReturn() async throws {
        let store = try makeStore()
        try await store.updateOverride(for: .app(bundleID: "Sample One")) { override in
            override.hidden = true
        }
        try await store.updateOverride(for: .app(bundleID: "Sample Two")) { override in
            override.disabled = true
        }
        let rows = [
            ScoredItem(item: app("Sample One"), quality: 0.9),
            ScoredItem(item: app("Sample Two"), quality: 0.9, placement: .pinnedTop),
            ScoredItem(item: app("Sample Three"), quality: 0.9),
        ]
        let source = QuerySource("samples", latency: .inline) { _ in rows }
        let (session, _) = await makeSession(
            items: apps("Safari"), sources: [source], commands: store)
        let published = Published(by: session)

        await search("sa", generation: 1, in: session)

        let results = try #require(published.all.first)
        #expect(sectionIDs(of: results) == ["results"])
        #expect(titles(in: results, section: "results").sorted() == ["Safari", "Sample Three"])
    }

    @Test func itemThatAppearsTwiceIsListedOnceWhereItComesFirst() async throws {
        // The source pins an item that the matcher finds as well, as a quicklink's source does.
        let pinned = ScoredItem(item: app("Safari"), quality: 1, placement: .pinnedTop)
        let source = QuerySource("pins", latency: .inline) { _ in [pinned] }
        let (session, _) = await makeSession(items: apps("Safari", "Sage"), sources: [source])
        let published = Published(by: session)

        await search("sa", generation: 1, in: session)

        let results = try #require(published.all.first)
        #expect(titles(in: results, section: "pinned") == ["Safari"])
        #expect(titles(in: results, section: "results") == ["Sage"])
    }

    // MARK: Fallback

    private let askAI = ItemID.command(FeatureID(rawValue: "ai"), "ask")

    private func fallbackRow(_ title: String, id: ItemID? = nil) -> ScoredItem {
        var item = app(title)
        if let id {
            item = SearchItem(id: id, title: title, icon: .symbol("link"), kindLabel: "Command")
        }
        return ScoredItem(item: item, quality: 0, placement: .fallback)
    }

    @Test func fallbackSectionIsShownInTheUsersOrderWhenNothingWasFound() async throws {
        let store = try makeStore()
        try await store.updateFallbackOrder { order in
            order = [
                .app(bundleID: "DuckDuckGo"), .app(bundleID: "Missing"), .app(bundleID: "Google"),
            ]
        }
        let offered = [
            fallbackRow("Google"), fallbackRow("DuckDuckGo"), fallbackRow("Not On The List"),
        ]
        let web = QuerySource("web", latency: .inline) { _ in offered }
        let (session, _) = await makeSession(
            items: apps("Safari"), sources: [web], commands: store)
        let published = Published(by: session)

        await search(" how tall is a giraffe ", generation: 1, in: session)

        let results = try #require(published.all.first)
        #expect(sectionIDs(of: results) == ["fallback"])
        #expect(results.sections.first?.title == "Use “how tall is a giraffe” with")
        #expect(titles(in: results, section: "fallback") == ["DuckDuckGo", "Google"])
    }

    // Right after launch the apps have not been scanned. "Nothing found" then means "not
    // looked yet", and a Return typed that early must not become a web search.
    @Test func fallbackSectionWaitsForTheIndexToBeBuilt() async throws {
        let store = try makeStore()
        try await store.updateFallbackOrder { order in order = [.app(bundleID: "Google")] }
        let offered = [fallbackRow("Google")]
        let web = QuerySource("web", latency: .inline) { _ in offered }
        let index = IndexSource()
        let registry = CommandRegistry(sources: [index, web], commands: store)
        let now = now
        let session = SearchSession(registry: registry, usage: InMemoryUsageStore(), now: { now })
        let published = Published(by: session)

        session.update(query: "saf", generation: 1)
        let beforeTheIndex = try await published.next()
        #expect(beforeTheIndex.sections.isEmpty)

        // The index arrives, and the session searches again for the same query.
        index.yield(apps("Notes"))
        let withTheIndex = try await published.next()
        #expect(sectionIDs(of: withTheIndex) == ["fallback"])
    }

    @Test func fallbackRowsStayAwayWhileSomethingWasFound() async throws {
        let store = try makeStore()
        try await store.updateFallbackOrder { order in order = [.app(bundleID: "Google")] }
        let offered = [fallbackRow("Google")]
        let web = QuerySource("web", latency: .inline) { _ in offered }
        let (session, _) = await makeSession(
            items: apps("Safari"), sources: [web], commands: store)
        let published = Published(by: session)

        await search("saf", generation: 1, in: session)

        let results = try #require(published.all.first)
        #expect(sectionIDs(of: results) == ["results"])
    }

    @Test func emptyFieldHasNoFallbackSection() async throws {
        let store = try makeStore()
        try await store.updateFallbackOrder { order in order = [.app(bundleID: "Google")] }
        let offered = [fallbackRow("Google")]
        let web = QuerySource("web", latency: .inline) { _ in offered }
        let (session, _) = await makeSession(
            items: apps("Safari"), sources: [web], commands: store)
        let published = Published(by: session)

        await search("", generation: 1, in: session)

        let results = try #require(published.all.first)
        #expect(results.sections.isEmpty)
    }

    @Test func askAIGoesFirstWhateverTheListSays() async throws {
        let store = try makeStore()
        try await store.updateFallbackOrder { order in order = [.app(bundleID: "Google")] }
        let offered = [fallbackRow("Google"), fallbackRow("Ask AI", id: askAI)]
        let mixed = QuerySource("mixed", latency: .inline) { _ in offered }
        let (session, _) = await makeSession(
            items: apps("Safari"), sources: [mixed], commands: store)
        let published = Published(by: session)

        await search("zzz", generation: 1, in: session)

        let results = try #require(published.all.first)
        #expect(titles(in: results, section: "fallback") == ["Ask AI", "Google"])
    }

    @Test func disabledItemLeavesTheFallbackSectionButAHiddenOneStays() async throws {
        let store = try makeStore()
        try await store.updateFallbackOrder { order in
            order = [.app(bundleID: "Google"), .app(bundleID: "DuckDuckGo")]
        }
        try await store.updateOverride(for: .app(bundleID: "Google")) { override in
            override.hidden = true
        }
        try await store.updateOverride(for: .app(bundleID: "DuckDuckGo")) { override in
            override.disabled = true
        }
        let offered = [fallbackRow("Google"), fallbackRow("DuckDuckGo")]
        let web = QuerySource("web", latency: .inline) { _ in offered }
        let (session, _) = await makeSession(
            items: apps("Safari"), sources: [web], commands: store)
        let published = Published(by: session)

        await search("zzz", generation: 1, in: session)

        let results = try #require(published.all.first)
        #expect(titles(in: results, section: "fallback") == ["Google"])
    }

    @Test func itemPinnedForTheQueryIsNotRepeatedInTheFallbackSection() async throws {
        let store = try makeStore()
        try await store.updateFallbackOrder { order in
            order = [.app(bundleID: "Google"), .app(bundleID: "DuckDuckGo")]
        }
        let offered = [
            ScoredItem(item: app("Google"), quality: 1, placement: .pinnedTop),
            fallbackRow("Google"), fallbackRow("DuckDuckGo"),
        ]
        let web = QuerySource("web", latency: .inline) { _ in offered }
        let (session, _) = await makeSession(
            items: apps("Safari"), sources: [web], commands: store)
        let published = Published(by: session)

        await search("g giraffes", generation: 1, in: session)

        let results = try #require(published.all.first)
        #expect(sectionIDs(of: results) == ["pinned", "fallback"])
        #expect(titles(in: results, section: "pinned") == ["Google"])
        #expect(titles(in: results, section: "fallback") == ["DuckDuckGo"])
    }

    // MARK: Limits

    @Test func rankedSectionIsCutAtTheRowLimit() async throws {
        var items: [SearchItem] = []
        for number in 1...250 {
            items.append(app("Sample App \(number)"))
        }
        let (session, _) = await makeSession(items: items)
        let published = Published(by: session)

        await search("s", generation: 1, in: session)

        #expect(published.all.count == 1)
        let results = try #require(published.all.first)
        let rows = try #require(results.sections.first).rows
        #expect(rows.count == SearchSession.rankedRowLimit)
        // The best matches are the ones kept: the shortest names cover most of the query.
        #expect(rows.first?.item.title == "Sample App 1")
    }
}
