/// The launcher's navigation: a stack of frames, each with its own query and selection. Root
/// search is the bottom frame; every other frame is a screen pushed by an action or by Tab.
///
/// The state changes only through `apply(_:)`, which returns what the app must do in response.
public struct LauncherState: Equatable, Sendable {
    /// What navigation needs to know about a displayed row.
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: ItemID
        /// The action Return runs.
        public var primaryAction: ActionID?
        /// The screen Tab opens.
        public var tabTarget: ScreenRequest?

        public init(id: ItemID, primaryAction: ActionID? = nil, tabTarget: ScreenRequest? = nil) {
            self.id = id
            self.primaryAction = primaryAction
            self.tabTarget = tabTarget
        }

        public init(_ item: SearchItem) {
            self.init(id: item.id, primaryAction: item.actions.first?.id, tabTarget: item.tabTarget)
        }
    }

    public struct Frame: Equatable, Sendable {
        /// `nil` for root search.
        public var screen: ScreenRequest?
        public var query: String
        /// The rows in displayed order.
        public var rows: [Row]
        public var selection: ItemID?
        /// The `actionSerial` of the action this frame waits for; `nil` when none is running.
        /// Only the top frame can wait for one, because `push` puts nothing over a frame that
        /// does.
        var runningAction: UInt64?
        /// Set when the query changes and cleared when the rows that answer it arrive. Until
        /// then `rows` still answer the previous query. The rows that answer the query select
        /// their first row, where rows that merely update keep the selection.
        ///
        /// The rows that clear it are known to answer the query: root results by their
        /// generation, a screen's rows by the query they name.
        var waitsForRows = false
        /// Whether rows have ever arrived for this frame. A list screen answers every query and
        /// a custom screen none, and the reducer is not told which kind a screen is. It learns
        /// it here, from the first rows. Always true for root search.
        var answersQueries = false

        public var actionInFlight: Bool { runningAction != nil }

        public var selectedIndex: Int? {
            guard let selection else { return nil }
            return rows.firstIndex { $0.id == selection }
        }

        public var selectedRow: Row? {
            guard let selectedIndex else { return nil }
            return rows[selectedIndex]
        }
    }

    /// The ⌘K panel over the top frame. The app decides which actions match `filter` and
    /// supplies them with `.actionPanelRowsChanged` when the panel opens and when the filter
    /// changes.
    public struct ActionPanelState: Equatable, Sendable {
        /// What the search field holds while the panel is open.
        public var filter: String
        /// The listed actions in displayed order.
        public var rows: [ActionID]
        public var selection: ActionID?

        var selectedIndex: Int? {
            guard let selection else { return nil }
            return rows.firstIndex(of: selection)
        }
    }

    /// Return, ⌘1 to ⌘9 or Tab, pressed before the rows for the query had arrived.
    private enum PendingActivation: Equatable, Sendable {
        /// Return: perform the primary action of the selected row.
        case selectedRow
        /// ⌘1 to ⌘9: select the row at this 1-based position and perform its primary action.
        case row(at: Int)
        /// Tab: open the selected row's Tab target, or the fallback.
        case tab
    }

    /// Never empty; `stack[0]` is root search.
    public private(set) var stack: [Frame]
    /// `nil` while the action panel is closed.
    public private(set) var actionPanel: ActionPanelState?
    /// The question the panel is asking, shown over everything else. While it is up, Return
    /// and Esc answer it and nothing else the user does gets through.
    public private(set) var confirmation: Confirmation?
    /// Identifies the root query that results must answer. The only generation counter in the app.
    public private(set) var generation: UInt64
    /// Numbers the actions started. Its value after `.actionStarted` names that action in
    /// `.actionFinished`, so an outcome that arrives late is never taken for another action's.
    public private(set) var actionSerial: UInt64
    /// What the user asked for while the top frame still showed the rows of its previous query.
    /// It is performed on the rows for the current query when they arrive. `apply(_:)` says
    /// what drops it before then.
    private var pendingActivation: PendingActivation?
    /// The screen Tab opens at the root when the selected item has no Tab target of its own.
    public var tabFallback: ScreenRequest?

    public init() {
        var root = Frame(screen: nil, query: "", rows: [], selection: nil)
        root.answersQueries = true
        stack = [root]
        actionPanel = nil
        confirmation = nil
        generation = 0
        actionSerial = 0
        pendingActivation = nil
        tabFallback = nil
    }

    public var top: Frame { stack[topIndex] }

    /// How many screens are pushed; 0 is root search.
    public var depth: Int { topIndex }

    /// What the search field shows: the action panel's filter while the panel is open, otherwise
    /// the top frame's query.
    public var searchFieldText: String { actionPanel?.filter ?? top.query }

    private var topIndex: Int { stack.count - 1 }

    /// Whether the top frame still shows the rows of its previous query. Return, ⌘1 to ⌘9 and
    /// Tab then wait for the rows that answer the current one (`pendingActivation`). An item's
    /// shortcut and the action panel are ignored, because they name actions of the row that is
    /// on its way out.
    ///
    /// Root search and list screens answer every query. A custom screen is sent its queries
    /// too but has no rows to answer with, so it never counts as waiting.
    private var topAwaitsRows: Bool { top.waitsForRows && top.answersQueries }

    public mutating func apply(_ intent: LauncherIntent) -> [LauncherEffect] {
        guard confirmation != nil else { return applyToLauncher(intent) }

        // A confirmation is up. The two groups without an effect of their own are written out,
        // without a `default`, so that a new intent has to be put in one of them.
        switch intent {
        case .performPrimary:
            return answerConfirmation(true)
        case .escape:
            return answerConfirmation(false)
        case .willShow, .didHide, .askConfirmation:
            // The question goes away unanswered: the panel is gone, comes up fresh, or asks
            // something else. That counts as no, and then the intent does what it always does.
            return answerConfirmation(false) + applyToLauncher(intent)
        case .moveSelection, .activateIndex, .performAction, .tabComplete, .toggleActionPanel,
            .back, .openSettings, .push:
            // Nothing happens behind the question.
            return []
        case .queryChanged, .resultsArrived, .screenRowsChanged, .actionPanelRowsChanged,
            .actionStarted, .actionFinished:
            // The app reporting what happened anyway. The key router keeps typing from the
            // field while a confirmation is up; text that changes all the same, through the
            // field's context menu, is followed so that the state and the field agree.
            return applyToLauncher(intent)
        }
    }

    private mutating func answerConfirmation(_ answer: Bool) -> [LauncherEffect] {
        confirmation = nil
        return [.answerConfirmation(answer)]
    }

    private mutating func applyToLauncher(_ intent: LauncherIntent) -> [LauncherEffect] {
        // A pending activation waits for the rows of the query it was pressed for, and is
        // given up when anything else happens first. Both groups are written out, without a
        // `default`, so that a new intent has to be put in one of them.
        switch intent {
        case .resultsArrived, .screenRowsChanged, .actionPanelRowsChanged, .actionFinished:
            // The app reporting back, which says nothing about what the user wants. That holds
            // for an outcome too. No activation is pending while the top frame waits for an
            // action, so an outcome that meets one is late, and `actionFinished` drops it.
            break
        case .willShow, .didHide, .queryChanged, .moveSelection, .activateIndex, .performPrimary,
            .performAction, .tabComplete, .toggleActionPanel, .back, .escape, .openSettings, .push,
            .actionStarted, .askConfirmation:
            // The user did something else before the results arrived, or the launcher went
            // away. `.actionStarted` is here because one action runs at a time, so an activation
            // cannot wait behind it, and `.askConfirmation` because nothing may start behind a
            // question.
            pendingActivation = nil
        }

        switch intent {
        case .willShow:
            return resetForShow()
        case .didHide:
            // Giving up the pending activation, above, is all that hiding does.
            return []
        case .queryChanged(let text):
            return setFieldText(text)
        case .moveSelection(let delta):
            return moveSelection(by: delta)
        case .activateIndex(let position):
            return activateRow(at: position)
        case .performPrimary:
            return performPrimary()
        case .performAction(let action):
            return perform(action)
        case .tabComplete:
            return tabComplete()
        case .toggleActionPanel:
            return toggleActionPanel()
        case .back:
            return goBack()
        case .escape:
            return escape()
        case .openSettings:
            return [.openSettings]
        case .push(let request):
            return push(request)
        case .resultsArrived(let rows, let generation):
            // Any other generation answers a query that has since changed.
            if generation != self.generation { return [] }
            return rowsArrived(rows, forFrameAt: 0)
        case .screenRowsChanged(let rows, let query):
            // Root search gets its rows from `.resultsArrived` only.
            if depth == 0 { return [] }
            // Even rows that come too late say that this screen answers its queries.
            stack[topIndex].answersQueries = true
            if query != top.query { return [] }
            return rowsArrived(rows, forFrameAt: topIndex)
        case .actionPanelRowsChanged(let rows):
            return setActionPanelRows(rows)
        case .askConfirmation(let question):
            confirmation = question
            return []
        case .actionStarted:
            return actionStarted()
        case .actionFinished(let outcome, let serial):
            return actionFinished(outcome, serial: serial)
        }
    }
}

