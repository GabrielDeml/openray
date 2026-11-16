import Foundation
import Testing

@testable import OpenRayCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct SnippetsSettingsModelTests {
    /// 15 November 2026, 09:41 UTC.
    private let clock = TestClock(Date(timeIntervalSince1970: 1_794_735_660))
    private let created = Date(timeIntervalSince1970: 1_790_000_000)

    private func snippet(_ name: String, keyword: String? = nil, body: String = "text") -> Snippet {
        Snippet(name: name, keyword: keyword, body: body, createdAt: created, updatedAt: created)
    }

    private func makeModel(
        holding snippets: [Snippet] = []
    ) async throws -> (model: SnippetsSettingsModel, store: SnippetStore) {
        let store = SnippetStore(database: try AppDatabase.inMemory())
        for snippet in snippets {
            try await store.save(snippet)
        }
        let clock = clock
        let model = SnippetsSettingsModel(
            store: store, now: { clock.now }, locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!)
        return (model, store)
    }

    /// The model hears of every change through the store's stream, a moment after the write.
    private func wait(until condition: () -> Bool) async {
        while !condition() {
            await Task.yield()
        }
    }

    // MARK: The list

    @Test func listFollowsTheStore() async throws {
        let signature = snippet("Signature")
        let (model, store) = try await makeModel(holding: [signature])
        #expect(model.snippets.isEmpty)

        model.start()
        await wait { model.snippets == [signature] }

        let address = snippet("Address")
        try await store.save(address)
        await wait { model.snippets == [address, signature] }

        await model.delete(signature.id)
        await wait { model.snippets == [address] }
        #expect(model.errorMessage == nil)
    }

    @Test func startingTwiceStillFollowsTheStore() async throws {
        let (model, store) = try await makeModel()

        model.start()
        model.start()
        try await store.save(snippet("Signature"))

        await wait { model.snippets.count == 1 }
    }

    // MARK: The editor

    @Test func editorOpensOnTheSnippetItIsGiven() async throws {
        let signature = snippet("Signature", keyword: "sig", body: "Kind regards")
        let (model, _) = try await makeModel()
        #expect(model.draft == nil)

        model.edit(signature)

        #expect(model.draft == signature)
    }

    @Test func editorOpensOnANewSnippetWhenItIsGivenNone() async throws {
        let (model, _) = try await makeModel()

        model.edit(nil)

        let draft = try #require(model.draft)
        #expect(draft.name == "")
        #expect(draft.keyword == nil)
        #expect(draft.body == "")
    }

    // "Edit Snippet…" and "Create Snippet" in the launcher can be run while the editor is
    // open in Settings.
    @Test func openEditorKeepsWhatWasTypedWhenAnotherSnippetIsAskedFor() async throws {
        let signature = snippet("Signature", body: "Kind regards")
        let address = snippet("Address")
        let (model, _) = try await makeModel(holding: [signature, address])
        model.edit(signature)
        model.draft?.body = "All the best"

        model.edit(address)
        model.edit(nil)
        // The stored snippet itself would take the typed text away just the same.
        model.edit(signature)

        #expect(model.draft?.id == signature.id)
        #expect(model.draft?.body == "All the best")
    }

    @Test func editorOpensAgainOnceItWasClosed() async throws {
        let signature = snippet("Signature")
        let address = snippet("Address")
        let (model, _) = try await makeModel()
        model.edit(signature)

        model.cancelEditing()
        model.edit(address)

        #expect(model.draft == address)
    }

    @Test func cancellingClosesTheEditorAndStoresNothing() async throws {
        let (model, store) = try await makeModel()
        model.edit(nil)

        model.cancelEditing()

        #expect(model.draft == nil)
        #expect(try await store.search("").isEmpty)
    }

    @Test func snippetWithoutANameOrWithoutTextCannotBeSaved() async throws {
        let (model, _) = try await makeModel()

        #expect(model.problem(with: snippet("", body: "text")) == "Give the snippet a name.")
        #expect(model.problem(with: snippet("  \n", body: "text")) == "Give the snippet a name.")
        #expect(
            model.problem(with: snippet("Signature", body: ""))
                == "Write the text the snippet pastes.")
        #expect(model.problem(with: snippet("Signature", body: "Kind regards")) == nil)
        // A snippet may well be nothing but a line break.
        #expect(model.problem(with: snippet("Line break", body: "\n")) == nil)
    }

    @Test func snippetWithTwoCursorsCannotBeSaved() async throws {
        let (model, _) = try await makeModel()

        let twoCursors = snippet("Greeting", body: "Hi {cursor}, see {cursor}")
        let oneWrittenOut = snippet("Help", body: "{{cursor}} puts the caret here: {cursor}")

        #expect(model.problem(with: twoCursors) == "A snippet can have {cursor} only once.")
        #expect(model.problem(with: oneWrittenOut) == nil)
    }

    // MARK: Saving

    @Test func newSnippetIsStoredTrimmedAndStampedByTheClock() async throws {
        let (model, store) = try await makeModel()
        model.edit(nil)
        var draft = try #require(model.draft)
        draft.name = "  Signature "
        draft.keyword = " sig "
        draft.body = "Kind regards\n"

        // The editor was open for ten minutes. The snippet is as old as its saving.
        clock.advance(minutes: 10)
        await model.save(draft)

        let stored = try #require(try await store.search("").first)
        #expect(stored.id == draft.id)
        #expect(stored.name == "Signature")
        #expect(stored.keyword == "sig")
        #expect(stored.body == "Kind regards\n")
        #expect(stored.createdAt == clock.now)
        #expect(stored.updatedAt == clock.now)
        #expect(model.draft == nil)
        #expect(model.errorMessage == nil)
    }

    @Test func editedSnippetKeepsItsFirstDateAndGetsANewSecondOne() async throws {
        let signature = snippet("Signature", body: "Kind regards")
        let (model, store) = try await makeModel(holding: [signature])
        model.edit(signature)
        var draft = try #require(model.draft)
        draft.body = "All the best"

        await model.save(draft)

        let stored = try #require(try await store.search("").first)
        #expect(stored.body == "All the best")
        #expect(stored.createdAt == created)
        #expect(stored.updatedAt == clock.now)
        #expect(model.draft == nil)
    }

    @Test func keywordOfAnotherSnippetKeepsTheEditorOpenAndSaysWhy() async throws {
        let signature = snippet("Signature", keyword: "sig")
        let (model, store) = try await makeModel(holding: [signature])
        model.edit(nil)
        // The editor's fields write into the draft, and Save hands it over as it is.
        model.draft?.name = "Second signature"
        model.draft?.keyword = "sig"
        model.draft?.body = "Cheers"
        let typed = try #require(model.draft)

        await model.save(typed)

        #expect(model.errorMessage == "Another snippet already has the keyword “sig”.")
        // What was typed is still in the editor.
        #expect(model.draft == typed)
        #expect(try await store.search("") == [signature])

        // With another keyword it goes through, and the message goes away.
        model.draft?.keyword = "sig2"
        let corrected = try #require(model.draft)
        await model.save(corrected)

        #expect(model.errorMessage == nil)
        #expect(model.draft == nil)
        #expect(try await store.search("").map(\.name) == ["Second signature", "Signature"])
    }

    @Test func closingTheEditorForgetsItsError() async throws {
        let signature = snippet("Signature", keyword: "sig")
        let (model, _) = try await makeModel(holding: [signature])
        model.edit(nil)
        await model.save(snippet("Second", keyword: "sig"))
        #expect(model.errorMessage != nil)

        model.cancelEditing()

        #expect(model.errorMessage == nil)
        #expect(model.draft == nil)
    }

    // MARK: Preview

    @Test func previewShowsWhatWouldBePastedNow() async throws {
        let (model, _) = try await makeModel()
        let reply = snippet(
            "Reply", body: "On {date format=\"yyyy-MM-dd\"} you wrote: {clipboard}{cursor}")

        #expect(model.preview(of: reply) == "On 2026-11-15 you wrote: (what you copied last)")
    }
}
