import Foundation
import Observation

/// The list screen behind "Search Files" (docs/DESIGN.md §4.8): it answers what is typed into
/// the search field with the files of that name, and gives each row its actions.
///
/// This is the screen's half of the list-screen contract of §4.1.5. What it adds to the
/// rules there is patience: a search can take a while and cannot be stopped, so the model
/// waits for the typing to pause and never has two searches running.
@MainActor @Observable public final class FileSearchModel {
    /// How long the field has to rest before its text is searched.
    static let debounceDelay = Duration.milliseconds(120)

    /// Whether the detail pane shows a Quick Look preview of the selected file in place of
    /// what Spotlight says about it. ⌘Y flips it.
    public private(set) var showsPreview = false

    /// The files of the rows on screen, for the detail pane.
    private var shownHits: [FileHit] = []
    /// The text those rows answer.
    @ObservationIgnored private var shownText = ""
    /// Whether they were found by the walk, which gives their section its title.
    @ObservationIgnored private var shownHitsAreWalked = false

    @ObservationIgnored private let search: @Sendable (String) async -> FileSearch.Answer
    @ObservationIgnored private weak var context: (any ScreenContext)?
    @ObservationIgnored private let host: any FileActionHost
    @ObservationIgnored private let homeFolder: String
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    // A search runs synchronously inside Spotlight and cannot be cancelled. So only one runs
    // at a time, and what is typed meanwhile waits here: one text, replaced by any newer one.
    /// The text that is to be searched next, if any.
    @ObservationIgnored private var pendingText: String?
    /// Whether the field has rested long enough on `pendingText`.
    @ObservationIgnored private var pendingTextIsDue = false
    @ObservationIgnored private var isSearching = false

    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var debouncing: Task<Void, Never>?
    @ObservationIgnored private var searching: Task<Void, Never>?

