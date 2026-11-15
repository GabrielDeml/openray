import Testing

import OpenRayCore

// A test changes the state only with real intents, in the order the app would send them. The one
// shorthand is `search(_:finds:)` below, for tests that need a root search behind them before
// the part they are about. Tests about the search itself write its two intents out.

private let clipboard = ScreenRequest(feature: FeatureID(rawValue: "clipboard"), screen: "history")
private let openWith = ScreenRequest(feature: FeatureID(rawValue: "apps"), screen: "openWith")
private let chat = ScreenRequest(feature: FeatureID(rawValue: "ai"), screen: "chat")

/// Rows with the item IDs `system:<name>`. Each row's primary action is named after it: the row
/// "slack" runs "run-slack".
private func rows(_ names: String...) -> [LauncherState.Row] {
    names.map { name in
        LauncherState.Row(id: .system(name), primaryAction: ActionID(rawValue: "run-\(name)"))
    }
}

extension LauncherState {
    /// Types a root query and delivers its results. These are the two intents the app sends for
    /// a search, and nothing else.
    fileprivate mutating func search(_ query: String, finds rows: [Row]) {
        _ = apply(.queryChanged(query))
        _ = apply(.resultsArrived(rows: rows, generation: generation))
    }
}

@Suite struct LauncherStateQueryTests {
    @Test func startsAtAnEmptyRoot() {
        let state = LauncherState()

        #expect(state.depth == 0)
        #expect(state.top.screen == nil)
        #expect(state.top.query == "")
        #expect(state.top.rows.isEmpty)
        #expect(state.top.selection == nil)
        #expect(state.actionPanel == nil)
    }

    @Test func everyRootQueryChangeStartsASearchWithANewGeneration() {
        var state = LauncherState()

        let first = state.apply(.queryChanged("s"))
        let firstGeneration = state.generation
        let second = state.apply(.queryChanged("sa"))
        let secondGeneration = state.generation

        #expect(first == [.search(query: "s", generation: firstGeneration)])
        #expect(second == [.search(query: "sa", generation: secondGeneration)])
        #expect(secondGeneration == firstGeneration + 1)
        #expect(state.top.query == "sa")
    }

    @Test func unchangedQueryDoesNothing() {
        var state = LauncherState()
        _ = state.apply(.queryChanged("sa"))
        _ = state.apply(.resultsArrived(rows: rows("safari"), generation: state.generation))
        let before = state

        #expect(state.apply(.queryChanged("sa")) == [])
        #expect(state == before)
    }

    @Test func resultsOfTheCurrentGenerationBecomeTheRowsAndSelectTheFirst() {
        var state = LauncherState()
        _ = state.apply(.queryChanged("s"))

        let effects = state.apply(
            .resultsArrived(rows: rows("safari", "slack"), generation: state.generation))

        #expect(state.top.rows == rows("safari", "slack"))
        #expect(state.top.selection == .system("safari"))
        #expect(state.top.selectedIndex == 0)
        #expect(effects == [.scrollTo(.system("safari"))])
    }

    @Test func resultsOfAStaleGenerationAreDropped() {
        var state = LauncherState()
        _ = state.apply(.queryChanged("s"))
        let staleGeneration = state.generation
        _ = state.apply(.queryChanged("sl"))
        _ = state.apply(.resultsArrived(rows: rows("slack"), generation: state.generation))
        let before = state

        let effects = state.apply(
            .resultsArrived(rows: rows("safari", "siri"), generation: staleGeneration))

        #expect(effects == [])
        #expect(state == before)
    }

    @Test func resultsFromTheFutureAreDroppedToo() {
        var state = LauncherState()
        _ = state.apply(.queryChanged("s"))

        let effects = state.apply(
            .resultsArrived(rows: rows("safari"), generation: state.generation + 1))

        #expect(effects == [])
        #expect(state.top.rows.isEmpty)
    }

    @Test func screenQueryIsForwardedWithoutTouchingRootSearch() {
        var state = LauncherState()
        _ = state.apply(.queryChanged("clip"))
        _ = state.apply(.resultsArrived(rows: rows("history"), generation: state.generation))
        _ = state.apply(.push(clipboard))
        let generationBefore = state.generation

        let effects = state.apply(.queryChanged("invoice"))

        #expect(effects == [.forwardQuery("invoice")])
        #expect(state.generation == generationBefore)
        #expect(state.top.query == "invoice")
        #expect(state.stack[0].query == "clip")
    }
}

