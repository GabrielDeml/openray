import AppKit
import OpenRayCore
import SwiftUI

/// The apps on this Mac (docs/DESIGN.md §4.2.8), and the Settings pane for the folders they are
/// looked for in.
final class AppsFeature: Feature {
    let id = FeatureID(rawValue: "apps")

    /// Kept so that it can be told to read the folders again.
    private var index: AppIndexSource?

    func makeSources(_ env: FeatureEnvironment) -> [any SearchSource] {
        let index = AppIndexSource(
            host: env.workspace, commands: env.commands, preferences: env.preferencesStore)
        self.index = index
        return [index]
    }

    func systemDidWake() {
        // Nothing reports what changed in the app folders while the Mac was asleep.
        index?.rescan()
    }

    func settingsPane(_ env: FeatureEnvironment) -> SettingsPane? {
        SettingsPane(
            id: "applications", title: "Applications", systemImage: "square.grid.2x2", order: 20,
            makeView: { AnyView(ApplicationsSettingsView(preferences: env.preferences)) })
    }
}

/// Where apps are looked for: the folders macOS keeps them in, and the ones the user adds.
struct ApplicationsSettingsView: View {
    let preferences: Preferences

    var body: some View {
        Form {
            Section {
                ForEach(preferences.appFolders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder")
                        Text(folder)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Remove") {
                            remove(folder)
                        }
                    }
                }
                Button("Add Folder…") {
                    chooseFolder()
                }
            } header: {
                Text("More Folders")
            } footer: {
                Text(
                    "OpenRay finds apps in the Applications folders of this Mac. Add a folder here if you keep apps somewhere else."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private func remove(_ folder: String) {
        preferences.appFolders.removeAll { existing in existing == folder }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let path = url.path(percentEncoded: false)
        if !preferences.appFolders.contains(path) {
            preferences.appFolders.append(path)
        }
    }
}
