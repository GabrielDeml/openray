import Foundation
import Testing

@testable import OpenRayCore

@Suite(.timeLimit(.minutes(1))) struct CommandHotKeyStoreTests {
    private let safari = ItemID.app(bundleID: "com.apple.Safari")
    private let notes = ItemID.app(bundleID: "com.apple.Notes")

    // Key codes of an ANSI keyboard: kVK_ANSI_S, kVK_ANSI_N and kVK_F5.
    private let controlOptionS = HotKey(keyCode: 0x01, modifiers: [.control, .option])
    private let controlOptionN = HotKey(keyCode: 0x2D, modifiers: [.control, .option])
    private let commandF5 = HotKey(keyCode: 0x60, modifiers: [.command])

    private func makeStore() throws -> CommandHotKeyStore {
        CommandHotKeyStore(database: try AppDatabase.inMemory())
    }

    @Test func newDatabaseHasNoHotKeys() async throws {
        let store = try makeStore()

        #expect(try await store.all().isEmpty)
    }

    @Test func hotKeysComeBackAsTheyWereStored() async throws {
        let store = try makeStore()

        try await store.set(controlOptionS, for: safari)
        try await store.set(commandF5, for: notes)

        #expect(try await store.all() == [safari: controlOptionS, notes: commandF5])
    }

    @Test func everyModifierSurvivesTheRoundTrip() async throws {
        let store = try makeStore()
        let modifierSets: [HotKey.Modifiers] = [
            [.command], [.option], [.control], [.shift, .command],
            [.command, .option, .control, .shift],
        ]

        // A key of its own for each, because a chord belongs to one item.
        var stored: [ItemID: HotKey] = [:]
        for (number, modifiers) in modifierSets.enumerated() {
            let id = ItemID.system("command-\(number)")
            let hotKey = HotKey(keyCode: UInt32(number), modifiers: modifiers)
            try await store.set(hotKey, for: id)
            stored[id] = hotKey
        }

        #expect(try await store.all() == stored)
    }

    @Test func secondChordForAnItemReplacesTheFirst() async throws {
        let store = try makeStore()
        try await store.set(controlOptionS, for: safari)

        try await store.set(commandF5, for: safari)

        #expect(try await store.all() == [safari: commandF5])
    }

    @Test func chordGivenToAnotherItemIsTakenFromTheFirst() async throws {
        let store = try makeStore()
        try await store.set(controlOptionS, for: safari)
        try await store.set(controlOptionN, for: notes)

        try await store.set(controlOptionS, for: notes)

        #expect(try await store.all() == [notes: controlOptionS])
    }

    @Test func settingTheSameChordAgainChangesNothing() async throws {
        let store = try makeStore()
        try await store.set(controlOptionS, for: safari)

        try await store.set(controlOptionS, for: safari)

        #expect(try await store.all() == [safari: controlOptionS])
    }

    @Test func removingTakesOnlyThatItemsHotKey() async throws {
        let store = try makeStore()
        try await store.set(controlOptionS, for: safari)
        try await store.set(commandF5, for: notes)

        try await store.remove(safari)
        try await store.remove(.system("never-had-one"))

        #expect(try await store.all() == [notes: commandF5])
    }

    // The table's two integers are permanent once a release has written them (see the
    // migration), so their meaning is pinned here and not left to the round trip.
    @Test func storedIntegersAreTheKeyCodeAndTheModifierBits() async throws {
        let store = try makeStore()
        let shiftControlF5 = HotKey(keyCode: 0x60, modifiers: [.shift, .control])

        try await store.set(shiftControlF5, for: safari)

        let stored = try #require(try await store.storedValues(for: safari))
        #expect(stored.keyCode == 0x60)
        // Control is 1 << 2 and Shift is 1 << 3.
        #expect(stored.modifiers == 0b1100)
    }
}
