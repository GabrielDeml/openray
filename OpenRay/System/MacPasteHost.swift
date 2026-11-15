import AppKit
import OpenRayCore

/// The Mac's side of the paste path: the general pasteboard, synthetic key presses, and the
/// windows that have to get out of the way (docs/DESIGN.md §4.1.7). `PasteService` in Core
/// decides what happens when; this only does it.
///
/// Nothing else in OpenRay writes the general pasteboard or posts a key event.
final class MacPasteHost: PasteHost {
    /// Set by `AppDelegate` once the launcher exists; the launcher needs the paste service,
    /// which needs this host, first.
    weak var launcher: LauncherController?

    private let focusRestorer: FocusRestorer
    private let hud: HUDController

    init(focusRestorer: FocusRestorer, hud: HUDController) {
        self.focusRestorer = focusRestorer
        self.hud = hud
    }

    func writePasteboard(_ representations: [ClipRepresentation]) -> Int {
        let pasteboard = NSPasteboard.general
        var types: [NSPasteboard.PasteboardType] = []
        for representation in representations {
            types.append(NSPasteboard.PasteboardType(representation.uti))
        }

        // Declaring the types takes the pasteboard over and returns the change count of this
        // write; setting the data afterwards does not change it. The count is not read back
        // from the pasteboard, which would be one more access to it than the write needs.
        let changeCount = pasteboard.declareTypes(types, owner: nil)
        for representation in representations {
            let type = NSPasteboard.PasteboardType(representation.uti)
            let wasWritten = pasteboard.setData(representation.data, forType: type)
            if !wasWritten {
                Log.launcher.error(
                    "Could not write \(representation.uti, privacy: .public) to the pasteboard")
            }
        }
        return changeCount
    }

    func hideLauncher() {
        launcher?.hide()
    }

    var isOpenRayActive: Bool {
        NSApp.isActive
    }

    func restoreFocus() async -> Bool {
        await focusRestorer.restore()
    }

    var frontmostAppPID: pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func post(_ chord: KeyChord) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = keyCode(for: chord)
        // Set on both events, also when the chord has no modifiers: an event without flags of
        // its own takes the modifiers that are held down, and ⌘ usually still is, from the ⌘↩
        // that asked for the paste.
        let flags = eventFlags(for: chord.modifiers)

        for isKeyDown in [true, false] {
            let event = CGEvent(
                keyboardEventSource: source, virtualKey: keyCode, keyDown: isKeyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    func showHUD(_ text: String) {
        hud.show(text)
    }

    /// The key to press for the chord. A chord that names a character, as ⌘V does, means the
    /// key that types it on the current layout, wherever that key is: apps look at what a
    /// shortcut types, not at where its key sits. On Dvorak that is another key than on
    /// QWERTY. On a layout that has no key for the character, the chord's own key code has to
    /// do, which is the key's position on an ANSI keyboard.
    private func keyCode(for chord: KeyChord) -> CGKeyCode {
        guard let character = chord.characters else { return chord.keyCode }
        // Only ⌘ is given to the layout. Some layouts type other letters while it is held,
        // and that is the letter a shortcut goes by. Control and Option turn a key into
        // control characters and symbols, which would match nothing.
        let layoutModifiers = chord.modifiers.intersection(.command)
        let layoutKeyCode = KeyboardLayout.keyCode(typing: character, modifiers: layoutModifiers)
        return layoutKeyCode ?? chord.keyCode
    }

    private func eventFlags(for modifiers: HotKey.Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }
}
