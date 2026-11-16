import Foundation
import Observation

/// What Settings › Snippets shows and changes: the list of snippets and the one in the editor
/// (docs/DESIGN.md §4.9). Snippets are written here and nowhere else, so that the launcher
/// never has to hold a text editor.
@MainActor @Observable public final class SnippetsSettingsModel {
    /// Every snippet, by name, as the store last reported them.
    public private(set) var snippets: [Snippet] = []
    /// The snippet in the editor, as its fields hold it now; nil while the editor is closed.
    /// The pane shows the editor for as long as this is set, which is how "Edit Snippet…" and
    /// "Create Snippet" in the launcher open it. What is typed is kept here and not in the
    /// editor's view, so that it is still there when Settings shows another pane and comes
    /// back.
    public var draft: Snippet?
    /// Why the last change could not be stored.
    public private(set) var errorMessage: String?

    @ObservationIgnored private let store: SnippetStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let timeZone: TimeZone
    /// The draft that `edit(nil)` made and that has not been saved yet.
    @ObservationIgnored private var newDraftID: UUID?
    @ObservationIgnored private var following: Task<Void, Never>?

    /// `locale` and `timeZone` are what the preview renders `{date}` and `{time}` with. Like
    /// those of `SnippetSource`, the defaults follow System Settings.
    ///
    /// - Parameter now: Stamps what is saved, and is the time the preview shows.
    public init(
        store: SnippetStore, now: @escaping @Sendable () -> Date = { Date() },
        locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.store = store
        self.now = now
        self.locale = locale
        self.timeZone = timeZone
    }

    deinit {
        following?.cancel()
    }

    /// Begins to follow the store. The pane calls this every time it appears.
    public func start() {
        if following != nil { return }

        let changes = store.observeAll()
        following = Task { [weak self] in
            do {
                for try await snippets in changes {
                    self?.snippets = snippets
                }
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            // The stream has ended. The next time the pane appears, `start` follows a new one.
            self?.following = nil
        }
    }

    // MARK: The editor

    /// Opens the editor on the snippet, or on a new one for nil. An editor that is already
    /// open stays as it is: the launcher can ask for another snippet while one is being
    /// written, and what was typed must not go without a question.
    public func edit(_ snippet: Snippet?) {
        if draft != nil { return }

        errorMessage = nil
        if let snippet {
            draft = snippet
            return
        }
        let time = now()
        let newSnippet = Snippet(name: "", body: "", createdAt: time, updatedAt: time)
        newDraftID = newSnippet.id
        draft = newSnippet
    }

    /// Closes the editor without saving.
    public func cancelEditing() {
        draft = nil
        errorMessage = nil
    }

    /// What is wrong with a snippet the user is editing, or nil when it can be saved.
    public func problem(with snippet: Snippet) -> String? {
        let name = snippet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return String(
                localized: "Give the snippet a name.", bundle: .module,
                comment: "Shown in the snippet editor while the name is empty.")
        }
        if snippet.body.isEmpty {
            return String(
                localized: "Write the text the snippet pastes.", bundle: .module,
                comment: "Shown in the snippet editor while the text is empty.")
        }
        // The caret can only be left in one place.
        if SnippetRenderer.cursorCount(in: snippet.body) > 1 {
            return String(
                localized: "A snippet can have {cursor} only once.", bundle: .module,
                comment:
                    "Shown in the snippet editor while the text has the placeholder {cursor} more than once. {cursor} is typed as it stands."
            )
        }
        return nil
    }

    /// Stores the snippet and closes the editor. When the store refuses it, because another
    /// snippet has its keyword, the editor stays open on what was typed and `errorMessage`
    /// says why.
    public func save(_ snippet: Snippet) async {
        var stamped = snippet
        stamped.updatedAt = now()
        // A new snippet is as old as its saving, not as the opening of the editor.
        if stamped.id == newDraftID {
            stamped.createdAt = stamped.updatedAt
        }

        do {
            try await store.save(stamped)
            errorMessage = nil
            draft = nil
            newDraftID = nil
        } catch {
            // The editor still holds what was typed. One that was closed while the store was
            // asked stays closed, and has nowhere to show the message.
            if draft != nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func delete(_ id: UUID) async {
        do {
            try await store.delete(id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// What the snippet would paste now, for the editor to show under the text. The clipboard
    /// is not read for a preview; `{clipboard}` shows a stand-in.
    public func preview(of snippet: Snippet) -> String {
        let clipboardStandIn = String(
            localized: "(what you copied last)", bundle: .module,
            comment:
                "Stands in for the clipboard's text in the preview of a snippet that has the placeholder {clipboard}."
        )
        let rendered = SnippetRenderer.render(
            snippet.body, now: now(), locale: locale, timeZone: timeZone,
            clipboard: clipboardStandIn)
        return rendered.text
    }
}
