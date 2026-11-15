import Foundation
import Observation
import Synchronization
import Testing

import OpenRayCore

private let retention = PreferenceKey(name: "test.retentionDays", defaultValue: 30)
private let enabled = PreferenceKey(name: "test.enabled", defaultValue: false)
private let folders = PreferenceKey<[String]>(name: "test.folders", defaultValue: ["~/Scripts"])
private let commandShiftK = HotKey(keyCode: 0x28, modifiers: [.command, .shift])

@Suite struct PreferencesStoreTests {
    private let store = InMemoryPreferencesStore()

    @Test func unsetPreferenceHasItsDefault() {
        #expect(store.value(for: retention) == 30)
        #expect(store.value(for: .launcherHotKey) == .launcherDefault)
    }

    @Test func valuesRoundTrip() {
        store.set(7, for: retention)
        store.set(true, for: enabled)
        store.set(["/a", "/b"], for: folders)
        store.set(commandShiftK, for: .launcherHotKey)

        #expect(store.value(for: retention) == 7)
        #expect(store.value(for: enabled) == true)
        #expect(store.value(for: folders) == ["/a", "/b"])
        #expect(store.value(for: .launcherHotKey) == commandShiftK)
    }

    @Test func settingOnePreferenceLeavesTheOthersAlone() {
        store.set(7, for: retention)

        #expect(store.value(for: enabled) == false)
        #expect(store.value(for: .launcherHotKey) == .launcherDefault)
    }

    @Test func valueOfAnotherTypeUnderTheSameNameReadsAsTheDefault() {
        store.set("not a hotkey", for: PreferenceKey(name: "launcher.hotKey", defaultValue: ""))

        #expect(store.value(for: .launcherHotKey) == .launcherDefault)
    }

    // Clearing an optional preference is a stored value of its own, not a return to the default.
    // Both stores have to agree on that, or tests against the in-memory one prove nothing.
    @Test func optionalPreferenceSetToNilReadsAsNil() throws {
        let editor = PreferenceKey<String?>(name: "test.editor", defaultValue: "TextEdit")

        store.set(nil, for: editor)
        #expect(store.value(for: editor) == nil)

        let suiteName = "OpenRayCoreTests.optionalPreferenceSetToNilReadsAsNil"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let realStore = UserDefaultsPreferencesStore(defaults: defaults)

        realStore.set(nil, for: editor)
        #expect(realStore.value(for: editor) == nil)
    }

    // A stream that misses a change never yields again: fail instead of hanging.
    @Test(.timeLimit(.minutes(1))) func changesYieldTheCurrentValueThenEveryUpdate() async {
        store.set(7, for: retention)
        var changes = store.changes(for: retention).makeAsyncIterator()

        let current = await changes.next()
        store.set(14, for: retention)
        let second = await changes.next()
        store.set(1, for: retention)
        let third = await changes.next()

        #expect([current, second, third] == [7, 14, 1])
    }

    @Test(.timeLimit(.minutes(1))) func slowConsumerSeesTheNewestValue() async {
        var changes = store.changes(for: retention).makeAsyncIterator()

        store.set(1, for: retention)
        store.set(2, for: retention)
        let next = await changes.next()

        #expect(next == 2)
    }

    // Each `set` reads the store and yields in two steps. If two of them interleave, the stream
    // ends on the older value and nothing corrects it. The race needs many rounds to show.
    @Test(.timeLimit(.minutes(1))) func streamEndsOnTheStoredValueAfterConcurrentSets() async {
        var staleRounds = 0
        for _ in 0..<20_000 {
            // Every round starts from a store of its own, not the suite's.
            let store = InMemoryPreferencesStore()
            var changes = store.changes(for: retention).makeAsyncIterator()

            let settingOne = Task.detached { store.set(1, for: retention) }
            let settingTwo = Task.detached { store.set(2, for: retention) }
            await settingOne.value
            await settingTwo.value

            let lastYielded = await changes.next()
            let stored = store.value(for: retention)
            if lastYielded != stored {
                staleRounds += 1
            }
        }

        #expect(staleRounds == 0)
    }
}

/// A value with other values inside it, some of them optional.
private struct EditorChoice: Codable, Equatable, Sendable {
    var name: String
    var bundleID: String?
    var arguments: [String?]
    var hotKeys: [String: HotKey]
    var lastUsed: Date
}

/// What a value is after it was stored and read again, in each of the two stores. They share
/// their coding, but only the real one hands the coded value to `UserDefaults`.
///
/// Serialized because the tests share one `UserDefaults` suite. A suite of its own for every
/// test would leave as many files behind: removing a domain empties its file in
/// ~/Library/Preferences and does not delete it.
@Suite(.serialized) struct PreferenceRoundTripTests {
    private let suiteName = "OpenRayCoreTests.PreferenceRoundTripTests"

    /// Stores `value` and reads it back, first in the in-memory store and then in the
    /// `UserDefaults` one.
    ///
    /// - Parameter defaultValue: The key's default, which is what comes back if the stored value
    ///   cannot be read. It has to differ from `value` for the test to notice.
    private func readBack<V: Codable & Sendable>(
        _ value: V, ifUnreadable defaultValue: V
    ) throws -> (inMemory: V, userDefaults: V) {
        let key = PreferenceKey(name: "test.roundTrip", defaultValue: defaultValue)

        let memoryStore = InMemoryPreferencesStore()
        memoryStore.set(value, for: key)

        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let realStore = UserDefaultsPreferencesStore(defaults: defaults)
        realStore.set(value, for: key)

        return (inMemory: memoryStore.value(for: key), userDefaults: realStore.value(for: key))
    }

