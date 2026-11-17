import Foundation
import Testing

@testable import OpenRayCore

// Everything about registration runs against `FakeHotKeyRegistrar`: no test registers a hotkey
// with macOS.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CommandHotKeysTests {
    /// The items "Set Hotkey…" asked Settings to show.
    @MainActor private final class ShownSettings {
        var items: [ItemID] = []
    }

    private let safari = ItemID.app(bundleID: "com.apple.Safari")
    private let notes = ItemID.app(bundleID: "com.apple.Notes")
    private let sleep = ItemID.system("sleep")

    // Key codes of an ANSI keyboard: kVK_ANSI_S, kVK_ANSI_N, kVK_F5 and kVK_Space.
    private let controlOptionS = HotKey(keyCode: 0x01, modifiers: [.control, .option])
    private let controlOptionN = HotKey(keyCode: 0x2D, modifiers: [.control, .option])
    private let commandF5 = HotKey(keyCode: 0x60, modifiers: [.command])
    private let controlOptionSpace = HotKey(keyCode: 0x31, modifiers: [.control, .option])

    private let registrar = FakeHotKeyRegistrar()
    private let preferences = Preferences(store: InMemoryPreferencesStore())
    private let shownSettings = ShownSettings()
    private let store: CommandHotKeyStore
    private let hotKeys: CommandHotKeys

    init() throws {
        store = CommandHotKeyStore(database: try AppDatabase.inMemory())
        let shownSettings = shownSettings
        hotKeys = CommandHotKeys(
            store: store, registrar: registrar, preferences: preferences,
            showSettings: { id in shownSettings.items.append(id) })
    }

    private var safariItem: SearchItem { item(safari, "Safari") }
    private var notesItem: SearchItem { item(notes, "Notes") }
    private var sleepItem: SearchItem { item(sleep, "Sleep") }

    private func item(_ id: ItemID, _ title: String) -> SearchItem {
        SearchItem(id: id, title: title, icon: .symbol("app"), kindLabel: "Command")
    }

    private func disabling(_ id: ItemID) -> CommandOverrides {
        CommandOverrides(overrides: [id: ItemOverride(disabled: true)])
    }

    /// The model as it is after launch: the stored hotkeys read and these items published.
    private func launch(
        with items: [SearchItem], overrides: CommandOverrides = CommandOverrides()
    ) async {
        await hotKeys.load()
        hotKeys.update(items: items, overrides: overrides)
    }

    // MARK: Launch

    @Test func nothingIsRegisteredUntilTheHotKeysAreReadAndTheItemsAreThere() async throws {
        try await store.set(controlOptionS, for: safari)

        await hotKeys.load()
        #expect(registrar.calls.isEmpty)
        #expect(hotKeys.assignments == [safari: controlOptionS])

        hotKeys.update(items: [safariItem], overrides: CommandOverrides())
        #expect(registrar.calls == [.register(controlOptionS, .command(safari))])
    }

    @Test func itemsThatArriveBeforeTheHotKeysAreReadWaitForThem() async throws {
        try await store.set(controlOptionS, for: safari)

        hotKeys.update(items: [safariItem], overrides: CommandOverrides())
        #expect(registrar.calls.isEmpty)

        await hotKeys.load()
        #expect(registrar.calls == [.register(controlOptionS, .command(safari))])
    }

    // A dictionary has another order on every run. The model asks by raw ID so that a run can
    // be repeated: "app:com.apple.Notes", "app:com.apple.Safari", "system:sleep". Which order
    // it is matters to nothing else.
    @Test func storedHotKeysAreRegisteredInTheSameOrderOnEveryRun() async throws {
        try await store.set(commandF5, for: sleep)
        try await store.set(controlOptionS, for: safari)
        try await store.set(controlOptionN, for: notes)

        await launch(with: [sleepItem, safariItem, notesItem])

        #expect(
            registrar.calls == [
                .register(controlOptionN, .command(notes)),
                .register(controlOptionS, .command(safari)),
                .register(commandF5, .command(sleep)),
            ])
        #expect(hotKeys.failures.isEmpty)
    }

    @Test func publishingTheSameItemsAgainAsksTheRegistrarForNothing() async throws {
        try await store.set(controlOptionS, for: safari)
        await launch(with: [safariItem])
        registrar.forgetCalls()

        hotKeys.update(items: [safariItem, notesItem], overrides: CommandOverrides())

        #expect(registrar.calls.isEmpty)
    }

    // MARK: Items that come and go

    @Test func hotKeyOfAnItemThatIsGoneIsReleasedAndKeptForWhenItIsBack() async throws {
        try await store.set(controlOptionS, for: safari)
        await launch(with: [safariItem, notesItem])
        registrar.forgetCalls()

        hotKeys.update(items: [notesItem], overrides: CommandOverrides())

        #expect(registrar.calls == [.unregister(.command(safari))])
        #expect(hotKeys.hotKey(for: safari) == controlOptionS)
        #expect(try await store.all() == [safari: controlOptionS])

        hotKeys.update(items: [notesItem, safariItem], overrides: CommandOverrides())

        #expect(registrar.hotKeys == [.command(safari): controlOptionS])
    }

    @Test func disabledItemIsNotRegisteredUntilItIsEnabledAgain() async throws {
        try await store.set(controlOptionS, for: safari)
        await launch(with: [safariItem], overrides: disabling(safari))

        #expect(registrar.calls.isEmpty)
        #expect(hotKeys.hotKey(for: safari) == controlOptionS)

        hotKeys.update(items: [safariItem], overrides: CommandOverrides())
        #expect(registrar.hotKeys == [.command(safari): controlOptionS])

        hotKeys.update(items: [safariItem], overrides: disabling(safari))
        #expect(registrar.hotKeys.isEmpty)
    }

    @Test func hiddenItemKeepsItsHotKeyRegistered() async throws {
        try await store.set(controlOptionS, for: safari)
        let hidden = CommandOverrides(overrides: [safari: ItemOverride(hidden: true)])

        await launch(with: [safariItem], overrides: hidden)

        #expect(registrar.hotKeys == [.command(safari): controlOptionS])
    }

    // MARK: Assigning

    @Test func assigningRegistersTheChordAndStoresIt() async throws {
        await launch(with: [safariItem])

        await hotKeys.assign(controlOptionS, to: safari)

        #expect(registrar.calls == [.register(controlOptionS, .command(safari))])
        #expect(hotKeys.hotKey(for: safari) == controlOptionS)
        #expect(hotKeys.refusals.isEmpty)
        #expect(hotKeys.errorMessage == nil)
        #expect(try await store.all() == [safari: controlOptionS])
    }

    @Test func secondChordReplacesTheFirst() async throws {
        await launch(with: [safariItem])
        await hotKeys.assign(controlOptionS, to: safari)

        await hotKeys.assign(commandF5, to: safari)

        #expect(registrar.hotKeys == [.command(safari): commandF5])
        #expect(try await store.all() == [safari: commandF5])
    }

    @Test func sameChordAgainChangesNothing() async throws {
        await launch(with: [safariItem])
        await hotKeys.assign(controlOptionS, to: safari)
        registrar.forgetCalls()

        await hotKeys.assign(controlOptionS, to: safari)

        #expect(registrar.calls.isEmpty)
        #expect(hotKeys.refusals.isEmpty)
        #expect(try await store.all() == [safari: controlOptionS])
    }

    @Test func assigningToADisabledItemStoresWithoutRegistering() async throws {
        await launch(with: [safariItem], overrides: disabling(safari))

        await hotKeys.assign(controlOptionS, to: safari)

        #expect(registrar.calls.isEmpty)
        #expect(hotKeys.hotKey(for: safari) == controlOptionS)
        #expect(try await store.all() == [safari: controlOptionS])
    }

    @Test func itemTheSourcesNeverYieldedCannotBeAssignedAHotKey() async throws {
        await launch(with: [safariItem])

        await hotKeys.assign(controlOptionS, to: .file(path: "/tmp/report.pdf"))

        #expect(registrar.calls.isEmpty)
        #expect(hotKeys.assignments.isEmpty)
        #expect(try await store.all().isEmpty)
    }

    @Test func nothingIsAssignedBeforeTheStoredHotKeysAreRead() async throws {
        try await store.set(commandF5, for: notes)
        hotKeys.update(items: [safariItem, notesItem], overrides: CommandOverrides())

        // The chord another item has in the store, which the model does not know yet.
        await hotKeys.assign(commandF5, to: safari)

        #expect(registrar.calls.isEmpty)
        #expect(try await store.all() == [notes: commandF5])
    }

    // MARK: Refusals

    @Test func chordOfTheLauncherIsRefused() async throws {
        preferences.launcherHotKey = controlOptionS
        await launch(with: [safariItem])

        await hotKeys.assign(controlOptionS, to: safari)

        #expect(hotKeys.refusals == [safari: .opensLauncher(controlOptionS)])
        #expect(registrar.calls.isEmpty)
        #expect(hotKeys.assignments.isEmpty)
        #expect(try await store.all().isEmpty)
    }

    @Test func chordOfAnotherItemIsRefusedWithThatItemsTitle() async throws {
        await launch(with: [safariItem, notesItem])
        await hotKeys.assign(controlOptionS, to: notes)
        registrar.forgetCalls()

        await hotKeys.assign(controlOptionS, to: safari)

        #expect(hotKeys.refusals == [safari: .belongsTo(controlOptionS, itemTitle: "Notes")])
        #expect(registrar.calls.isEmpty)
        #expect(try await store.all() == [notes: controlOptionS])
    }

    // A disabled item is still there to be enabled again, so it holds its chord.
    @Test func chordOfADisabledItemIsRefusedToo() async throws {
        try await store.set(controlOptionS, for: notes)
        await launch(with: [safariItem, notesItem], overrides: disabling(notes))

        await hotKeys.assign(controlOptionS, to: safari)

        #expect(hotKeys.refusals == [safari: .belongsTo(controlOptionS, itemTitle: "Notes")])
        #expect(try await store.all() == [notes: controlOptionS])
    }

    @Test func chordOfAnItemThatIsGoneIsTakenOver() async throws {
        try await store.set(controlOptionS, for: notes)
        await launch(with: [safariItem])

        await hotKeys.assign(controlOptionS, to: safari)

        #expect(hotKeys.refusals.isEmpty)
        #expect(hotKeys.assignments == [safari: controlOptionS])
        #expect(registrar.hotKeys == [.command(safari): controlOptionS])
        #expect(try await store.all() == [safari: controlOptionS])
    }

    @Test(arguments: [HotKeyError.inUseByAnotherApp, .rejected(-9868)])
    func chordTheRegistrarRefusesLeavesThePreviousHotKey(error: HotKeyError) async throws {
        await launch(with: [safariItem])
        await hotKeys.assign(controlOptionS, to: safari)
        registrar.refusedChords = [commandF5: error]

        await hotKeys.assign(commandF5, to: safari)

        let refused = HotKeyFailure(hotKey: commandF5, error: error)
        #expect(hotKeys.refusals == [safari: .notRegistered(refused)])
        #expect(hotKeys.hotKey(for: safari) == controlOptionS)
        #expect(registrar.hotKeys == [.command(safari): controlOptionS])
        #expect(try await store.all() == [safari: controlOptionS])
        // The stored hotkey still works, so there is no failure to show for it.
        #expect(hotKeys.failures.isEmpty)
    }

    // What happens when the launcher runs on its fallback, ⌃⌥Space, which is not the chord in
    // the preferences.
    @Test func chordTheLauncherSlotHoldsIsRefusedByTheRegistrar() async throws {
        _ = registrar.register(controlOptionSpace, for: .launcher)
        await launch(with: [safariItem])

        await hotKeys.assign(controlOptionSpace, to: safari)

        let refused = HotKeyFailure(
            hotKey: controlOptionSpace, error: .heldBySlot(.launcher))
        #expect(hotKeys.refusals == [safari: .notRegistered(refused)])
        #expect(hotKeys.assignments.isEmpty)
        #expect(try await store.all().isEmpty)
    }

    @Test func nextTryForTheItemForgetsItsRefusal() async throws {
        preferences.launcherHotKey = controlOptionS
        await launch(with: [safariItem, notesItem])
        await hotKeys.assign(controlOptionS, to: safari)
        await hotKeys.assign(controlOptionS, to: notes)

        await hotKeys.assign(commandF5, to: safari)

        #expect(hotKeys.refusals == [notes: .opensLauncher(controlOptionS)])
    }

    @Test func clearingTheRefusalsForgetsThoseOfEveryItem() async throws {
        preferences.launcherHotKey = controlOptionS
        await launch(with: [safariItem, notesItem])
        await hotKeys.assign(controlOptionS, to: safari)
        await hotKeys.assign(controlOptionS, to: notes)

        hotKeys.clearRefusals()

        #expect(hotKeys.refusals.isEmpty)
    }

    // MARK: Clearing

    @Test func clearingReleasesTheHotKeyAndRemovesItFromTheStore() async throws {
        await launch(with: [safariItem, notesItem])
        await hotKeys.assign(controlOptionS, to: safari)
        await hotKeys.assign(controlOptionN, to: notes)
        registrar.forgetCalls()

        await hotKeys.clear(safari)

        #expect(registrar.calls == [.unregister(.command(safari))])
        #expect(hotKeys.assignments == [notes: controlOptionN])
        #expect(try await store.all() == [notes: controlOptionN])
    }

    @Test func clearingAlsoForgetsTheRefusalAndTheFailureOfTheItem() async throws {
        try await store.set(controlOptionS, for: safari)
        registrar.refusedChords = [controlOptionS: .inUseByAnotherApp, commandF5: .rejected(-50)]
        await launch(with: [safariItem])
        await hotKeys.assign(commandF5, to: safari)
        #expect(hotKeys.failures[safari] != nil)
        #expect(hotKeys.refusals[safari] != nil)

        await hotKeys.clear(safari)

        #expect(hotKeys.failures.isEmpty)
        #expect(hotKeys.refusals.isEmpty)
        #expect(try await store.all().isEmpty)
    }

    // MARK: Failures

    @Test func storedHotKeyThatIsRefusedIsAFailureUntilItCanBeRegistered() async throws {
        try await store.set(controlOptionS, for: safari)
        registrar.refusedChords = [controlOptionS: .inUseByAnotherApp]

        await launch(with: [safariItem])

        let failure = HotKeyFailure(hotKey: controlOptionS, error: .inUseByAnotherApp)
        #expect(hotKeys.failures == [safari: failure])
        // It stays the item's hotkey: the other app may let go of the chord.
        #expect(hotKeys.hotKey(for: safari) == controlOptionS)

        // The registry publishes again while the chord is still taken.
        hotKeys.update(items: [safariItem, notesItem], overrides: CommandOverrides())
        #expect(hotKeys.failures == [safari: failure])

        registrar.refusedChords = [:]
        hotKeys.update(items: [safariItem], overrides: CommandOverrides())

        #expect(hotKeys.failures.isEmpty)
        #expect(registrar.hotKeys == [.command(safari): controlOptionS])
    }

    // The row would otherwise go on saying that the chord is in use while the hotkey works.
    @Test func refusalOfAChordGoesWhenThatChordIsRegisteredLater() async throws {
        try await store.set(controlOptionS, for: safari)
        registrar.refusedChords = [controlOptionS: .inUseByAnotherApp]
        await launch(with: [safariItem])
        // Recorded again while the other app still has it.
        await hotKeys.assign(controlOptionS, to: safari)
        #expect(hotKeys.refusals[safari] != nil)

        registrar.refusedChords = [:]
        hotKeys.update(items: [safariItem], overrides: CommandOverrides())

        #expect(hotKeys.refusals.isEmpty)
        #expect(hotKeys.failures.isEmpty)
    }

    // The refusal of another chord than the stored one is about a try that changed nothing,
    // and stays until the next try.
    @Test func refusalOfAnotherChordStaysWhenTheStoredOneIsRegistered() async throws {
        try await store.set(controlOptionS, for: safari)
        registrar.refusedChords = [
            controlOptionS: .inUseByAnotherApp, commandF5: .inUseByAnotherApp,
        ]
        await launch(with: [safariItem])
        await hotKeys.assign(commandF5, to: safari)

        registrar.refusedChords = [commandF5: .inUseByAnotherApp]
        hotKeys.update(items: [safariItem], overrides: CommandOverrides())

        let refused = HotKeyFailure(hotKey: commandF5, error: .inUseByAnotherApp)
        #expect(hotKeys.refusals == [safari: .notRegistered(refused)])
        #expect(hotKeys.failures.isEmpty)
    }

    // The launcher ran on its fallback, ⌃⌥Space, which a command has as its hotkey, and is
    // then given a chord of its own in Settings.
    @Test func hotKeyTheLauncherStoodOnIsRegisteredWhenTheLauncherMovesOffIt() async throws {
        _ = registrar.register(controlOptionSpace, for: .launcher)
        try await store.set(controlOptionSpace, for: safari)
        await launch(with: [safariItem])
        let failure = HotKeyFailure(hotKey: controlOptionSpace, error: .heldBySlot(.launcher))
        #expect(hotKeys.failures == [safari: failure])

        _ = registrar.register(commandF5, for: .launcher)
        hotKeys.launcherHotKeyDidChange()

        #expect(hotKeys.failures.isEmpty)
        #expect(registrar.hotKeys[.command(safari)] == controlOptionSpace)
    }

    @Test func recordingTheFailedChordAgainTriesItAgain() async throws {
        try await store.set(controlOptionS, for: safari)
        registrar.refusedChords = [controlOptionS: .inUseByAnotherApp]
        await launch(with: [safariItem])
        registrar.refusedChords = [:]

        await hotKeys.assign(controlOptionS, to: safari)

        #expect(hotKeys.failures.isEmpty)
        #expect(hotKeys.refusals.isEmpty)
        #expect(registrar.hotKeys == [.command(safari): controlOptionS])
    }

    @Test func failureGoesWithAnItemThatIsDisabledOrGone() async throws {
        try await store.set(controlOptionS, for: safari)
        try await store.set(controlOptionN, for: notes)
        registrar.refusedChords = [
            controlOptionS: .inUseByAnotherApp, controlOptionN: .inUseByAnotherApp,
        ]
        await launch(with: [safariItem, notesItem])
        #expect(hotKeys.failures.count == 2)

        hotKeys.update(items: [safariItem], overrides: disabling(safari))

        #expect(hotKeys.failures.isEmpty)
    }

    // MARK: While a recorder records

    @Test func nothingIsRegisteredWhileARecorderRecords() async throws {
        try await store.set(controlOptionS, for: safari)
        await launch(with: [])

        hotKeys.recorderDidBegin()
        hotKeys.update(items: [safariItem], overrides: CommandOverrides())
        #expect(registrar.calls.isEmpty)

        hotKeys.recorderDidEnd(notRestored: [:])
        #expect(registrar.calls == [.register(controlOptionS, .command(safari))])
    }

    @Test func hotKeyThatDidNotComeBackAfterRecordingIsAFailureAndIsTriedAgain() async throws {
        try await store.set(controlOptionS, for: safari)
        try await store.set(controlOptionN, for: notes)
        await launch(with: [safariItem, notesItem])

        // What a recorder does around its recording, with another app taking ⌃⌥S meanwhile.
        registrar.suspendAll()
        hotKeys.recorderDidBegin()
        registrar.notRestoredAtResume = [.command(safari): .inUseByAnotherApp]
        registrar.refusedChords = [controlOptionS: .inUseByAnotherApp]
        hotKeys.recorderDidEnd(notRestored: registrar.resumeAll())

        let failure = HotKeyFailure(hotKey: controlOptionS, error: .inUseByAnotherApp)
        #expect(hotKeys.failures == [safari: failure])
        #expect(registrar.hotKeys == [.command(notes): controlOptionN])

        registrar.refusedChords = [:]
        hotKeys.update(items: [safariItem, notesItem], overrides: CommandOverrides())

        #expect(hotKeys.failures.isEmpty)
        #expect(registrar.hotKeys[.command(safari)] == controlOptionS)
    }

    // The launcher's slot is in the same answer of `resumeAll`. It is `LauncherHotKey`'s.
    @Test func launcherSlotThatDidNotComeBackIsNotThisModelsConcern() async throws {
        try await store.set(controlOptionS, for: safari)
        await launch(with: [safariItem])
        registrar.forgetCalls()

        hotKeys.recorderDidBegin()
        hotKeys.recorderDidEnd(notRestored: [.launcher: .inUseByAnotherApp])

        #expect(registrar.calls.isEmpty)
        #expect(hotKeys.failures.isEmpty)
    }

    // MARK: Reading

    @Test func pressedItemIsOnlyOneThatIsThereAndEnabled() async {
        await launch(with: [safariItem, notesItem], overrides: disabling(notes))

        #expect(hotKeys.item(pressedFor: safari)?.title == "Safari")
        #expect(hotKeys.item(pressedFor: notes) == nil)
        #expect(hotKeys.item(pressedFor: sleep) == nil)
    }

    @Test func onlyItemsTheSourcesYieldedCanHaveAHotKey() async {
        await launch(with: [safariItem, notesItem], overrides: disabling(notes))

        #expect(hotKeys.canHaveHotKey(safari))
        #expect(hotKeys.canHaveHotKey(notes))
        #expect(!hotKeys.canHaveHotKey(.file(path: "/tmp/report.pdf")))
    }

    @Test func titleIsKnownOnlyForAnItemTheSourcesYielded() async {
        await launch(with: [safariItem])

        #expect(hotKeys.title(of: safari) == "Safari")
        #expect(hotKeys.title(of: sleep) == nil)
    }

    // What the launcher's recorder asks before it takes a chord.
    @Test func chordIsHeldByAnItemThatExistsWhetherOrNotItsHotKeyIsRegistered() async throws {
        try await store.set(controlOptionS, for: safari)
        try await store.set(controlOptionN, for: notes)
        try await store.set(commandF5, for: sleep)
        registrar.refusedChords = [controlOptionS: .inUseByAnotherApp]
        await launch(with: [safariItem, notesItem], overrides: disabling(notes))

        // Safari's hotkey could not be registered and that of Notes is only stored, so the
        // registrar knows of neither.
        #expect(registrar.hotKeys.isEmpty)
        #expect(hotKeys.holder(of: controlOptionS) == safari)
        #expect(hotKeys.holder(of: controlOptionN) == notes)
        // Sleep is not among the items, and an item that is gone does not hold its chord.
        #expect(hotKeys.holder(of: commandF5) == nil)
        #expect(hotKeys.holder(of: controlOptionSpace) == nil)
    }

    @Test func settingsActionClosesTheLauncherAndOpensSettingsOnTheItem() async throws {
        await launch(with: [safariItem])
        let action = try #require(hotKeys.settingsAction(for: safari))
        let context = FakeActionContext()

        let outcome = try await action.perform(context)

        #expect(action.id == ActionID(rawValue: "set-hotkey"))
        #expect(action.title == "Set Hotkey…")
        #expect(context.closeLauncherCount == 1)
        #expect(shownSettings.items == [safari])
        #expect(outcome == .closeLauncher)
    }

    @Test func itemThatCannotHaveAHotKeyHasNoSettingsAction() async {
        await launch(with: [safariItem])

        #expect(hotKeys.settingsAction(for: .file(path: "/tmp/report.pdf")) == nil)
    }
}
