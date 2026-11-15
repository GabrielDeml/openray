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
    /// The app the launcher was opened over.
    var previousApp: AppRef? { get }
}

/// The only observable state the launcher's views read: the navigation state and the results
/// for the current query. Every intent goes through `apply(_:)`, which runs the effects the
/// reducer returns: it hands searches to the `SearchSession`, runs actions and records what
/// the user picked.
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
    @ObservationIgnored private let search: SearchSession
    @ObservationIgnored private let usage: any UsageStore
    /// The action that was started last. Esc cancels it while its frame waits for it.
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var announcementTask: Task<Void, Never>?

    init(search: SearchSession, usage: any UsageStore) {
        self.search = search
        self.usage = usage
        search.onResults = { [weak self] results in
            self?.receive(results)
        }
    }

    var selectedItem: SearchItem? {
        guard let selection = state.top.selection else { return nil }
        return item(withID: selection)
    }

    private func item(withID id: ItemID) -> SearchItem? {
        for section in results.sections {
            for row in section.rows {
                if row.item.id == id { return row.item }
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
            // The session answers every search through `receive(_:)`, with no rows if it found
            // nothing, unless a newer search replaces this one first. The reducer counts on
            // that: a Return pressed ahead of the results waits for them.
            search.update(query: query, generation: generation)
        case .perform(let action, let item):
            perform(action, on: item)
        case .cancelAction:
            actionTask?.cancel()
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
        case .forwardQuery, .showScreen, .popScreen:
            // Unreachable until something can push a screen.
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

    // MARK: Results

    /// Takes what the search session found: the sections for the list, and their rows for the
    /// navigation state.
    private func receive(_ newResults: SearchResults) {
        // Results for a query that has since changed.
        guard newResults.generation == state.generation else { return }
        results = newResults

        // In displayed order, across the sections: the selection moves through all of them.
        var rows: [LauncherState.Row] = []
        for section in newResults.sections {
            for row in section.rows {
                rows.append(LauncherState.Row(row.item))
            }
        }
        apply(.resultsArrived(rows: rows, generation: newResults.generation))
        shell?.resultsDidCommit()
    }

    // MARK: Actions

    private func perform(_ actionID: ActionID, on itemID: ItemID?) {
        // An action without an item belongs to a screen, and there are no screens yet.
        guard let itemID, let item = item(withID: itemID) else { return }
        guard let action = item.actions.first(where: { $0.id == actionID }) else { return }

        // The confirmation view and `PermissionCenter` arrive with milestone 3. Until then an
        // action that asks for either does not run: nothing destructive may go ahead without
        // its confirmation.
        if action.confirmation != nil || !action.requiredPermissions.isEmpty {
            Log.launcher.error(
                """
                Did not run the action \(actionID.rawValue, privacy: .public): it needs a \
                confirmation or a permission, and the launcher cannot ask for either yet
                """)
            return
        }

        let query = state.top.query
        recordPick(of: item.id, query: query)

        // The frame has to wait for the action before anything here can suspend, so that a
        // second Return does not start it again. Applying an intent from inside an effect is
        // fine at this point: the reducer has returned, and `.perform` is the last effect of
        // its list.
        apply(.actionStarted)
        let serial = state.actionSerial
        let context = LauncherActionContext(query: query, shell: shell)

        actionTask = Task {
            let outcome: ActionOutcome
            do {
                outcome = try await action.perform(context)
            } catch {
                // An action that stops because Esc cancelled it has not failed.
                let wasCancelled = error is CancellationError || Task.isCancelled
                if !wasCancelled {
                    // Milestone 3 shows the error's description in the HUD as well, with the
                    // launcher still open. Until then this line is the only trace of a failure,
                    // so the error's domain and code are public. Its description can name a
                    // file and stays private.
                    let nsError = error as NSError
                    Log.launcher.error(
                        """
                        The action \(actionID.rawValue, privacy: .public) failed with \
                        \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public): \
                        \(error)
                        """)
                }
                outcome = .keepOpen
            }
            apply(.actionFinished(outcome, serial: serial))
        }
    }

    /// Counts the pick for ranking (docs/DESIGN.md §4.2.7).
    private func recordPick(of item: ItemID, query: String) {
        let pickedAt = Date()
        Task {
            do {
                try await usage.record(pick: item, query: query, at: pickedAt)
            } catch {
                // Only the write to the database failed. The store has counted the pick in
                // memory, so ranking uses it until the app quits.
                Log.storage.error("Could not store a pick: \(error)")
            }
        }
    }
}
