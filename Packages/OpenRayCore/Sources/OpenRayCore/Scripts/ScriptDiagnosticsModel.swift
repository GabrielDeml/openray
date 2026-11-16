import Foundation

/// The list screen behind "Script Diagnostics" (docs/DESIGN.md §4.10): the files and folders
/// in the script folders that give no command, each with the reason. Typing narrows the list.
///
/// It shows the problems as they were when the screen was pushed. Every show of the launcher
/// pops the screen, so whoever has put a file right and comes back gets a new list.
@MainActor public final class ScriptDiagnosticsModel {
    private let diagnostics: [ScriptDiagnostic]
    private let host: any ScriptActionHost
    private weak var context: (any ScreenContext)?
    private var following: Task<Void, Never>?

    /// - Parameter diagnostics: What the last scan reported (`ScriptSource.diagnostics`).
    public init(
        diagnostics: [ScriptDiagnostic], host: any ScriptActionHost, context: any ScreenContext
    ) {
        self.diagnostics = diagnostics
        self.host = host
        self.context = context

        // The problems are known at once, so the first answer has them already.
        answer("")

        let textChanges = context.searchTextChanges()
        // The stream ends when the screen is popped, and the task with it.
        following = Task { [weak self] in
            for await text in textChanges {
                self?.answer(text)
            }
        }
    }

    deinit {
        following?.cancel()
    }

    /// The problem a row stands for. The view beside the list asks, to show the sentence
    /// whole: a row has one line for it.
    public func diagnostic(for id: ItemID) -> ScriptDiagnostic? {
        diagnostics.first { Self.itemID(of: $0) == id }
    }

    private func answer(_ text: String) {
        guard let context else { return }
        let foldedFilter = Array(SearchQuery(text).normalized.unicodeScalars)

        // In the order of the scan, which is the order of the folders: the filter is there
        // to shorten the list, not to reorder it.
        var rows: [ScoredItem] = []
        for diagnostic in diagnostics {
            if !foldedFilter.isEmpty && !Self.matches(diagnostic, foldedFilter) { continue }
            rows.append(ScoredItem(item: item(for: diagnostic), quality: 1))
        }
        var sections: [ResultSection] = []
        if !rows.isEmpty {
            sections.append(ResultSection(id: "diagnostics", rows: rows))
        }

        // nil leaves the launcher's "No Results" for a filter that nothing passes.
        var emptyMessage: String?
        if diagnostics.isEmpty {
            emptyMessage = String(
                localized: "No problems in your script folders.", bundle: .module,
                comment:
                    "Shown in the Script Diagnostics list when every file in the script folders is in order."
            )
        }
        context.setSections(sections, answering: text, emptyMessage: emptyMessage)
    }

    /// Whether the filter is found in the name of the file or folder, or in what is wrong
    /// with it.
    private static func matches(
        _ diagnostic: ScriptDiagnostic, _ foldedFilter: [Unicode.Scalar]
    ) -> Bool {
        let name = NormalizedName(diagnostic.name)
        if FuzzyMatcher.match(foldedFilter, in: name) != nil { return true }

        let message = NormalizedName(diagnostic.message)
        return FuzzyMatcher.match(foldedFilter, in: message) != nil
    }

    /// A command of the scripts feature and not `script:<path>`: a pick in this list is
    /// recorded like any other, and it is not a pick of the script the file may become.
    private static func itemID(of diagnostic: ScriptDiagnostic) -> ItemID {
        .command(ScriptSource.feature, "diagnostic.\(diagnostic.path)")
    }

    private func item(for diagnostic: ScriptDiagnostic) -> SearchItem {
        // The same two words, with the same comments, as the rows of file search have.
        let kindLabel: String
        if diagnostic.isFolder {
            kindLabel = String(
                localized: "Folder", bundle: .module,
                comment:
                    "The kind of a search result that is a folder, shown at the end of its row.")
        } else {
            kindLabel = String(
                localized: "File", bundle: .module,
                comment: "The kind of a search result that is a file, shown at the end of its row.")
        }

        var actions: [ActionDescriptor] = []
        // A folder has nothing to edit, so Return shows it in Finder.
        if !diagnostic.isFolder {
            actions.append(ScriptFileActions.openInEditor(diagnostic.path, host: host))
        }
        actions.append(ScriptFileActions.showInFinder(diagnostic.path, host: host))
        actions.append(ScriptFileActions.copyPath(diagnostic.path))

        return SearchItem(
            id: Self.itemID(of: diagnostic), title: diagnostic.name,
            subtitle: diagnostic.message, icon: .symbol("exclamationmark.triangle"),
            kindLabel: kindLabel, actions: actions)
    }
}
