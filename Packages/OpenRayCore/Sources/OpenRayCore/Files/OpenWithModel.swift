import Foundation

/// The list screen behind "Open With…" (docs/DESIGN.md §4.8): the apps that can open one
/// file, the default app first. Typing narrows the list, and Return opens the file with the
/// selected app.
@MainActor public final class OpenWithModel {
    private let fileURL: URL
    /// The apps in the order the list shows them.
    private let apps: [OpenWithApp]
    private let host: any FileActionHost
    private weak var context: (any ScreenContext)?
    private var following: Task<Void, Never>?

    /// - Parameter filePath: The file to open, as the screen's request names it.
    public init(filePath: String, host: any FileActionHost, context: any ScreenContext) {
        let fileURL = URL(filePath: filePath)
        self.fileURL = fileURL
        self.host = host
        self.context = context
        apps = Self.sorted(host.appsAbleToOpen(fileURL))

        // The apps are known at once, so the first answer has them already.
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

    /// The default app first, then the others by name, and by path where two have one name.
    private static func sorted(_ apps: [OpenWithApp]) -> [OpenWithApp] {
        apps.sorted { first, second in
            if first.isDefault != second.isDefault { return first.isDefault }

            let nameOrder = first.name.localizedStandardCompare(second.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return first.path < second.path
        }
    }

    private func answer(_ text: String) {
        guard let context else { return }
        let foldedFilter = Array(SearchQuery(text).normalized.unicodeScalars)

        // The matching apps stay in the list's own order, the default app on top: the list
        // is short, and the filter is there to shorten it further, not to reorder it.
        var rows: [ScoredItem] = []
        for app in apps {
            if !foldedFilter.isEmpty {
                let name = NormalizedName(app.name)
                if FuzzyMatcher.match(foldedFilter, in: name) == nil { continue }
            }
            rows.append(ScoredItem(item: item(for: app), quality: 1))
        }
        var sections: [ResultSection] = []
        if !rows.isEmpty {
            sections.append(ResultSection(id: "apps", rows: rows))
        }

        // nil leaves the launcher's "No Results" for a filter that no app passes.
        var emptyMessage: String?
        if apps.isEmpty {
            emptyMessage = String(
                localized: "No app can open this file", bundle: .module,
                comment: "Shown in the Open With list when no app can open the selected file.")
        }
        context.setSections(sections, answering: text, emptyMessage: emptyMessage)
    }

    private func item(for app: OpenWithApp) -> SearchItem {
        let kindLabel = String(
            localized: "Application", bundle: .module,
            comment: "The kind of a search result that is an app, shown at the end of its row.")
        var accessories: [String] = []
        if app.isDefault {
            let defaultLabel = String(
                localized: "Default", bundle: .module,
                comment:
                    "Marks the app in the Open With list that opens the file when no app is chosen."
            )
            accessories.append(defaultLabel)
        }

        let host = host
        let fileURL = fileURL
        let open = ActionDescriptor(
            id: ActionID(rawValue: "open"), title: ActionTitles.open
        ) { context in
            // The app's window must not come up behind the panel (§4.1.6).
            context.closeLauncher()
            try await host.open(fileURL, withAppAt: app.url)
            return .closeLauncher
        }
        // A command of file search and not the app's own item: choosing Preview for one file
        // is not a pick of Preview in root search.
        return SearchItem(
            id: .command(FileSearchSource.feature, "openWith.\(app.path)"), title: app.name,
            icon: .file(path: app.path), kindLabel: kindLabel, accessories: accessories,
            actions: [open])
    }
}