@Suite struct LauncherStateSelectionTests {
    @Test func laterRowsOfTheSameSearchNeverMoveTheHighlight() {
        var state = LauncherState()
        state.search("s", finds: rows("safari", "slack", "sleep"))
        _ = state.apply(.moveSelection(1))

        // A slow section arrives: a row is inserted above the selection and others below.
        let effects = state.apply(
            .resultsArrived(
                rows: rows("calc", "safari", "slack", "sleep", "file"),
                generation: state.generation))

        #expect(state.top.selection == .system("slack"))
        #expect(state.top.selectedIndex == 2)
        #expect(effects == [.scrollTo(.system("slack"))])
    }

    @Test func rowsThatLeaveTheSelectionInPlaceCauseNoScroll() {
        var state = LauncherState()
        state.search("s", finds: rows("safari", "slack"))

        let effects = state.apply(
            .resultsArrived(rows: rows("safari", "slack", "sleep"), generation: state.generation))

        #expect(state.top.selection == .system("safari"))
        #expect(effects == [])
    }

    @Test func newQuerySelectsItsBestResultEvenIfTheOldSelectionStillMatches() {
        var state = LauncherState()
        state.search("sa", finds: rows("safari", "sandbox"))

        _ = state.apply(.queryChanged("san"))
        _ = state.apply(
            .resultsArrived(rows: rows("sandbox", "safari"), generation: state.generation))

        #expect(state.top.selection == .system("sandbox"))
    }

    @Test func selectionWaitsOnTheOldRowUntilTheNewResultsArrive() {
        var state = LauncherState()
        state.search("s", finds: rows("safari", "slack"))
        _ = state.apply(.moveSelection(1))

        _ = state.apply(.queryChanged("sl"))

        #expect(state.top.selection == .system("slack"))
        #expect(state.top.rows == rows("safari", "slack"))
    }

    @Test func whenTheSelectedRowDisappearsTheSelectionKeepsItsPosition() {
        var state = LauncherState()
        _ = state.apply(.push(clipboard))
        _ = state.apply(.screenRowsChanged(rows("a", "b", "c", "d")))
        _ = state.apply(.moveSelection(2))

        let effects = state.apply(.screenRowsChanged(rows("a", "b", "d")))

        #expect(state.top.selection == .system("d"))
        #expect(effects == [.scrollTo(.system("d"))])
    }

    @Test func whenTheLastRowDisappearsTheSelectionMovesToTheNewLastRow() {
        var state = LauncherState()
        _ = state.apply(.push(clipboard))
        _ = state.apply(.screenRowsChanged(rows("a", "b", "c")))
        _ = state.apply(.moveSelection(2))

        _ = state.apply(.screenRowsChanged(rows("a")))

        #expect(state.top.selection == .system("a"))
    }

    @Test func emptyRowsClearTheSelection() {
        var state = LauncherState()
        state.search("s", finds: rows("safari"))

        let effects = state.apply(.resultsArrived(rows: [], generation: state.generation))

        #expect(state.top.selection == nil)
        #expect(effects == [])
    }

    @Test func screenRowsKeepTheSelectionByIDWhenARowIsInsertedAbove() {
        var state = LauncherState()
        _ = state.apply(.push(clipboard))
        _ = state.apply(.screenRowsChanged(rows("old", "older")))

        _ = state.apply(.screenRowsChanged(rows("new", "old", "older")))

        #expect(state.top.selection == .system("old"))
    }

    @Test func screenRowsThatAnswerANewQuerySelectTheFirstRow() {
        var state = LauncherState()
        _ = state.apply(.push(clipboard))
        _ = state.apply(.screenRowsChanged(rows("a", "b", "c")))
        _ = state.apply(.moveSelection(2))

        _ = state.apply(.queryChanged("x"))
        _ = state.apply(.screenRowsChanged(rows("b", "c")))

        #expect(state.top.selection == .system("b"))
    }

    @Test func screenRowsAreIgnoredAtTheRoot() {
        var state = LauncherState()
        state.search("s", finds: rows("safari"))
        let before = state

        #expect(state.apply(.screenRowsChanged(rows("x", "y"))) == [])
        #expect(state == before)
    }

    @Test func rootResultsArrivingUnderAScreenUpdateTheRootFrameQuietly() {
        var state = LauncherState()
        _ = state.apply(.queryChanged("clip"))
        _ = state.apply(.push(clipboard))

        let effects = state.apply(
            .resultsArrived(rows: rows("history"), generation: state.generation))

        #expect(effects == [])
        #expect(state.top.rows.isEmpty)
        #expect(state.stack[0].rows == rows("history"))
        #expect(state.stack[0].selection == .system("history"))
    }

