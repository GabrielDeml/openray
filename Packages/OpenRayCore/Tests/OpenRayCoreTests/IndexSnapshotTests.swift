import Foundation
import Testing

@testable import OpenRayCore

@Suite struct IndexSnapshotTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func app(
        _ title: String, id: String, alternateNames: [NameVariant] = []
    ) -> SearchItem {
        SearchItem(
            id: .app(bundleID: id), title: title, alternateNames: alternateNames,
            icon: .symbol("app"), kindLabel: "Application")
    }

    /// The folded text of every name of the entry, in order.
    private func foldedNames(of entry: IndexSnapshot.Entry) -> [String] {
        var texts: [String] = []
        for name in entry.names {
            var text = String.UnicodeScalarView()
            text.append(contentsOf: name.normalized.scalars)
            texts.append(String(text))
        }
        return texts
    }

    @Test func emptySnapshotHasNoEntries() async {
        let built = await IndexSnapshot.build(from: [])

        #expect(IndexSnapshot.empty.entries.isEmpty)
        #expect(built.entries.isEmpty)
        #expect(built.duplicateIDCount == 0)
    }

    @Test func nameInAnotherScriptGetsATransliteration() async throws {
        let snapshot = await IndexSnapshot.build(from: [app("微信", id: "com.tencent.xinWeChat")])
        let entry = try #require(snapshot.entries.first)

        #expect(foldedNames(of: entry) == ["微信", "wei xin"])
        #expect(entry.names[0].isTitle)
        #expect(entry.names[0].weight == 1)
        #expect(!entry.names[1].isTitle)
        #expect(entry.names[1].weight == 0.9)
    }

    @Test func transliterationIsFoundByItsLettersAndByItsInitials() async throws {
        let snapshot = await IndexSnapshot.build(from: [app("微信", id: "com.tencent.xinWeChat")])

        let byLetters = try #require(
            await snapshot.rank(query: SearchQuery("weixin"), usage: UsageSnapshot(), now: now))
        let byInitials = try #require(
            await snapshot.rank(query: SearchQuery("wx"), usage: UsageSnapshot(), now: now))

        #expect(byLetters.rows.count == 1)
        #expect(byInitials.rows.count == 1)
        // An acronym, times the weight of a transliteration.
        #expect(byInitials.rows.first?.scored.quality == 0.75 * 0.9)
        // The matched letters are not in the title, so there is nothing to highlight.
        #expect(byInitials.rows.first?.scored.highlights == [])
    }

    @Test func mixedScriptsTransliterateTogether() async throws {
        let snapshot = await IndexSnapshot.build(from: [app("微信 Привет", id: "example.mixed")])
        let entry = try #require(snapshot.entries.first)

        #expect(foldedNames(of: entry) == ["微信 привет", "wei xin privet"])
    }

    @Test func latinNameWithDiacriticsGetsNoSecondName() async throws {
        let snapshot = await IndexSnapshot.build(from: [
            app("Größe", id: "example.groesse"),
            app("Café", id: "example.cafe"),
        ])

        #expect(foldedNames(of: snapshot.entries[0]) == ["grosse"])
        #expect(foldedNames(of: snapshot.entries[1]) == ["cafe"])
    }

    @Test func alternateNamesKeepTheirWeightAndTransliterateToo() async throws {
        let wechat = app(
            "WeChat", id: "com.tencent.xinWeChat",
            alternateNames: [NameVariant(text: "微信", weight: 0.95)])
        let snapshot = await IndexSnapshot.build(from: [wechat])
        let entry = try #require(snapshot.entries.first)

        #expect(foldedNames(of: entry) == ["wechat", "微信", "wei xin"])
        #expect(entry.names[1].weight == 0.95)
        #expect(entry.names[2].weight == 0.95 * 0.9)
    }

    @Test func namesThatFoldToTheSameTextCollapseAndKeepTheHigherWeight() async throws {
        let code = app(
            "Code", id: "com.microsoft.VSCode",
            alternateNames: [
                NameVariant(text: "code", weight: 0.95),
                NameVariant(text: "VS Code", weight: 0.8),
                NameVariant(text: "vs code", weight: 0.95),
            ])
        let snapshot = await IndexSnapshot.build(from: [code])
        let entry = try #require(snapshot.entries.first)

        #expect(foldedNames(of: entry) == ["code", "vs code"])
        #expect(entry.names[0].isTitle)
        #expect(entry.names[0].weight == 1)
        #expect(entry.names[1].weight == 0.95)
    }

    @Test func itemWithAnIDThatAlreadyOccurredIsLeftOutAndCounted() async {
        let snapshot = await IndexSnapshot.build(from: [
            app("Safari", id: "com.apple.Safari"),
            app("Notes", id: "com.apple.Notes"),
            app("Safari Copy", id: "com.apple.Safari"),
        ])

        var titles: [String] = []
        for entry in snapshot.entries {
            titles.append(entry.item.title)
        }
        #expect(titles == ["Safari", "Notes"])
        #expect(snapshot.duplicateIDCount == 1)
    }

    // MARK: Overrides

    private let safari = ItemID.app(bundleID: "com.apple.Safari")
    private let notes = ItemID.app(bundleID: "com.apple.Notes")

    private var safariAndNotes: [SearchItem] {
        [app("Safari", id: "com.apple.Safari"), app("Notes", id: "com.apple.Notes")]
    }

    private func titles(of snapshot: IndexSnapshot) -> [String] {
        snapshot.entries.map(\.item.title)
    }

    @Test func hiddenAndDisabledItemsAreLeftOutOfTheIndex() async {
        let hidden = CommandOverrides(overrides: [safari: ItemOverride(hidden: true)])
        let disabled = CommandOverrides(overrides: [notes: ItemOverride(disabled: true)])

        let withoutSafari = await IndexSnapshot.build(from: safariAndNotes, overrides: hidden)
        let withoutNotes = await IndexSnapshot.build(from: safariAndNotes, overrides: disabled)

        #expect(titles(of: withoutSafari) == ["Notes"])
        #expect(titles(of: withoutNotes) == ["Safari"])
        // Leaving an item out on purpose is not the mistake that the duplicate count reports.
        #expect(withoutSafari.duplicateIDCount == 0)
    }

    @Test func aliasesBecomeNamesWithTheAliasWeight() async throws {
        let overrides = CommandOverrides(aliases: ["web": safari, "browser": safari, "n": notes])

        let snapshot = await IndexSnapshot.build(from: safariAndNotes, overrides: overrides)

        let safariEntry = try #require(snapshot.entries.first)
        #expect(foldedNames(of: safariEntry) == ["safari", "browser", "web"])
        #expect(safariEntry.names[1].isAlias)
        #expect(safariEntry.names[1].weight == 0.95)
        #expect(!safariEntry.names[0].isAlias)
        #expect(foldedNames(of: snapshot.entries[1]) == ["notes", "n"])
    }

    @Test func aliasThatRepeatsAnOwnNameKeepsThatNamesWeightAndStillPins() async throws {
        let overrides = CommandOverrides(aliases: ["safari": safari])

        let snapshot = await IndexSnapshot.build(from: safariAndNotes, overrides: overrides)

        let entry = try #require(snapshot.entries.first)
        #expect(foldedNames(of: entry) == ["safari"])
        #expect(entry.names[0].weight == 1)
        #expect(entry.names[0].isAlias)
        #expect(entry.names[0].isTitle)
    }

    @Test func queryThatEqualsAnAliasPinsTheItemWithFullQuality() async throws {
        let overrides = CommandOverrides(aliases: ["web": safari])
        let snapshot = await IndexSnapshot.build(
            from: safariAndNotes + [app("Web Inspector", id: "example.inspector")],
            overrides: overrides)

        let ranked = try #require(
            await snapshot.rank(query: SearchQuery("Web"), usage: UsageSnapshot(), now: now))

        let safariRow = try #require(ranked.rows.first { $0.scored.item.id == safari })
        #expect(safariRow.scored.placement == .pinnedTop)
        #expect(safariRow.scored.quality == 1)
        // Found through the alias, so nothing in the title is highlighted.
        #expect(safariRow.scored.highlights == [])
        let inspectorRow = try #require(
            ranked.rows.first { $0.scored.item.title == "Web Inspector" })
        #expect(inspectorRow.scored.placement == .ranked)
    }

    @Test func beginningOfAnAliasRanksAsAPrefixOfAnAliasAndDoesNotPin() async throws {
        let overrides = CommandOverrides(aliases: ["browser": safari])
        let snapshot = await IndexSnapshot.build(from: safariAndNotes, overrides: overrides)

        let ranked = try #require(
            await snapshot.rank(query: SearchQuery("bro"), usage: UsageSnapshot(), now: now))

        let row = try #require(ranked.rows.first)
        #expect(row.scored.item.id == safari)
        #expect(row.scored.placement == .ranked)
        // The prefix tier, 0.9 + 0.1 · 3/7, times the weight of an alias.
        let prefixQuality = 0.9 + 0.1 * 3 / 7
        #expect(abs(row.scored.quality - prefixQuality * 0.95) < 1e-12)
    }

    @Test func shortcutsTheLauncherReservesAreRemovedAndCounted() async throws {
        let copy = KeyChord(keyCode: VirtualKey.ansiC, modifiers: [.command], characters: "c")
        let find = KeyChord(keyCode: 0x03, modifiers: [.command, .shift], characters: "f")
        func action(_ name: String, _ shortcut: KeyChord?) -> ActionDescriptor {
            ActionDescriptor(id: ActionID(rawValue: name), title: name, shortcut: shortcut) { _ in
                .keepOpen
            }
        }
        var item = app("Safari", id: "com.apple.Safari")
        item.actions = [action("open", nil), action("copy", copy), action("find", find)]

        let snapshot = await IndexSnapshot.build(from: [item])

        let actions = try #require(snapshot.entries.first).item.actions
        #expect(actions.map(\.shortcut) == [nil, nil, find])
        #expect(snapshot.reservedShortcutCount == 1)
    }
}
