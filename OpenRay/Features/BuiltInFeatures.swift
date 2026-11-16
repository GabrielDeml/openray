import OpenRayCore

/// The features OpenRay ships with. This list is the one place a new command is added: its
/// feature makes the sources, the settings pane and the screens, and the launcher finds them
/// here (docs/DESIGN.md §4.2.3).
///
/// The order is the order of the sources in root search. Of two sources that yield an item
/// with the same ID, the earlier one keeps it.
enum BuiltInFeatures {
    static func make() -> [any Feature] {
        [
            AppsFeature(),
            SystemCommandsFeature(),
            WindowManagementFeature(),
            QuicklinksFeature(),
            SnippetsFeature(),
            FileSearchFeature(),
            ScriptsFeature(),
            CalculatorFeature(),
            QuickAIFeature(),
            UpdatesFeature(),
            OpenRayFeature(),
            PermissionsFeature(),
        ]
    }
}
