import Accessibility
import Observation
import OpenRayCore

/// What the launcher's model needs from the window around it.
protocol LauncherShell: AnyObject {
    var isLauncherVisible: Bool { get }
    func hide()
    /// Makes the search field first responder with its text selected.
    func focusSearchField()
    func setSearchFieldText(_ text: String)
    func openSettings()
    /// New results are in the model and will be drawn at the next display refresh.
    func resultsDidCommit()
}

/// The only observable state the launcher's views read: the navigation state and the results
/// for the current query. Every intent goes through `apply(_:)`, which runs the effects the
/// reducer returns.
@Observable
final class LauncherModel {
    /// Asks the list to bring a row into view. `serial` makes two requests for the same row
    /// distinct.
    nonisolated struct ScrollRequest: Equatable {
        let item: ItemID
        let serial: UInt64
    }

    private(set) var state = LauncherState()
    private(set) var results = SearchResults(sections: [], generation: 0)
    private(set) var scrollRequest: ScrollRequest?

    @ObservationIgnored weak var shell: (any LauncherShell)?
    @ObservationIgnored private let source: any SearchSource
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var announcementTask: Task<Void, Never>?

    init(source: any SearchSource) {
        self.source = source
    }

    var selectedItem: SearchItem? {
        guard let selection = state.top.selection else { return nil }
        for section in results.sections {
            for row in section.rows {
                if row.item.id == selection { return row.item }
            }
        }
        return nil
    }

    /// The shortcuts of the selected item's actions, for `KeyRouter`.
    var selectedItemShortcuts: [KeyChord: ActionID] {
        guard let item = selectedItem else { return [:] }
        var shortcuts: [KeyChord: ActionID] = [:]
        for action in item.actions {
            if let shortcut = action.shortcut {
                shortcuts[shortcut] = action.id
            }
        }
        return shortcuts
    }

    /// Whether the current query has been answered with nothing.
    var hasNoResults: Bool {
        let resultsAnswerCurrentQuery = results.generation == state.generation
        return resultsAnswerCurrentQuery && results.sections.isEmpty && !state.top.query.isEmpty
    }

    func apply(_ intent: LauncherIntent) {
        // Opening the action panel hands the search field to the panel's filter, and the
        // overlay that would show the panel does not exist until items have secondary actions.
        if intent == .toggleActionPanel { return }
        let fieldTextBefore = state.searchFieldText
        let effects = state.apply(intent)

        // The reducer changes the field's text without an effect: Esc clears the query, and
        // leaving a screen restores the query below it. The field is written only then, because
        // text an input method is still composing is in the field but not yet in the state, and
        // writing would discard it.
        if state.searchFieldText != fieldTextBefore {
            shell?.setSearchFieldText(state.searchFieldText)
        }
        // After the field is written, so that `.focusSearchField` selects the new text.
        for effect in effects {
            run(effect)
        }
    }

    private func run(_ effect: LauncherEffect) {
        switch effect {
        case .search(let query, let generation):
            startSearch(for: query, generation: generation)
        case .perform:
            // Running an action needs an `ActionContext`, which arrives with the first real
            // source. Until then, choosing a row closes the launcher.
            shell?.hide()
        case .hide:
            shell?.hide()
        case .focusSearchField:
            shell?.focusSearchField()
        case .scrollTo(let item):
            let previousSerial = scrollRequest?.serial ?? 0
            scrollRequest = ScrollRequest(item: item, serial: previousSerial + 1)
            announceSelection()
        case .openSettings:
            shell?.openSettings()
        case .forwardQuery, .showScreen, .popScreen, .cancelAction:
            // Unreachable until something can push a screen or leave an action running.
            break
        }
    }

    /// Tells assistive technologies which row is selected. The search field keeps the keyboard
    /// focus, so they do not notice the selection moving. Waits until the selection has settled:
    /// a held arrow key would otherwise queue an announcement for every row it passes.
    private func announceSelection() {
        announcementTask?.cancel()
        announcementTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // Not once the launcher has gone: the announcement would be spoken over the app the
            // user went to. Results that arrive after that still move the selection.
            guard shell?.isLauncherVisible == true else { return }
            guard let item = selectedItem, let index = state.top.selectedIndex else { return }
            let position = String(
                localized: "\(item.title), \(index + 1) of \(state.top.rows.count)",
                comment: "VoiceOver: the selected result and its position in the list")
            AccessibilityNotification.Announcement(position).post()
        }
    }

    private func startSearch(for query: String, generation: UInt64) {
        searchTask?.cancel()
        searchTask = Task {
            var rows: [ScoredItem] = []
            do {
                rows = try await source.results(for: SearchQuery(query)) ?? []
            } catch {
                // A source that honours cancellation throws when the next search cancels this
                // one. Every search but the last ends that way, so it is not worth logging.
                if !Task.isCancelled {
                    Log.launcher.error("Search failed: \(error)")
                }
            }
            // A search that failed still publishes, with no rows: the reducer waits for an
            // answer to every search. One that was replaced is dropped in `publish`, by its
            // generation.
            publish(rows, generation: generation)
        }
    }

    private func publish(_ rows: [ScoredItem], generation: UInt64) {
        // Results for a query that has since changed.
        guard generation == state.generation else { return }

        // No section rather than an empty one: `hasNoResults` looks at `sections`, and the
        // list would draw the header with nothing under it.
        var sections: [ResultSection] = []
        if !rows.isEmpty {
            let title = String(localized: "Results")
            sections.append(ResultSection(id: "results", title: title, rows: rows))
        }
        results = SearchResults(sections: sections, generation: generation)

        let navigationRows = rows.map { LauncherState.Row($0.item) }
        apply(.resultsArrived(rows: navigationRows, generation: generation))
        shell?.resultsDidCommit()
    }
}
