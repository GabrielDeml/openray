import Foundation
import Observation

/// The list screen behind "Search Snippets" (docs/DESIGN.md §4.9): it answers what is typed
/// into the search field with the snippets whose name, keyword or text contains it.
///
/// This is the screen's half of the list-screen contract of §4.1.5. The shell draws the rows
/// and owns the selection and the keys; the model only says which rows answer which text.
@MainActor @Observable public final class SnippetSearchModel {
    /// The snippets of the rows on screen, for the detail pane.
    private var shownSnippets: [Snippet] = []

    @ObservationIgnored private let store: SnippetStore
    @ObservationIgnored private weak var context: (any ScreenContext)?
    /// Builds the rows, so that a snippet has the same actions here as in root search.
    @ObservationIgnored private let source: SnippetSource
    /// Whether the user has no snippets at all, as the store last reported. The empty list
    /// then says so, whatever is typed.
    @ObservationIgnored private var hasNoSnippets = false
    /// How many answers were started, so that one can tell whether another began after it.
    @ObservationIgnored private var answerCount = 0
    @ObservationIgnored private var followingText: Task<Void, Never>?
    @ObservationIgnored private var followingSnippets: Task<Void, Never>?

    public init(store: SnippetStore, source: SnippetSource, context: any ScreenContext) {
        self.store = store
        self.source = source
        self.context = context

        // The empty field is answered before the store has been asked, with no rows for now.
        // The launcher learns from a screen's first answer that it is a list, and only then
        // does a Return typed ahead of the rows wait for them (§4.1.4).
        context.setSections([], answering: "", emptyMessage: nil)

        let textChanges = context.searchTextChanges()
        // The stream ends when the screen is popped, and the task with it.
        followingText = Task { [weak self] in
            await self?.answer("")
            for await text in textChanges {
                await self?.answer(text)
            }
        }

        let snippetChanges = store.observeAll()
        followingSnippets = Task { [weak self] in
            do {
                for try await snippets in snippetChanges {
                    await self?.snippetsDidChange(isEmpty: snippets.isEmpty)
                }
            } catch {
                // The list stays as it is and still answers what is typed.
                Log.storage.error("Cannot follow the snippets: \(error)")
            }
        }
    }

    deinit {
        followingText?.cancel()
        followingSnippets?.cancel()
    }

    /// The snippet of a row on screen. nil for a row that has just gone.
    public func snippet(for id: ItemID) -> Snippet? {
        shownSnippets.first { $0.itemID == id }
    }

    /// A snippet was deleted here, or saved or deleted in Settings while the list was open:
    /// the text in the field is answered again.
    private func snippetsDidChange(isEmpty: Bool) async {
        hasNoSnippets = isEmpty
        guard let context else { return }
        await answer(context.searchText)
    }

    private func answer(_ text: String) async {
        answerCount += 1
        let thisAnswer = answerCount

        var found: [Snippet] = []
        // nil leaves the launcher's "No Results" for a text that finds nothing.
        var emptyMessage: String?
        do {
            found = try await store.search(text)
            if hasNoSnippets {
                emptyMessage = String(
                    localized: "No snippets yet. Add one with Create Snippet.", bundle: .module,
                    comment:
                        "Shown in the list of snippets while there are none. Create Snippet is the name of a command."
                )
            }
        } catch {
            Log.storage.error("Cannot search the snippets: \(error)")
            emptyMessage = error.localizedDescription
        }
        // Another answer was started while the store was being read, for the next text or
        // for a change to the snippets. It reads the store later than this one did, so its
        // rows are the ones to show.
        if thisAnswer != answerCount { return }
        guard let context else { return }

        var rows: [ScoredItem] = []
        for snippet in found {
            rows.append(ScoredItem(item: source.item(for: snippet), quality: 1))
        }
        // An answer without rows has no section either, as in root search.
        var sections: [ResultSection] = []
        if !rows.isEmpty {
            sections.append(ResultSection(id: "snippets", rows: rows))
        }

        // The shell shows the rows only while the field still holds the text they answer,
        // and the detail pane has to describe the rows that are shown.
        if text == context.searchText {
            shownSnippets = found
        }
        context.setSections(sections, answering: text, emptyMessage: emptyMessage)
    }
}
