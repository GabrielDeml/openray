import Foundation
import Testing

@testable import OpenRayCore

@Suite(.timeLimit(.minutes(1))) struct SnippetStoreTests {
    private let created = Date(timeIntervalSince1970: 1_790_000_000)
    private let later = Date(timeIntervalSince1970: 1_790_000_600)

    private func makeStore() throws -> SnippetStore {
        SnippetStore(database: try AppDatabase.inMemory())
    }

    private func snippet(
        _ name: String, keyword: String? = nil, body: String = "text", id: UUID = UUID()
    ) -> Snippet {
        Snippet(
            id: id, name: name, keyword: keyword, body: body, createdAt: created,
            updatedAt: created)
    }

    /// The names of what a search finds, in the order it returns them.
    private func names(of query: String, in store: SnippetStore) async throws -> [String] {
        try await store.search(query).map(\.name)
    }

    // MARK: Saving

    @Test func savedSnippetIsReportedToWhoeverFollowsTheStore() async throws {
        let store = try makeStore()
        var snippetSets = store.observeAll().makeAsyncIterator()
        #expect(try await snippetSets.next() == [])

        let signature = snippet("Signature", keyword: "sig", body: "Kind regards\nAda")
        try await store.save(signature)

        #expect(try await snippetSets.next() == [signature])
    }

    @Test func savingAgainChangesTheSnippetAndKeepsWhenItWasCreated() async throws {
        let store = try makeStore()
        let signature = snippet("Signature", keyword: "sig", body: "Kind regards")
        try await store.save(signature)

        var edited = signature
        edited.name = "Sign-off"
        edited.keyword = "bye"
        edited.body = "All the best"
        // An editor that had lost the original date must not be able to change it.
        edited.createdAt = later
        edited.updatedAt = later
        try await store.save(edited)

        let stored = try await store.search("")
        #expect(stored.count == 1)
        #expect(stored.first?.name == "Sign-off")
        #expect(stored.first?.keyword == "bye")
        #expect(stored.first?.body == "All the best")
        #expect(stored.first?.createdAt == created)
        #expect(stored.first?.updatedAt == later)
    }

    @Test func nameIsStoredWithoutTheSpaceAroundItAndTheTextAsItIs() async throws {
        let store = try makeStore()

        try await store.save(snippet("  Address \n", keyword: " home ", body: "  1 Main St\n"))

        let stored = try #require(try await store.search("").first)
        #expect(stored.name == "Address")
        #expect(stored.keyword == "home")
        #expect(stored.body == "  1 Main St\n")
    }

    @Test func blankKeywordIsNoKeywordAndAnyNumberOfSnippetsCanHaveNone() async throws {
        let store = try makeStore()

        try await store.save(snippet("First", keyword: ""))
        try await store.save(snippet("Second", keyword: "   "))
        try await store.save(snippet("Third", keyword: nil))

        let stored = try await store.search("")
        #expect(stored.map(\.name) == ["First", "Second", "Third"])
        #expect(stored.allSatisfy { $0.keyword == nil })
    }

    @Test func keywordOfAnotherSnippetIsRefusedAndNothingIsWritten() async throws {
        let store = try makeStore()
        let signature = snippet("Signature", keyword: "sig")
        try await store.save(signature)

        let second = snippet("Second signature", keyword: "sig")
        await #expect(throws: SnippetStoreError.keywordTaken("sig")) {
            try await store.save(second)
        }
        #expect(try await store.search("") == [signature])

        // Taking the keyword of another snippet by editing is refused the same way, and the
        // snippet stays as it was.
        let address = snippet("Address", keyword: "addr")
        try await store.save(address)
        var renamed = address
        renamed.keyword = "sig"
        await #expect(throws: SnippetStoreError.keywordTaken("sig")) {
            try await store.save(renamed)
        }
        #expect(try await store.search("") == [address, signature])
    }

    @Test func snippetCanBeSavedAgainWithItsOwnKeyword() async throws {
        let store = try makeStore()
        var signature = snippet("Signature", keyword: "sig")
        try await store.save(signature)

        signature.body = "Cheers"
        try await store.save(signature)

        #expect(try await store.search("").map(\.body) == ["Cheers"])
    }

    @Test func keywordErrorNamesTheKeyword() {
        let error = SnippetStoreError.keywordTaken("sig")

        #expect(error.localizedDescription == "Another snippet already has the keyword “sig”.")
    }

    // MARK: Deleting

    @Test func deletingTakesTheAliasAndTheOverrideOfTheItemWithIt() async throws {
        let database = try AppDatabase.inMemory()
        let store = SnippetStore(database: database)
        let commands = CommandStore(database: database)
        let signature = snippet("Signature")
        let address = snippet("Address")
        try await store.save(signature)
        try await store.save(address)
        try await commands.setAliases(["s"], for: signature.itemID)
        try await commands.setAliases(["a"], for: address.itemID)
        try await commands.updateOverride(for: signature.itemID) { override in
            override.hidden = true
        }

        try await store.delete(signature.id)

        #expect(try await store.search("") == [address])
        let overrides = try await commands.snapshot()
        #expect(overrides.aliases == ["a": address.itemID])
        #expect(overrides.overrides.isEmpty)
    }

    @Test func deletingTakesTheHotKeyOfTheItemWithIt() async throws {
        let database = try AppDatabase.inMemory()
        let store = SnippetStore(database: database)
        let hotKeyStore = CommandHotKeyStore(database: database)
        let signature = snippet("Signature")
        let address = snippet("Address")
        let controlOptionS = HotKey(keyCode: 0x01, modifiers: [.control, .option])
        let controlOptionA = HotKey(keyCode: 0x00, modifiers: [.control, .option])
        try await store.save(signature)
        try await store.save(address)
        try await hotKeyStore.set(controlOptionS, for: signature.itemID)
        try await hotKeyStore.set(controlOptionA, for: address.itemID)

        try await store.delete(signature.id)

        #expect(try await hotKeyStore.all() == [address.itemID: controlOptionA])
    }

    @Test func deletingWhatIsNotThereDoesNothing() async throws {
        let store = try makeStore()
        try await store.save(snippet("Signature"))

        try await store.delete(UUID())

        #expect(try await names(of: "", in: store) == ["Signature"])
    }

    // MARK: Searching

    @Test func emptyQueryFindsEverySnippetByName() async throws {
        let store = try makeStore()
        for name in ["Reply 10", "address", "Reply 2", "Zoom link"] {
            try await store.save(snippet(name))
        }

        // Numbers count as numbers, and case does not decide the order.
        let expected = ["address", "Reply 2", "Reply 10", "Zoom link"]
        #expect(try await names(of: "", in: store) == expected)
        #expect(try await names(of: "  \n", in: store) == expected)
    }

    @Test func threeLettersFromTheMiddleOfAWordAreFoundInEveryColumn() async throws {
        let store = try makeStore()
        try await store.save(snippet("Signature", body: "Kind regards"))
        try await store.save(snippet("Address", keyword: "homeward", body: "1 Main St"))
        try await store.save(snippet("Greeting", body: "Welcome aboard"))

        #expect(try await names(of: "gnat", in: store) == ["Signature"])
        #expect(try await names(of: "mew", in: store) == ["Address"])
        #expect(try await names(of: "lcome ab", in: store) == ["Greeting"])
        #expect(try await names(of: "GNAT", in: store) == ["Signature"])
        #expect(try await names(of: "xyz", in: store) == [])
    }

    @Test func indexFollowsAnEdit() async throws {
        let store = try makeStore()
        var greeting = snippet("Greeting", keyword: "hello", body: "Welcome aboard")
        try await store.save(greeting)

        greeting.name = "Farewell"
        greeting.keyword = "later"
        greeting.body = "Safe travels"
        try await store.save(greeting)

        for oldText in ["Greeting", "hello", "Welcome"] {
            #expect(try await names(of: oldText, in: store) == [])
        }
        for newText in ["Farewell", "later", "travels"] {
            #expect(try await names(of: newText, in: store) == ["Farewell"])
        }
    }

    @Test func indexForgetsADeletedSnippet() async throws {
        let store = try makeStore()
        let greeting = snippet("Greeting", keyword: "hello", body: "Welcome aboard")
        try await store.save(greeting)
        try await store.save(snippet("Signature", body: "Kind regards"))

        try await store.delete(greeting.id)

        for text in ["Greeting", "hello", "Welcome"] {
            #expect(try await names(of: text, in: store) == [])
        }
        #expect(try await names(of: "regards", in: store) == ["Signature"])
    }

    @Test(arguments: [
        "say \"hi\"", "\"", "\"\"\"", "a* b", "name:x", "x - y", "^top", "(a)", "a AND b",
        "a OR b", "NOT a", "NEAR(a b)", "{body}", "a\\b", "100%", "a_b",
    ])
    func whatLooksLikeQuerySyntaxIsSearchedForAsText(_ text: String) async throws {
        let store = try makeStore()
        try await store.save(snippet("With it", body: "before \(text) after"))
        try await store.save(snippet("Without it", body: "a b x y top name"))

        #expect(try await names(of: text, in: store) == ["With it"])
    }

    @Test func oneAndTwoLetterQueriesAreFoundWithoutTheIndex() async throws {
        let store = try makeStore()
        try await store.save(snippet("Signature", keyword: "sg", body: "Kind regards"))
        try await store.save(snippet("Address", body: "1 Main St"))
        try await store.save(snippet("Zoom", body: "https://example.com/j/42"))

        #expect(try await names(of: "si", in: store) == ["Signature"])
        #expect(try await names(of: "sg", in: store) == ["Signature"])
        #expect(try await names(of: "42", in: store) == ["Zoom"])
        #expect(try await names(of: "D", in: store) == ["Address", "Signature"])
        #expect(try await names(of: "q", in: store) == [])
    }

    // "är" goes past the index and "ärg" through it. Both have to find the capital Ä.
    @Test func caseOfALetterOutsideASCIIDoesNotCountAtAnyLength() async throws {
        let store = try makeStore()
        try await store.save(snippet("Ärger", body: "Das tut mir leid."))
        try await store.save(snippet("Greeting", body: "Welcome aboard"))

        #expect(try await names(of: "ä", in: store) == ["Ärger"])
        #expect(try await names(of: "är", in: store) == ["Ärger"])
        #expect(try await names(of: "ärg", in: store) == ["Ärger"])
        #expect(try await names(of: "ÄR", in: store) == ["Ärger"])
    }

    @Test func percentAndUnderscoreInAShortQueryMeanThemselves() async throws {
        let store = try makeStore()
        try await store.save(snippet("Discount", body: "5% off"))
        try await store.save(snippet("Variable", body: "user_id"))
        try await store.save(snippet("Path", body: "C:\\Users"))
        try await store.save(snippet("Plain", body: "nothing special"))

        #expect(try await names(of: "%", in: store) == ["Discount"])
        #expect(try await names(of: "_", in: store) == ["Variable"])
        #expect(try await names(of: "\\", in: store) == ["Path"])
        #expect(try await names(of: "r_", in: store) == ["Variable"])
    }

    @Test func matchInTheNameComesBeforeOneInTheKeywordAndOneInTheText() async throws {
        let store = try makeStore()
        try await store.save(snippet("Closing", body: "The invoice is attached."))
        try await store.save(snippet("Billing", keyword: "invoice", body: "Thank you."))
        try await store.save(snippet("Invoice reminder", body: "A friendly reminder."))
        try await store.save(snippet("Unrelated", body: "Nothing to see."))

        #expect(
            try await names(of: "invoice", in: store) == ["Invoice reminder", "Billing", "Closing"])
    }

    // Where the text is decides, not how often it occurs or how short the snippet is.
    @Test func matchInTheNameOfALongSnippetComesBeforeTwoMatchesInAShortText() async throws {
        let store = try makeStore()
        let longBody = String(repeating: "Somewhere on a street in a town. ", count: 12)
        try await store.save(snippet("Address", body: longBody))
        try await store.save(snippet("Reply", body: "address? address!"))

        #expect(try await names(of: "address", in: store) == ["Address", "Reply"])
    }

    @Test func shortQueryIsOrderedByWhereItWasFoundToo() async throws {
        let store = try makeStore()
        try await store.save(snippet("Closing", body: "No reply needed."))
        try await store.save(snippet("Billing", keyword: "no"))
        try await store.save(snippet("Notes", body: "text"))
        try await store.save(snippet("Another note", body: "text"))

        #expect(
            try await names(of: "no", in: store)
                == ["Another note", "Notes", "Billing", "Closing"])
    }
}
