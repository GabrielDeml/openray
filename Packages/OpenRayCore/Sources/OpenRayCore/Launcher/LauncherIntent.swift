/// Everything that can happen to the launcher's navigation state.
public enum LauncherIntent: Sendable, Equatable {
    /// The panel is about to appear.
    case willShow
    /// The panel has gone. Changes nothing, except that an activation still waiting for results
    /// is given up and a confirmation that was up is answered with no.
    case didHide
    /// The search field's text changed.
    case queryChanged(String)
    /// Move the selection by this many rows; negative is up.
    case moveSelection(Int)
    /// Select the row with this 1-based position and run its primary action. Waits for the rows
    /// of the current query as `.performPrimary` does.
    case activateIndex(Int)
    /// Run the primary action of the selected row. The rows on screen answer the previous query
    /// until the rows for the current one arrive. Pressed in between, this waits for those rows;
    /// `LauncherState.apply(_:)` says what makes it give up. While a confirmation is up, this
    /// answers it with yes instead.
    case performPrimary
    /// Run this action of the selected item. Ignored while the rows for the current query have
    /// not arrived: the item is still one the previous query found.
    case performAction(ActionID)
    /// Open the selected row's Tab target, or the fallback. Waits for the rows of the current
    /// query as `.performPrimary` does.
    case tabComplete
    /// Open or close the action panel. It does not open while the rows for the current query
    /// have not arrived.
    case toggleActionPanel
    case back
    case escape
    case openSettings
    /// Open a screen on top of the stack. Ignored while the top frame waits for an action.
    case push(ScreenRequest)
    /// Root search results. Dropped unless `generation` is the state's current generation.
    case resultsArrived(rows: [LauncherState.Row], generation: UInt64)
    /// The rows of the top screen, and the query they answer. Dropped when that is not the
    /// screen's query any more. A list screen sends this for every query it is forwarded, also
    /// when its rows stay the same.
    case screenRowsChanged([LauncherState.Row], query: String)
    /// The actions the open action panel lists, after filtering.
    case actionPanelRowsChanged([ActionID])
    /// Ask the user this before going on. The answer comes back as `.answerConfirmation`: yes
    /// for Return, no for Esc and when the launcher is hidden or shown again first.
    case askConfirmation(Confirmation)
    /// An action began running for the top frame. `LauncherState.actionSerial` then names it.
    case actionStarted
    /// The action that was given `serial` when it started has returned. Dropped unless its frame
    /// still waits for it: not after it was cancelled, after the launcher was shown again, or
    /// once another action has started in its place.
    case actionFinished(ActionOutcome, serial: UInt64)
}

/// What the app must do after an intent was applied.
public enum LauncherEffect: Sendable, Equatable {
    /// Run a root search and deliver its rows with `.resultsArrived` and this generation. A
    /// search that found nothing, or failed, still has to deliver its empty rows: until then
    /// the state takes the rows it holds for those of the previous query.
    case search(query: String, generation: UInt64)
    /// Pass the query to the top screen. A list screen answers with `.screenRowsChanged` naming
    /// this query, also when its rows stay the same.
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
    /// The user answered the confirmation, or it went away unanswered, which counts as no.
    case answerConfirmation(Bool)
}
