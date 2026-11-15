/// Everything that can happen to the launcher's navigation state.
public enum LauncherIntent: Sendable, Equatable {
    /// The panel is about to appear.
    case willShow
    /// The search field's text changed.
    case queryChanged(String)
    /// Move the selection by this many rows; negative is up.
    case moveSelection(Int)
    /// Select the row with this 1-based position and run its primary action.
    case activateIndex(Int)
    case performPrimary
    case performAction(ActionID)
    case tabComplete
    case toggleActionPanel
    case back
    case escape
    case openSettings
    case push(ScreenRequest)
    /// Root search results. Dropped unless `generation` is the state's current generation.
    case resultsArrived(rows: [LauncherState.Row], generation: UInt64)
    /// The top screen's rows changed.
    case screenRowsChanged([LauncherState.Row])
    /// The actions the open action panel lists, after filtering.
    case actionPanelRowsChanged([ActionID])
    /// An action began running for the top frame. `LauncherState.actionSerial` then names it.
    case actionStarted
    /// The action that was given `serial` when it started has returned. Dropped unless its frame
    /// still waits for it: not after it was cancelled, after the launcher was shown again, or
    /// once another action has started in its place.
    case actionFinished(ActionOutcome, serial: UInt64)
}

/// What the app must do after an intent was applied.
public enum LauncherEffect: Sendable, Equatable {
    /// Run a root search and deliver its rows with `.resultsArrived` and this generation.
    case search(query: String, generation: UInt64)
    /// Pass the query to the top screen.
    case forwardQuery(String)
    /// Run an action of the item, or a screen-level action when the item is `nil`.
    case perform(ActionID, on: ItemID?)
    /// Cancel the running action.
    case cancelAction
    case showScreen(ScreenRequest)
    /// Drop the top screen. Emitted once per frame removed.
    case popScreen
    case hide
    /// Make the search field first responder with its text selected.
    case focusSearchField
    case scrollTo(ItemID)
    case openSettings
}
