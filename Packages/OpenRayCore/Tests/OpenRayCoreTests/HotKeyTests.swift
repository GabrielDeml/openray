import Foundation
import Testing

import OpenRayCore

@Suite struct HotKeyTests {
    private let space: UInt32 = 0x31  // kVK_Space

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
}