    /// Expects `value` to come back unchanged from both stores. A failure is reported at the
    /// line that called this, and says which store it was.
    private func expectRoundTrip<V: Codable & Sendable & Equatable>(
        _ value: V, ifUnreadable defaultValue: V,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let stored = try readBack(value, ifUnreadable: defaultValue)
        #expect(stored.inMemory == value, "in-memory store", sourceLocation: sourceLocation)
        #expect(stored.userDefaults == value, "UserDefaults store", sourceLocation: sourceLocation)
    }

    // "$null" is what `PropertyListEncoder` writes for nil, and what its decoder refuses to
    // read as a string.
    @Test func stringThatLooksLikeANilMarkerRoundTrips() throws {
        try expectRoundTrip("$null", ifUnreadable: "")
        try expectRoundTrip(["$null", "null"], ifUnreadable: [])

        let optional: String? = "$null"
        try expectRoundTrip(optional, ifUnreadable: "")
        let noString: String? = nil
        try expectRoundTrip(noString, ifUnreadable: "")
    }

    @Test func stringsThatLookLikeJSONRoundTrip() throws {
        let strings = [
            "", "null", "true", "7", "{}", "\"quoted\"", "back\\slash", "two\nlines", "naïve 🙂",
        ]

        for string in strings {
            try expectRoundTrip(string, ifUnreadable: "unreadable")
        }
    }

    @Test func doublesRoundTripExactly() throws {
        let doubles = [
            0.1 + 0.2, 1.0 / 3.0, -0.0, 1e-7, 1e21,
            Double.greatestFiniteMagnitude, Double.leastNonzeroMagnitude,
            Double.infinity, -Double.infinity,
        ]

        for double in doubles {
            let stored = try readBack(double, ifUnreadable: 42)
            // By bit pattern, because -0.0 == 0.0.
            #expect(stored.inMemory.bitPattern == double.bitPattern, "in-memory store")
            #expect(stored.userDefaults.bitPattern == double.bitPattern, "UserDefaults store")
        }

        // NaN is equal to nothing, itself included.
        let storedNaN = try readBack(Double.nan, ifUnreadable: 42)
        #expect(storedNaN.inMemory.isNaN)
        #expect(storedNaN.userDefaults.isNaN)
    }

    @Test func integersAtTheirLimitsRoundTrip() throws {
        try expectRoundTrip(Int64.min, ifUnreadable: 0)
        try expectRoundTrip(UInt64.max, ifUnreadable: 0)
    }

    @Test func dataRoundTrips() throws {
        let bytes = Data([0x00, 0xFF, 0x0A, 0x22, 0x5C])
        try expectRoundTrip(bytes, ifUnreadable: Data([1]))
        try expectRoundTrip(Data(), ifUnreadable: Data([1]))
    }

    @Test func datesRoundTripToTheLastFraction() throws {
        let dates = [
            Date(timeIntervalSince1970: 1_700_000_000.123_456_7),
            Date(timeIntervalSinceReferenceDate: -0.000_001),
            Date.distantPast,
            Date.distantFuture,
        ]

        let epoch = Date(timeIntervalSince1970: 0)
        for date in dates {
            try expectRoundTrip(date, ifUnreadable: epoch)
        }
    }

    @Test func nestedValuesRoundTrip() throws {
        let choice = EditorChoice(
            name: "$null",
            bundleID: nil,
            arguments: ["--wait", nil, "$null"],
            hotKeys: ["open": commandShiftK, "$null": .launcherDefault],
            lastUsed: Date(timeIntervalSince1970: 1_700_000_000.5))
        let nothing = EditorChoice(
            name: "", bundleID: "", arguments: [], hotKeys: [:],
            lastUsed: Date(timeIntervalSince1970: 0))

        try expectRoundTrip(choice, ifUnreadable: nothing)
        try expectRoundTrip([[choice], []], ifUnreadable: [])
    }

    // What an earlier build stored: the value as a property list, here a dictionary.
    @Test func valueStoredAsAPropertyListReadsAsTheDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let realStore = UserDefaultsPreferencesStore(defaults: defaults)

        defaults.set(["keyCode": 40, "modifiers": 9], forKey: "launcher.hotKey")

        #expect(realStore.value(for: .launcherHotKey) == .launcherDefault)
    }
}

@MainActor @Suite struct PreferencesTests {
    private let store = InMemoryPreferencesStore()

    @Test func launcherHotKeyDefaultsToOptionSpace() {
        #expect(Preferences(store: store).launcherHotKey == .launcherDefault)
    }

    @Test func writesReachTheStoreUnderTheDocumentedName() {
        let preferences = Preferences(store: store)

        preferences.launcherHotKey = commandShiftK
        preferences[retention] = 7

        #expect(PreferenceKey<HotKey>.launcherHotKey.name == "launcher.hotKey")
        #expect(store.value(for: .launcherHotKey) == commandShiftK)
        #expect(store.value(for: retention) == 7)
    }

    @Test func valuesSurviveANewFacadeOverTheSameStore() {
        Preferences(store: store).launcherHotKey = commandShiftK

        #expect(Preferences(store: store).launcherHotKey == commandShiftK)
    }

    @Test func writingAPreferenceInvalidatesObserversThatReadIt() {
        let preferences = Preferences(store: store)
        let invalidated = Mutex(false)
        withObservationTracking {
            _ = preferences.launcherHotKey
        } onChange: {
            invalidated.withLock { flag in flag = true }
        }
        let invalidatedBeforeTheWrite = invalidated.withLock { flag in flag }

        preferences.launcherHotKey = commandShiftK
        let invalidatedByTheWrite = invalidated.withLock { flag in flag }

        #expect(!invalidatedBeforeTheWrite)
        #expect(invalidatedByTheWrite)
    }
}
