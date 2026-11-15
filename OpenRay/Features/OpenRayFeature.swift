import OpenRayCore

/// OpenRay's own commands. So far that is the one that opens Settings.
final class OpenRayFeature: Feature {
    let id = FeatureID(rawValue: "openray")

    func makeSources(_ env: FeatureEnvironment) -> [any SearchSource] {
        let showSettings = env.showSettings
        let open = ActionDescriptor(
            id: ActionID(rawValue: "open"), title: String(localized: "Open Settings")
        ) { context in
            // Settings is a window outside the panel.
            context.closeLauncher()
            showSettings(nil)
            return .closeLauncher
        }
        let settings = SearchItem(
            id: .command(id, "settings"),
            title: String(localized: "\(AppInfo.name) Settings"),
            alternateNames: [.keyword(String(localized: "Preferences"))],
            icon: .symbol("gearshape"),
            kindLabel: String(localized: "Command"),
            actions: [open])
        return [SettingsCommandSource(settings: settings)]
    }
}

/// Yields the Settings command once; it never changes.
private struct SettingsCommandSource: SearchSource {
    let id = SourceID(rawValue: "openray")
    let latency = SourceLatency.inline
    let settings: SearchItem

    func indexedItems() -> AsyncStream<[SearchItem]> {
        AsyncStream { continuation in
            continuation.yield([settings])
            continuation.finish()
        }
    }
}
