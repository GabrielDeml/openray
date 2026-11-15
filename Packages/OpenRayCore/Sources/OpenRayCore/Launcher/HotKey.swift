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