    @Test func moveSelectionStepsThroughTheRowsAndStopsAtTheEnds() {
        var state = LauncherState()
        state.search("s", finds: rows("a", "b", "c"))

        #expect(state.apply(.moveSelection(1)) == [.scrollTo(.system("b"))])
        #expect(state.apply(.moveSelection(1)) == [.scrollTo(.system("c"))])
        #expect(state.apply(.moveSelection(1)) == [])
        #expect(state.top.selection == .system("c"))

        #expect(state.apply(.moveSelection(-1)) == [.scrollTo(.system("b"))])
        #expect(state.apply(.moveSelection(-1)) == [.scrollTo(.system("a"))])
        #expect(state.apply(.moveSelection(-1)) == [])
        #expect(state.top.selection == .system("a"))
    }

    @Test func largeMovesStopAtTheEnds() {
        var state = LauncherState()
        state.search("s", finds: rows("a", "b", "c"))

        _ = state.apply(.moveSelection(.max))
        #expect(state.top.selection == .system("c"))
        _ = state.apply(.moveSelection(.min))
        #expect(state.top.selection == .system("a"))
    }

    @Test func movingWithNothingToSelectDoesNothing() {
        var state = LauncherState()

        #expect(state.apply(.moveSelection(1)) == [])
        #expect(state.apply(.moveSelection(-1)) == [])
        #expect(state.top.selection == nil)
    }
}

@Suite struct LauncherStateNavigationTests {
    @Test func pushShowsTheScreenInAFreshFrame() {
        var state = LauncherState()
        state.search("clip", finds: rows("history"))

        let effects = state.apply(.push(clipboard))

        #expect(effects == [.showScreen(clipboard)])
        #expect(state.depth == 1)
        #expect(state.top.screen == clipboard)
        #expect(state.top.query == "")
        #expect(state.top.rows.isEmpty)
        #expect(state.searchFieldText == "")
    }

    @Test func goingBackRestoresEachFramesQueryAndSelection() {
        var state = LauncherState()
        // Root: "clip", with the second row selected.
        state.search("clip", finds: rows("calendar", "history"))
        _ = state.apply(.moveSelection(1))
        // First screen: "inv", with the second row selected.
        _ = state.apply(.push(clipboard))
        _ = state.apply(.queryChanged("inv"))
        _ = state.apply(.screenRowsChanged(rows("invoice", "invite")))
        _ = state.apply(.moveSelection(1))
        // Second screen: "pre".
        _ = state.apply(.push(openWith))
        _ = state.apply(.queryChanged("pre"))

        let first = state.apply(.back)

        #expect(first == [.popScreen, .scrollTo(.system("invite"))])
        #expect(state.top.screen == clipboard)
        #expect(state.top.query == "inv")
        #expect(state.top.selection == .system("invite"))
        #expect(state.searchFieldText == "inv")

        let second = state.apply(.back)

        #expect(second == [.popScreen, .scrollTo(.system("history"))])
        #expect(state.depth == 0)
        #expect(state.top.query == "clip")
        #expect(state.top.selection == .system("history"))
    }

    @Test func backAtTheRootDoesNothing() {
        var state = LauncherState()
        state.search("s", finds: rows("safari"))
        let before = state

        #expect(state.apply(.back) == [])
        #expect(state == before)
    }

    @Test func goingBackDoesNotRestartRootSearch() {
        var state = LauncherState()
        state.search("clip", finds: rows("history"))
        _ = state.apply(.push(clipboard))
        let generationBefore = state.generation

        _ = state.apply(.back)

        #expect(state.generation == generationBefore)
    }

    @Test func backCancelsAnActionRunningInTheFrameItLeaves() {
        var state = LauncherState()
        _ = state.apply(.push(clipboard))
        _ = state.apply(.actionStarted)

        #expect(state.apply(.back) == [.cancelAction, .popScreen])
        #expect(state.depth == 0)
    }

    @Test func openSettingsAsksTheAppToOpenSettings() {
        var state = LauncherState()

        #expect(state.apply(.openSettings) == [.openSettings])
    }
}

// The Esc ladder: each press undoes the innermost thing. A running action comes first, then the
// action panel, the top screen, the query, and at last the launcher itself.
@Suite struct LauncherStateEscapeTests {
    @Test func firstRungCancelsTheRunningActionAndNothingElse() {
        var state = LauncherState()
        state.search("clip", finds: rows("history"))
        _ = state.apply(.push(clipboard))
        _ = state.apply(.actionStarted)

        let effects = state.apply(.escape)

        #expect(effects == [.cancelAction])
        #expect(!state.top.actionInFlight)
        #expect(state.depth == 1)
    }

