import Accessibility
import Observation
import OpenRayCore
import SwiftUI

/// What the search bar shows. The model decides it from the screen on top and the action
/// panel; the window applies it.
nonisolated struct SearchBarAppearance: Equatable {
    var placeholder: String
    /// A screen can do without the search field. The bar then shows the screen's title.
    var isFieldHidden: Bool
    /// The title of the screen on top; nil at the root.
    var screenTitle: String?
}

/// What the launcher's model needs from the window around it.
protocol LauncherShell: AnyObject {
    var isLauncherVisible: Bool { get }
    func hide()
    /// Makes the search field first responder with its text selected.
    func focusSearchField()
    func setSearchFieldText(_ text: String)
    func setSearchBar(_ appearance: SearchBarAppearance)
    func openSettings()
    /// New results are in the model and will be drawn at the next display refresh.
    func resultsDidCommit()
    /// The app the launcher was opened over.
    var previousApp: AppRef? { get }
}

/// The only observable state the launcher's views read: the navigation state, the results for
/// the current query and the screens on the stack. Every intent goes through `apply(_:)`, which
/// runs the effects the reducer returns: it hands searches to the `SearchSession`, shows and
/// drops screens, runs actions and records what the user picked.
@Observable
final class LauncherModel {
    /// Asks the list to bring a row into view. `serial` makes two requests for the same row
    /// distinct.
    nonisolated struct ScrollRequest: Equatable {
        let item: ItemID
        let serial: UInt64
    }

    /// A screen on the stack: what its feature built, and the context the two talk through.
    struct ActiveScreen {
        let spec: ScreenSpec
        let context: LauncherScreenContext
    }

    /// One row of the action panel.
    struct ActionPanelRow: Identifiable {
        let id: ActionID
        let title: String
        let icon: IconSource?
        let isDestructive: Bool
        /// The chord that runs the action without the panel; nil for an action without one.
        let shortcut: KeyChord?
        /// Whether Return runs the action while the panel is closed.
        let isPrimary: Bool
    }

    /// An action together with the row it acts on; a screen's own action has no row.
    private struct ActionTarget {
        let action: ActionDescriptor
        let row: ScoredItem?
    }

    private static let rootSearchBar = SearchBarAppearance(
        placeholder: String(localized: "Search for apps and commands…"), isFieldHidden: false,
        screenTitle: nil)

    private(set) var state = LauncherState()
    private(set) var results = SearchResults(sections: [], generation: 0)
    /// One for every frame above root search, in the order of `state.stack`.
    private(set) var screens: [ActiveScreen] = []
    private(set) var scrollRequest: ScrollRequest?
    private(set) var searchBar = LauncherModel.rootSearchBar

    @ObservationIgnored weak var shell: (any LauncherShell)?
    @ObservationIgnored private let search: SearchSession
    @ObservationIgnored private let usage: any UsageStore
    @ObservationIgnored private let screenRegistry: ScreenRegistry
    @ObservationIgnored private let permissions: any PermissionChecking
    @ObservationIgnored private let hud: HUDController
    @ObservationIgnored private let pasteService: PasteService
    @ObservationIgnored private let commandHotKeys: CommandHotKeys
    /// The action that was started last. Esc cancels it while its frame waits for it.
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var announcementTask: Task<Void, Never>?
    /// Whoever asked the confirmation that is up, waiting for the answer.
    @ObservationIgnored private var confirmationAnswer: CheckedContinuation<Bool, Never>?

    /// - Parameter tabFallback: The screen Tab opens from root search for a query whose
    ///   selected row has no Tab target of its own, or nil when no feature takes the query.
    init(
        search: SearchSession, usage: any UsageStore, screenRegistry: ScreenRegistry,
        permissions: any PermissionChecking, hud: HUDController, pasteService: PasteService,
        commandHotKeys: CommandHotKeys, tabFallback: ScreenRequest?
    ) {
        self.search = search
        self.usage = usage
        self.screenRegistry = screenRegistry
        self.permissions = permissions
        self.hud = hud
        self.pasteService = pasteService
        self.commandHotKeys = commandHotKeys
        state.tabFallback = tabFallback
        search.onResults = { [weak self] results in
            self?.receive(results)
        }
    }