// MARK: - Showing

extension LauncherState {
    /// Hiding leaves the frames alone, so showing starts over: root search with the previous query
    /// (which the field selects, so typing replaces it) and fresh results for it. An action still
    /// running from before keeps running, but its outcome no longer navigates.
    private mutating func resetForShow() -> [LauncherEffect] {
        // Not `pop`, which would cancel the running action.
        let screensToClose = depth
        stack.removeLast(screensToClose)
        actionPanel = nil
        stack[0].runningAction = nil
        stack[0].selection = stack[0].rows.first?.id

        var effects = [LauncherEffect](repeating: .popScreen, count: screensToClose)
        effects += startRootSearch()
        effects.append(.focusSearchField)
        if let selection = stack[0].selection {
            effects.append(.scrollTo(selection))
        }
        return effects
    }
}

// MARK: - Query

extension LauncherState {
    private mutating func setFieldText(_ text: String) -> [LauncherEffect] {
        if text == searchFieldText { return [] }
        // While the action panel is open the field holds its filter, not the frame's query.
        if var panel = actionPanel {
            panel.filter = text
            // With no selection, the rows that arrive for the new filter select their first
            // action.
            panel.selection = nil
            actionPanel = panel
            return []
        }
        return setQuery(text)
    }

    private mutating func setQuery(_ text: String) -> [LauncherEffect] {
        if text == top.query { return [] }
        stack[topIndex].query = text
        if depth == 0 {
            return startRootSearch()
        }
        // A screen searches for itself and answers with `.screenRowsChanged`.
        stack[topIndex].waitsForRows = true
        return [.forwardQuery(text)]
    }