    @Test func secondRungClosesTheActionPanel() {
        var state = LauncherState()
        state.search("clip", finds: rows("history"))
        _ = state.apply(.push(clipboard))
        _ = state.apply(.screenRowsChanged(rows("invoice")))
        _ = state.apply(.toggleActionPanel)

        let effects = state.apply(.escape)

        #expect(effects == [])
        #expect(state.actionPanel == nil)
        #expect(state.depth == 1)
    }

    @Test func thirdRungPopsTheFrame() {
        var state = LauncherState()
        state.search("clip", finds: rows("history"))
        _ = state.apply(.push(clipboard))
        _ = state.apply(.screenRowsChanged(rows("invoice")))
        _ = state.apply(.toggleActionPanel)
        // The second rung: this press only closes the action panel.
        _ = state.apply(.escape)

        let effects = state.apply(.escape)

        #expect(effects == [.popScreen, .scrollTo(.system("history"))])
        #expect(state.depth == 0)
        #expect(state.top.query == "clip")
    }

    @Test func fourthRungClearsTheQueryAndSearchesAgain() {
        var state = LauncherState()
        state.search("clip", finds: rows("history"))

        let effects = state.apply(.escape)

        #expect(effects == [.search(query: "", generation: state.generation)])
        #expect(state.top.query == "")
        #expect(state.searchFieldText == "")
    }

    @Test func lastRungHides() {
        var state = LauncherState()

        #expect(state.apply(.escape) == [.hide])
    }

    @Test func repeatedEscapeDescendsOneRungAtATime() {
        var state = LauncherState()
        state.search("clip", finds: rows("history"))
        _ = state.apply(.push(clipboard))
        _ = state.apply(.screenRowsChanged(rows("invoice")))
        // Performing an action closes the action panel, so the app never has one running under
        // an open panel. The panel's rung comes first here, and the action starts after it.
        _ = state.apply(.toggleActionPanel)
        _ = state.apply(.escape)
        _ = state.apply(.actionStarted)

        let first = state.apply(.escape)
        let second = state.apply(.escape)
        let third = state.apply(.escape)
        let fourth = state.apply(.escape)

        #expect(first == [.cancelAction])
        #expect(second == [.popScreen, .scrollTo(.system("history"))])
        #expect(third == [.search(query: "", generation: state.generation)])
        #expect(fourth == [.hide])
    }

    @Test func hidingKeepsTheStateForTheNextShow() {
        var state = LauncherState()
        // Results for the empty query the launcher starts with.
        _ = state.apply(.resultsArrived(rows: rows("recent"), generation: state.generation))
        let before = state

        _ = state.apply(.escape)

        #expect(state == before)
    }
}

@Suite struct LauncherStateTabTests {
    @Test func tabPushesTheSelectedItemsTabTarget() {
        var state = LauncherState()
        state.tabFallback = chat
        // Return has an action to run on this row as well. Tab still opens its Tab target.
        let safari = LauncherState.Row(
            id: .system("safari"), primaryAction: ActionID(rawValue: "run-safari"),
            tabTarget: openWith)
        state.search("saf", finds: [safari])

        let effects = state.apply(.tabComplete)

        #expect(effects == [.showScreen(openWith)])
        #expect(state.top.screen == openWith)
        #expect(state.stack[0].query == "saf")
    }

    @Test func tabAtTheRootFallsBackWithTheQueryAsArgument() {
        var state = LauncherState()
        state.tabFallback = chat
        state.search("why is the sky blue", finds: rows("safari"))
        let chatWithQuestion = ScreenRequest(
            feature: chat.feature, screen: chat.screen, argument: "why is the sky blue")

        let effects = state.apply(.tabComplete)

        #expect(effects == [.showScreen(chatWithQuestion)])
        #expect(state.top.screen == chatWithQuestion)
        #expect(state.top.query == "")
    }

    @Test func tabFallsBackEvenWithoutResults() {
        var state = LauncherState()
        state.tabFallback = chat
        state.search("zzz", finds: [])
        let chatWithQuestion = ScreenRequest(
            feature: chat.feature, screen: chat.screen, argument: "zzz")

        let effects = state.apply(.tabComplete)

        #expect(effects == [.showScreen(chatWithQuestion)])
        #expect(state.depth == 1)
    }

    @Test func tabWithAnEmptyQueryDoesNothing() {
        var state = LauncherState()
        state.tabFallback = chat
        // Results for the empty query the launcher starts with.
        _ = state.apply(.resultsArrived(rows: rows("safari"), generation: state.generation))

        #expect(state.apply(.tabComplete) == [])
        #expect(state.depth == 0)
    }

