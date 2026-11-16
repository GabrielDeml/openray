import Testing

import OpenRayCore

@Suite struct KeyRouterTests {
    private let router = KeyRouter()
    private let atRoot = KeyRouter.Context(queryIsEmpty: true, depth: 0)

    private let open = ActionID(rawValue: "open")
    private let reveal = ActionID(rawValue: "reveal")
    private let commandReturn = KeyChord(keyCode: VirtualKey.returnKey, modifiers: [.command])

    // Key codes of keys the router has no rule for (Events.h).
    private let ansiA: UInt16 = 0x00
    private let ansiC: UInt16 = 0x08
    private let ansiV: UInt16 = 0x09
    private let ansiX: UInt16 = 0x07
    private let ansiZ: UInt16 = 0x06
    private let ansiM: UInt16 = 0x2E

    /// What the router makes of one key press. `characters` is what the layout types on the key
    /// without its modifiers. Without a context, the launcher is at the root with an empty query.
    private func intent(
        _ keyCode: UInt16, _ modifiers: HotKey.Modifiers = [], _ characters: String? = nil,
        in context: KeyRouter.Context? = nil
    ) -> LauncherIntent? {
        let chord = KeyChord(keyCode: keyCode, modifiers: modifiers, characters: characters)
        return router.intent(for: chord, in: context ?? atRoot)
    }

    /// Whether the router keeps one key press from AppKit although it has no intent for it.
    private func swallows(
        _ keyCode: UInt16, _ modifiers: HotKey.Modifiers, _ characters: String?,
        in context: KeyRouter.Context? = nil
    ) -> Bool {
        let chord = KeyChord(keyCode: keyCode, modifiers: modifiers, characters: characters)
        return router.swallows(chord, in: context ?? atRoot)
    }

    /// Whether the launcher keeps a chord for itself, so that no action may use it.
    private func reserves(
        _ keyCode: UInt16, _ modifiers: HotKey.Modifiers, _ characters: String?
    ) -> Bool {
        router.reserves(KeyChord(keyCode: keyCode, modifiers: modifiers, characters: characters))
    }

    // MARK: The routing table, row by row

    @Test func escapeKeySendsEscape() {
        #expect(intent(VirtualKey.escape, [], "\u{1B}") == .escape)
    }

    @Test func arrowsMoveTheSelection() {
        #expect(intent(VirtualKey.upArrow, [], "\u{F700}") == .moveSelection(-1))
        #expect(intent(VirtualKey.downArrow, [], "\u{F701}") == .moveSelection(1))
    }

    @Test func controlPAndControlNMoveTheSelection() {
        #expect(intent(VirtualKey.ansiP, [.control], "p") == .moveSelection(-1))
        #expect(intent(VirtualKey.ansiN, [.control], "n") == .moveSelection(1))
    }

    @Test func returnPerformsThePrimaryAction() {
        #expect(intent(VirtualKey.returnKey, [], "\r") == .performPrimary)
        #expect(intent(VirtualKey.keypadEnter, [], "\u{03}") == .performPrimary)
    }

    @Test func tabCompletes() {
        #expect(intent(VirtualKey.tab, [], "\t") == .tabComplete)
    }

    @Test func commandKTogglesTheActionPanel() {
        #expect(intent(VirtualKey.ansiK, [.command], "k") == .toggleActionPanel)
    }

    @Test(arguments: zip(VirtualKey.ansiDigits, 1...9))
    func commandDigitActivatesThatRow(keyCode: UInt16, position: Int) {
        #expect(intent(keyCode, [.command], String(position)) == .activateIndex(position))
    }

    @Test func commandLeftBracketGoesBack() {
        #expect(intent(VirtualKey.ansiLeftBracket, [.command], "[") == .back)
    }

