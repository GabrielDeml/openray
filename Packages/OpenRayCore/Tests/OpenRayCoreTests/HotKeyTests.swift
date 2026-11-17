import Foundation
import Testing

import OpenRayCore

@Suite struct HotKeyTests {
    private let space: UInt32 = 0x31  // kVK_Space

    /// Whether the recorder would refuse one key press. `characters` is what the recorder reads
    /// from the event: what the key types with ⌘ held if ⌘ is in the chord, and otherwise what
    /// it types without its modifiers.
    private func isReserved(
        _ keyCode: UInt16, _ modifiers: HotKey.Modifiers, _ characters: String?
    ) -> Bool {
        let chord = KeyChord(keyCode: keyCode, modifiers: modifiers, characters: characters)
        return HotKey.isReservedShortcut(chord)
    }

    @Test func launcherDefaultIsOptionSpace() {
        #expect(HotKey.launcherDefault == HotKey(keyCode: space, modifiers: [.option]))
    }

    @Test func carbonModifiersUseTheEventsHeaderBits() {
        // In Events.h, cmdKey is 0x0100, shiftKey 0x0200, optionKey 0x0800, controlKey 0x1000.
        #expect(HotKey(keyCode: 0, modifiers: [.command]).carbonModifiers == 0x0100)
        #expect(HotKey(keyCode: 0, modifiers: [.shift]).carbonModifiers == 0x0200)
        #expect(HotKey(keyCode: 0, modifiers: [.option]).carbonModifiers == 0x0800)
        #expect(HotKey(keyCode: 0, modifiers: [.control]).carbonModifiers == 0x1000)
        #expect(HotKey(keyCode: 0, modifiers: []).carbonModifiers == 0)
        #expect(HotKey(keyCode: 0, modifiers: [.command, .shift]).carbonModifiers == 0x0300)

        let allFour = HotKey(keyCode: 0, modifiers: [.command, .option, .control, .shift])
        #expect(allFour.carbonModifiers == 0x1B00)
    }

    @Test func hotKeyWithCommandOrControlIsValid() {
        #expect(HotKey(keyCode: space, modifiers: [.command]).validate() == .ok)
        #expect(HotKey(keyCode: space, modifiers: [.control]).validate() == .ok)
        #expect(HotKey(keyCode: space, modifiers: [.command, .shift]).validate() == .ok)
        #expect(HotKey(keyCode: space, modifiers: [.control, .option]).validate() == .ok)
        #expect(HotKey(keyCode: space, modifiers: [.command, .option, .shift]).validate() == .ok)
    }

    @Test func hotKeyWithoutCommandControlOrOptionNeedsAModifier() {
        #expect(HotKey(keyCode: space, modifiers: []).validate() == .needsModifier)
        #expect(HotKey(keyCode: space, modifiers: [.shift]).validate() == .needsModifier)
    }

    @Test func hotKeyWithOnlyOptionOrOptionShiftIsUsableWithAWarning() {
        let optionSpace = HotKey(keyCode: space, modifiers: [.option])
        let optionShiftSpace = HotKey(keyCode: space, modifiers: [.option, .shift])

        #expect(optionSpace.validate() == .optionShiftOnly)
        #expect(optionShiftSpace.validate() == .optionShiftOnly)
    }

    @Test func editingAndWindowShortcutsAreReserved() {
        // Each character with its kVK_ANSI_* key code.
        let keys: [(character: String, keyCode: UInt16)] = [
            ("a", 0x00), ("c", 0x08), ("v", 0x09), ("x", 0x07), ("z", 0x06),
            ("q", 0x0C), ("w", 0x0D), ("h", 0x04), ("m", 0x2E), (",", 0x2B),
        ]
        for key in keys {
            #expect(isReserved(key.keyCode, [.command], key.character), "⌘\(key.character)")
        }
    }

    @Test func redoIsReserved() {
        // With Shift held the letter may arrive in upper case.
        #expect(isReserved(VirtualKey.ansiZ, [.command, .shift], "Z"))
        #expect(isReserved(VirtualKey.ansiZ, [.command, .shift], "z"))
    }

    @Test func appSwitcherAndForceQuitAreReserved() {
        #expect(isReserved(VirtualKey.tab, [.command], "\t"))
        // Shift-Tab arrives as the back-tab character, U+0019 (NSBackTabCharacter).
        #expect(isReserved(VirtualKey.tab, [.command, .shift], "\u{19}"))
        #expect(isReserved(VirtualKey.escape, [.command, .option], "\u{1B}"))
    }

    @Test func reservedShortcutsFollowTheKeyboardLayout() {
        // On Dvorak the key at the ANSI "I" position types "c", and the ANSI "C" key types "j".
        let ansiI: UInt16 = 0x22
        #expect(isReserved(ansiI, [.command], "c"))
        #expect(!isReserved(VirtualKey.ansiC, [.command], "j"))
    }

