import Testing

@testable import OpenRayCore

// The registry publishes from tasks of its own. The tests wait for that through `onChange`,
// never by sleeping; the time limits only stop a test that would otherwise wait forever.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CommandRegistryTests {
    /// A source that yields what the test tells it to, when the test tells it to.
    private final class ManualSource: SearchSource {
        let id: SourceID
        let latency = SourceLatency.inline
        /// Gets an element when the registry stops listening.
        let terminations: AsyncStream<Void>

        private let itemSets: AsyncStream<[SearchItem]>
        private let continuation: AsyncStream<[SearchItem]>.Continuation

        init(_ name: String) {
            id = SourceID(rawValue: name)
            (itemSets, continuation) = AsyncStream.makeStream(of: [SearchItem].self)

            let (terminations, terminationContinuation) = AsyncStream.makeStream(of: Void.self)
            self.terminations = terminations
            continuation.onTermination = { _ in
                terminationContinuation.yield()
            }
        }

        func indexedItems() -> AsyncStream<[SearchItem]> {
            itemSets
        }

        func yield(_ items: [SearchItem]) {
            continuation.yield(items)
        }
    }

    /// A source that keeps the protocol's defaults and so has no indexed items.
    private struct QueryOnlySource: SearchSource {
        let id = SourceID(rawValue: "query-only")
        let latency = SourceLatency.inline
    }

    private func app(_ title: String, id: String) -> SearchItem {
        SearchItem(
            id: .app(bundleID: id), title: title, icon: .symbol("app"), kindLabel: "Application")
    }

    private func titles(in registry: CommandRegistry) -> [String] {
        var titles: [String] = []
        for entry in registry.snapshot.entries {
            titles.append(entry.item.title)
        }
        return titles
    }

    /// One element for every snapshot the registry publishes from now on.
    private func changes(of registry: CommandRegistry) -> AsyncStream<Void> {
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self)
        registry.onChange = {
            continuation.yield()
        }
        return changes
    }

    /// Returns once the registry's snapshot holds exactly these titles.
    private func wait(
        for expectedTitles: [String], in registry: CommandRegistry, changes: AsyncStream<Void>
    ) async {
        for await _ in changes {
            if titles(in: registry) == expectedTitles { return }
        }
    }

    @Test func snapshotIsEmptyBeforeAnySourceHasYielded() {
        let registry = CommandRegistry(sources: [ManualSource("apps")])

        #expect(registry.snapshot.entries.isEmpty)
        #expect(registry.sources.count == 1)
    }

    @Test func yieldedItemsArePublishedInANewSnapshot() async {
        let apps = ManualSource("apps")
        let registry = CommandRegistry(sources: [apps])
        let changes = changes(of: registry)

        apps.yield([app("Safari", id: "com.apple.Safari"), app("Notes", id: "com.apple.Notes")])
        await wait(for: ["Safari", "Notes"], in: registry, changes: changes)

        // The snapshot is ready for matching, not just a list of items.
        let results = await registry.snapshot.rank(
            query: SearchQuery("saf"), usage: UsageSnapshot(), now: .now)
        #expect(results?.rows.first?.scored.item.title == "Safari")
    }

    @Test func newYieldReplacesTheItemsOfItsSourceAndLeavesTheOtherSourcesAlone() async {
        let apps = ManualSource("apps")
        let commands = ManualSource("commands")
        let registry = CommandRegistry(sources: [apps, commands])
        let changes = changes(of: registry)

        apps.yield([app("Safari", id: "com.apple.Safari")])
        commands.yield([app("Sleep", id: "example.sleep")])
        await wait(for: ["Safari", "Sleep"], in: registry, changes: changes)

        apps.yield([app("Notes", id: "com.apple.Notes"), app("Mail", id: "com.apple.mail")])
        await wait(for: ["Notes", "Mail", "Sleep"], in: registry, changes: changes)

        apps.yield([])
        await wait(for: ["Sleep"], in: registry, changes: changes)
    }

    @Test func itemsAreOrderedBySourceWhicheverYieldsFirst() async {
        let apps = ManualSource("apps")
        let commands = ManualSource("commands")
        let registry = CommandRegistry(sources: [apps, commands])
        let changes = changes(of: registry)

        commands.yield([app("Sleep", id: "example.sleep")])
        apps.yield([app("Safari", id: "com.apple.Safari")])
        await wait(for: ["Safari", "Sleep"], in: registry, changes: changes)
    }

    // A snapshot of half the sources would list "Quit Safari" where Safari is about to be.
    @Test func nothingIsPublishedUntilEverySourceHasReported() async {
        let apps = ManualSource("apps")
        let commands = ManualSource("commands")
        let registry = CommandRegistry(sources: [apps, commands])
        var publishedTitles: [[String]] = []
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self)
        registry.onChange = { [weak registry] in
            if let registry {
                publishedTitles.append(registry.snapshot.entries.map(\.item.title))
            }
            continuation.yield()
        }
        #expect(!registry.isReady)

        commands.yield([app("Quit Safari", id: "example.quit")])
        apps.yield([app("Safari", id: "com.apple.Safari")])
        await wait(for: ["Safari", "Quit Safari"], in: registry, changes: changes)

        // The commands were there first, and still no snapshot was made of them alone.
        #expect(publishedTitles == [["Safari", "Quit Safari"]])
        #expect(registry.isReady)
    }

    @Test func ofTwoItemsWithOneIDTheEarlierSourcesItemIsKept() async {
        let first = ManualSource("first")
        let second = ManualSource("second")
        let registry = CommandRegistry(sources: [first, second])
        let changes = changes(of: registry)

        second.yield([app("Safari from the second", id: "com.apple.Safari")])
        first.yield([app("Safari from the first", id: "com.apple.Safari")])
        await wait(for: ["Safari from the first"], in: registry, changes: changes)

        #expect(registry.snapshot.duplicateIDCount == 1)
    }

    @Test func sourceWithoutIndexedItemsAddsNothing() async {
        let apps = ManualSource("apps")
        let registry = CommandRegistry(sources: [QueryOnlySource(), apps])
        let changes = changes(of: registry)

        apps.yield([app("Safari", id: "com.apple.Safari")])
        await wait(for: ["Safari"], in: registry, changes: changes)
    }

    // Building a snapshot takes longer the more items it has, so without care the build for a
    // long list could finish after the build for a short list that was yielded later, and
    // replace it.
    @Test func buildThatWasOvertakenIsNeverPublished() async {
        let apps = ManualSource("apps")
        let registry = CommandRegistry(sources: [apps])
        var publishedCounts: [Int] = []
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self)
        registry.onChange = { [weak registry] in
            if let registry {
                publishedCounts.append(registry.snapshot.entries.count)
            }
            continuation.yield()
        }

        var manyItems: [SearchItem] = []
        for number in 1...2_000 {
            manyItems.append(app("Sample Application \(number)", id: "example.sample.\(number)"))
        }
        apps.yield(manyItems)
        apps.yield([app("Safari", id: "com.apple.Safari")])
        await wait(for: ["Safari"], in: registry, changes: changes)

        // The build for the long list is still running or has just ended. Another one of the
        // same size, started only now, ends after it. So once this one is published, the first
        // has had its chance to publish too.
        manyItems.append(app("Notes", id: "com.apple.Notes"))
        apps.yield(manyItems)
        for await _ in changes {
            if registry.snapshot.entries.count == 2_001 { break }
        }

        #expect(publishedCounts == [1, 2_001])
    }

    // MARK: Overrides

    @Test func registryAppliesTheStoresOverridesAndFollowsItsChanges() async throws {
        let store = CommandStore(database: try AppDatabase.inMemory())
        let safari = ItemID.app(bundleID: "com.apple.Safari")
        try await store.updateOverride(for: safari) { override in override.hidden = true }
        let apps = ManualSource("apps")
        let registry = CommandRegistry(sources: [apps], commands: store)
        let changes = changes(of: registry)

        apps.yield([app("Safari", id: "com.apple.Safari"), app("Notes", id: "com.apple.Notes")])
        await wait(for: ["Notes"], in: registry, changes: changes)

        // What the sources yielded stays available as it came, for Settings.
        #expect(registry.items.map(\.title) == ["Safari", "Notes"])
        #expect(registry.overrides.overrides[safari]?.hidden == true)

        try await store.updateOverride(for: safari) { override in override = ItemOverride() }
        await wait(for: ["Safari", "Notes"], in: registry, changes: changes)

        try await store.setAliases(["web"], for: safari)
        for await _ in changes {
            if registry.overrides.aliases["web"] == safari { break }
        }
        let results = await registry.snapshot.rank(
            query: SearchQuery("web"), usage: UsageSnapshot(), now: .now)
        #expect(results?.rows.first?.scored.placement == .pinnedTop)
    }

    @Test func itemsListsEachIDOnceInSourceOrder() async {
        let apps = ManualSource("apps")
        let commands = ManualSource("commands")
        let registry = CommandRegistry(sources: [apps, commands])
        let changes = changes(of: registry)

        apps.yield([app("Safari", id: "com.apple.Safari")])
        commands.yield([app("Safari Copy", id: "com.apple.Safari"), app("Sleep", id: "sleep")])
        await wait(for: ["Safari", "Sleep"], in: registry, changes: changes)

        #expect(registry.items.map(\.title) == ["Safari", "Sleep"])
    }

    @Test func registryThatGoesAwayStopsListeningToItsSources() async {
        let apps = ManualSource("apps")

        // Nothing holds the registry, so it is gone as soon as it is made.
        _ = CommandRegistry(sources: [apps])

        for await _ in apps.terminations {
            break
        }
    }
}
