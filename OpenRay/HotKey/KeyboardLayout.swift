import Carbon.HIToolbox
import OpenRayCore

/// Asks the current keyboard layout which key types what.
enum KeyboardLayout {
    /// What the key types on the current layout while the given modifiers are held, or nil for
    /// a key that types nothing.
    ///
    /// - Parameter modifiers: Some layouts type something else with Command held: on
    ///   "Dvorak – QWERTY ⌘" the keys are QWERTY then.
    static func characters(
        forKeyCode keyCode: UInt16, modifiers: HotKey.Modifiers = []
    ) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        // The property comes back as an untyped pointer to a `CFData` that the input source owns.
        let layout = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data

        // `UCKeyTranslate` wants the Carbon modifiers shifted down by a byte, as they are in
        // the `modifiers` field of an event record.
        let modifierKeyState = (modifiers.carbonModifiers >> 8) & 0xFF
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { bytes in
            UCKeyTranslate(
                bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                modifierKeyState,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr else { return nil }
        let typed = String(utf16CodeUnits: characters, count: length)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return typed.isEmpty ? nil : typed
    }

    /// The key that types `character` while the given modifiers are held, or nil when the
    /// current layout has no such key.
    static func keyCode(typing character: String, modifiers: HotKey.Modifiers) -> UInt16? {
        // Virtual key codes fit in seven bits.
        for keyCode in UInt16(0)..<128 {
            let typed = characters(forKeyCode: keyCode, modifiers: modifiers)
            if typed?.lowercased() == character.lowercased() {
                return keyCode
            }
        }
        return nil
    }
}
