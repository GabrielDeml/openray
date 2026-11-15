import Foundation
import Testing

@testable import OpenRayCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct UpdateSourceTests {
    private let context = FakeActionContext()
    private let updater = FakeUpdater()

    private func makeModel(_ availability: UpdaterAvailability = .available) -> UpdatesModel {
        UpdatesModel(updater: updater, availability: availability)
    }

    private func indexedItems(of source: UpdateSource) async -> [SearchItem] {
        var items: [SearchItem] = []
        for await itemSet in source.indexedItems() {
            items = itemSet
        }
        return items
    }

    @Test func sourceIsInline() {
        let source = UpdateSource(updates: makeModel())

        #expect(source.id == SourceID(rawValue: "updates"))
        #expect(source.latency == .inline)
    }

    // Stored overrides, aliases and usage rows are keyed by these names, so they must not
    // change.
    @Test func itemsKeepTheirNames() async throws {
        let updates = makeModel()
        let source = UpdateSource(updates: updates)
        updates.updateIsWaiting(version: "0.2.0")

        let command = try #require(await indexedItems(of: source).first)
        let row = try #require(try await source.results(for: SearchQuery(""))?.first)

        #expect(command.id.rawValue == "command:updates.check")
        #expect(row.item.id.rawValue == "command:updates.available")
    }

    // MARK: Check for Updates

    @Test func checkForUpdatesIsIndexedOnceAndTheStreamEnds() async throws {
        let source = UpdateSource(updates: makeModel())
        var itemSets = source.indexedItems().makeAsyncIterator()

        let items = try #require(await itemSets.next())
        // The registry waits for every source to yield or to end, and this one is done.
        #expect(await itemSets.next() == nil)

        #expect(items.count == 1)
        let command = try #require(items.first)
        #expect(command.title == "Check for Updates")
        #expect(command.kindLabel == "Command")
        #expect(command.alternateNames.map(\.text) == ["Update", "Upgrade"])
    }

    @Test(arguments: [UpdaterAvailability.developmentBuild, .notConfigured])
    func buildThatCannotUpdateHasNoCommand(_ availability: UpdaterAvailability) async {
        let source = UpdateSource(updates: makeModel(availability))

        #expect(await indexedItems(of: source).isEmpty)
    }

    @Test func checkForUpdatesClosesTheLauncherAndAsksTheUpdater() async throws {
        let source = UpdateSource(updates: makeModel())
        let command = try #require(await indexedItems(of: source).first)
        let action = try #require(command.actions.first)
        #expect(command.actions.count == 1)

        let outcome = try await action.perform(context)

        #expect(outcome == .closeLauncher)
        #expect(context.closeLauncherCount == 1)
        #expect(updater.checkCount == 1)
    }

    // MARK: Update Available

    @Test(arguments: ["", "   ", "\n"])
    func emptyFieldHasNoRowWhileNoUpdateIsWaiting(_ query: String) async throws {
        let source = UpdateSource(updates: makeModel())

        #expect(try await source.results(for: SearchQuery(query)) == nil)
    }

    @Test func emptyFieldSaysWhichUpdateIsWaiting() async throws {
        let updates = makeModel()
        let source = UpdateSource(updates: updates)
        updates.updateIsWaiting(version: "0.2.0")

        let rows = try #require(try await source.results(for: SearchQuery(" ")))

        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.placement == .pinnedTop)
        #expect(row.item.title == "Update Available")
        #expect(row.item.subtitle == "Version 0.2.0")
    }

    @Test func typedQueryGetsNoRowForAWaitingUpdate() async throws {
        let updates = makeModel()
        let source = UpdateSource(updates: updates)
        updates.updateIsWaiting(version: "0.2.0")

        #expect(try await source.results(for: SearchQuery("saf")) == nil)
    }

    @Test func rowIsGoneOnceTheUpdateWasSeen() async throws {
        let updates = makeModel()
        let source = UpdateSource(updates: updates)
        updates.updateIsWaiting(version: "0.2.0")

        updates.updateWasSeen()

        #expect(try await source.results(for: SearchQuery("")) == nil)
    }

    @Test func updateAvailableClosesTheLauncherAndAsksTheUpdater() async throws {
        let updates = makeModel()
        let source = UpdateSource(updates: updates)
        updates.updateIsWaiting(version: "0.2.0")
        let row = try #require(try await source.results(for: SearchQuery(""))?.first)
        let action = try #require(row.item.actions.first)
        #expect(row.item.actions.count == 1)

        let outcome = try await action.perform(context)

        // The updater brings the update it is holding to the front when it is asked to check.
        #expect(outcome == .closeLauncher)
        #expect(context.closeLauncherCount == 1)
        #expect(updater.checkCount == 1)
    }
}
