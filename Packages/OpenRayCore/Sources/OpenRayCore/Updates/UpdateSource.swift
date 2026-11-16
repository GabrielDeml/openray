import Foundation

/// Updates in root search (docs/DESIGN.md §6.4).
///
/// "Check for Updates" is a command that is found by its name, in a build that can update
/// itself. And while an update is waiting to be looked at, the empty search field has
/// "Update Available" at its top.
public struct UpdateSource: SearchSource {
    public static let feature = FeatureID(rawValue: "updates")

    public let id = SourceID(rawValue: "updates")
    public let latency = SourceLatency.inline

    private let updates: UpdatesModel

    public init(updates: UpdatesModel) {
        self.updates = updates
    }

    /// The "Check for Updates" command, or nothing in a build whose updater never runs: a
    /// command that could only say so would be in the way.
    public func indexedItems() -> AsyncStream<[SearchItem]> {
        var commands: [SearchItem] = []
        if updates.availability == .available {
            commands.append(Self.checkItem(updates: updates))
        }
        return AsyncStream { continuation in
            continuation.yield(commands)
            continuation.finish()
        }
    }

    public func results(for query: SearchQuery) async throws -> [ScoredItem]? {
        let typed = query.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.isEmpty else { return nil }

        // Only the model knows whether an update is waiting, and it lives on the main actor.
        guard let version = await updates.waitingUpdateVersion else { return nil }
        let item = Self.updateAvailableItem(version: version, updates: updates)
        return [ScoredItem(item: item, quality: 1, placement: .pinnedTop)]
    }

    // MARK: Items

    private static var kindLabel: String {
        String(
            localized: "Command", bundle: .module,
            comment: "The kind of a search result that is a command, shown at the end of its row."
        )
    }

    private static func checkItem(updates: UpdatesModel) -> SearchItem {
        let title = String(
            localized: "Check for Updates", bundle: .module,
            comment: "The command that looks for a newer version of OpenRay.")
        let keywords = [
            String(
                localized: "Update", bundle: .module,
                comment: "Another word the Check for Updates command is found by."),
            String(
                localized: "Upgrade", bundle: .module,
                comment: "Another word the Check for Updates command is found by."),
        ]
        var alternateNames: [NameVariant] = []
        for keyword in keywords {
            alternateNames.append(.keyword(keyword))
        }

        let check = ActionDescriptor(id: ActionID(rawValue: "check"), title: title) { context in
            showUpdaterWindow(of: updates, closing: context)
        }
        return SearchItem(
            id: .command(feature, "check"), title: title, alternateNames: alternateNames,
            icon: .symbol("arrow.triangle.2.circlepath"), kindLabel: kindLabel, actions: [check])
    }

    private static func updateAvailableItem(version: String, updates: UpdatesModel) -> SearchItem {
        let title = String(
            localized: "Update Available", bundle: .module,
            comment:
                "The row at the top of the empty search field while a newer version of OpenRay is waiting to be installed."
        )
        let subtitle = String(
            localized: "Version \(version)", bundle: .module,
            comment:
                "Under Update Available: the version that can be installed. The placeholder is a version number such as 0.2.0."
        )
        let showTitle = String(
            localized: "Show Update", bundle: .module,
            comment: "The action of the Update Available row. It opens the window of the update.")
        let show = ActionDescriptor(id: ActionID(rawValue: "show"), title: showTitle) { context in
            showUpdaterWindow(of: updates, closing: context)
        }
        return SearchItem(
            id: .command(feature, "available"), title: title, subtitle: subtitle,
            icon: .symbol("arrow.down.circle"), kindLabel: kindLabel, actions: [show])
    }

    /// What both rows do. A check that the user asks for is also what brings an update that is
    /// already waiting to the front.
    @MainActor
    private static func showUpdaterWindow(
        of updates: UpdatesModel, closing context: any ActionContext
    ) -> ActionOutcome {
        // The updater's windows are outside the panel.
        context.closeLauncher()
        updates.checkForUpdates()
        return .closeLauncher
    }
}
