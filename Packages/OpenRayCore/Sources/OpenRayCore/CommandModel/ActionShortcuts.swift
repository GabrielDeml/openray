/// Which key chord runs which of an item's actions while the item is selected
/// (docs/DESIGN.md §4.2.2). The key monitor and the action panel both ask here, so the panel
/// never shows a shortcut that the keyboard does not answer to.
public enum ActionShortcuts {
    /// ⌘↩, which an item's second action gets when it has no shortcut of its own.
    public static let secondAction = KeyChord(
        keyCode: VirtualKey.returnKey, modifiers: [.command])

    /// The chord that runs `actions[index]`, or nil when it has none.
    ///
    /// A shortcut the launcher reserves (`KeyRouter.reserves`) is not offered. The registry
    /// removes those from indexed items and logs them; rows that a source computes for a query
    /// and the rows of a screen never pass the registry, so they are left out here as well.
    ///
    /// Of two actions whose shortcuts one key press would trigger, the earlier one keeps its
    /// shortcut and the later one has none. So a press never has two actions to choose from.
    public static func shortcut(
        ofActionAt index: Int, in actions: [ActionDescriptor]
    ) -> KeyChord? {
        guard let chord = wantedShortcut(ofActionAt: index, in: actions) else { return nil }

        for earlierIndex in actions.indices where earlierIndex < index {
            guard let earlierChord = wantedShortcut(ofActionAt: earlierIndex, in: actions) else {
                continue
            }
            // Not `==`: two chords can be one key recorded in two ways, by what it types and
            // by its key code.
            if earlierChord.isTriggered(by: chord) {
                return nil
            }
        }
        return chord
    }

    /// The chord the action would have if no earlier action stood in its way.
    private static func wantedShortcut(
        ofActionAt index: Int, in actions: [ActionDescriptor]
    ) -> KeyChord? {
        if let ownShortcut = actions[index].shortcut {
            let isReserved = KeyRouter().reserves(ownShortcut)
            return isReserved ? nil : ownShortcut
        }

        guard index == 1 else { return nil }
        // Another action that asked for ⌘↩ itself keeps it.
        let isTaken = actions.contains { action in
            action.shortcut?.isTriggered(by: secondAction) == true
        }
        return isTaken ? nil : secondAction
    }

    /// Every shortcut of `actions`, as `KeyRouter.Context.selectedItemShortcuts` takes them.
    public static func shortcuts(of actions: [ActionDescriptor]) -> [KeyChord: ActionID] {
        var shortcuts: [KeyChord: ActionID] = [:]
        for index in actions.indices {
            if let chord = shortcut(ofActionAt: index, in: actions) {
                shortcuts[chord] = actions[index].id
            }
        }
        return shortcuts
    }
}
