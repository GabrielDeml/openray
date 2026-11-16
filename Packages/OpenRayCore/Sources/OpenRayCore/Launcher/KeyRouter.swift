/// Maps a key press in the launcher panel to an intent. Every key the launcher reacts to is
/// decided here.
public struct KeyRouter: Sendable {
    public struct Context: Sendable {
        public var actionPanelOpen: Bool
        /// Whether the panel is asking the user to confirm something.
        public var confirmationOpen: Bool
        /// Whether the search field is empty.
        public var queryIsEmpty: Bool
        /// How many screens are pushed; 0 is root search.
        public var depth: Int
        /// The shortcuts of the selected item's actions.
        public var selectedItemShortcuts: [KeyChord: ActionID]
        /// Whether an input method is composing text in the search field.
        public var hasMarkedText: Bool
        /// Whether the screen on top has hidden the search field, so that no key can be typed
        /// into it.
        public var searchFieldHidden: Bool
        /// Whether this press is the key repeating because it is held down.
        public var keyIsRepeating: Bool

        public init(
            actionPanelOpen: Bool = false,
            confirmationOpen: Bool = false,
            queryIsEmpty: Bool,
            depth: Int,
            selectedItemShortcuts: [KeyChord: ActionID] = [:],
            hasMarkedText: Bool = false,
            searchFieldHidden: Bool = false,
            keyIsRepeating: Bool = false
        ) {
            self.actionPanelOpen = actionPanelOpen
            self.confirmationOpen = confirmationOpen
            self.queryIsEmpty = queryIsEmpty
            self.depth = depth
            self.selectedItemShortcuts = selectedItemShortcuts
            self.hasMarkedText = hasMarkedText
            self.searchFieldHidden = searchFieldHidden
            self.keyIsRepeating = keyIsRepeating
        }

        public init(
            state: LauncherState,
            selectedItemShortcuts: [KeyChord: ActionID] = [:],
            hasMarkedText: Bool = false,
            searchFieldHidden: Bool = false,
            keyIsRepeating: Bool = false
        ) {
            self.init(
                actionPanelOpen: state.actionPanel != nil,
                confirmationOpen: state.confirmation != nil,
                queryIsEmpty: state.searchFieldText.isEmpty,
                depth: state.depth,
                selectedItemShortcuts: selectedItemShortcuts,
                hasMarkedText: hasMarkedText,
                searchFieldHidden: searchFieldHidden,
                keyIsRepeating: keyIsRepeating
            )
        }
    }

    public init() {}

    /// - Returns: The intent for `chord`, or `nil` to let AppKit handle the key.
    public func intent(for chord: KeyChord, in context: Context) -> LauncherIntent? {
        // Composition owns Return, the arrows and Esc until the input method commits.
        if context.hasMarkedText { return nil }
        if context.confirmationOpen { return confirmationIntent(for: chord, in: context) }
        // The launcher's own keys win over the shortcuts of the selected item's actions.
        if let intent = launcherKeyIntent(for: chord, in: context) { return intent }

        guard let action = itemShortcutAction(for: chord, in: context) else { return nil }
        // A shortcut acts once for each press, like Return. ⌘R held on the output of a
        // script that is over in a moment would run it again for as long as the key is down.
        if context.keyIsRepeating { return nil }
        return .performAction(action)
    }

    /// Whether the launcher keeps `chord` from AppKit although it has no intent for it.
    ///
    /// ⌘Q is always kept. Let through, it would reach Quit in the main menu and end OpenRay,
    /// while the menu bar still shows the app behind the panel. Whoever presses ⌘Q there does
    /// not expect the launcher and its hotkey to be gone.
    ///
    /// Every other key is kept while it has nowhere sensible to go: under a confirmation, where
    /// it would edit the query behind the question, and on a screen that hides the search
    /// field, where AppKit would find no one to take it and beep. A held Return, a held
    /// ⌘1 to ⌘9 and a held shortcut of the selected item are kept as well: they have no
    /// intent, and the field editor would end editing on the first and beep at the others.
    public func swallows(_ chord: KeyChord, in context: Context) -> Bool {
        if isQuit(chord) { return true }
        // An input method that is composing gets all its keys, as in `intent(for:in:)`.
        if context.hasMarkedText { return false }
        if context.keyIsRepeating {
            if isReturn(chord) || isRowDigit(chord) { return true }
            if itemShortcutAction(for: chord, in: context) != nil { return true }
        }
        return context.confirmationOpen || context.searchFieldHidden
    }

    /// Whether the launcher keeps `chord` for itself, in which case no action may have it as its
    /// shortcut: the chords of the routing table, ⌘Q, and the editing chords of the search
    /// field. An action with ⌘C would take Copy away from the field.
    public func reserves(_ chord: KeyChord) -> Bool {
        if isQuit(chord) || isEditingChord(chord) { return true }
        // Delete is the launcher's only on a screen with an empty field. It is reserved
        // everywhere, so that a shortcut does not work in one place and not in another.
        let onAScreenWithAnEmptyField = Context(queryIsEmpty: true, depth: 1)
        return launcherKeyIntent(for: chord, in: onAScreenWithAnEmptyField) != nil
    }

