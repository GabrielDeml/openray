/// A key press as the launcher sees it: a physical key, modifiers, and what the layout types.
public struct KeyChord: Hashable, Codable, Sendable {
    public var keyCode: UInt16
    public var modifiers: HotKey.Modifiers
    /// What the key produces without its modifiers (`charactersIgnoringModifiers`).
    public var characters: String?

    public init(keyCode: UInt16, modifiers: HotKey.Modifiers = [], characters: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.characters = characters
    }
}

extension KeyChord {
    /// What the key types, lower-cased, when that is ASCII. A layout that types something else
    /// (Cyrillic, for example) has no usable character, and the chord is identified by its key
    /// code instead.
    private var asciiCharacters: String? {
        guard let characters, !characters.isEmpty, characters.allSatisfy(\.isASCII) else {
            return nil
        }
        return characters.lowercased()
    }

    /// Whether this chord's key types `character`, falling back to the key's position on an ANSI
    /// keyboard when the layout does not type ASCII.
    func types(_ character: String, ansiKeyCode: UInt16) -> Bool {
        if let typed = asciiCharacters {
            return typed == character
        }
        return keyCode == ansiKeyCode
    }

    /// Whether `pressed` triggers this shortcut.
    func isTriggered(by pressed: KeyChord) -> Bool {
        guard modifiers == pressed.modifiers else { return false }
        if let expected = asciiCharacters, let typed = pressed.asciiCharacters {
            return expected == typed
        }
        return keyCode == pressed.keyCode
    }
}

/// Virtual key codes, copied from Events.h (HIToolbox) because Core does not import Carbon.
public enum VirtualKey {
    public static let returnKey: UInt16 = 0x24  // kVK_Return
    public static let tab: UInt16 = 0x30  // kVK_Tab
    public static let space: UInt16 = 0x31  // kVK_Space
    public static let delete: UInt16 = 0x33  // kVK_Delete
    public static let escape: UInt16 = 0x35  // kVK_Escape
    public static let keypadEnter: UInt16 = 0x4C  // kVK_ANSI_KeypadEnter
    public static let leftArrow: UInt16 = 0x7B  // kVK_LeftArrow
    public static let downArrow: UInt16 = 0x7D  // kVK_DownArrow
    public static let upArrow: UInt16 = 0x7E  // kVK_UpArrow

    public static let ansiA: UInt16 = 0x00  // kVK_ANSI_A
    public static let ansiC: UInt16 = 0x08  // kVK_ANSI_C
    public static let ansiE: UInt16 = 0x0E  // kVK_ANSI_E
    public static let ansiH: UInt16 = 0x04  // kVK_ANSI_H
    public static let ansiK: UInt16 = 0x28  // kVK_ANSI_K
    public static let ansiM: UInt16 = 0x2E  // kVK_ANSI_M
    public static let ansiN: UInt16 = 0x2D  // kVK_ANSI_N
    public static let ansiP: UInt16 = 0x23  // kVK_ANSI_P
    public static let ansiQ: UInt16 = 0x0C  // kVK_ANSI_Q
    public static let ansiR: UInt16 = 0x0F  // kVK_ANSI_R
    public static let ansiV: UInt16 = 0x09  // kVK_ANSI_V
    public static let ansiW: UInt16 = 0x0D  // kVK_ANSI_W
    public static let ansiX: UInt16 = 0x07  // kVK_ANSI_X
    public static let ansiY: UInt16 = 0x10  // kVK_ANSI_Y
    public static let ansiZ: UInt16 = 0x06  // kVK_ANSI_Z
    public static let ansiLeftBracket: UInt16 = 0x21  // kVK_ANSI_LeftBracket
    public static let ansiComma: UInt16 = 0x2B  // kVK_ANSI_Comma

    /// kVK_ANSI_1 to kVK_ANSI_9, in that order. The codes are not consecutive.
    public static let ansiDigits: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
}
