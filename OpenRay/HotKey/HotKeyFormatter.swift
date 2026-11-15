import Carbon.HIToolbox
import OpenRayCore

/// Turns a hotkey into what the user reads, such as "⌥Space". The key's name follows the current
/// keyboard layout; the binding itself stays on the physical key.
enum HotKeyFormatter {
    static func string(for hotKey: HotKey) -> String {
        symbols(for: hotKey.modifiers) + keyName(for: hotKey.keyCode)
    }

    /// An action's shortcut as the action panel shows it, such as "⌘↩".
    static func string(for chord: KeyChord) -> String {
        symbols(for: chord.modifiers) + keyName(for: UInt32(chord.keyCode))
    }

    /// The modifier symbols in the order macOS menus show them.
    static func symbols(for modifiers: HotKey.Modifiers) -> String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols
    }

    static func keyName(for keyCode: UInt32) -> String {
        if let name = namedKeys[Int(keyCode)] { return name }
        if let character = layoutCharacter(for: keyCode) { return character }
        return String(localized: "Key \(keyCode)")
    }

    /// Keys that type nothing visible, or the same thing on every layout.
    private static let namedKeys: [Int: String] = [
        kVK_Space: String(localized: "Space"),
        kVK_Return: "↩",
        kVK_ANSI_KeypadEnter: "⌤",
        kVK_Tab: "⇥",
        kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_Home: "↖",
        kVK_End: "↘",
        kVK_PageUp: "⇞",
        kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// What the key types on the current keyboard layout, in upper case.
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let keyCode = UInt16(exactly: keyCode) else { return nil }
        return KeyboardLayout.characters(forKeyCode: keyCode)?.uppercased()
    }
}