    // MARK: What is on screen

    var topScreen: ActiveScreen? { screens.last }

    /// The sections the list shows: those of the list screen on top, or the root results.
    var visibleSections: [ResultSection] {
        topScreen?.context.sections ?? results.sections
    }

    var selectedItem: SearchItem? {
        guard let selection = state.top.selection else { return nil }
        return row(withID: selection)?.item
    }

    private func row(withID id: ItemID) -> ScoredItem? {
        for section in visibleSections {
            for row in section.rows {
                if row.item.id == id { return row }
            }
        }
        return nil
    }

    /// The global hotkeys of commands by item, for the rows that show theirs.
    var hotKeysOfItems: [ItemID: HotKey] {
        commandHotKeys.assignments
    }

    /// The actions that ⌘K lists and that shortcuts run: those of the selected item, or of the
    /// screen on top when it is a custom screen.
    var currentActions: [ActionDescriptor] {
        if let item = selectedItem { return actions(of: item) }
        return topScreen?.context.screenActions ?? []
    }

    /// The item's own actions and, when the item can have a global hotkey, "Set Hotkey…" after
    /// them. Whatever lists or runs an item's actions has to ask here, or the panel would
    /// offer an action that `perform` cannot find.
    ///
    /// On an item with one action of its own, such as a window command, the added action is
    /// the second and so gets ⌘↩ like any second action (`ActionShortcuts`).
    private func actions(of item: SearchItem) -> [ActionDescriptor] {
        var actions = item.actions
        // A row without actions has no action panel, and gets none for this.
        if actions.isEmpty { return actions }
        if let setHotKey = commandHotKeys.settingsAction(for: item.id) {
            actions.append(setHotKey)
        }
        return actions
    }

    /// The shortcuts of the current actions, for `KeyRouter`.
    var currentShortcuts: [KeyChord: ActionID] {
        ActionShortcuts.shortcuts(of: currentActions)
    }

    /// The rows of the open action panel, in the order the reducer holds them.
    var actionPanelRows: [ActionPanelRow] {
        guard let panel = state.actionPanel else { return [] }
        let actions = currentActions

        var rows: [ActionPanelRow] = []
        for id in panel.rows {
            guard let index = actions.firstIndex(where: { $0.id == id }) else { continue }
            let action = actions[index]
            let row = ActionPanelRow(
                id: id, title: action.title, icon: action.icon,
                isDestructive: action.isDestructive,
                shortcut: ActionShortcuts.shortcut(ofActionAt: index, in: actions),
                isPrimary: index == 0)
            rows.append(row)
        }
        return rows
    }

    /// What the list says in place of rows: the current query has been answered with nothing.
    /// nil while there are rows, and while the answer is still on its way.
    var emptyListMessage: String? {
        let noResults = String(localized: "No Results")

        if let context = topScreen?.context {
            let rowsAnswerCurrentQuery = context.answeredQuery == state.top.query
            let hasRows = context.sections.contains { section in !section.rows.isEmpty }
            if !rowsAnswerCurrentQuery || hasRows { return nil }
            // A list screen can say why it is empty: "No snippets yet". When it does not, a
            // text that found nothing gets the same words as at the root, and an empty field
            // gets none.
            if let message = context.emptyMessage { return message }
            return state.top.query.isEmpty ? nil : noResults
        }

        if state.top.query.isEmpty { return nil }
        let resultsAnswerCurrentQuery = results.generation == state.generation
        let foundNothing = resultsAnswerCurrentQuery && results.sections.isEmpty
        return foundNothing ? noResults : nil
    }

    // MARK: Intents

