import Foundation
import Testing

@testable import OpenRayCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct SnippetSearchModelTests {
    private let context = FakeScreenContext(
        request: ScreenRequest(feature: SnippetSource.feature, screen: SnippetSource.searchScreen))
    private let created = Date(timeIntervalSince1970: 1_790_000_000)
    private let noSnippetsYet = "No snippets yet. Add one with Create Snippet."

    private let signature: Snippet
    private let address: Snippet

    init() {
        signature = Snippet(
            name: "Signature", keyword: "sig", body: "Kind regards\nAda", createdAt: created,
            updatedAt: created)
        address = Snippet(
            name: "Address", body: "1 Main St", createdAt: created, updatedAt: created)
    }

    private func makeStore(_ snippets: [Snippet]) async throws -> SnippetStore {
        let store = SnippetStore(database: try AppDatabase.inMemory())
        for snippet in snippets {
            try await store.save(snippet)
        }
        return store
    }

    @discardableResult
    private func makeModel(_ store: SnippetStore) -> SnippetSearchModel {
        let source = SnippetSource(store: store) { _ in }
        let model = SnippetSearchModel(store: store, source: source, context: context)
        context.model = model
        return model
    }

    /// The model answers from tasks of its own, a moment after it was asked.
    private func wait(until condition: () -> Bool) async {
        while !condition() {
            await Task.yield()
        }
    }

    // MARK: Answers

    @Test func emptyFieldIsAnsweredAtOnceAndThenWithEverySnippet() async throws {
        makeModel(try await makeStore([signature, address]))

        // Before the store has been asked: this is what tells the launcher that the screen
        // is a list, so it cannot wait.
        #expect(context.answers.count == 1)
        #expect(context.answers.first?.query == "")
        #expect(context.answers.first?.sections.isEmpty == true)
        #expect(context.answers.first?.emptyMessage == nil)

        await wait { context.answers.last?.itemIDs.count == 2 }

        let answer = try #require(context.answers.last)
        #expect(answer.query == "")
        #expect(answer.itemIDs == [address.itemID, signature.itemID])
        #expect(answer.emptyMessage == nil)
        #expect(answer.sections.count == 1)
        #expect(answer.sections.first?.title == nil)
    }

    @Test func everyTextIsAnsweredWithThatTextNamed() async throws {
        makeModel(try await makeStore([signature, address]))

        await context.typeAndWaitForAnswer("regards")
        #expect(context.answers.last?.itemIDs == [signature.itemID])

        await context.typeAndWaitForAnswer("main")
        #expect(context.answers.last?.itemIDs == [address.itemID])

        // Two letters go another way through the store and are answered all the same.
        await context.typeAndWaitForAnswer("si")
        #expect(context.answers.last?.itemIDs == [signature.itemID])
    }

    @Test func textThatFindsNothingIsAnsweredWithoutRowsAndWithoutAMessage() async throws {
        makeModel(try await makeStore([signature]))

        await context.typeAndWaitForAnswer("nothing like this")

        // No section at all, and the launcher's own "No Results".
        #expect(context.answers.last?.sections.isEmpty == true)
        #expect(context.answers.last?.emptyMessage == nil)
    }

    @Test func textThatComesBackIsAnsweredAgain() async throws {
        makeModel(try await makeStore([signature, address]))

        await context.typeAndWaitForAnswer("sig")
        await context.typeAndWaitForAnswer("")
        #expect(context.answers.last?.itemIDs == [address.itemID, signature.itemID])
        await context.typeAndWaitForAnswer("sig")
        #expect(context.answers.last?.itemIDs == [signature.itemID])
    }

    @Test func rowsCarryTheActionsOfTheSnippet() async throws {
        makeModel(try await makeStore([signature]))
        await wait { context.answers.last?.itemIDs.count == 1 }

        let row = try #require(context.answers.last?.sections.first?.rows.first)
        #expect(row.item.title == "Signature")
        #expect(row.item.actions.map(\.id.rawValue) == ["paste", "copy", "edit", "delete"])
        #expect(row.placement == .ranked)
    }

    @Test func listScreenSetsNoActionsOfItsOwnAndLeavesTheFieldAlone() async throws {
        makeModel(try await makeStore([signature]))
        await context.typeAndWaitForAnswer("sig")

        // Return runs a screen's own actions on custom screens only (§4.1.5).
        #expect(context.screenActions.isEmpty)
        #expect(context.searchText == "sig")
    }

    // MARK: Following the store

    @Test func deletedSnippetLeavesTheListWhileItIsOpen() async throws {
        let store = try await makeStore([signature, address])
        makeModel(store)
        await context.typeAndWaitForAnswer("a")
        #expect(context.answers.last?.itemIDs == [address.itemID, signature.itemID])

        try await store.delete(address.id)
        await wait { context.answers.last?.itemIDs == [signature.itemID] }

        // The text in the field was answered again, not the empty one the screen began with.
        #expect(context.answers.last?.query == "a")
    }

    @Test func snippetSavedInSettingsShowsUpInTheOpenList() async throws {
        let store = try await makeStore([signature])
        makeModel(store)
        await wait { context.answers.last?.itemIDs.count == 1 }

        try await store.save(address)

        await wait { context.answers.last?.itemIDs == [address.itemID, signature.itemID] }
    }

    // MARK: The empty list

    @Test func listWithoutAnySnippetSaysHowToAddOne() async throws {
        let store = try await makeStore([])
        makeModel(store)

        await wait { context.answers.last?.emptyMessage == noSnippetsYet }
        #expect(context.answers.last?.sections.isEmpty == true)

        // Typing does not turn it into "No Results": there is nothing to search.
        await context.typeAndWaitForAnswer("sig")
        #expect(context.answers.last?.emptyMessage == noSnippetsYet)

        try await store.save(signature)
        await wait { context.answers.last?.itemIDs == [signature.itemID] }
        #expect(context.answers.last?.emptyMessage == nil)
    }

    @Test func listSaysSoAgainOnceTheLastSnippetIsDeleted() async throws {
        let store = try await makeStore([signature])
        makeModel(store)
        await wait { context.answers.last?.itemIDs.count == 1 }

        try await store.delete(signature.id)

        await wait { context.answers.last?.emptyMessage == noSnippetsYet }
    }

    // MARK: Detail pane

    @Test func detailPaneIsServedFromTheRowsOnScreen() async throws {
        let model = makeModel(try await makeStore([signature, address]))

        await context.typeAndWaitForAnswer("regards")

        #expect(model.snippet(for: signature.itemID) == signature)
        #expect(model.snippet(for: address.itemID) == nil)
        #expect(model.snippet(for: .snippet(UUID())) == nil)
    }

    // MARK: Lifetime

    @Test func modelGoesAwayWithItsScreen() async throws {
        let store = try await makeStore([signature])
        weak var releasedModel: SnippetSearchModel?
        do {
            let model = makeModel(store)
            releasedModel = model
            await wait { context.answers.last?.itemIDs.count == 1 }
        }

        // The screen was popped: the launcher drops the spec that held the model, and the
        // stream of the search text ends.
        context.close()

        await wait { releasedModel == nil }
    }
}