    @Test func tabWithoutAFallbackDoesNothing() {
        var state = LauncherState()
        state.search("saf", finds: rows("safari"))

        #expect(state.apply(.tabComplete) == [])
        #expect(state.depth == 0)
    }

    @Test func tabInsideAScreenNeverUsesTheFallback() {
        var state = LauncherState()
        state.tabFallback = chat
        _ = state.apply(.push(clipboard))
        _ = state.apply(.queryChanged("inv"))
        _ = state.apply(.screenRowsChanged(rows("invoice")))

        #expect(state.apply(.tabComplete) == [])
        #expect(state.depth == 1)
    }

    @Test func tabInsideAScreenStillPushesATabTarget() {
        var state = LauncherState()
        // Return could act on this row as well.
        let file = LauncherState.Row(
            id: .system("file"), primaryAction: ActionID(rawValue: "run-file"), tabTarget: openWith)
        _ = state.apply(.push(clipboard))
        _ = state.apply(.screenRowsChanged([file]))

        #expect(state.apply(.tabComplete) == [.showScreen(openWith)])
        #expect(state.depth == 2)
    }
}

@Suite struct LauncherStateShowTests {
    @Test func showingAgainResetsToTheRootAndKeepsThePreviousQuery() {
        var state = LauncherState()
        state.search("clip", finds: rows("calendar", "history"))
        _ = state.apply(.moveSelection(1))
        _ = state.apply(.push(clipboard))
        _ = state.apply(.queryChanged("inv"))
        _ = state.apply(.push(openWith))
        _ = state.apply(.toggleActionPanel)

        let effects = state.apply(.willShow)

        #expect(state.depth == 0)
        #expect(state.actionPanel == nil)
        #expect(state.top.query == "clip")
        #expect(state.searchFieldText == "clip")
        #expect(state.top.selection == .system("calendar"))
        #expect(
            effects == [
                .popScreen, .popScreen,
                .search(query: "clip", generation: state.generation),
                .focusSearchField,
                .scrollTo(.system("calendar")),
            ])
    }

    @Test func showingSearchesAgainSoResultsFromBeforeAreStale() {
        var state = LauncherState()
        _ = state.apply(.queryChanged("s"))
        let generationBeforeShowing = state.generation

        _ = state.apply(.willShow)
        let effects = state.apply(
            .resultsArrived(rows: rows("safari"), generation: generationBeforeShowing))

        #expect(effects == [])
        #expect(state.top.rows.isEmpty)
    }

    @Test func firstShowSearchesTheEmptyQueryAndFocusesTheField() {
        var state = LauncherState()

        let effects = state.apply(.willShow)

        #expect(effects == [.search(query: "", generation: state.generation), .focusSearchField])
    }

    @Test func resultsAfterShowingSelectTheFirstRow() {
        var state = LauncherState()
        state.search("s", finds: rows("safari", "slack"))
        _ = state.apply(.moveSelection(1))

        _ = state.apply(.willShow)
        _ = state.apply(
            .resultsArrived(rows: rows("sleep", "safari", "slack"), generation: state.generation))

        #expect(state.top.selection == .system("sleep"))
    }

    @Test func actionStillRunningFromBeforeNoLongerNavigates() {
        var state = LauncherState()
        state.search("empty", finds: rows("trash"))
        _ = state.apply(.actionStarted)

        let shown = state.apply(.willShow)
        let finished = state.apply(.actionFinished(.closeLauncher, serial: state.actionSerial))

        #expect(!shown.contains(.cancelAction))
        #expect(!state.top.actionInFlight)
        #expect(finished == [])
    }
}

// An action is reported in two intents, as the app does it: `.actionStarted` when it begins, and
// `.actionFinished` when it returns, carrying the `actionSerial` the state had after the start.
@Suite struct LauncherStateActionTests {
    private let reveal = ActionID(rawValue: "reveal")

    @Test func returnPerformsThePrimaryActionOfTheSelectedRow() {
        var state = LauncherState()
        state.search("s", finds: rows("safari", "slack"))
        _ = state.apply(.moveSelection(1))

        let effects = state.apply(.performPrimary)

        #expect(effects == [.perform(ActionID(rawValue: "run-slack"), on: .system("slack"))])
    }

    @Test func returnWithNothingSelectedDoesNothing() {
        var state = LauncherState()

        #expect(state.apply(.performPrimary) == [])
    }

