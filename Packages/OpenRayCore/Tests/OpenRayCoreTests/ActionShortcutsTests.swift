import Testing

import OpenRayCore

@Suite struct ActionShortcutsTests {
    private let commandReturn = KeyChord(keyCode: VirtualKey.returnKey, modifiers: [.command])
    private let commandShiftF = KeyChord(
        keyCode: 0x03, modifiers: [.command, .shift], characters: "f")
    private let commandC = KeyChord(
        keyCode: VirtualKey.ansiC, modifiers: [.command], characters: "c")

    private func action(_ name: String, shortcut: KeyChord? = nil) -> ActionDescriptor {
        ActionDescriptor(id: ActionID(rawValue: name), title: name, shortcut: shortcut) { _ in
            .keepOpen
        }
    }

    @Test func secondActionGetsCommandReturn() {
        let actions = [action("open"), action("reveal"), action("quit")]

        #expect(ActionShortcuts.shortcut(ofActionAt: 0, in: actions) == nil)
        #expect(ActionShortcuts.shortcut(ofActionAt: 1, in: actions) == commandReturn)
        #expect(ActionShortcuts.shortcut(ofActionAt: 2, in: actions) == nil)
    }

    @Test func secondActionKeepsAShortcutOfItsOwn() {
        let actions = [action("open"), action("reveal", shortcut: commandShiftF)]

        #expect(ActionShortcuts.shortcut(ofActionAt: 1, in: actions) == commandShiftF)
    }

    @Test func commandReturnStaysWithTheActionThatAskedForIt() {
        let actions = [action("open"), action("reveal"), action("quit", shortcut: commandReturn)]

        #expect(ActionShortcuts.shortcut(ofActionAt: 1, in: actions) == nil)
        #expect(ActionShortcuts.shortcut(ofActionAt: 2, in: actions) == commandReturn)
    }

    @Test func reservedShortcutIsNotOffered() {
        let actions = [action("open"), action("reveal"), action("copy", shortcut: commandC)]

        #expect(ActionShortcuts.shortcut(ofActionAt: 2, in: actions) == nil)
        #expect(ActionShortcuts.shortcuts(of: actions) == [commandReturn: actions[1].id])
    }

    @Test func shortcutsOfAnItemMapEachChordToItsAction() {
        let actions = [action("open"), action("reveal"), action("find", shortcut: commandShiftF)]

        let shortcuts = ActionShortcuts.shortcuts(of: actions)

        #expect(shortcuts == [commandReturn: actions[1].id, commandShiftF: actions[2].id])
    }

    @Test func ofTwoActionsWithOneChordTheEarlierKeepsIt() {
        let actions = [
            action("open"), action("find", shortcut: commandShiftF),
            action("filter", shortcut: commandShiftF),
        ]

        #expect(ActionShortcuts.shortcuts(of: actions) == [commandShiftF: actions[1].id])
    }

    // One key can be recorded by what it types or by its key code alone. The key press
    // triggers both, so they count as the same chord.
    @Test func sameKeyRecordedInTwoWaysBelongsToTheEarlierActionToo() {
        let byKeyCode = KeyChord(keyCode: 0x03, modifiers: [.command, .shift])
        let actions = [
            action("open"), action("find", shortcut: commandShiftF),
            action("filter", shortcut: byKeyCode),
        ]

        #expect(ActionShortcuts.shortcut(ofActionAt: 2, in: actions) == nil)
        #expect(ActionShortcuts.shortcuts(of: actions) == [commandShiftF: actions[1].id])
    }

    @Test func itemWithOneActionHasNoShortcuts() {
        #expect(ActionShortcuts.shortcuts(of: [action("open")]).isEmpty)
        #expect(ActionShortcuts.shortcuts(of: []).isEmpty)
    }
}

@Suite struct ActionPanelFilterTests {
    private func action(_ title: String) -> ActionDescriptor {
        ActionDescriptor(id: ActionID(rawValue: title), title: title) { _ in .keepOpen }
    }

    private func titles(_ actions: [ActionDescriptor]) -> [String] {
        actions.map(\.title)
    }

    private var appActions: [ActionDescriptor] {
        [action("Open"), action("Show in Finder"), action("Quit"), action("Hide from Root Search")]
    }

    @Test func emptyFilterKeepsEveryAction() {
        let listed = ActionPanelFilter.actions(appActions, matching: "")

        #expect(titles(listed) == ["Open", "Show in Finder", "Quit", "Hide from Root Search"])
    }

    @Test func filterKeepsTheActionsItMatchesInTheirOwnOrder() {
        // "Hide from Root Search" starts with the filter and still stays below "Show in Finder".
        let listed = ActionPanelFilter.actions(appActions, matching: "hi")

        #expect(titles(listed) == ["Show in Finder", "Hide from Root Search"])
    }

    @Test func filterIsFoldedLikeASearchQuery() {
        let listed = ActionPanelFilter.actions(appActions, matching: "  QUIT ")

        #expect(titles(listed) == ["Quit"])
    }

    @Test func filterThatMatchesNothingListsNothing() {
        #expect(ActionPanelFilter.actions(appActions, matching: "zzz").isEmpty)
    }
}