    @Test func deleteGoesBackOnlyFromAnEmptyFieldInsideAScreen() {
        let emptyInScreen = KeyRouter.Context(queryIsEmpty: true, depth: 1)
        let typedInScreen = KeyRouter.Context(queryIsEmpty: false, depth: 2)
        let filteringActions = KeyRouter.Context(
            actionPanelOpen: true, queryIsEmpty: true, depth: 1)

        #expect(intent(VirtualKey.delete, in: emptyInScreen) == .back)
        #expect(intent(VirtualKey.delete, in: typedInScreen) == nil)
        #expect(intent(VirtualKey.delete, in: atRoot) == nil)
        #expect(intent(VirtualKey.delete, in: filteringActions) == nil)
    }

    // Holding Delete is how a half-written line is thrown away. The repeat that comes after
    // the last character is gone must not throw the screen away with it.
    @Test func heldDeleteDoesNotGoBack() {
        let repeating = KeyRouter.Context(queryIsEmpty: true, depth: 1, keyIsRepeating: true)

        #expect(intent(VirtualKey.delete, in: repeating) == nil)
        // ⌘[ has nothing to do with editing, and goes back however long it is held.
        #expect(intent(VirtualKey.ansiLeftBracket, [.command], "[", in: repeating) == .back)
    }

    @Test func commandCommaOpensSettings() {
        #expect(intent(VirtualKey.ansiComma, [.command], ",") == .openSettings)
    }

