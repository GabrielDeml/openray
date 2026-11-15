import OpenRayCore
import SwiftUI

/// One built-in feature: the sources it adds to search, the pane it adds to Settings and the
/// screens it can push (docs/DESIGN.md §4.2.3). `BuiltInFeatures.swift` lists them, and adding a
/// feature there is all it takes for its commands to appear in the launcher.
protocol Feature: AnyObject {
    var id: FeatureID { get }
    func makeSources(_ env: FeatureEnvironment) -> [any SearchSource]
    /// The feature's page in Settings, if it has one.
    func settingsPane(_ env: FeatureEnvironment) -> SettingsPane?
    /// The screen a request names, or nil when the feature has no such screen.
    func makeScreen(
        _ request: ScreenRequest, context: any ScreenContext, env: FeatureEnvironment
    ) -> ScreenSpec?
    /// The Mac woke from sleep. A feature that follows the system through notifications may
    /// have missed some while it slept.
    func systemDidWake()
    /// The screen Tab opens from root search when the selected row has none of its own. The
    /// launcher adds the query as the request's argument (§4.1.4). nil for every feature but
    /// the one that takes the query.
    var tabFallback: ScreenRequest? { get }
}

extension Feature {
    func settingsPane(_ env: FeatureEnvironment) -> SettingsPane? { nil }

    func systemDidWake() {}

    func makeScreen(
        _ request: ScreenRequest, context: any ScreenContext, env: FeatureEnvironment
    ) -> ScreenSpec? {
        nil
    }

    var tabFallback: ScreenRequest? { nil }
}

/// The services features share, built once by `AppDelegate`.
struct FeatureEnvironment {
    let database: AppDatabase
    let usage: any UsageStore
    let commands: CommandStore
    let preferences: Preferences
    /// The store behind `preferences`, for Core sources that follow a preference off the main
    /// actor.
    let preferencesStore: any PreferencesStore
    let permissions: PermissionCenter
    /// Where secrets are kept: the Keychain.
    let secrets: any SecretStore
    let system: any SystemControl
    let workspace: WorkspaceActions
    /// What the updater is set to and whether an update is waiting.
    let updates: UpdatesModel
    /// Everything the launcher's sources have yielded so far (`CommandRegistry.items`), for a
    /// feature that says something about the commands of others. Empty while the features are
    /// still being asked for their sources.
    let currentItems: () -> [SearchItem]
    /// Opens the settings window, on a pane if one is named.
    let showSettings: (SettingsPane.ID?) -> Void
}

/// What a pushed screen looks like and how it takes part in the launcher (§4.1.5).
struct ScreenSpec {
    var title: String
    var searchBar: SearchBarMode
    var body: Body

    enum Body {
        /// The shell draws the rows the screen sets through `ScreenContext.setSections` and owns
        /// the selection, Return, ⌘1 to ⌘9 and ⌘K as it does for root search. `detail` draws
        /// the selected item beside the list.
        case list(detail: ((ItemID) -> AnyView)?)
        /// The feature draws the screen. Every key intent is offered to `handleIntent` first,
        /// which returns true when the screen has dealt with it.
        case custom(AnyView, handleIntent: (LauncherIntent) -> Bool)
    }

    /// What a custom screen takes key intents with; nil for a list screen.
    var intentHandler: ((LauncherIntent) -> Bool)? {
        switch body {
        case .list: return nil
        case .custom(_, let handleIntent): return handleIntent
        }
    }

    /// A custom screen that leaves every key to the shell.
    static func custom(
        title: String, searchBar: SearchBarMode, view: some View
    ) -> ScreenSpec {
        ScreenSpec(
            title: title, searchBar: searchBar,
            body: .custom(AnyView(view), handleIntent: { _ in false }))
    }
}

/// Finds the feature a `ScreenRequest` names and has it build the screen.
final class ScreenRegistry {
    private let features: [any Feature]
    private let env: FeatureEnvironment

    init(features: [any Feature], env: FeatureEnvironment) {
        self.features = features
        self.env = env
    }

    /// - Returns: nil when no feature has that ID or the feature has no such screen.
    func makeScreen(_ request: ScreenRequest, context: any ScreenContext) -> ScreenSpec? {
        guard let feature = features.first(where: { $0.id == request.feature }) else {
            return nil
        }
        return feature.makeScreen(request, context: context, env: env)
    }
}