    func apply(_ intent: LauncherIntent) {
        var intent = intent
        if let screen = customScreenTakingKeys, let handleIntent = screen.spec.intentHandler {
            if Self.isOfferedToScreens(intent) && handleIntent(intent) { return }
            // Return that the screen left alone runs the screen's first action, as it runs
            // the first action of a selected item.
            if intent == .performPrimary, let primary = screen.context.screenActions.first {
                intent = .performAction(primary.id)
            }
        }

        let fieldTextBefore = state.searchFieldText
        let depthBefore = state.depth
        let effects = state.apply(intent)

        // The reducer changes the field's text without an effect: Esc clears the query, leaving
        // a screen restores the query below it, and the action panel swaps its filter in and
        // out. The field is written only then, because text an input method is still composing
        // is in the field but not yet in the state, and writing would discard it.
        if state.searchFieldText != fieldTextBefore {
            shell?.setSearchFieldText(state.searchFieldText)
        }
        // After the field is written, so that `.focusSearchField` selects the new text.
        for effect in effects {
            run(effect)
        }

        if state.depth < depthBefore {
            deliverRowsOfTopScreen()
        }
        syncActionPanelRows()
        updateSearchBar()
    }

    /// The custom screen on top, while keys are its to take: not under the action panel or a
    /// confirmation, and not while an action runs.
    private var customScreenTakingKeys: ActiveScreen? {
        guard let screen = topScreen, screen.spec.intentHandler != nil else { return nil }
        let isCovered = state.actionPanel != nil || state.confirmation != nil
        if isCovered || state.top.actionInFlight { return nil }
        return screen
    }

    /// Whether a custom screen gets the first say on the intent. Only what a key press means
    /// is offered. Text changes reach a screen through its `ScreenContext`, and what the app
    /// reports back to the reducer is not a screen's to stop.
    private static func isOfferedToScreens(_ intent: LauncherIntent) -> Bool {
        switch intent {
        case .moveSelection, .activateIndex, .performPrimary, .tabComplete, .back, .escape:
            return true
        case .willShow, .didHide, .queryChanged, .performAction, .toggleActionPanel,
            .openSettings, .push, .resultsArrived, .screenRowsChanged, .actionPanelRowsChanged,
            .askConfirmation, .actionStarted, .actionFinished:
            return false
        }
    }

