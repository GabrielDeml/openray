import Foundation
import Testing

@testable import OpenRayCore

/// Stands in for Settings › Snippets: it records which snippet the editor was opened on.
@MainActor private final class FakeSnippetEditor {
    /// One entry for every time the editor was opened; nil is a new snippet.
    private(set) var opened: [Snippet?] = []

    func open(_ snippet: Snippet?) {
        opened.append(snippet)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct SnippetSourceTests {
    private let context = FakeActionContext()
    private let editor = FakeSnippetEditor()
    /// 15 November 2026, 09:41 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_735_660)
    private let created = Date(timeIntervalSince1970: 1_790_000_000)

    private func snippet(_ name: String, keyword: String? = nil, body: String) -> Snippet {
        Snippet(name: name, keyword: keyword, body: body, createdAt: created, updatedAt: created)
    }

    private func makeStore(_ snippets: [Snippet] = []) async throws -> SnippetStore {
        let store = SnippetStore(database: try AppDatabase.inMemory())
        for snippet in snippets {
            try await store.save(snippet)
        }
        return store
    }

    private func makeSource(_ store: SnippetStore) -> SnippetSource {
        let now = now
        let editor = editor
        return SnippetSource(
            store: store, now: { now }, locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!
        ) { snippet in
            editor.open(snippet)
        }
    }

    /// The snippet's row, from a source over a store that holds only this snippet.
    private func item(
        for snippet: Snippet
    ) async throws -> (item: SearchItem, store: SnippetStore) {
        let store = try await makeStore([snippet])
        return (makeSource(store).item(for: snippet), store)
    }

    private func action(_ id: String, of item: SearchItem) throws -> ActionDescriptor {
        try #require(item.actions.first { $0.id == ActionID(rawValue: id) })
    }

    // MARK: Indexed items

    @Test func snippetsAreIndexedAfterTheTwoCommands() async throws {
        let signature = snippet("Signature", keyword: "sig", body: "Kind regards\nAda")
        let address = snippet("Address", body: "1 Main St")
        let source = makeSource(try await makeStore([signature, address]))

        var itemSets = source.indexedItems().makeAsyncIterator()
        let items = try #require(await itemSets.next())

        #expect(
            items.map(\.id.rawValue) == [
                "command:snippets.search",
                "command:snippets.create",
                "snippet:\(address.id.uuidString)",
                "snippet:\(signature.id.uuidString)",
            ])
        #expect(items.map(\.title) == ["Search Snippets", "Create Snippet", "Address", "Signature"])
        #expect(items.map(\.kindLabel) == ["Command", "Command", "Snippet", "Snippet"])
    }

    @Test func indexFollowsTheStore() async throws {
        let store = try await makeStore()
        let source = makeSource(store)
        var itemSets = source.indexedItems().makeAsyncIterator()
        let initial = try #require(await itemSets.next())
        #expect(initial.count == 2)

        let signature = snippet("Signature", body: "Kind regards")
        try await store.save(signature)
        let afterSaving = try #require(await itemSets.next())
        #expect(afterSaving.last?.id == signature.itemID)

        try await store.delete(signature.id)
        let afterDeleting = try #require(await itemSets.next())
        #expect(afterDeleting.count == 2)
    }

    @Test func snippetIsAlsoFoundByItsKeyword() async throws {
        let withKeyword = try await item(for: snippet("Signature", keyword: "sig", body: "x")).item
        let withoutKeyword = try await item(for: snippet("Address", body: "x")).item

        #expect(withKeyword.alternateNames == [.keyword("sig")])
        #expect(withoutKeyword.alternateNames.isEmpty)
    }

    @Test func rowShowsTheBeginningOfTheFirstLineAsItWasWritten() async throws {
        let short = try await item(for: snippet("Signature", body: "Kind regards, {cursor}\nAda"))
        let long = try await item(
            for: snippet("Terms", body: String(repeating: "word ", count: 30)))
        let blankFirstLine = try await item(for: snippet("Padded", body: "\n\nBelow the gap"))

        #expect(short.item.subtitle == "Kind regards, {cursor}")
        #expect(long.item.subtitle == String(repeating: "word ", count: 12) + "…")
        #expect(blankFirstLine.item.subtitle == "Below the gap")
    }

    // MARK: Commands

    @Test func searchSnippetsOpensTheListWithReturnAndWithTab() async throws {
        let source = makeSource(try await makeStore())
        var itemSets = source.indexedItems().makeAsyncIterator()
        let search = try #require(await itemSets.next()?.first)
        let list = ScreenRequest(feature: SnippetSource.feature, screen: SnippetSource.searchScreen)

        #expect(try await search.actions[0].perform(context) == .push(list))
        #expect(search.tabTarget == list)
        #expect(context.calls.isEmpty)
    }

    @Test func createSnippetClosesTheLauncherAndOpensTheEditorOnANewOne() async throws {
        let source = makeSource(try await makeStore())
        var itemSets = source.indexedItems().makeAsyncIterator()
        let items = try #require(await itemSets.next())
        let create = try #require(items.first { $0.id.rawValue == "command:snippets.create" })

        let outcome = try await create.actions[0].perform(context)

        #expect(outcome == .closeLauncher)
        #expect(context.calls == [.closeLauncher])
        #expect(editor.opened == [nil])
        #expect(create.alternateNames == [.keyword("New Snippet")])
    }

    // MARK: Pasting and copying

    @Test func pasteRendersTheSnippetAndLeavesTheCaretWhereItAsks() async throws {
        let greeting = snippet(
            "Greeting", body: "Hi {cursor}, thanks for writing on {date format=\"yyyy-MM-dd\"}.")
        let row = try await item(for: greeting).item

        let outcome = try await action("paste", of: row).perform(context)

        #expect(outcome == .closeLauncher)
        #expect(
            context.pasted == [
                .text("Hi , thanks for writing on 2026-11-15.", cursorOffsetFromEnd: 35)
            ])
        // A snippet that does not ask for the clipboard leaves it unread.
        #expect(context.calls == [.paste])
    }

