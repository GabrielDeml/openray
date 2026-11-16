import Foundation

/// The snippets in root search (docs/DESIGN.md §4.9): every snippet as an item found by its
/// name and keyword, and the two commands, "Search Snippets" and "Create Snippet".
///
/// The list screen behind "Search Snippets" shows the same items, built by the same function,
/// so a snippet has the same actions wherever it is found.
public struct SnippetSource: SearchSource {
    public static let feature = FeatureID(rawValue: "snippets")
    /// The list screen that searches the snippets' text as well as their names.
    public static let searchScreen = "search"

    public let id = SourceID(rawValue: "snippets")
    public let latency = SourceLatency.inline

    private let store: SnippetStore
    private let now: @Sendable () -> Date
    private let locale: Locale
    private let timeZone: TimeZone
    private let openEditor: @MainActor @Sendable (Snippet?) -> Void

    /// `now`, `locale` and `timeZone` are what `{date}` and `{time}` are rendered with. The
    /// source lives as long as OpenRay runs, so the two defaults are the values that follow
    /// System Settings: a Mac that changes its time zone must not go on pasting the old time.
    ///
    /// - Parameter openEditor: Opens Settings › Snippets with the snippet in its editor, or
    ///   with a new one for nil. It is handed the snippet and not its ID, so that the pane has
    ///   nothing to look up before its own store has reported.
    public init(
        store: SnippetStore, now: @escaping @Sendable () -> Date = { Date() },
        locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent,
        openEditor: @escaping @MainActor @Sendable (Snippet?) -> Void
    ) {
        self.store = store
        self.now = now
        self.locale = locale
        self.timeZone = timeZone
        self.openEditor = openEditor
    }

    // MARK: Indexed items