    @Test func returnOnARowWithoutActionsDoesNothing() {
        var state = LauncherState()
        let inert = LauncherState.Row(id: .system("inert"))
        state.search("x", finds: [inert])

        #expect(state.apply(.performPrimary) == [])
    }

    @Test func shortcutPerformsItsActionOnTheSelectedRow() {
        var state = LauncherState()
        state.search("s", finds: rows("safari"))

        let effects = state.apply(.performAction(reveal))

        #expect(effects == [.perform(reveal, on: .system("safari"))])
    }

    @Test func screenLevelActionHasNoItem() {
        var state = LauncherState()
        let copyAnswer = ActionID(rawValue: "copy-answer")
        _ = state.apply(.push(chat))

        let effects = state.apply(.performAction(copyAnswer))

        #expect(effects == [.perform(copyAnswer, on: nil)])
    }

    @Test func activateIndexSelectsThatRowAndPerformsItsPrimaryAction() {
        var state = LauncherState()
        state.search("s", finds: rows("a", "b", "c"))

        let effects = state.apply(.activateIndex(3))

        #expect(state.top.selection == .system("c"))
        #expect(
            effects == [
                .scrollTo(.system("c")),
                .perform(ActionID(rawValue: "run-c"), on: .system("c")),
            ])
    }

    @Test func activatingTheSelectedRowOnlyPerforms() {
        var state = LauncherState()
        state.search("s", finds: rows("a", "b"))

        let effects = state.apply(.activateIndex(1))

        #expect(effects == [.perform(ActionID(rawValue: "run-a"), on: .system("a"))])
    }

    @Test(arguments: [0, 3, -1, .max, .min])
    func activatingAPositionWithoutARowDoesNothing(position: Int) {
        var state = LauncherState()
        state.search("s", finds: rows("a", "b"))
        let before = state

        #expect(state.apply(.activateIndex(position)) == [])
        #expect(state == before)
    }

    @Test func activatingARowOfAnEmptyListDoesNothing() {
        var state = LauncherState()

        #expect(state.apply(.activateIndex(1)) == [])
    }

    @Test func whileAnActionRunsNoOtherActionOrScreenStarts() {
        var state = LauncherState()
        state.tabFallback = chat
        state.search("s", finds: rows("a", "b"))
        _ = state.apply(.actionStarted)

        #expect(state.top.actionInFlight)
        #expect(state.apply(.performPrimary) == [])
        #expect(state.apply(.performAction(reveal)) == [])
        #expect(state.apply(.activateIndex(2)) == [])
        #expect(state.apply(.tabComplete) == [])
        #expect(state.apply(.toggleActionPanel) == [])
        #expect(state.actionPanel == nil)
        #expect(state.depth == 0)
    }

    @Test func typingAndMovingStillWorkWhileAnActionRuns() {
        var state = LauncherState()
        state.search("s", finds: rows("a", "b"))
        _ = state.apply(.actionStarted)

        let moved = state.apply(.moveSelection(1))
        let typed = state.apply(.queryChanged("sl"))

        #expect(moved == [.scrollTo(.system("b"))])
        #expect(typed == [.search(query: "sl", generation: state.generation)])
    }

    @Test(arguments: [ActionOutcome.closeLauncher, .showHUD("Copied")])
    func outcomesThatCloseTheLauncherHideIt(outcome: ActionOutcome) {
        var state = LauncherState()
        state.search("s", finds: rows("a"))
        _ = state.apply(.actionStarted)

        let effects = state.apply(.actionFinished(outcome, serial: state.actionSerial))

        #expect(effects == [.hide])
        #expect(!state.top.actionInFlight)
    }

    @Test func keepOpenOnlyEndsTheAction() {
        var state = LauncherState()
        state.search("s", finds: rows("a"))
        _ = state.apply(.actionStarted)

        let effects = state.apply(.actionFinished(.keepOpen, serial: state.actionSerial))

        #expect(effects == [])
        #expect(!state.top.actionInFlight)
        // The next action can start.
        let next = state.apply(.performPrimary)
        #expect(next == [.perform(ActionID(rawValue: "run-a"), on: .system("a"))])
    }

    @Test func popToRootRemovesEveryScreen() {
        var state = LauncherState()
        state.search("clip", finds: rows("history"))
        _ = state.apply(.push(clipboard))
        _ = state.apply(.push(openWith))
        _ = state.apply(.actionStarted)

        let effects = state.apply(.actionFinished(.popToRoot, serial: state.actionSerial))

        #expect(effects == [.popScreen, .popScreen, .scrollTo(.system("history"))])
        #expect(state.depth == 0)
        #expect(state.top.query == "clip")
    }

    @Test func pushOutcomeShowsTheScreen() {
        var state = LauncherState()
        state.search("clip", finds: rows("history"))
        _ = state.apply(.actionStarted)

        let effects = state.apply(.actionFinished(.push(clipboard), serial: state.actionSerial))

        #expect(effects == [.showScreen(clipboard)])
        #expect(state.top.screen == clipboard)
        #expect(!state.stack[0].actionInFlight)
    }

    @Test func replaceQueryAtTheRootSearchesForTheNewText() {
        var state = LauncherState()
        state.search("2+2", finds: rows("answer"))
        _ = state.apply(.actionStarted)

        let effects = state.apply(.actionFinished(.replaceQuery("4"), serial: state.actionSerial))

        #expect(effects == [.search(query: "4", generation: state.generation)])
        #expect(state.searchFieldText == "4")
    }

    @Test func replaceQueryInsideAScreenForwardsTheNewText() {
        var state = LauncherState()
        _ = state.apply(.push(clipboard))
        _ = state.apply(.actionStarted)

        let effects = state.apply(
            .actionFinished(.replaceQuery("inv"), serial: state.actionSerial))

        #expect(effects == [.forwardQuery("inv")])
        #expect(state.top.query == "inv")
    }

    @Test func outcomeOfACancelledActionIsDropped() {
        var state = LauncherState()
        state.search("s", finds: rows("a"))
        _ = state.apply(.actionStarted)
        _ = state.apply(.escape)

        let effects = state.apply(.actionFinished(.push(clipboard), serial: state.actionSerial))

        #expect(effects == [])
        #expect(state.depth == 0)
    }

    @Test func lateOutcomeOfACancelledActionIsNotTakenForTheNextAction() {
        var state = LauncherState()
        state.search("s", finds: rows("a"))
        _ = state.apply(.actionStarted)
        let cancelled = state.actionSerial
        _ = state.apply(.escape)
        _ = state.apply(.actionStarted)
        let running = state.actionSerial

        #expect(state.apply(.actionFinished(.keepOpen, serial: cancelled)) == [])
        #expect(state.top.actionInFlight)
        #expect(state.apply(.actionFinished(.closeLauncher, serial: running)) == [.hide])
        #expect(!state.top.actionInFlight)
    }

    @Test func outcomeOfAnActionFromBeforeTheLastShowIsNotTakenForTheNextAction() {
        var state = LauncherState()
        state.search("clip", finds: rows("history"))
        _ = state.apply(.actionStarted)
        let detached = state.actionSerial
        _ = state.apply(.willShow)
        _ = state.apply(.actionStarted)
        let running = state.actionSerial

        #expect(state.apply(.actionFinished(.closeLauncher, serial: detached)) == [])
        #expect(state.top.actionInFlight)
        #expect(
            state.apply(.actionFinished(.push(clipboard), serial: running))
                == [.showScreen(clipboard)])
    }

    @Test func outcomeOfAnActionWhoseScreenWasLeftIsDropped() {
        var state = LauncherState()
        _ = state.apply(.push(clipboard))
        _ = state.apply(.actionStarted)
        let abandoned = state.actionSerial
        _ = state.apply(.back)

        #expect(state.apply(.actionFinished(.push(openWith), serial: abandoned)) == [])
        #expect(state.depth == 0)
    }
}

