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
        var runningAction: UInt64?
        /// Set when the query changes: the rows that answer it select their first row, where
        /// rows that merely update keep the selection.
        var selectsFirstRowOnArrival = false

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

    /// Never empty; `stack[0]` is root search.
    public private(set) var stack: [Frame]
    /// `nil` while the action panel is closed.
    public private(set) var actionPanel: ActionPanelState?
    /// Identifies the root query that results must answer. The only generation counter in the app.
    public private(set) var generation: UInt64
    /// Numbers the actions started. Its value after `.actionStarted` names that action in
    /// `.actionFinished`, so an outcome that arrives late is never taken for another action's.
    public private(set) var actionSerial: UInt64
    /// The screen Tab opens at the root when the selected item has no Tab target of its own.
    public var tabFallback: ScreenRequest?

    public init() {
        stack = [Frame(screen: nil, query: "", rows: [], selection: nil)]
        actionPanel = nil
        generation = 0
        actionSerial = 0
        tabFallback = nil
    }

    public var top: Frame { stack[topIndex] }

    /// How many screens are pushed; 0 is root search.
    public var depth: Int { topIndex }

    /// What the search field shows: the action panel's filter while the panel is open, otherwise
    /// the top frame's query.
    public var searchFieldText: String { actionPanel?.filter ?? top.query }

    private var topIndex: Int { stack.count - 1 }

    public mutating func apply(_ intent: LauncherIntent) -> [LauncherEffect] {
        switch intent {
        case .willShow:
            return resetForShow()
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
            return setRows(rows, ofFrameAt: 0)
        case .screenRowsChanged(let rows):
            // Root search gets its rows from `.resultsArrived` only.
            if depth == 0 { return [] }
            return setRows(rows, ofFrameAt: topIndex)
        case .actionPanelRowsChanged(let rows):
            return setActionPanelRows(rows)
        case .actionStarted:
            return actionStarted()
        case .actionFinished(let outcome, let serial):
            return actionFinished(outcome, serial: serial)
        }
    }
}

// MARK: - Showing

extension LauncherState {
    /// Hiding leaves the state alone, so showing starts over: root search with the previous query
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
        stack[topIndex].selectsFirstRowOnArrival = true
        return [.forwardQuery(text)]
    }

    private mutating func startRootSearch() -> [LauncherEffect] {
        generation += 1
        stack[0].selectsFirstRowOnArrival = true
        return [.search(query: stack[0].query, generation: generation)]
    }
}

// MARK: - Rows and selection

extension LauncherState {
    private mutating func setRows(_ rows: [Row], ofFrameAt index: Int) -> [LauncherEffect] {
        var frame = stack[index]
        let previousSelection = frame.selection
        let previousIndex = frame.selectedIndex

        frame.rows = rows
        if frame.selectsFirstRowOnArrival {
            frame.selectsFirstRowOnArrival = false
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
        guard let action = top.selectedRow?.primaryAction else { return [] }
        return perform(action)
    }

    /// One action runs at a time per frame; Esc cancels it.
    private mutating func perform(_ action: ActionID) -> [LauncherEffect] {
        if top.actionInFlight { return [] }
        actionPanel = nil
        return [.perform(action, on: top.selection)]
    }

    private mutating func activateRow(at position: Int) -> [LauncherEffect] {
        // ⌘1 to ⌘9 belong to the list, which the action panel covers while it is open.
        if actionPanel != nil { return [] }
        let frame = top
        if frame.actionInFlight { return [] }
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
        // No frame waits for this action if it was cancelled, if the launcher was shown again
        // since, or if its frame is gone. A frame that has started another action waits for that.
        guard let index = stack.lastIndex(where: { $0.runningAction == serial }) else { return [] }
        stack[index].runningAction = nil
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

    /// The Esc ladder: each press undoes the innermost thing.
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
