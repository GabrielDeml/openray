import Foundation
import Testing

@testable import OpenRayCore

/// Opens nothing. The quicklinks in these tests are only listed.
@MainActor private final class UnusedQuicklinkOpener: QuicklinkOpening {
    func open(_ url: URL, withAppBundleID bundleID: String?) async throws {}
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct QuickAISourceTests {
    private let context = FakeActionContext()
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private let ai = FeatureID(rawValue: "ai")

    /// A session whose provider answers with `script`.
    private func makeSession(_ script: [FakeAIProvider.Reply] = []) -> QuickAISession {
        let now = now
        return QuickAISession(
            provider: FakeAIProvider(script),
            preferences: Preferences(store: InMemoryPreferencesStore()), now: { now })
    }

    private func rows(for query: String, from source: QuickAISource) async throws -> [ScoredItem] {
        try await source.results(for: SearchQuery(query)) ?? []
    }

    // MARK: The source

    @Test func sourceIsInline() {
        let source = QuickAISource(session: makeSession())

        #expect(source.id == SourceID(rawValue: "ai"))
        #expect(source.latency == .inline)
    }

    // Stored overrides, aliases and usage rows are keyed by these names, so they must not
    // change.
    @Test func chatScreenAndTheAskCommandKeepTheirNames() async throws {
        let source = QuickAISource(session: makeSession())

        #expect(QuickAISource.chatScreenRequest() == ScreenRequest(feature: ai, screen: "chat"))
        #expect(
            QuickAISource.chatScreenRequest(asking: "why?")
                == ScreenRequest(feature: ai, screen: "chat", argument: "why?"))

        let row = try #require(try await rows(for: "why?", from: source).first)
        #expect(row.item.id.rawValue == "command:ai.ask")
        #expect(row.item.id == QuickAISource.askItemID)
    }

    // MARK: Ask AI as a fallback

    @Test func queryIsOfferedToAskAIAsAFallback() async throws {
        let source = QuickAISource(session: makeSession())

        let rows = try await rows(for: "  how tall is a giraffe ", from: source)

        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.placement == .fallback)
        #expect(row.item.id == .command(ai, "ask"))
        #expect(row.item.title == "Ask AI")
        #expect(row.item.kindLabel == "Command")

        // Return and Tab both open the chat with the question, without the space around it.
        let asking = ScreenRequest(feature: ai, screen: "chat", argument: "how tall is a giraffe")
        let action = try #require(row.item.actions.first)
        #expect(row.item.actions.count == 1)
        #expect(try await action.perform(context) == .push(asking))
        #expect(row.item.tabTarget == asking)
    }

    @Test(arguments: ["", "   ", "\n"])
    func blankQueryGetsNoRowsWithoutAThread(_ query: String) async throws {
        let source = QuickAISource(session: makeSession())

        #expect(try await source.results(for: SearchQuery(query)) == nil)
    }

    // MARK: Continue AI chat

    @Test func emptyFieldOffersToContinueALiveThread() async throws {
        let session = makeSession([.answer("Bern.")])
        let source = QuickAISource(session: session)
        session.ask("What is the capital of Switzerland?")
        await waitForEnd(of: session.replyTask)

        let rows = try await rows(for: "", from: source)

        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.placement == .pinnedTop)
        #expect(row.item.id.rawValue == "command:ai.continue")
        #expect(row.item.title == "Continue AI chat")

        // It opens the chat as it is and asks nothing.
        let chat = ScreenRequest(feature: ai, screen: "chat")
        let action = try #require(row.item.actions.first)
        #expect(try await action.perform(context) == .push(chat))
        #expect(row.item.tabTarget == chat)
    }

    @Test func replyThatIsStillArrivingCanBeComeBackTo() async throws {
        let session = makeSession([.open])
        let source = QuickAISource(session: session)
        session.ask("What is the capital of Switzerland?")

        let rows = try await rows(for: " ", from: source)

        #expect(rows.map(\.item.id.rawValue) == ["command:ai.continue"])
    }

    @Test func typedQueryIsNotOfferedTheThread() async throws {
        let session = makeSession([.answer("Bern.")])
        let source = QuickAISource(session: session)
        session.ask("What is the capital of Switzerland?")
        await waitForEnd(of: session.replyTask)

        let rows = try await rows(for: "saf", from: source)

        #expect(rows.map(\.item.id.rawValue) == ["command:ai.ask"])
        #expect(rows.map(\.placement) == [.fallback])
    }

    @Test func threadThatWasEndedIsNotOffered() async throws {
        let session = makeSession([.answer("Bern.")])
        let source = QuickAISource(session: session)
        session.ask("What is the capital of Switzerland?")
        await waitForEnd(of: session.replyTask)

        session.newChat()

        #expect(try await source.results(for: SearchQuery("")) == nil)
    }

    // MARK: Ask AI as a command

    @Test func askAIIsIndexedOnceAndTheStreamEnds() async throws {
        let source = QuickAISource(session: makeSession())
        var itemSets = source.indexedItems().makeAsyncIterator()

        let items = try #require(await itemSets.next())
        // The registry waits for every source to yield or to end, and this one is done.
        #expect(await itemSets.next() == nil)

        #expect(items.count == 1)
        let command = try #require(items.first)
        #expect(command.id == .command(ai, "ask"))
        #expect(command.title == "Ask AI")
        #expect(command.alternateNames.map(\.text) == ["Quick AI", "Chat"])

        // Found by name, it opens the chat without a question.
        let chat = ScreenRequest(feature: ai, screen: "chat")
        let action = try #require(command.actions.first)
        #expect(try await action.perform(context) == .push(chat))
        #expect(command.tabTarget == chat)
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

    /// Root search over the quicklinks a new database starts with and Quick AI.
    private func makeSearchSession() throws -> SearchSession {
        let commands = CommandStore(database: try AppDatabase.inMemory())
        let quicklinks = QuicklinkSource(commands: commands, opener: UnusedQuicklinkOpener())
        let quickAI = QuickAISource(session: makeSession())
        let registry = CommandRegistry(sources: [quicklinks, quickAI], commands: commands)
        let now = now
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

    @Test func askAILeadsTheFallbackSectionWhenASearchFindsNothing() async throws {
        let session = try makeSearchSession()
        let published = resultsPublished(by: session)

        session.update(query: "how tall is a giraffe", generation: 1)

        // The first answer can come before the index is built, and has no fallback rows then.
        for await results in published {
            let fallback = titles(in: results, section: "fallback")
            if fallback.isEmpty { continue }

            #expect(fallback == ["Ask AI", "Google", "DuckDuckGo"])
            #expect(results.sections.map(\.id) == ["fallback"])
            break
        }
    }

    @Test func askAIIsFoundByItsName() async throws {
        let session = try makeSearchSession()
        let published = resultsPublished(by: session)

        session.update(query: "ask", generation: 1)

        for await results in published {
            let found = titles(in: results, section: "results")
            if found.isEmpty { continue }

            #expect(found == ["Ask AI"])
            break
        }
    }
}
