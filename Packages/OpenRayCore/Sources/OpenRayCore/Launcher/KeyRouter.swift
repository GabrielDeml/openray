/// Maps a key press in the launcher panel to an intent. Every key the launcher reacts to is
/// decided here.
public struct KeyRouter: Sendable {
    public struct Context: Sendable {
        public var actionPanelOpen: Bool
        /// Whether the search field is empty.
        public var queryIsEmpty: Bool
        /// How many screens are pushed; 0 is root search.
        public var depth: Int
        /// The shortcuts of the selected item's actions.
        public var selectedItemShortcuts: [KeyChord: ActionID]
        /// Whether an input method is composing text in the search field.
        public var hasMarkedText: Bool

        public init(
            actionPanelOpen: Bool = false,
            queryIsEmpty: Bool,
            depth: Int,
            selectedItemShortcuts: [KeyChord: ActionID] = [:],
            hasMarkedText: Bool = false
        ) {
            self.actionPanelOpen = actionPanelOpen
            self.queryIsEmpty = queryIsEmpty
            self.depth = depth
            self.selectedItemShortcuts = selectedItemShortcuts
            self.hasMarkedText = hasMarkedText
        }

        public init(
            state: LauncherState,
            selectedItemShortcuts: [KeyChord: ActionID] = [:],
            hasMarkedText: Bool = false
        ) {
            self.init(
                actionPanelOpen: state.actionPanel != nil,
                queryIsEmpty: state.searchFieldText.isEmpty,
                depth: state.depth,
                selectedItemShortcuts: selectedItemShortcuts,
                hasMarkedText: hasMarkedText
            )
        }
    }

    public init() {}

    /// - Returns: The intent for `chord`, or `nil` to let AppKit handle the key.
    public func intent(for chord: KeyChord, in context: Context) -> LauncherIntent? {
        // Composition owns Return, the arrows and Esc until the input method commits.
        if context.hasMarkedText { return nil }
        // The launcher's own keys win over the shortcuts of the selected item's actions.
        if let intent = launcherKeyIntent(for: chord, in: context) { return intent }
        return itemShortcutIntent(for: chord, in: context)
    }

    private func launcherKeyIntent(for chord: KeyChord, in context: Context) -> LauncherIntent? {
        switch chord.modifiers {
        case []:
            switch chord.keyCode {
            case VirtualKey.escape: return .escape
            case VirtualKey.upArrow: return .moveSelection(-1)
            case VirtualKey.downArrow: return .moveSelection(1)
            case VirtualKey.returnKey, VirtualKey.keypadEnter: return .performPrimary
            case VirtualKey.tab: return .tabComplete
            case VirtualKey.delete:
                // Delete on an empty field leaves the screen. While the action panel is open the
                // field holds the panel's filter, and Delete stays an editing key.
                if context.queryIsEmpty && context.depth > 0 && !context.actionPanelOpen {
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
                return .activateIndex(digit + 1)
            }
            if chord.types("[", ansiKeyCode: VirtualKey.ansiLeftBracket) { return .back }
            if chord.types(",", ansiKeyCode: VirtualKey.ansiComma) { return .openSettings }
            return nil
        default:
            return nil
        }
    }

    private func itemShortcutIntent(for chord: KeyChord, in context: Context) -> LauncherIntent? {
        // Two shortcuts can match one key press when they differ only in what they record of the
        // key. Dictionary order changes from run to run, so the lowest action ID wins.
        var lowest: ActionID?
        for (shortcut, action) in context.selectedItemShortcuts {
            guard shortcut.isTriggered(by: chord) else { continue }
            if let current = lowest, current.rawValue <= action.rawValue { continue }
            lowest = action
        }
        guard let lowest else { return nil }
        return .performAction(lowest)
    }
}