    private mutating func startRootSearch() -> [LauncherEffect] {
        generation += 1
        stack[0].waitsForRows = true
        return [.search(query: stack[0].query, generation: generation)]
    }
}

// MARK: - Rows and selection

extension LauncherState {
    /// Sets a frame's rows, then performs the activation that was waiting for them, if there
    /// is one. The first rows for a query use the activation up, also when they are empty:
    /// rows that a slow source adds later only update the list.
    private mutating func rowsArrived(_ rows: [Row], forFrameAt index: Int) -> [LauncherEffect] {
        var effects = setRows(rows, ofFrameAt: index)

        // An activation waits for the rows of the frame on top. Root results that arrive
        // under a screen are not what it waits for.
        guard index == topIndex, let activation = pendingActivation else { return effects }
        pendingActivation = nil
        switch activation {
        case .selectedRow:
            effects += performPrimary()
        case .row(let position):
            effects += activateRow(at: position)
        case .tab:
            effects += tabComplete()
        }
        return effects
    }

    private mutating func setRows(_ rows: [Row], ofFrameAt index: Int) -> [LauncherEffect] {
        var frame = stack[index]
        let previousSelection = frame.selection
        let previousIndex = frame.selectedIndex

        frame.rows = rows
        if frame.waitsForRows {
            frame.waitsForRows = false
            frame.selection = rows.first?.id
        } else if frame.selectedIndex == nil {
            // The selected row is gone (or nothing was selected). Stay at its position rather
            // than jump to the top.
            if rows.isEmpty {
                frame.selection = nil
            } else {
                let position = min(previousIndex ?? 0, rows.count - 1)
                frame.selection = rows[position].id
            }
        }
        stack[index] = frame

        // Only the top frame is on screen. A frame below scrolls when it comes back, in `pop`.
        guard index == topIndex else { return [] }
        guard let selection = frame.selection else { return [] }

        // The same row at a new position has to be scrolled to as well: rows inserted above it
        // may have pushed it out of view.
        let selectionChanged = selection != previousSelection
        let positionChanged = frame.selectedIndex != previousIndex
        if selectionChanged || positionChanged {
            return [.scrollTo(selection)]
        }
        return []
    }

