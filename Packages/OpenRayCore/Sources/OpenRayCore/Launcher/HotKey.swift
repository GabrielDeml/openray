/// A global hotkey: a physical key plus modifiers.
public struct HotKey: Codable, Hashable, Sendable {
    /// Virtual key code (`kVK_*`), which names a physical key whatever the keyboard layout.
    public var keyCode: UInt32
    public var modifiers: Modifiers

    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        // Persisted with the hotkey preference: the bit assignments never change.
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)

        /// The four modifiers out of an `NSEvent.ModifierFlags` raw value; other flags (Caps
        /// Lock, Fn, the numeric pad) are dropped.
        public init(eventModifierFlags flags: UInt) {
            // NSEventModifierFlagShift, Control, Option and Command from NSEvent.h (AppKit).
            self = []
            if flags & (1 << 17) != 0 { insert(.shift) }
            if flags & (1 << 18) != 0 { insert(.control) }
            if flags & (1 << 19) != 0 { insert(.option) }
            if flags & (1 << 20) != 0 { insert(.command) }
        }
    }

    public enum Validation: Sendable, Equatable {
        case ok
        /// Unusable: a hotkey needs at least one of Command, Control or Option.
        case needsModifier
        /// Usable, with a warning: some macOS versions refuse to register chords whose only
        /// modifiers are Option or Option+Shift.
        case optionShiftOnly
    }

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The modifiers as `RegisterEventHotKey` expects them.
    public var carbonModifiers: UInt32 {
        // cmdKey, shiftKey, optionKey and controlKey from Events.h (HIToolbox).
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= 1 << 8 }
        if modifiers.contains(.shift) { carbon |= 1 << 9 }
        if modifiers.contains(.option) { carbon |= 1 << 11 }
        if modifiers.contains(.control) { carbon |= 1 << 12 }
        return carbon
    }

    public func validate() -> Validation {
        if modifiers.isDisjoint(with: [.command, .control, .option]) { return .needsModifier }
        if modifiers.isSubset(of: [.option, .shift]) { return .optionShiftOnly }
        return .ok
    }

    public static let launcherDefault = HotKey(
        keyCode: UInt32(VirtualKey.space), modifiers: [.option])
}

extension HotKey {
    /// Whether `chord` is a shortcut that people use in every app, such as ⌘C or ⌘Tab. A global
    /// hotkey on it would take the shortcut away from all of them, so the recorder refuses it.
    ///
    /// This takes the key press and not a `HotKey` because ⌘C is the key that types "c", wherever
    /// the keyboard layout puts it.
    public static func isReservedShortcut(_ chord: KeyChord) -> Bool {
        switch chord.modifiers {
        case [.command]:
            // The app switcher.
            if chord.keyCode == VirtualKey.tab { return true }
            for key in reservedCommandKeys {
                if chord.types(key.character, ansiKeyCode: key.ansiKeyCode) { return true }
            }
            return false
        case [.command, .shift]:
            // The app switcher going backwards, and Redo.
            if chord.keyCode == VirtualKey.tab { return true }
            return chord.types("z", ansiKeyCode: VirtualKey.ansiZ)
        case [.command, .option]:
            // Force Quit.
            return chord.keyCode == VirtualKey.escape
        default:
            return false
        }
    }

    /// The keys that are reserved with Command alone, each with its key code on an ANSI
    /// keyboard. The list is short on purpose: it has the shortcuts that work nearly everywhere,
    /// and leaves out those that only some apps have (⌘S, ⌘N, ⌘F) or that the user can reassign
    /// in System Settings (⌘Space, ⌘`).
    private static let reservedCommandKeys: [(character: String, ansiKeyCode: UInt16)] = [
        ("a", VirtualKey.ansiA),  // Select All
        ("c", VirtualKey.ansiC),  // Copy
        ("v", VirtualKey.ansiV),  // Paste
        ("x", VirtualKey.ansiX),  // Cut
        ("z", VirtualKey.ansiZ),  // Undo
        ("q", VirtualKey.ansiQ),  // Quit
        ("w", VirtualKey.ansiW),  // Close
        ("h", VirtualKey.ansiH),  // Hide
        ("m", VirtualKey.ansiM),  // Minimize
        (",", VirtualKey.ansiComma),  // Settings, in the launcher's own panel too
    ]
}
