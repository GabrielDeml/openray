import OpenRayCore
import SwiftUI

/// Snippets (docs/DESIGN.md §4.9): every snippet and the two commands in search, the list
/// behind "Search Snippets", and the pane of Settings where snippets are written.
final class SnippetsFeature: Feature {
    let id = SnippetSource.feature

    /// Made with the source and kept for the list screen and the pane.
    private var store: SnippetStore?
    private var source: SnippetSource?
    /// The pane's model. The source opens the editor through it, which is how "Edit Snippet…"
    /// and "Create Snippet" get from the launcher into Settings.
    private var settings: SnippetsSettingsModel?

    func makeSources(_ env: FeatureEnvironment) -> [any SearchSource] {
        let store = SnippetStore(database: env.database)
        let settings = SnippetsSettingsModel(store: store)
        let showSettings = env.showSettings
        let source = SnippetSource(store: store) { snippet in
            settings.edit(snippet)
            showSettings(SettingsPane.snippetsID)
        }

        self.store = store
        self.source = source
        self.settings = settings
        return [source]
    }

    func settingsPane(_ env: FeatureEnvironment) -> SettingsPane? {
        // The sources are made before the panes, so the model is there.
        guard let settings else { return nil }
        return SettingsPane(
            id: SettingsPane.snippetsID, title: "Snippets", systemImage: "text.quote", order: 70,
            makeView: { AnyView(SnippetsSettingsView(model: settings)) })
    }

    func makeScreen(
        _ request: ScreenRequest, context: any ScreenContext, env: FeatureEnvironment
    ) -> ScreenSpec? {
        guard request.screen == SnippetSource.searchScreen, let store, let source else {
            return nil
        }

        let model = SnippetSearchModel(store: store, source: source, context: context)
        // The detail view exists only while a row is selected, so the spec holds the model.
        return ScreenSpec(
            title: String(localized: "Search Snippets"),
            searchBar: .filter(placeholder: String(localized: "Search snippets…")),
            body: .list(detail: { selection in
                AnyView(SnippetDetailView(snippet: model.snippet(for: selection)))
            }),
            model: model)
    }
}

/// The selected snippet beside the list: its name, its keyword, and its text as it was
/// written, placeholders and all. Nothing here can be selected or edited; the keyboard stays
/// with the search field.
private struct SnippetDetailView: View {
    /// nil for a moment after the selected snippet was deleted.
    let snippet: Snippet?

    var body: some View {
        ScrollView {
            if let snippet {
                VStack(alignment: .leading, spacing: 10) {
                    Text(snippet.name)
                        .font(.system(size: 15, weight: .semibold))
                    if let keyword = snippet.keyword {
                        Text("Keyword: \(keyword)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    Text(snippet.body)
                        .font(.system(size: 12, design: .monospaced))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }
}
