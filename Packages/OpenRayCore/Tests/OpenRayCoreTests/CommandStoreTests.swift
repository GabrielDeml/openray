import Foundation
import Testing

@testable import OpenRayCore

@Suite(.timeLimit(.minutes(1))) struct CommandStoreTests {
    private let safari = ItemID.app(bundleID: "com.apple.Safari")
    private let notes = ItemID.app(bundleID: "com.apple.Notes")
    private let created = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeStore() throws -> CommandStore {
        CommandStore(database: try AppDatabase.inMemory())
    }

    private func wiki(id: UUID = UUID()) -> Quicklink {
        Quicklink(
            id: id, name: "Wikipedia", template: "https://en.wikipedia.org/wiki/{query}",
            openWith: "com.apple.Safari", icon: "📚", createdAt: created)
    }

    // MARK: Seeds

    @Test func newDatabaseStartsWithTheSeededQuicklinksAndFallbackList() async throws {
        let store = try makeStore()

        let overrides = try await store.snapshot()

        #expect(overrides.quicklinks.map(\.name) == ["Google", "DuckDuckGo"])
        #expect(overrides.quicklinks[0].template == "https://www.google.com/search?q={query}")
        #expect(
            overrides.fallbackOrder.map(\.rawValue) == [
                "quicklink:1A47E6BE-FE88-4B7B-8351-8A31C8F89B17",
                "quicklink:387E4923-C4DD-4185-A582-2C149037FD3F",
                "command:files.search",
            ])
        #expect(overrides.aliases.isEmpty)
        #expect(overrides.overrides.isEmpty)
    }

    // MARK: Aliases

    @Test func aliasIsStoredFoldedLikeAQuery() async throws {
        let store = try makeStore()

        try await store.setAliases(["  Café "], for: safari)

        let overrides = try await store.snapshot()
        #expect(overrides.aliases == ["cafe": safari])
        #expect(overrides.aliases[SearchQuery("CAFÉ").normalized] == safari)
    }

    @Test func itemCanHaveSeveralAliases() async throws {
        let store = try makeStore()

        try await store.setAliases(["web", "browser", "Web"], for: safari)

        let overrides = try await store.snapshot()
        #expect(overrides.aliases(of: safari) == ["browser", "web"])
        #expect(overrides.aliases(of: notes).isEmpty)
    }

    @Test func settingAliasesReplacesTheOnesTheItemHad() async throws {
        let store = try makeStore()
        try await store.setAliases(["web", "browser"], for: safari)
        try await store.setAliases(["n"], for: notes)

        try await store.setAliases(["browser", "surf"], for: safari)

        let overrides = try await store.snapshot()
        #expect(overrides.aliases(of: safari) == ["browser", "surf"])
        // Another item's aliases are not touched.
        #expect(overrides.aliases(of: notes) == ["n"])

        try await store.setAliases([], for: safari)
        #expect(try await store.snapshot().aliases == ["n": notes])
    }

    @Test func aliasGivenToAnotherItemIsTakenFromTheFirst() async throws {
        let store = try makeStore()
        try await store.setAliases(["n"], for: safari)

        try await store.setAliases(["N"], for: notes)

        #expect(try await store.snapshot().aliases == ["n": notes])
    }

    @Test func aliasThatIsEmptyOnceFoldedIsLeftOut() async throws {
        let store = try makeStore()

        try await store.setAliases(["   ", "web", ""], for: safari)

        #expect(try await store.snapshot().aliases == ["web": safari])
    }

    // MARK: Overrides

    @Test func overrideIsStoredPerItem() async throws {
        let store = try makeStore()

        try await store.updateOverride(for: safari) { override in override.hidden = true }
        try await store.updateOverride(for: notes) { override in override.disabled = true }

        let overrides = try await store.snapshot()
        #expect(overrides.overrides[safari] == ItemOverride(hidden: true, disabled: false))
        #expect(overrides.overrides[notes] == ItemOverride(hidden: false, disabled: true))
        #expect(!overrides.isSearchable(safari))
        #expect(!overrides.isSearchable(notes))
        #expect(!overrides.isDisabled(safari))
        #expect(overrides.isDisabled(notes))
    }

    @Test func overrideThatSaysNothingRemovesTheRow() async throws {
        let store = try makeStore()
        try await store.updateOverride(for: safari) { override in override.hidden = true }

        try await store.updateOverride(for: safari) { override in override = ItemOverride() }

        let overrides = try await store.snapshot()
        #expect(overrides.overrides.isEmpty)
        #expect(overrides.isSearchable(safari))
    }

    @Test func updateChangesOnePartAndKeepsTheOther() async throws {
        let store = try makeStore()

        try await store.updateOverride(for: safari) { override in override.hidden = true }
        try await store.updateOverride(for: safari) { override in override.disabled = true }

        #expect(
            try await store.snapshot().overrides[safari]
                == ItemOverride(hidden: true, disabled: true))
    }

    // MARK: Quicklinks

    @Test func savedQuicklinkComesBackWithEveryField() async throws {
        let store = try makeStore()
        let quicklink = wiki()

        try await store.saveQuicklink(quicklink)

        let stored = try await store.snapshot().quicklinks.last
        #expect(stored == quicklink)
    }

    @Test func savingAgainReplacesTheQuicklinkWithThatID() async throws {
        let store = try makeStore()
        var quicklink = wiki()
        try await store.saveQuicklink(quicklink)

        quicklink.name = "Wiki"
        quicklink.openWith = nil
        quicklink.icon = nil
        try await store.saveQuicklink(quicklink)

        let quicklinks = try await store.snapshot().quicklinks
        #expect(quicklinks.count == 3)
        #expect(quicklinks.last == quicklink)
    }

    @Test func deletingAQuicklinkTakesItsAliasOverrideAndFallbackRowWithIt() async throws {
        let store = try makeStore()
        let quicklink = wiki()
        try await store.saveQuicklink(quicklink)
        try await store.setAliases(["w"], for: quicklink.itemID)
        try await store.setAliases(["web"], for: safari)
        try await store.updateOverride(for: quicklink.itemID) { override in override.hidden = true }
        try await store.updateFallbackOrder { order in order = [quicklink.itemID, safari] }

        try await store.deleteQuicklink(quicklink.id)

        let overrides = try await store.snapshot()
        #expect(overrides.quicklinks.map(\.name) == ["Google", "DuckDuckGo"])
        #expect(overrides.aliases == ["web": safari])
        #expect(overrides.overrides.isEmpty)
        #expect(overrides.fallbackOrder == [safari])
    }

    @Test func deletingAQuicklinkTakesItsHotKeyWithIt() async throws {
        let database = try AppDatabase.inMemory()
        let store = CommandStore(database: database)
        let hotKeyStore = CommandHotKeyStore(database: database)
        let quicklink = wiki()
        let controlOptionW = HotKey(keyCode: 0x0D, modifiers: [.control, .option])
        let controlOptionS = HotKey(keyCode: 0x01, modifiers: [.control, .option])
        try await store.saveQuicklink(quicklink)
        try await hotKeyStore.set(controlOptionW, for: quicklink.itemID)
        try await hotKeyStore.set(controlOptionS, for: safari)

        try await store.deleteQuicklink(quicklink.id)

        #expect(try await hotKeyStore.all() == [safari: controlOptionS])
    }

    // MARK: Fallback order

    @Test func fallbackOrderIsChangedFromWhatIsStored() async throws {
        let store = try makeStore()
        let notes = notes
        let safari = safari

        try await store.updateFallbackOrder { order in order = [notes, safari] }
        try await store.updateFallbackOrder { order in order.removeAll { $0 == notes } }
        try await store.updateFallbackOrder { order in order.append(notes) }

        #expect(try await store.snapshot().fallbackOrder == [safari, notes])
    }

    @Test func itemNamedTwiceKeepsItsFirstPlace() async throws {
        let store = try makeStore()

        try await store.updateFallbackOrder { order in order = [notes, safari, notes] }

        #expect(try await store.snapshot().fallbackOrder == [notes, safari])
    }

    // MARK: Changes

    @Test func changesYieldTheCurrentStateAndThenEveryChange() async throws {
        let store = try makeStore()
        var changes = store.changes().makeAsyncIterator()

        let initial = try await changes.next()
        #expect(initial?.aliases.isEmpty == true)
        #expect(initial?.quicklinks.count == 2)

        try await store.setAliases(["web"], for: safari)
        let afterAlias = try await changes.next()
        #expect(afterAlias?.aliases == ["web": safari])

        try await store.updateOverride(for: notes) { override in override.hidden = true }
        let afterOverride = try await changes.next()
        #expect(afterOverride?.overrides[notes]?.hidden == true)
    }

    @Test func writeThatChangesNothingIsNotAChange() async throws {
        let store = try makeStore()
        var changes = store.changes().makeAsyncIterator()
        _ = try await changes.next()

        // Setting the aliases an item already has writes to the table and leaves it as it was.
        try await store.setAliases([], for: safari)
        try await store.setAliases(["web"], for: safari)

        let next = try await changes.next()
        #expect(next?.aliases == ["web": safari])
    }
}
