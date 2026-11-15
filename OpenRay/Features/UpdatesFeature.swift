import OpenRayCore
import SwiftUI

/// Updates (docs/DESIGN.md §6.4): "Check for Updates" and "Update Available" in search, and
/// the pane of Settings for when OpenRay looks for updates. The updater itself is started by
/// `AppDelegate`, which also hands its model to the menu-bar menu and to onboarding.
final class UpdatesFeature: Feature {
    let id = UpdateSource.feature

    func makeSources(_ env: FeatureEnvironment) -> [any SearchSource] {
        [UpdateSource(updates: env.updates)]
    }

    func settingsPane(_ env: FeatureEnvironment) -> SettingsPane? {
        let updates = env.updates
        return SettingsPane(
            id: SettingsPane.updatesID, title: "Updates",
            systemImage: "arrow.triangle.2.circlepath", order: 90,
            makeView: { AnyView(UpdatesSettingsView(updates: updates)) })
    }
}