    private mutating func moveSelection(by delta: Int) -> [LauncherEffect] {
        // While the action panel is open the arrows move through its actions, not the list.
        if var panel = actionPanel {
            let target = Self.index(
                movingFrom: panel.selectedIndex, by: delta, rowCount: panel.rows.count)
            if let target {
                panel.selection = panel.rows[target]
                actionPanel = panel
            }
            return []
        }

        let frame = top
        let target = Self.index(
            movingFrom: frame.selectedIndex, by: delta, rowCount: frame.rows.count)
        guard let target else { return [] }

        let targetID = frame.rows[target].id
        // Already at the end of the list.
        if targetID == frame.selection { return [] }
        stack[topIndex].selection = targetID
        return [.scrollTo(targetID)]
    }

    /// The index `delta` rows from `current`, stopping at either end. With nothing selected, a
    /// move down selects the first row and a move up the last. `nil` when there are no rows.
    private static func index(movingFrom current: Int?, by delta: Int, rowCount: Int) -> Int? {
        if rowCount == 0 { return nil }
        if delta == 0 { return current }
        guard let current else {
            return delta > 0 ? 0 : rowCount - 1
        }
        // The step is limited before it is added, so that a huge delta cannot overflow.
        let step = min(max(delta, -rowCount), rowCount)
        let target = current + step
        return min(max(target, 0), rowCount - 1)
    }

    private mutating func setActionPanelRows(_ rows: [ActionID]) -> [LauncherEffect] {
        guard var panel = actionPanel else { return [] }
        panel.rows = rows
        // An action that is still listed stays selected.
        if panel.selectedIndex == nil {
            panel.selection = rows.first
        }
        actionPanel = panel
        return []
    }
}

// MARK: - Actions

extension LauncherState {
    private mutating func performPrimary() -> [LauncherEffect] {
        // Return runs the action selected in the action panel while it is open, otherwise the
        // selected row's primary action.
        if let panel = actionPanel {
            guard let action = panel.selection else { return [] }
            return perform(action)
        }
        if top.actionInFlight { return [] }
        // The rows on screen still answer the previous query. Return is meant for what the
        // current query finds, so it waits for those rows.
        if topAwaitsRows {
            pendingActivation = .selectedRow
            return []
        }
        guard let action = top.selectedRow?.primaryAction else { return [] }
        return perform(action)
    }

    /// One action runs at a time per frame; Esc cancels it.
    private mutating func perform(_ action: ActionID) -> [LauncherEffect] {
        if top.actionInFlight { return [] }
        // Only an item's shortcut gets this far while the frame waits for its rows; Return is
        // held back in `performPrimary`. The shortcut names an action of the row that was
        // selected when it was pressed, a row of the previous query. It cannot wait as Return
        // does, because the rows on their way have actions of their own.
        if topAwaitsRows { return [] }
        actionPanel = nil
        return [.perform(action, on: top.selection)]
    }

    private mutating func activateRow(at position: Int) -> [LauncherEffect] {
        // ⌘1 to ⌘9 belong to the list, which the action panel covers while it is open.
        if actionPanel != nil { return [] }
        let frame = top
        if frame.actionInFlight { return [] }
        // As with Return: the position is meant for the rows the current query finds.
        if topAwaitsRows {
            pendingActivation = .row(at: position)
            return []
        }
        // `position` is 1-based.
        guard position >= 1, position <= frame.rows.count else { return [] }
        let row = frame.rows[position - 1]

        var effects: [LauncherEffect] = []
        if frame.selection != row.id {
            stack[topIndex].selection = row.id
            effects.append(.scrollTo(row.id))
        }
        if let action = row.primaryAction {
            effects.append(.perform(action, on: row.id))
        }
        return effects
    }