@Suite struct LauncherStateActionPanelTests {
    private let open = ActionID(rawValue: "open")
    private let reveal = ActionID(rawValue: "reveal")
    private let copyPath = ActionID(rawValue: "copy-path")

    /// A root search for "saf" with "safari" selected and the action panel open on it. The panel
    /// lists `open`, `reveal` and `copyPath` in that order, and `open` is selected.
    private func launcherWithActionPanelOpen() -> LauncherState {
        var state = LauncherState()
        state.search("saf", finds: rows("safari", "safari-preview"))
        _ = state.apply(.toggleActionPanel)
        _ = state.apply(.actionPanelRowsChanged([open, reveal, copyPath]))
        return state
    }

    @Test func toggleOpensThePanelWithAnEmptyFilterAndClosesItAgain() {
        var state = LauncherState()
        state.search("saf", finds: rows("safari"))

        #expect(state.apply(.toggleActionPanel) == [])
        #expect(state.actionPanel?.filter == "")
        #expect(state.searchFieldText == "")

        #expect(state.apply(.toggleActionPanel) == [])
        #expect(state.actionPanel == nil)
        #expect(state.searchFieldText == "saf")
    }

    @Test func panelDoesNotOpenAtTheRootWithoutASelectedItem() {
        var state = LauncherState()

        _ = state.apply(.toggleActionPanel)

        #expect(state.actionPanel == nil)
    }