    private func run(_ effect: LauncherEffect) {
        switch effect {
        case .search(let query, let generation):
            // The session answers every search through `receive(_:)`, with no rows if it found
            // nothing, unless a newer search replaces this one first. The reducer counts on
            // that: a Return pressed ahead of the results waits for them.
            search.update(query: query, generation: generation)
        case .forwardQuery(let text):
            topScreen?.context.receiveSearchText(text)
        case .perform(let action, let item):
            perform(action, on: item)
        case .cancelAction:
            actionTask?.cancel()
        case .showScreen(let request):
            show(request)
        case .popScreen:
            let screen = screens.removeLast()
            screen.context.close()
        case .hide:
            shell?.hide()
        case .focusSearchField:
            // The screens of the last session are gone by now. A field that one of them hid
            // has to be back before it can take the focus.
            updateSearchBar()
            shell?.focusSearchField()
        case .scrollTo(let item):
            let previousSerial = scrollRequest?.serial ?? 0
            scrollRequest = ScrollRequest(item: item, serial: previousSerial + 1)
            announceSelection()
        case .openSettings:
            shell?.openSettings()
        case .answerConfirmation(let answer):
            confirmationAnswer?.resume(returning: answer)
            confirmationAnswer = nil
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

        let rows = Self.rows(of: newResults.sections)
        apply(.resultsArrived(rows: rows, generation: newResults.generation))
        shell?.resultsDidCommit()
    }

    /// The rows of every section in displayed order: the selection moves through all of them.
    private static func rows(of sections: [ResultSection]) -> [LauncherState.Row] {
        var rows: [LauncherState.Row] = []
        for section in sections {
            for row in section.rows {
                rows.append(LauncherState.Row(row.item))
            }
        }
        return rows
    }

    // MARK: Screens

    private func show(_ request: ScreenRequest) {
        // A screen starts with an empty search field, and that is the query its actions see.
        let actionContext = LauncherActionContext(
            query: "", model: self, pasteService: pasteService)
        let context = LauncherScreenContext(
            request: request, model: self, actionContext: actionContext)

        guard let spec = screenRegistry.makeScreen(request, context: context) else {
            // The reducer has pushed a frame for the request already, and `screens` has to
            // keep step with its stack. So a request that nobody answers gets a screen that
            // says so.
            Log.launcher.error(
                """
                No feature has the screen \(request.screen, privacy: .public) of \
                \(request.feature.rawValue, privacy: .public)
                """)
            screens.append(ActiveScreen(spec: .unavailable, context: context))
            return
        }
        screens.append(ActiveScreen(spec: spec, context: context))
        // A list screen usually sets its first rows while it is being built, which is before
        // it was on top.
        deliverRowsOfTopScreen()
    }

    /// Hands the rows of the list screen on top to the reducer. A screen's rows only reach the
    /// reducer while the screen is on top, so this runs for rows that were set when it was
    /// not: before it was pushed, and under the screens that have since been popped.
    private func deliverRowsOfTopScreen() {
        guard let context = topScreen?.context, let query = context.answeredQuery else { return }
        apply(.screenRowsChanged(Self.rows(of: context.sections), query: query))
    }

    private func isOnTop(_ context: LauncherScreenContext) -> Bool {
        topScreen?.context === context
    }

    /// Whether the user is looking at the screen.
    func isShowing(_ context: LauncherScreenContext) -> Bool {
        isOnTop(context) && shell?.isLauncherVisible == true
    }

    func screen(
        _ context: LauncherScreenContext, didAnswer query: String,
        with sections: [ResultSection]
    ) {
        if isOnTop(context) {
            apply(.screenRowsChanged(Self.rows(of: sections), query: query))
        }
    }

    func screenDidSetActions(_ context: LauncherScreenContext) {
        // The panel may be open on the actions that were just replaced.
        if isOnTop(context) {
            syncActionPanelRows()
        }
    }

    func screenDidChangeSearchBar(_ context: LauncherScreenContext) {
        if isOnTop(context) {
            updateSearchBar()
        }
    }

    func screen(_ context: LauncherScreenContext, wantsSearchText text: String) {
        // While the action panel is open the field holds its filter, which is not the
        // screen's to change.
        guard isOnTop(context), state.actionPanel == nil else { return }
        apply(.queryChanged(text))
    }

    private func updateSearchBar() {
        let appearance = currentSearchBar()
        if appearance == searchBar { return }
        searchBar = appearance
        shell?.setSearchBar(appearance)
    }

    private func currentSearchBar() -> SearchBarAppearance {
        let title = topScreen?.spec.title
        // The panel's filter needs the field, also on a screen that hides it.
        if state.actionPanel != nil {
            return SearchBarAppearance(
                placeholder: String(localized: "Search for actions…"), isFieldHidden: false,
                screenTitle: title)
        }
        guard let screen = topScreen else { return Self.rootSearchBar }

        let mode = screen.context.searchBarMode ?? screen.spec.searchBar
        switch mode {
        case .hidden:
            return SearchBarAppearance(placeholder: "", isFieldHidden: true, screenTitle: title)
        case .filter(let placeholder), .input(let placeholder):
            return SearchBarAppearance(
                placeholder: placeholder, isFieldHidden: false, screenTitle: title)
        }
    }

    // MARK: Action panel

    /// Tells the reducer which actions the open panel lists for its filter. The reducer owns
    /// the selection among them; which actions match is decided here, where the actions are.
    private func syncActionPanelRows() {
        guard let panel = state.actionPanel else { return }
        let matching = ActionPanelFilter.actions(currentActions, matching: panel.filter)
        let ids = matching.map(\.id)

        // A new filter clears the panel's selection, and the rows that answer it select their
        // first action. So rows that are the same as before still have to be sent then.
        let needsSelection = panel.selection == nil && !ids.isEmpty
        if ids != panel.rows || needsSelection {
            apply(.actionPanelRowsChanged(ids))
        }
    }

    // MARK: Actions

    private func target(of actionID: ActionID, on itemID: ItemID?) -> ActionTarget? {
        if let itemID {
            guard let row = row(withID: itemID) else { return nil }
            let rowActions = actions(of: row.item)
            guard let action = rowActions.first(where: { $0.id == actionID }) else { return nil }
            return ActionTarget(action: action, row: row)
        }
        // An action without an item belongs to the screen on top.
        let screenActions = topScreen?.context.screenActions ?? []
        guard let action = screenActions.first(where: { $0.id == actionID }) else { return nil }
        return ActionTarget(action: action, row: nil)
    }

    private func perform(_ actionID: ActionID, on itemID: ItemID?) {
        guard let target = target(of: actionID, on: itemID) else { return }
        let query = state.top.query
        let context = LauncherActionContext(
            query: query, model: self, pasteService: pasteService)

        // The frame has to wait for the action before anything here can suspend, so that a
        // second Return does not start it again. That covers the confirmation and the
        // permission check too, which come before the action itself. Applying an intent from
        // inside an effect is fine at this point: the reducer has returned, and `.perform` is
        // the last effect of its list.
        apply(.actionStarted)
        let serial = state.actionSerial

        actionTask = Task {
            // The steps from the confirmation to the outcome are Core's (§4.1.4).
            let ending = await ActionRunner.run(
                target.action, context: context, permissions: permissions
            ) {
                // Picks are counted for the items of root search and of list screens. A
                // screen's own action has no item to count.
                guard let row = target.row else { return }
                // A fallback row was not found by the query. It is handed the query to act
                // on, as a web search or as a question for Quick AI, and that is nothing to
                // learn from and nothing to keep on disk (§4.2.7).
                let isFallbackRow = row.placement == .fallback
                recordPick(of: row.item.id, query: isFallbackRow ? "" : query)
            }

            let outcome: ActionOutcome
            switch ending {
            case .outcome(let actionOutcome):
                outcome = actionOutcome
            case .failure(let error):
                // With the launcher still open. `ActionRunner` has logged the error.
                hud.show(error.localizedDescription)
                outcome = .keepOpen
            }
            apply(.actionFinished(outcome, serial: serial))
            // After the launcher has closed, which is what the outcome asks for. The message
            // is shown even when the outcome came too late to navigate: the action did run.
            if case .showHUD(let text) = outcome {
                hud.show(text)
            }
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

    // MARK: For actions

    /// The context of an action that a command's hotkey started. No frame started it, so it
    /// has no query. It is made here because the paste service is the model's.
    func makeHotKeyActionContext() -> LauncherActionContext {
        LauncherActionContext(query: "", model: self, pasteService: pasteService)
    }

    func showHUD(_ text: String) {
        hud.show(text)
    }

    /// Asks the user in the panel and waits for Return or Esc (§4.1.6).
    func confirm(_ confirmation: Confirmation) async -> Bool {
        // A panel that is not on screen cannot ask, and what cannot be confirmed does not
        // happen.
        guard shell?.isLauncherVisible == true else { return false }

        return await withCheckedContinuation { continuation in
            // In this order: a question that is still up is answered with no by this intent,
            // and that answer belongs to whoever is in `confirmationAnswer` now.
            apply(.askConfirmation(confirmation))
            confirmationAnswer = continuation

            var spoken = confirmation.title
            if let message = confirmation.message {
                spoken += " " + message
            }
            AccessibilityNotification.Announcement(spoken).post()
        }
    }
}

extension ScreenSpec {
    /// What is shown for a request that no feature answers. Esc leaves it like any screen.
    fileprivate static var unavailable: ScreenSpec {
        let message = Text("This screen is not available.")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        return .custom(title: String(localized: "Not Available"), searchBar: .hidden, view: message)
    }
}