    /// - Parameters:
    ///   - search: Finds the files for a text (`FileSearch.search`).
    ///   - homeFolder: Written as "~" in the folder a row names.
    ///   - sleep: Waits out the pause after a keystroke. Tests pass one they control.
    public init(
        search: @escaping @Sendable (String) async -> FileSearch.Answer,
        context: any ScreenContext, host: any FileActionHost,
        homeFolder: String = NSHomeDirectory(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.search = search
        self.context = context
        self.host = host
        self.homeFolder = homeFolder
        self.sleep = sleep

        // The launcher learns from a screen's first answer that it is a list, and only then
        // does a Return typed ahead of the rows wait for them (§4.1.4).
        context.setSections([], answering: "", emptyMessage: Self.hintMessage)

        let textChanges = context.searchTextChanges()
        // What was typed in root search, when the screen was opened from the fallback row.
        let textToSearch = context.request.argument ?? ""
        // The stream ends when the screen is popped, and the task with it.
        following = Task { [weak self] in
            // From here and not from the initializer: the launcher takes a text only from the
            // screen on top, and this one is not on the stack before it is built (§4.1.5).
            self?.putIntoEmptyField(textToSearch)
            for await text in textChanges {
                self?.textDidChange(text)
            }
        }
    }

    deinit {
        following?.cancel()
        debouncing?.cancel()
        searching?.cancel()
    }

    /// The file of a row on screen. nil for a row that has just gone.
    public func hit(for id: ItemID) -> FileHit? {
        shownHits.first { $0.itemID == id }
    }

    /// The folder the file lies in, as its row and the detail pane write it.
    public func folder(of hit: FileHit) -> String {
        Self.folder(of: hit.path, withHomeAs: homeFolder)
    }

    private func putIntoEmptyField(_ text: String) {
        guard let context, !text.isEmpty else { return }
        // Whatever the user has typed since the screen opened is newer than what it was
        // opened with.
        if context.searchText.isEmpty {
            context.setSearchText(text)
        }
    }

    // MARK: Searching

    private func textDidChange(_ text: String) {
        debouncing?.cancel()
        debouncing = nil

        let hasNothingToSearch = SpotlightQueryBuilder.tokens(of: text).isEmpty
        if hasNothingToSearch {
            // Answered at once, and nothing waits any more. A search that is still running
            // will answer a text the field has left, which the launcher drops.
            pendingText = nil
            pendingTextIsDue = false
            show([], answering: text, emptyMessage: Self.hintMessage)
            return
        }

        pendingText = text
        pendingTextIsDue = false
        let sleep = sleep
        debouncing = Task { [weak self] in
            do {
                try await sleep(Self.debounceDelay)
            } catch {
                return
            }
            // A keystroke can arrive after the pause has ended and before this runs again.
            if Task.isCancelled { return }
            self?.pendingTextIsDue = true
            self?.searchPendingTextIfFree()
        }
    }

    private func searchPendingTextIfFree() {
        guard !isSearching, pendingTextIsDue, let text = pendingText else { return }
        pendingText = nil
        pendingTextIsDue = false
        isSearching = true

        let search = search
        searching = Task { [weak self] in
            let answer = await search(text)
            self?.searchDidEnd(answer, for: text)
        }
    }

    private func searchDidEnd(_ answer: FileSearch.Answer, for text: String) {
        isSearching = false

        switch answer {
        case .found(let hits):
            show(hits, answering: text, emptyMessage: nil)
        case .nothingFound:
            show([], answering: text, emptyMessage: Self.nothingFoundMessage)
        case .spotlightLooksOff:
            show([], answering: text, emptyMessage: Self.spotlightOffMessage)
        case .foundByWalking(let hits):
            show(hits, areWalked: true, answering: text, emptyMessage: Self.nothingFoundMessage)
        }

        // What was typed while Spotlight was busy. If the field has not rested on it yet,
        // the pause that is still running starts the search.
        searchPendingTextIfFree()
    }

    /// Answers `text` with the hits as rows.
    ///
    /// - Parameter emptyMessage: What the list says if there are no hits.
    private func show(
        _ hits: [FileHit], areWalked: Bool = false, answering text: String,
        emptyMessage: String?
    ) {
        guard let context else { return }

        var rows: [ScoredItem] = []
        for hit in hits {
            rows.append(ScoredItem(item: item(for: hit), quality: 1))
        }
        // An answer without rows has no section either, as in root search.
        var sections: [ResultSection] = []
        if !rows.isEmpty {
            let title = areWalked ? Self.walkedSectionTitle : nil
            sections.append(ResultSection(id: "files", title: title, rows: rows))
        }

        // The shell shows the rows only while the field still holds the text they answer,
        // and the detail pane has to describe the rows that are shown.
        if text == context.searchText {
            shownHits = hits
            shownText = text
            shownHitsAreWalked = areWalked
        }
        context.setSections(sections, answering: text, emptyMessage: emptyMessage)
    }

    // MARK: Messages

    private static var hintMessage: String {
        String(
            localized: "Type to search for files by name", bundle: .module,
            comment: "Shown in the list of Search Files while the search field is empty.")
    }

    private static var nothingFoundMessage: String {
        String(
            localized: "No files found", bundle: .module,
            comment: "Shown in the list of Search Files when no file has the name that was typed.")
    }

    private static var spotlightOffMessage: String {
        String(
            localized:
                """
                Spotlight indexing appears to be off.
                To turn it on, run this in Terminal: sudo mdutil -i on /
                Settings › File Search has a slower search that works without it.
                """,
            bundle: .module,
            comment:
                "Shown in the list of Search Files when Spotlight returns nothing at all. The command after the colon is typed as it stands. File Search is the name of a pane of the settings window."
        )
    }

    private static var walkedSectionTitle: String {
        String(
            localized: "Found without Spotlight", bundle: .module,
            comment:
                "The heading over the files that Search Files found by reading folders itself, because Spotlight indexing is off."
        )
    }

    // MARK: Rows

    private func item(for hit: FileHit) -> SearchItem {
        let kindLabel: String
        if hit.isFolder {
            kindLabel = String(
                localized: "Folder", bundle: .module,
                comment:
                    "The kind of a search result that is a folder, shown at the end of its row.")
        } else {
            kindLabel = String(
                localized: "File", bundle: .module,
                comment: "The kind of a search result that is a file, shown at the end of its row.")
        }

        return SearchItem(
            id: hit.itemID, title: hit.name, subtitle: folder(of: hit),
            icon: .file(path: hit.path), kindLabel: kindLabel,
            actions: [
                openAction(for: hit), showInFinderAction(for: hit), openWithAction(for: hit),
                quickLookAction(), copyPathAction(for: hit), moveToTrashAction(for: hit),
            ])
    }

    /// The folder a file lies in, with the home folder written as "~":
    /// `~/Documents/Taxes` for `/Users/ada/Documents/Taxes/2026.pdf`.
    static func folder(of path: String, withHomeAs homeFolder: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        if folder == homeFolder {
            return "~"
        }
        if folder.hasPrefix(homeFolder + "/") {
            return "~" + String(folder.dropFirst(homeFolder.count))
        }
        return folder
    }

    // MARK: Actions

    private func openAction(for hit: FileHit) -> ActionDescriptor {
        let host = host

        return ActionDescriptor(
            id: ActionID(rawValue: "open"), title: ActionTitles.open
        ) { context in
            // The launcher goes first (§4.1.6): the app's window must not come up behind
            // the panel.
            context.closeLauncher()
            try await host.open(hit.url)
            return .closeLauncher
        }
    }

    /// The second action, so ⌘↩ runs it (`ActionShortcuts`).
    private func showInFinderAction(for hit: FileHit) -> ActionDescriptor {
        let host = host

        return ActionDescriptor(
            id: ActionID(rawValue: "show-in-finder"), title: ActionTitles.showInFinder,
            icon: .symbol("folder")
        ) { context in
            context.closeLauncher()
            host.showInFinder(hit.url)
            return .closeLauncher
        }
    }

    private func openWithAction(for hit: FileHit) -> ActionDescriptor {
        let title = String(
            localized: "Open With…", bundle: .module,
            comment: "The action that lists the apps the selected file can be opened with.")
        let appList = ScreenRequest(
            feature: FileSearchSource.feature, screen: FileSearchSource.openWithScreen,
            argument: hit.path)

        return ActionDescriptor(
            id: ActionID(rawValue: "open-with"), title: title,
            icon: .symbol("arrow.up.forward.app")
        ) { _ in
            .push(appList)
        }
    }

    private func quickLookAction() -> ActionDescriptor {
        let title = String(
            localized: "Quick Look", bundle: .module,
            comment:
                "The action that shows a preview of the selected file beside the list, and hides it again."
        )
        let shortcut = KeyChord(keyCode: VirtualKey.ansiY, modifiers: [.command], characters: "y")

        return ActionDescriptor(
            id: ActionID(rawValue: "quick-look"), title: title, icon: .symbol("eye"),
            shortcut: shortcut
        ) { [weak self] _ in
            self?.showsPreview.toggle()
            return .keepOpen
        }
    }

    private func copyPathAction(for hit: FileHit) -> ActionDescriptor {
        // ⌘C alone is Copy in the search field.
        let shortcut = KeyChord(
            keyCode: VirtualKey.ansiC, modifiers: [.command, .shift], characters: "c")

        return ActionDescriptor(
            id: ActionID(rawValue: "copy-path"), title: ActionTitles.copyPath,
            icon: .symbol("doc.on.doc"), shortcut: shortcut
        ) { context in
            context.copy(.text(hit.path, cursorOffsetFromEnd: nil))
            return .copiedToClipboard
        }
    }

    private func moveToTrashAction(for hit: FileHit) -> ActionDescriptor {
        let title = String(
            localized: "Move to Trash", bundle: .module,
            comment:
                "The action that moves the selected file to the Trash. Also the button that confirms it."
        )
        let confirmation = Confirmation(
            title: String(
                localized: "Move “\(hit.name)” to the Trash?", bundle: .module,
                comment:
                    "The title of the confirmation before a file is moved to the Trash. The placeholder is the file's name."
            ),
            confirmTitle: title)
        let shortcut = KeyChord(keyCode: VirtualKey.ansiX, modifiers: [.control], characters: "x")
        let host = host

        return ActionDescriptor(
            id: ActionID(rawValue: "move-to-trash"), title: title, icon: .symbol("trash"),
            shortcut: shortcut, isDestructive: true, confirmation: confirmation
        ) { [weak self] _ in
            try await host.moveToTrash(hit.url)
            Log.files.info("Moved to the Trash: \(hit.path, privacy: .private)")
            self?.removeFromList(hit)
            return .keepOpen
        }
    }

    /// Takes a file that was just moved to the Trash off the list. Spotlight's index learns of
    /// the move a moment later, so searching again now would bring the row back.
    ///
    /// The move can wait on a prompt of macOS, and the list may have moved on by then. A list
    /// that no longer shows the file is left as it is, with whatever message it has.
    private func removeFromList(_ hit: FileHit) {
        let isShown = shownHits.contains { shown in shown.path == hit.path }
        guard isShown else { return }

        var remaining = shownHits
        remaining.removeAll { shown in shown.path == hit.path }
        show(
            remaining, areWalked: shownHitsAreWalked, answering: shownText,
            emptyMessage: Self.nothingFoundMessage)
    }
}