    @Test func panelOpensOnAScreenWithoutRowsForItsScreenActions() {
        var state = LauncherState()
        _ = state.apply(.push(chat))

        _ = state.apply(.toggleActionPanel)

        #expect(state.actionPanel != nil)
    }

    @Test func rowsSelectTheFirstAction() {
        let state = launcherWithActionPanelOpen()

        #expect(state.actionPanel?.rows == [open, reveal, copyPath])
        #expect(state.actionPanel?.selection == open)
    }

    @Test func typingFiltersThePanelAndLeavesTheFramesQueryAlone() {
        var state = launcherWithActionPanelOpen()
        let generationBefore = state.generation

        let effects = state.apply(.queryChanged("re"))

        #expect(effects == [])
        #expect(state.actionPanel?.filter == "re")
        #expect(state.searchFieldText == "re")
        #expect(state.top.query == "saf")
        #expect(state.generation == generationBefore)
    }

    @Test func moveSelectionMovesWithinThePanelNotTheList() {
        var state = launcherWithActionPanelOpen()

        #expect(state.apply(.moveSelection(1)) == [])
        #expect(state.actionPanel?.selection == reveal)
        #expect(state.top.selection == .system("safari"))

        _ = state.apply(.moveSelection(5))
        #expect(state.actionPanel?.selection == copyPath)
        _ = state.apply(.moveSelection(-5))
        #expect(state.actionPanel?.selection == open)
    }

    @Test func returnPerformsTheSelectedActionOnTheSelectedItemAndClosesThePanel() {
        var state = launcherWithActionPanelOpen()
        _ = state.apply(.moveSelection(1))

        let effects = state.apply(.performPrimary)

        #expect(effects == [.perform(reveal, on: .system("safari"))])
        #expect(state.actionPanel == nil)
        #expect(state.searchFieldText == "saf")
    }

    @Test func returnWithNoMatchingActionDoesNothing() {
        var state = launcherWithActionPanelOpen()
        _ = state.apply(.queryChanged("zzz"))
        _ = state.apply(.actionPanelRowsChanged([]))

        #expect(state.apply(.performPrimary) == [])
        #expect(state.actionPanel != nil)
    }

    @Test func rowsForANewFilterSelectTheirFirstAction() {
        var state = launcherWithActionPanelOpen()
        _ = state.apply(.moveSelection(1))

        _ = state.apply(.queryChanged("o"))
        _ = state.apply(.actionPanelRowsChanged([copyPath, open, reveal]))

        #expect(state.actionPanel?.selection == copyPath)
    }

    @Test func rowsThatMerelyUpdateKeepTheSelectedAction() {
        var state = launcherWithActionPanelOpen()
        let quit = ActionID(rawValue: "quit")
        _ = state.apply(.moveSelection(1))

        _ = state.apply(.actionPanelRowsChanged([quit, reveal]))
        #expect(state.actionPanel?.selection == reveal)

        _ = state.apply(.actionPanelRowsChanged([quit]))
        #expect(state.actionPanel?.selection == quit)
    }

    @Test func rowsWithoutAnOpenPanelAreIgnored() {
        var state = LauncherState()
        state.search("saf", finds: rows("safari"))
        let before = state

        #expect(state.apply(.actionPanelRowsChanged([open, reveal, copyPath])) == [])
        #expect(state == before)
    }

    @Test func shortcutPerformsItsActionAndClosesThePanel() {
        var state = launcherWithActionPanelOpen()

        let effects = state.apply(.performAction(copyPath))

        #expect(effects == [.perform(copyPath, on: .system("safari"))])
        #expect(state.actionPanel == nil)
    }

    @Test func rowShortcutsAndTabAreInertWhileThePanelIsOpen() {
        var state = launcherWithActionPanelOpen()
        state.tabFallback = chat
        let before = state

        #expect(state.apply(.activateIndex(2)) == [])
        #expect(state.apply(.tabComplete) == [])
        #expect(state == before)
    }

    @Test func backClosesThePanelBeforeLeavingTheScreen() {
        var state = LauncherState()
        _ = state.apply(.push(clipboard))
        _ = state.apply(.toggleActionPanel)

        #expect(state.apply(.back) == [])
        #expect(state.actionPanel == nil)
        #expect(state.depth == 1)
    }

    @Test func pushingAScreenClosesThePanel() {
        var state = launcherWithActionPanelOpen()

        _ = state.apply(.push(clipboard))

        #expect(state.actionPanel == nil)
        #expect(state.searchFieldText == "")
    }
}
