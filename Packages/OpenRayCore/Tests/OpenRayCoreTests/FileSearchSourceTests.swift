import Foundation
import Testing

@testable import OpenRayCore

/// Opens nothing. The quicklinks in these tests are only listed.
@MainActor private final class UnusedQuicklinkOpener: QuicklinkOpening {
    func open(_ url: URL, withAppBundleID bundleID: String?) async throws {}
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct FileSearchSourceTests {
    private let source = FileSearchSource()
    private let context = FakeActionContext()
    private let files = FeatureID(rawValue: "files")
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: The command

    @Test func sourceIsInline() {
        #expect(source.id == SourceID(rawValue: "files"))
        #expect(source.latency == .inline)
    }

    @Test func searchFilesIsIndexedOnceAndTheStreamEnds() async throws {
        var itemSets = source.indexedItems().makeAsyncIterator()

        let items = try #require(await itemSets.next())
        // The registry waits for every source to yield or to end, and this one is done.
        #expect(await itemSets.next() == nil)

        #expect(items.count == 1)
        let command = try #require(items.first)
        #expect(command.title == "Search Files")
        #expect(command.kindLabel == "Command")
        #expect(command.alternateNames.map(\.text) == ["Find File", "File Search"])

        // Found by name, it opens the screen with an empty field.
        let screen = ScreenRequest(feature: files, screen: "search")
        let action = try #require(command.actions.first)
        #expect(command.actions.count == 1)
        #expect(try await action.perform(context) == .push(screen))
        #expect(command.tabTarget == screen)
    }

    // A new database has this ID on its fallback list since milestone 3, and stored aliases
    // and picks are keyed by it, so it must not change.
    @Test func commandHasTheIDTheFallbackListWasSeededWith() async throws {
        var itemSets = source.indexedItems().makeAsyncIterator()
        let command = try #require(await itemSets.next()?.first)

        #expect(command.id.rawValue == "command:files.search")
        #expect(command.id == CommandSeeds.searchFiles)
        #expect(command.id == FileSearchSource.searchItemID)
        #expect(FileSearchSource.searchScreen == "search")
        #expect(FileSearchSource.openWithScreen == "openWith")
    }

    // MARK: The fallback row

    @Test func queryGetsAFallbackRowThatTakesItAlong() async throws {
        let rows = try #require(try await source.results(for: SearchQuery("  tax return 2026 ")))

        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.placement == .fallback)
        #expect(row.item.id == CommandSeeds.searchFiles)
        #expect(row.item.title == "Search Files")

        // The text as typed, without the spaces around it.
        let screen = ScreenRequest(feature: files, screen: "search", argument: "tax return 2026")
        let action = try #require(row.item.actions.first)
        #expect(try await action.perform(context) == .push(screen))
        #expect(row.item.tabTarget == screen)
    }

    @Test func blankQueryGetsNoRow() async throws {
        #expect(try await source.results(for: SearchQuery("")) == nil)
        #expect(try await source.results(for: SearchQuery("   ")) == nil)
    }

    // MARK: In root search

    /// Everything a session publishes, for a test to take one by one.
    private func resultsPublished(by session: SearchSession) -> AsyncStream<SearchResults> {
        let (published, continuation) = AsyncStream.makeStream(of: SearchResults.self)
        session.onResults = { results in
            continuation.yield(results)
        }
        return published
    }

    /// Root search over what a new database starts with: the two seeded quicklinks, Quick AI
    /// and file search, with the fallback list as the migration wrote it.
    private func makeSearchSession() throws -> SearchSession {
        let commands = CommandStore(database: try AppDatabase.inMemory())
        let quicklinks = QuicklinkSource(commands: commands, opener: UnusedQuicklinkOpener())
        let now = now
        let aiSession = QuickAISession(
            provider: FakeAIProvider([]),
            preferences: Preferences(store: InMemoryPreferencesStore()), now: { now })
        let registry = CommandRegistry(
            sources: [quicklinks, QuickAISource(session: aiSession), source], commands: commands)
        return SearchSession(registry: registry, usage: InMemoryUsageStore(), now: { now })
    }

    private func titles(in results: SearchResults, section id: String) -> [String] {
        var titles: [String] = []
        for section in results.sections where section.id == id {
            for row in section.rows {
                titles.append(row.item.title)
            }
        }
        return titles
    }

    @Test func searchFilesClosesTheFallbackSectionOfANewInstall() async throws {
        let session = try makeSearchSession()
        let published = resultsPublished(by: session)

        session.update(query: "tax return 2026", generation: 1)

        // The first answer can come before the index is built, and has no fallback rows then.
        for await results in published {
            let fallback = titles(in: results, section: "fallback")
            if fallback.isEmpty { continue }

            #expect(fallback == ["Ask AI", "Google", "DuckDuckGo", "Search Files"])
            #expect(results.sections.map(\.id) == ["fallback"])
            break
        }
    }

    @Test(arguments: ["search fi", "find fi", "file se"])
    func searchFilesIsFoundByItsNameAndByItsKeywords(_ query: String) async throws {
        let session = try makeSearchSession()
        let published = resultsPublished(by: session)

        session.update(query: query, generation: 1)

        for await results in published {
            let found = titles(in: results, section: "results")
            if found.isEmpty { continue }

            #expect(found == ["Search Files"])
            break
        }
    }
}