    @Test func pasteReadsTheClipboardOnlyForASnippetThatAsksAndClosesTheLauncherFirst()
        async throws
    {
        let reply = snippet("Quote", body: "> {clipboard}\n")
        let row = try await item(for: reply).item
        context.clipboard = "what they wrote"

        let outcome = try await action("paste", of: row).perform(context)

        #expect(outcome == .closeLauncher)
        #expect(context.calls == [.closeLauncher, .readClipboard, .paste])
        #expect(context.pasted == [.text("> what they wrote\n", cursorOffsetFromEnd: nil)])
    }

    @Test func clipboardWithoutTextPastesTheRestOfTheSnippet() async throws {
        let row = try await item(for: snippet("Quote", body: "[{clipboard}]")).item
        context.clipboard = nil

        _ = try await action("paste", of: row).perform(context)

        #expect(context.pasted == [.text("[]", cursorOffsetFromEnd: nil)])
        #expect(context.clipboardReadCount == 1)
    }

    @Test func placeholderWrittenOutInDoubledBracesReadsNoClipboard() async throws {
        let row = try await item(for: snippet("Help", body: "Type {{clipboard}} here")).item
        context.clipboard = "secret"

        _ = try await action("paste", of: row).perform(context)

        #expect(context.pasted == [.text("Type {clipboard} here", cursorOffsetFromEnd: nil)])
        #expect(context.clipboardReadCount == 0)
    }

    @Test func copyPutsTheRenderedTextOnTheClipboardAndSaysSo() async throws {
        let row = try await item(for: snippet("Greeting", body: "Hi {cursor}, thanks")).item

        let outcome = try await action("copy", of: row).perform(context)

        #expect(outcome == .copiedToClipboard)
        #expect(context.copied == [.text("Hi , thanks", cursorOffsetFromEnd: nil)])
        #expect(context.calls == [.copy])
    }

    @Test func copyOfASnippetWithTheClipboardReadsItFirst() async throws {
        let row = try await item(for: snippet("Twice", body: "{clipboard} {clipboard}")).item
        context.clipboard = "echo"

        _ = try await action("copy", of: row).perform(context)

        #expect(context.calls == [.closeLauncher, .readClipboard, .copy])
        #expect(context.copied == [.text("echo echo", cursorOffsetFromEnd: nil)])
    }

    // MARK: Editing and deleting

    @Test func editClosesTheLauncherAndHandsTheSnippetToTheEditor() async throws {
        let signature = snippet("Signature", keyword: "sig", body: "Kind regards")
        let row = try await item(for: signature).item

        let outcome = try await action("edit", of: row).perform(context)

        #expect(outcome == .closeLauncher)
        #expect(context.calls == [.closeLauncher])
        #expect(editor.opened == [signature])
    }

    @Test func deleteAsksFirstAndNamesTheSnippet() async throws {
        let row = try await item(for: snippet("Signature", body: "Kind regards")).item

        let delete = try action("delete", of: row)

        #expect(delete.isDestructive)
        #expect(delete.confirmation?.title == "Delete “Signature”?")
        #expect(delete.confirmation?.confirmTitle == "Delete Snippet")
    }

    @Test func deleteRemovesTheSnippetAndLeavesTheLauncherOpen() async throws {
        let signature = snippet("Signature", body: "Kind regards")
        let (row, store) = try await item(for: signature)

        let outcome = try await action("delete", of: row).perform(context)

        #expect(outcome == .keepOpen)
        #expect(try await store.search("").isEmpty)
    }

    @Test func deleteThatIsNotConfirmedDeletesNothing() async throws {
        let signature = snippet("Signature", body: "Kind regards")
        let (row, store) = try await item(for: signature)
        context.confirmationAnswer = false

        _ = await ActionRunner.run(
            try action("delete", of: row), context: context, permissions: FakePermissionChecker()
        ) {}

        #expect(context.confirmations.count == 1)
        #expect(try await store.search("") == [signature])
    }

    // MARK: Shortcuts

    @Test func actionsComeInTheOrderOfTheirKeys() async throws {
        let row = try await item(for: snippet("Signature", body: "Kind regards")).item
        let actions = row.actions

        #expect(actions.map(\.id.rawValue) == ["paste", "copy", "edit", "delete"])
        #expect(
            actions.map(\.title) == [
                "Paste Snippet", "Copy Snippet", "Edit Snippet…", "Delete Snippet",
            ])

        let commandE = KeyChord(keyCode: VirtualKey.ansiE, modifiers: [.command], characters: "e")
        let controlX = KeyChord(keyCode: VirtualKey.ansiX, modifiers: [.control], characters: "x")
        // Return runs the first action; the second gets ⌘↩ without asking for it.
        let commandReturn = ActionShortcuts.secondAction
        #expect(ActionShortcuts.shortcut(ofActionAt: 0, in: actions) == nil)
        #expect(ActionShortcuts.shortcut(ofActionAt: 1, in: actions) == commandReturn)
        #expect(ActionShortcuts.shortcut(ofActionAt: 2, in: actions) == commandE)
        #expect(ActionShortcuts.shortcut(ofActionAt: 3, in: actions) == controlX)
    }

    @Test func noShortcutIsOneTheLauncherKeepsForItself() async throws {
        let row = try await item(for: snippet("Signature", body: "Kind regards")).item

        for action in row.actions {
            guard let shortcut = action.shortcut else { continue }
            #expect(!KeyRouter().reserves(shortcut))
        }
    }
}