    @Test func reservedShortcutsGoByWhatTheKeyTypesWithCommandHeld() {
        // "Dvorak – QWERTY ⌘" is Dvorak until ⌘ is held and QWERTY while it is. The ANSI "C" key
        // types "j" on its own and is ⌘C; the ANSI "I" key types "c" on its own and is ⌘I. The
        // recorder passes the character typed with ⌘ held.
        let ansiI: UInt16 = 0x22
        #expect(isReserved(VirtualKey.ansiC, [.command], "c"))
        #expect(!isReserved(ansiI, [.command], "i"))
    }

    @Test func reservedShortcutsGoByKeyPositionWhenTheLayoutIsNotASCII() {
        // A Russian layout types the Cyrillic "с" on the ANSI "C" key, and ⌘ with it still copies.
        #expect(isReserved(VirtualKey.ansiC, [.command], "с"))
        #expect(isReserved(VirtualKey.ansiC, [.command], nil))
    }

    @Test func otherChordsAreNotReserved() {
        #expect(!isReserved(VirtualKey.space, [.option], " "))
        #expect(!isReserved(VirtualKey.space, [.command], " "))
        #expect(!isReserved(VirtualKey.space, [.control, .option], " "))

        // The reserved keys are free with other modifiers.
        #expect(!isReserved(VirtualKey.ansiC, [.control], "c"))
        #expect(!isReserved(VirtualKey.ansiC, [.command, .option], "c"))
        #expect(!isReserved(VirtualKey.ansiC, [.command, .shift], "C"))
        #expect(!isReserved(VirtualKey.tab, [.control], "\t"))
        #expect(!isReserved(VirtualKey.escape, [.command], "\u{1B}"))

        // A Command shortcut that only some apps have.
        #expect(!isReserved(VirtualKey.ansiK, [.command], "k"))
    }

    @Test func modifiersComeFromAnEventsFlags() {
        // Raw NSEvent.ModifierFlags: ⌘ is 1 << 20, ⌥ 1 << 19, ⌃ 1 << 18, ⇧ 1 << 17.
        #expect(HotKey.Modifiers(eventModifierFlags: 0x10_0000) == .command)
        #expect(HotKey.Modifiers(eventModifierFlags: 0x08_0000) == .option)
        #expect(HotKey.Modifiers(eventModifierFlags: 0x04_0000) == .control)
        #expect(HotKey.Modifiers(eventModifierFlags: 0x02_0000) == .shift)
        #expect(HotKey.Modifiers(eventModifierFlags: 0x1A_0000) == [.command, .option, .shift])
    }

    @Test func capsLockFunctionAndNumericPadFlagsAreNotModifiers() {
        // Caps Lock is 1 << 16, the numeric pad 1 << 21, Fn 1 << 23; arrow keys set the last two.
        #expect(HotKey.Modifiers(eventModifierFlags: 0xA0_0000) == [])
        // ⌘ with Caps Lock on. The low 16 bits depend on the device and are not modifiers either.
        #expect(HotKey.Modifiers(eventModifierFlags: 0x11_0100) == .command)
    }

    @Test func codableRoundTrip() throws {
        let hotKey = HotKey(keyCode: 0x28, modifiers: [.command, .control, .shift])

        let encoded = try JSONEncoder().encode(hotKey)
        let decoded = try JSONDecoder().decode(HotKey.self, from: encoded)

        #expect(decoded == hotKey)
    }

    /// A hotkey saved by one version must mean the same chord in every later version.
    @Test func storedFormatIsStable() throws {
        // Modifiers 13 is Command (1) + Control (4) + Shift (8).
        let stored = Data(#"{"keyCode":49,"modifiers":13}"#.utf8)
        let decoded = try JSONDecoder().decode(HotKey.self, from: stored)
        #expect(decoded == HotKey(keyCode: 49, modifiers: [.command, .control, .shift]))

        // Modifiers 2 is Option, and key code 49 is Space.
        let storedOptionSpace = Data(#"{"keyCode":49,"modifiers":2}"#.utf8)
        let optionSpace = try JSONDecoder().decode(HotKey.self, from: storedOptionSpace)
        #expect(optionSpace == .launcherDefault)
    }

    // The log line of a refused chord is public, and the ID of a script is its path.
    @Test func logDescriptionOfAnErrorDoesNotNameTheCommandThatHoldsTheChord() {
        let script = ItemID.script(path: "/Users/ada/Scripts/deploy.sh")

        #expect(HotKeyError.heldBySlot(.command(script)).logDescription == "held by a command")
        #expect(HotKeyError.heldBySlot(.launcher).logDescription == "held by the launcher")
        #expect(HotKeyError.inUseByAnotherApp.logDescription == "in use by another app")
        #expect(HotKeyError.rejected(-9868).logDescription == "rejected with -9868")
    }
}
