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
    }
}
