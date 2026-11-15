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