    public func indexedItems() -> AsyncStream<[SearchItem]> {
        // Every element is the full list, so a consumer that falls behind needs only the newest.
        let (items, continuation) = AsyncStream.makeStream(
            of: [SearchItem].self, bufferingPolicy: .bufferingNewest(1))
        let changes = store.observeAll()

        let following = Task {
            do {
                for try await snippets in changes {
                    var items = [searchCommand(), createCommand()]
                    for snippet in snippets {
                        items.append(item(for: snippet))
                    }
                    continuation.yield(items)
                }
            } catch {
                // The snippets read so far stay in the index.
                Log.storage.error("Cannot read the snippets: \(error)")
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            following.cancel()
        }
        return items
    }

    // MARK: Commands

    private static var commandKindLabel: String {
        String(
            localized: "Command", bundle: .module,
            comment: "The kind of a search result that is a command, shown at the end of its row."
        )
    }

    private func searchCommand() -> SearchItem {
        let title = String(
            localized: "Search Snippets", bundle: .module,
            comment: "The command that opens the list of snippets, which searches their text.")
        let screen = ScreenRequest(feature: Self.feature, screen: Self.searchScreen)
        let open = ActionDescriptor(id: ActionID(rawValue: "search"), title: title) { _ in
            .push(screen)
        }
        return SearchItem(
            id: .command(Self.feature, "search"), title: title,
            icon: .symbol("text.magnifyingglass"), kindLabel: Self.commandKindLabel,
            tabTarget: screen, actions: [open])
    }

    private func createCommand() -> SearchItem {
        let title = String(
            localized: "Create Snippet", bundle: .module,
            comment: "The command that opens Settings with the editor for a new snippet.")
        let keyword = String(
            localized: "New Snippet", bundle: .module,
            comment: "Another name the Create Snippet command is found by.")

        let create = ActionDescriptor(id: ActionID(rawValue: "create"), title: title) { context in
            // Settings is a window outside the panel.
            context.closeLauncher()
            openEditor(nil)
            return .closeLauncher
        }
        return SearchItem(
            id: .command(Self.feature, "create"), title: title,
            alternateNames: [.keyword(keyword)], icon: .symbol("plus.square.on.square"),
            kindLabel: Self.commandKindLabel, actions: [create])
    }

    // MARK: Snippets

    /// How many characters of a snippet's first line its row shows.
    private static let subtitleLength = 60

    /// The snippet as a row, in root search and in the list of "Search Snippets" alike.
    public func item(for snippet: Snippet) -> SearchItem {
        let kindLabel = String(
            localized: "Snippet", bundle: .module,
            comment: "The kind of a search result that is a snippet, shown at the end of its row.")

        var alternateNames: [NameVariant] = []
        if let keyword = snippet.keyword {
            alternateNames.append(.keyword(keyword))
        }
        return SearchItem(
            id: snippet.itemID, title: snippet.name, subtitle: Self.subtitle(of: snippet),
            alternateNames: alternateNames, icon: .symbol("text.quote"), kindLabel: kindLabel,
            actions: [
                pasteAction(for: snippet), copyAction(for: snippet), editAction(for: snippet),
                deleteAction(for: snippet),
            ])
    }

    private static func subtitle(of snippet: Snippet) -> String {
        let firstLine = snippet.firstLine
        if firstLine.count <= subtitleLength {
            return firstLine
        }
        return String(firstLine.prefix(subtitleLength)) + "…"
    }

    private func pasteAction(for snippet: Snippet) -> ActionDescriptor {
        let title = String(
            localized: "Paste Snippet", bundle: .module,
            comment: "The action that pastes the selected snippet into the app the user was in.")

        return ActionDescriptor(id: ActionID(rawValue: "paste"), title: title) { context in
            let rendered = await render(snippet, context: context)
            let content = PasteContent.text(
                rendered.text, cursorOffsetFromEnd: rendered.cursorOffsetFromEnd)
            // When the paste could only copy, the paste service has said so in the HUD.
            _ = await context.paste(content)
            return .closeLauncher
        }
    }

    /// The second action, so ⌘↩ runs it (`ActionShortcuts`).
    private func copyAction(for snippet: Snippet) -> ActionDescriptor {
        let title = String(
            localized: "Copy Snippet", bundle: .module,
            comment: "The action that copies the selected snippet's text to the clipboard.")

        return ActionDescriptor(
            id: ActionID(rawValue: "copy"), title: title, icon: .symbol("doc.on.doc")
        ) { context in
            let rendered = await render(snippet, context: context)
            context.copy(.text(rendered.text, cursorOffsetFromEnd: nil))
            return .copiedToClipboard
        }
    }

    /// The snippet's text as it is pasted or copied at this moment.
    @MainActor private func render(
        _ snippet: Snippet, context: any ActionContext
    ) async -> SnippetRenderer.Rendered {
        var clipboard: String?
        // The clipboard is read for a snippet that asks for it and for no other. macOS may
        // answer the read with its paste alert, a system window that would come up behind the
        // panel, so the launcher goes first (§4.1.6).
        if SnippetRenderer.usesClipboard(snippet.body) {
            context.closeLauncher()
            clipboard = await context.clipboardText()
        }
        return SnippetRenderer.render(
            snippet.body, now: now(), locale: locale, timeZone: timeZone, clipboard: clipboard)
    }

    private func editAction(for snippet: Snippet) -> ActionDescriptor {
        let title = String(
            localized: "Edit Snippet…", bundle: .module,
            comment: "The action that opens Settings with the selected snippet in the editor.")
        let shortcut = KeyChord(keyCode: VirtualKey.ansiE, modifiers: [.command], characters: "e")

        return ActionDescriptor(
            id: ActionID(rawValue: "edit"), title: title, icon: .symbol("pencil"),
            shortcut: shortcut
        ) { context in
            // Settings is a window outside the panel.
            context.closeLauncher()
            openEditor(snippet)
            return .closeLauncher
        }
    }

    private func deleteAction(for snippet: Snippet) -> ActionDescriptor {
        let title = String(
            localized: "Delete Snippet", bundle: .module,
            comment:
                "The action that deletes the selected snippet. Also the button that confirms it."
        )
        let confirmation = Confirmation(
            title: String(
                localized: "Delete “\(snippet.name)”?", bundle: .module,
                comment:
                    "The title of the confirmation before deleting a snippet. The placeholder is the snippet's name."
            ),
            message: String(
                localized: "The snippet is deleted for good.", bundle: .module,
                comment: "The message of the confirmation before deleting a snippet."),
            confirmTitle: title)
        let shortcut = KeyChord(keyCode: VirtualKey.ansiX, modifiers: [.control], characters: "x")

        return ActionDescriptor(
            id: ActionID(rawValue: "delete"), title: title, icon: .symbol("trash"),
            shortcut: shortcut, isDestructive: true, confirmation: confirmation
        ) { _ in
            try await store.delete(snippet.id)
            // The row goes when the store reports the change, in root search and in the list.
            return .keepOpen
        }
    }
}