    private func isQuit(_ chord: KeyChord) -> Bool {
        chord.modifiers == [.command] && chord.types("q", ansiKeyCode: VirtualKey.ansiQ)
    }

    /// Return or keypad Enter with no modifier.
    private func isReturn(_ chord: KeyChord) -> Bool {
        let isReturnKey =
            chord.keyCode == VirtualKey.returnKey || chord.keyCode == VirtualKey.keypadEnter
        return chord.modifiers.isEmpty && isReturnKey
    }

    /// ⌘1 to ⌘9, by the key code of the digit row.
    private func isRowDigit(_ chord: KeyChord) -> Bool {
        chord.modifiers == [.command] && VirtualKey.ansiDigits.contains(chord.keyCode)
    }

    /// Select All, Copy, Paste, Cut, Undo and Redo, which the field editor performs through the
    /// Edit menu.
    private func isEditingChord(_ chord: KeyChord) -> Bool {
        switch chord.modifiers {
        case [.command]:
            return chord.types("a", ansiKeyCode: VirtualKey.ansiA)
                || chord.types("c", ansiKeyCode: VirtualKey.ansiC)
                || chord.types("v", ansiKeyCode: VirtualKey.ansiV)
                || chord.types("x", ansiKeyCode: VirtualKey.ansiX)
                || chord.types("z", ansiKeyCode: VirtualKey.ansiZ)
        case [.command, .shift]:
            return chord.types("z", ansiKeyCode: VirtualKey.ansiZ)
        default:
            return false
        }
    }

    /// A confirmation has two keys: Return says yes and Esc says no. The reducer turns these
    /// two intents into the answer while a confirmation is up.
    private func confirmationIntent(for chord: KeyChord, in context: Context) -> LauncherIntent? {
        guard chord.modifiers.isEmpty else { return nil }
        switch chord.keyCode {
        case VirtualKey.returnKey, VirtualKey.keypadEnter:
            // The Return that asked for the action is often still down when the question
            // comes up, and its repeat would say yes to a shutdown nobody has read. Yes takes
            // a press of its own.
            if context.keyIsRepeating { return nil }
            return .performPrimary
        case VirtualKey.escape:
            return .escape
        default:
            return nil
        }
    }

    private func launcherKeyIntent(for chord: KeyChord, in context: Context) -> LauncherIntent? {
        switch chord.modifiers {
        case []:
            switch chord.keyCode {
            case VirtualKey.escape: return .escape
            case VirtualKey.upArrow: return .moveSelection(-1)
            case VirtualKey.downArrow: return .moveSelection(1)
            case VirtualKey.returnKey, VirtualKey.keypadEnter:
                // Return acts once for each press. Held a moment too long on "Search
                // Snippets", its repeat would land on the list that the press brought up and
                // paste the first snippet.
                if context.keyIsRepeating { return nil }
                return .performPrimary
            case VirtualKey.tab: return .tabComplete
            case VirtualKey.delete:
                // Delete on an empty field leaves the screen. While the action panel is open the
                // field holds the panel's filter, and Delete stays an editing key.
                let leavesScreen =
                    context.queryIsEmpty && context.depth > 0 && !context.actionPanelOpen
                // Whoever holds Delete to empty the field does not mean to leave once it is
                // empty. Leaving takes a press of its own.
                if leavesScreen && !context.keyIsRepeating {
                    return .back
                }
                return nil
            default: return nil
            }
        case [.control]:
            if chord.types("p", ansiKeyCode: VirtualKey.ansiP) { return .moveSelection(-1) }
            if chord.types("n", ansiKeyCode: VirtualKey.ansiN) { return .moveSelection(1) }
            return nil
        case [.command]:
            if chord.types("k", ansiKeyCode: VirtualKey.ansiK) { return .toggleActionPanel }
            // By key code: the digit row needs Shift on AZERTY, and ⌘⇧1 is a different chord.
            if let digit = VirtualKey.ansiDigits.firstIndex(of: chord.keyCode) {
                // ⌘n is Return on the n-th row, and like Return it acts once for each press.
                if context.keyIsRepeating { return nil }
                return .activateIndex(digit + 1)
            }
            if chord.types("[", ansiKeyCode: VirtualKey.ansiLeftBracket) { return .back }
            if chord.types(",", ansiKeyCode: VirtualKey.ansiComma) { return .openSettings }
            return nil
        default:
            return nil
        }
    }

    /// The action of the selected item whose shortcut the chord triggers.
    private func itemShortcutAction(for chord: KeyChord, in context: Context) -> ActionID? {
        // Two shortcuts can match one key press when they differ only in what they record of the
        // key. Dictionary order changes from run to run, so the lowest action ID wins.
        var lowest: ActionID?
        for (shortcut, action) in context.selectedItemShortcuts {
            guard shortcut.isTriggered(by: chord) else { continue }
            if let current = lowest, current.rawValue <= action.rawValue { continue }
            lowest = action
        }
        return lowest
    }
}