    private mutating func toggleActionPanel() -> [LauncherEffect] {
        if actionPanel != nil {
            actionPanel = nil
            return []
        }
        if top.actionInFlight { return [] }
        // The panel would open on a row of the previous query and list that row's actions.
        if topAwaitsRows { return [] }
        // A screen has actions of its own. Root search has none, so there the panel needs a
        // selected item to list the actions of.
        if depth == 0 && top.selection == nil { return [] }
        actionPanel = ActionPanelState(filter: "", rows: [], selection: nil)
        return []
    }

    private mutating func actionStarted() -> [LauncherEffect] {
        actionSerial += 1
        stack[topIndex].runningAction = actionSerial
        return []
    }

    private mutating func actionFinished(
        _ outcome: ActionOutcome, serial: UInt64
    ) -> [LauncherEffect] {
        // Only the top frame can wait for an action, so that is where the outcome applies. It
        // does not wait for this one if the action was cancelled, if the launcher was shown
        // again since, or if the action's frame is gone. A frame that has started another action
        // waits for that.
        guard top.runningAction == serial else { return [] }
        stack[topIndex].runningAction = nil
        switch outcome {
        case .closeLauncher, .showHUD:
            return [.hide]
        case .keepOpen:
            return []
        case .popToRoot:
            return pop(depth)
        case .push(let request):
            return push(request)
        case .replaceQuery(let text):
            actionPanel = nil
            return setQuery(text)
        }
    }
}

// MARK: - Navigation

extension LauncherState {
    private mutating func push(_ request: ScreenRequest) -> [LauncherEffect] {
        // Nothing goes over a frame that waits for an action. The outcome navigates from the
        // frame that started the action (it can push a screen or replace the query), and it
        // would land on the wrong frame if another one had been pushed in the meantime.
        if top.actionInFlight { return [] }
        actionPanel = nil
        stack.append(Frame(screen: request, query: "", rows: [], selection: nil))
        return [.showScreen(request)]
    }

    /// Removes the top `count` frames, cancelling an action that was running in one of them.
    private mutating func pop(_ count: Int) -> [LauncherEffect] {
        actionPanel = nil
        guard count > 0 else { return [] }

        var effects: [LauncherEffect] = []
        let framesToRemove = stack.suffix(count)
        if framesToRemove.contains(where: \.actionInFlight) {
            effects.append(.cancelAction)
        }
        stack.removeLast(count)
        effects += [LauncherEffect](repeating: .popScreen, count: count)
        // The frame that is on top now shows its selection again.
        if let selection = top.selection {
            effects.append(.scrollTo(selection))
        }
        return effects
    }

    private mutating func tabComplete() -> [LauncherEffect] {
        if actionPanel != nil || top.actionInFlight { return [] }
        // As with Return: Tab is meant for the row the current query finds, which may have a
        // Tab target where the row on screen has none.
        if topAwaitsRows {
            pendingActivation = .tab
            return []
        }
        if let target = top.selectedRow?.tabTarget {
            return push(target)
        }
        // The fallback is for root search only, and it needs a query to pass on.
        guard depth == 0, !top.query.isEmpty else { return [] }
        guard var fallback = tabFallback else { return [] }
        fallback.argument = top.query
        return push(fallback)
    }

    private mutating func goBack() -> [LauncherEffect] {
        if actionPanel != nil {
            actionPanel = nil
            return []
        }
        if depth == 0 { return [] }
        return pop(1)
    }

    /// The Esc ladder: each press undoes the innermost thing. Its first rung is not here: a
    /// confirmation that is up takes Esc before anything else, in `apply(_:)`.
    private mutating func escape() -> [LauncherEffect] {
        if top.actionInFlight {
            stack[topIndex].runningAction = nil
            return [.cancelAction]
        }
        if actionPanel != nil {
            actionPanel = nil
            return []
        }
        if depth > 0 {
            return pop(1)
        }
        if !top.query.isEmpty {
            return setQuery("")
        }
        return [.hide]
    }
}