    @Test func shortcutOfTheSelectedItemPerformsItsAction() {
        let context = KeyRouter.Context(
            queryIsEmpty: false, depth: 0,
            selectedItemShortcuts: [
                commandReturn: reveal,
                KeyChord(keyCode: ansiC, modifiers: [.command, .shift], characters: "c"): open,
            ])

        #expect(
            intent(VirtualKey.returnKey, [.command], "\r", in: context) == .performAction(reveal))
        // charactersIgnoringModifiers still applies Shift.
        #expect(intent(ansiC, [.command, .shift], "C", in: context) == .performAction(open))
        #expect(intent(ansiC, [.command], "c", in: context) == nil)
    }

    // MARK: Priority

    @Test func fixedChordsWinOverItemShortcuts() {
        let greedy = KeyRouter.Context(
            queryIsEmpty: true, depth: 1,
            selectedItemShortcuts: [
                KeyChord(keyCode: VirtualKey.escape): open,
                KeyChord(keyCode: VirtualKey.returnKey): open,
                KeyChord(keyCode: VirtualKey.delete): open,
                KeyChord(keyCode: VirtualKey.ansiK, modifiers: [.command], characters: "k"): open,
                KeyChord(keyCode: VirtualKey.ansiDigits[2], modifiers: [.command]): open,
                KeyChord(keyCode: VirtualKey.ansiComma, modifiers: [.command]): open,
            ])

        #expect(intent(VirtualKey.escape, in: greedy) == .escape)
        #expect(intent(VirtualKey.returnKey, in: greedy) == .performPrimary)
        #expect(intent(VirtualKey.delete, in: greedy) == .back)
        #expect(intent(VirtualKey.ansiK, [.command], "k", in: greedy) == .toggleActionPanel)
        #expect(intent(VirtualKey.ansiDigits[2], [.command], "3", in: greedy) == .activateIndex(3))
        #expect(intent(VirtualKey.ansiComma, [.command], ",", in: greedy) == .openSettings)
    }

    @Test func deleteShortcutAppliesWhenDeleteDoesNotGoBack() {
        let context = KeyRouter.Context(
            queryIsEmpty: false, depth: 1,
            selectedItemShortcuts: [
                KeyChord(keyCode: VirtualKey.delete, modifiers: [.control]): open
            ])

        #expect(intent(VirtualKey.delete, [.control], in: context) == .performAction(open))
        #expect(intent(VirtualKey.delete, in: context) == nil)
    }

    @Test func digitRowIsMatchedByKeyCodeBeforeAnyCharacterRule() {
        // AZERTY types "&" on the 1 key without Shift.
        #expect(intent(VirtualKey.ansiDigits[0], [.command], "&") == .activateIndex(1))
        // A layout that typed "," on a digit key would still activate the row.
        #expect(intent(VirtualKey.ansiDigits[4], [.command], ",") == .activateIndex(5))
    }

    // MARK: Layouts

    @Test func nonASCIILayoutFallsBackToTheKeyPosition() {
        // What the Russian layout types on the K, P, N, [ and , keys.
        #expect(intent(VirtualKey.ansiK, [.command], "\u{043B}") == .toggleActionPanel)
        #expect(intent(VirtualKey.ansiP, [.control], "\u{0437}") == .moveSelection(-1))
        #expect(intent(VirtualKey.ansiN, [.control], "\u{0442}") == .moveSelection(1))
        #expect(intent(VirtualKey.ansiLeftBracket, [.command], "\u{0445}") == .back)
        #expect(intent(VirtualKey.ansiComma, [.command], "\u{0431}") == .openSettings)
        #expect(intent(VirtualKey.ansiK, [.command], nil) == .toggleActionPanel)
    }

    @Test func asciiLayoutIsMatchedByWhatTheKeyTypes() {
        // Dvorak: the physical K key types "t", and the physical V key types "k".
        #expect(intent(VirtualKey.ansiK, [.command], "t") == nil)
        #expect(intent(ansiV, [.command], "k") == .toggleActionPanel)
        // AZERTY: the comma is on the physical M key.
        #expect(intent(ansiM, [.command], ",") == .openSettings)
    }

    @Test func capsLockDoesNotChangeLetterChords() {
        #expect(intent(VirtualKey.ansiK, [.command], "K") == .toggleActionPanel)
        #expect(intent(VirtualKey.ansiN, [.control], "N") == .moveSelection(1))
    }

    @Test func shortcutOnANonASCIILayoutIsMatchedByKeyCode() {
        let context = KeyRouter.Context(
            queryIsEmpty: false, depth: 0,
            selectedItemShortcuts: [
                KeyChord(keyCode: ansiC, modifiers: [.command, .shift], characters: "c"): open
            ])

        // The Russian layout types Cyrillic letters on the C and V keys.
        #expect(intent(ansiC, [.command, .shift], "\u{0421}", in: context) == .performAction(open))
        #expect(intent(ansiV, [.command, .shift], "\u{041C}", in: context) == nil)
    }

    // MARK: Fall-through

    @Test func editingChordsFallThroughToTheFieldEditor() {
        // Select All, Copy, Paste, Cut, Undo and Redo belong to the Edit menu.
        #expect(intent(ansiA, [.command], "a") == nil)
        #expect(intent(ansiC, [.command], "c") == nil)
        #expect(intent(ansiV, [.command], "v") == nil)
        #expect(intent(ansiX, [.command], "x") == nil)
        #expect(intent(ansiZ, [.command], "z") == nil)
        #expect(intent(ansiZ, [.command, .shift], "Z") == nil)
    }

    @Test func typingFallsThrough() {
        #expect(intent(ansiA, [], "a") == nil)
        #expect(intent(ansiA, [.shift], "A") == nil)
        #expect(intent(VirtualKey.space, [], " ") == nil)
        #expect(intent(VirtualKey.ansiK, [], "k") == nil)
        #expect(intent(VirtualKey.ansiDigits[0], [], "1") == nil)
        #expect(intent(VirtualKey.ansiComma, [], ",") == nil)
    }

    @Test func chordsWithOtherModifiersFallThrough() {
        #expect(intent(VirtualKey.ansiK, [.command, .shift], "K") == nil)
        #expect(intent(VirtualKey.ansiK, [.control], "k") == nil)
        #expect(intent(VirtualKey.ansiP, [.command, .control], "p") == nil)
        #expect(intent(VirtualKey.ansiDigits[0], [.command, .shift], "1") == nil)
        #expect(intent(VirtualKey.returnKey, [.option], "\r") == nil)
        #expect(intent(VirtualKey.downArrow, [.shift], "\u{F701}") == nil)
        #expect(intent(VirtualKey.tab, [.shift], "\u{19}") == nil)
        #expect(intent(VirtualKey.escape, [.shift], "\u{1B}") == nil)
    }

    @Test func everythingFallsThroughWhileAnInputMethodIsComposing() {
        let composing = KeyRouter.Context(
            queryIsEmpty: false, depth: 1,
            selectedItemShortcuts: [commandReturn: open],
            hasMarkedText: true)

        #expect(intent(VirtualKey.escape, in: composing) == nil)
        #expect(intent(VirtualKey.returnKey, in: composing) == nil)
        #expect(intent(VirtualKey.downArrow, in: composing) == nil)
        #expect(intent(VirtualKey.tab, in: composing) == nil)
        #expect(intent(VirtualKey.ansiK, [.command], "k", in: composing) == nil)
        #expect(intent(VirtualKey.returnKey, [.command], "\r", in: composing) == nil)
    }

    // MARK: Swallowed

    @Test func commandQHasNoIntentButIsKeptFromAppKit() {
        #expect(intent(VirtualKey.ansiQ, [.command], "q") == nil)
        #expect(swallows(VirtualKey.ansiQ, [.command], "q"))
    }

    @Test func commandQIsToldByWhatTheKeyTypes() {
        // On Dvorak the ANSI "X" key types "q", and the ANSI "Q" key types an apostrophe.
        #expect(swallows(ansiX, [.command], "q"))
        #expect(!swallows(VirtualKey.ansiQ, [.command], "'"))
        // A Russian layout types "й" on the ANSI "Q" key.
        #expect(swallows(VirtualKey.ansiQ, [.command], "\u{0439}"))
    }

    @Test func otherChordsAreNotSwallowed() {
        // The Q key with other modifiers, and typed on its own.
        #expect(!swallows(VirtualKey.ansiQ, [], "q"))
        #expect(!swallows(VirtualKey.ansiQ, [.shift], "Q"))
        #expect(!swallows(VirtualKey.ansiQ, [.command, .shift], "Q"))
        #expect(!swallows(VirtualKey.ansiQ, [.control, .command], "q"))
        // The editing chords have to reach the Edit menu.
        #expect(!swallows(ansiC, [.command], "c"))
        #expect(!swallows(ansiV, [.command], "v"))
        #expect(!swallows(ansiX, [.command], "x"))
    }

    // MARK: Under a confirmation

    private let confirming = KeyRouter.Context(
        confirmationOpen: true, queryIsEmpty: false, depth: 0)

    @Test func confirmationTakesReturnAndEscape() {
        #expect(intent(VirtualKey.returnKey, [], "\r", in: confirming) == .performPrimary)
        #expect(intent(VirtualKey.keypadEnter, [], "\u{03}", in: confirming) == .performPrimary)
        #expect(intent(VirtualKey.escape, [], "\u{1B}", in: confirming) == .escape)
    }

    // The Return that started the action is often still held when the question comes up.
    @Test func heldReturnDoesNotAnswerAConfirmation() {
        let repeating = KeyRouter.Context(
            confirmationOpen: true, queryIsEmpty: false, depth: 0, keyIsRepeating: true)

        #expect(intent(VirtualKey.returnKey, [], "\r", in: repeating) == nil)
        #expect(intent(VirtualKey.keypadEnter, [], "\u{03}", in: repeating) == nil)
        // It is kept from the field all the same.
        #expect(swallows(VirtualKey.returnKey, [], "\r", in: repeating))
        // A held Esc still says no.
        #expect(intent(VirtualKey.escape, [], "\u{1B}", in: repeating) == .escape)
    }

    // The Return that opened a list is often still held when its rows are there, and its
    // repeat would run the first of them.
    @Test func heldReturnActsOnlyOnce() {
        let repeating = KeyRouter.Context(queryIsEmpty: false, depth: 0, keyIsRepeating: true)
        let repeatingInAList = KeyRouter.Context(queryIsEmpty: true, depth: 1, keyIsRepeating: true)

        #expect(intent(VirtualKey.returnKey, [], "\r", in: repeating) == nil)
        #expect(intent(VirtualKey.keypadEnter, [], "\u{03}", in: repeating) == nil)
        #expect(intent(VirtualKey.returnKey, [], "\r", in: repeatingInAList) == nil)
        // The field editor does not get it either: it would end editing.
        #expect(swallows(VirtualKey.returnKey, [], "\r", in: repeating))
        #expect(swallows(VirtualKey.keypadEnter, [], "\u{03}", in: repeating))

        // A press of its own is Return as ever, and so is a held ⌘↩ of an item.
        #expect(intent(VirtualKey.returnKey, [], "\r") == .performPrimary)
        #expect(!swallows(VirtualKey.returnKey, [], "\r"))
        let withShortcut = KeyRouter.Context(
            queryIsEmpty: false, depth: 0, selectedItemShortcuts: [commandReturn: reveal],
            keyIsRepeating: true)
        #expect(
            intent(VirtualKey.returnKey, [.command], "\r", in: withShortcut)
                == .performAction(reveal))
    }

    // ⌘1 held on "Search Snippets" would otherwise paste the first snippet of the list it
    // opened.
    @Test func heldCommandDigitActsOnlyOnce() {
        let repeating = KeyRouter.Context(queryIsEmpty: false, depth: 0, keyIsRepeating: true)
        let firstDigit = VirtualKey.ansiDigits[0]

        #expect(intent(firstDigit, [.command], "1", in: repeating) == nil)
        // Unhandled, it would go on to AppKit as a key equivalent nobody has.
        #expect(swallows(firstDigit, [.command], "1", in: repeating))

        #expect(intent(firstDigit, [.command], "1") == .activateIndex(1))
    }

    @Test func heldReturnOfAnInputMethodStaysWithIt() {
        let composing = KeyRouter.Context(
            queryIsEmpty: false, depth: 0, hasMarkedText: true, keyIsRepeating: true)

        #expect(intent(VirtualKey.returnKey, [], "\r", in: composing) == nil)
        #expect(!swallows(VirtualKey.returnKey, [], "\r", in: composing))
    }

    @Test func confirmationKeepsEveryOtherKeyFromTheLauncherAndFromTheField() {
        // Keys the launcher would otherwise route.
        #expect(intent(VirtualKey.downArrow, [], "\u{F701}", in: confirming) == nil)
        #expect(intent(VirtualKey.ansiK, [.command], "k", in: confirming) == nil)
        #expect(intent(VirtualKey.returnKey, [.command], "\r", in: confirming) == nil)
        #expect(swallows(VirtualKey.downArrow, [], "\u{F701}", in: confirming))
        #expect(swallows(VirtualKey.ansiK, [.command], "k", in: confirming))
        // Typing and pasting, which would change the query behind the question.
        #expect(swallows(ansiA, [], "a", in: confirming))
        #expect(swallows(ansiV, [.command], "v", in: confirming))
    }

    @Test func itemShortcutsDoNotFireUnderAConfirmation() {
        let context = KeyRouter.Context(
            confirmationOpen: true, queryIsEmpty: false, depth: 0,
            selectedItemShortcuts: [commandReturn: reveal])

        #expect(intent(VirtualKey.returnKey, [.command], "\r", in: context) == nil)
    }

    @Test func composingInputMethodKeepsItsKeysUnderAConfirmation() {
        let composing = KeyRouter.Context(
            confirmationOpen: true, queryIsEmpty: false, depth: 0, hasMarkedText: true)

        #expect(intent(VirtualKey.returnKey, [], "\r", in: composing) == nil)
        #expect(!swallows(VirtualKey.returnKey, [], "\r", in: composing))
        // ⌘Q is kept from AppKit all the same.
        #expect(swallows(VirtualKey.ansiQ, [.command], "q", in: composing))
    }

    // MARK: With the search field hidden

    @Test func keysThatWouldBeTypedAreKeptWhileTheFieldIsHidden() {
        let hidden = KeyRouter.Context(queryIsEmpty: true, depth: 1, searchFieldHidden: true)

        // The launcher's own keys still work.
        #expect(intent(VirtualKey.escape, [], "\u{1B}", in: hidden) == .escape)
        #expect(intent(VirtualKey.returnKey, [], "\r", in: hidden) == .performPrimary)
        // Everything else would find no field to go to.
        #expect(intent(ansiA, [], "a", in: hidden) == nil)
        #expect(swallows(ansiA, [], "a", in: hidden))
    }

    // MARK: Reserved for the launcher

    @Test func chordsOfTheRoutingTableAreReserved() {
        #expect(reserves(VirtualKey.escape, [], "\u{1B}"))
        #expect(reserves(VirtualKey.returnKey, [], "\r"))
        #expect(reserves(VirtualKey.tab, [], "\t"))
        #expect(reserves(VirtualKey.delete, [], "\u{7F}"))
        #expect(reserves(VirtualKey.downArrow, [], "\u{F701}"))
        #expect(reserves(VirtualKey.ansiN, [.control], "n"))
        #expect(reserves(VirtualKey.ansiK, [.command], "k"))
        #expect(reserves(VirtualKey.ansiDigits[2], [.command], "3"))
        #expect(reserves(VirtualKey.ansiLeftBracket, [.command], "["))
        #expect(reserves(VirtualKey.ansiComma, [.command], ","))
        #expect(reserves(VirtualKey.ansiQ, [.command], "q"))
    }

    @Test func editingChordsOfTheSearchFieldAreReserved() {
        #expect(reserves(ansiA, [.command], "a"))
        #expect(reserves(ansiC, [.command], "c"))
        #expect(reserves(ansiV, [.command], "v"))
        #expect(reserves(ansiX, [.command], "x"))
        #expect(reserves(ansiZ, [.command], "z"))
        #expect(reserves(ansiZ, [.command, .shift], "z"))
    }

    @Test func chordsTheLauncherDoesNotUseAreFreeForActions() {
        #expect(!reserves(VirtualKey.returnKey, [.command], "\r"))
        #expect(!reserves(VirtualKey.returnKey, [.option], "\r"))
        #expect(!reserves(VirtualKey.tab, [.shift], "\t"))
        #expect(!reserves(VirtualKey.ansiK, [.command, .shift], "k"))
        #expect(!reserves(ansiC, [.command, .shift], "c"))
        #expect(!reserves(VirtualKey.delete, [.command], "\u{7F}"))
    }

    // MARK: Context from state

    @Test func contextDescribesTheLauncherState() {
        var state = LauncherState()
        var context = KeyRouter.Context(state: state)
        #expect(context.depth == 0)
        #expect(context.queryIsEmpty)
        #expect(!context.actionPanelOpen)

        _ = state.apply(
            .push(ScreenRequest(feature: FeatureID(rawValue: "clipboard"), screen: "history")))
        _ = state.apply(.queryChanged("inv"))
        context = KeyRouter.Context(state: state)
        #expect(context.depth == 1)
        #expect(!context.queryIsEmpty)

        // The field shows the action panel's empty filter, not the screen's query.
        _ = state.apply(.toggleActionPanel)
        context = KeyRouter.Context(state: state, selectedItemShortcuts: [commandReturn: open])
        #expect(context.actionPanelOpen)
        #expect(context.queryIsEmpty)
        #expect(context.selectedItemShortcuts == [commandReturn: open])
        #expect(!context.confirmationOpen)

        _ = state.apply(.askConfirmation(Confirmation(title: "Sure?", confirmTitle: "Yes")))
        context = KeyRouter.Context(state: state, searchFieldHidden: true)
        #expect(context.confirmationOpen)
        #expect(context.searchFieldHidden)
    }
}
