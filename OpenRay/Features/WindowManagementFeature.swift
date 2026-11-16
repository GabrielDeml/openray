import AppKit
import OpenRayCore
import SwiftUI

/// Window management (docs/DESIGN.md §4.7): Left Half, Maximize Window and the other window
/// commands in search, and their pane in Settings. The commands and where they put a window
/// are Core's; this hands them the screens and the windows of this Mac.
final class WindowManagementFeature: Feature {
    let id = WindowCommandSource.feature

    private let host = MacWindowHost()

    func makeSources(_ env: FeatureEnvironment) -> [any SearchSource] {
        [WindowCommandSource(host: host, preferences: env.preferencesStore)]
    }

    func settingsPane(_ env: FeatureEnvironment) -> SettingsPane? {
        SettingsPane(
            id: SettingsPane.windowManagementID, title: "Window Management",
            systemImage: "macwindow.on.rectangle", order: 50,
            makeView: { AnyView(WindowManagementSettingsView(preferences: env.preferences)) })
    }
}

/// The Mac as the window commands see it: its screens, whether Stage Manager is on, and the
/// controller that moves a window.
private final class MacWindowHost: WindowHost {
    private let controller = AXWindowController()

    var displays: [DisplayGeometry] {
        NSScreen.screens.map { $0.geometry }
    }

    /// No public API says whether Stage Manager is on. Its switch in System Settings is kept
    /// in this default, which is not documented.
    var isStageManagerOn: Bool {
        let windowManager = UserDefaults(suiteName: "com.apple.WindowManager")
        return windowManager?.bool(forKey: "GloballyEnabled") ?? false
    }

    /// The Dock's place is kept in this default, which is not documented either. Without a
    /// value the Dock is at the bottom.
    var isDockOnTheLeft: Bool {
        let dock = UserDefaults(suiteName: "com.apple.dock")
        return dock?.string(forKey: "orientation") == "left"
    }

    func perform(
        _ action: WindowAction, pid: pid_t, displays: [DisplayGeometry], gap: CGFloat,
        stageStripInset: CGFloat, isDockOnTheLeft: Bool
    ) async throws(WindowError) {
        try await controller.perform(
            action, pid: pid, displays: displays, gap: gap, stageStripInset: stageStripInset,
            isDockOnTheLeft: isDockOnTheLeft)
    }
}
