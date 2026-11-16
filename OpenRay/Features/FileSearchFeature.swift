import OpenRayCore
import SwiftUI

/// File search (docs/DESIGN.md §4.8): the "Search Files" command and its fallback row in
/// search, the list of files it opens, the "Open With" list, and the File Search pane of
/// Settings. Searching, ranking and what every action does are Core's; this hands them
/// Spotlight, the workspace and the views.
final class FileSearchFeature: Feature {
    let id = FileSearchSource.feature

    /// Made with the source and kept, so that what it has learned about Spotlight being on
    /// or off outlives a screen.
    private var search: FileSearch?

    func makeSources(_ env: FeatureEnvironment) -> [any SearchSource] {
        let folderWalk = FolderWalk()
        search = FileSearch(
            spotlight: SpotlightSearcher(),
            walk: { text, folders, limit in
                await folderWalk.hits(matching: text, in: folders, limit: limit)
            },
            preferences: env.preferencesStore, usage: env.usage)
        return [FileSearchSource()]
    }

    func settingsPane(_ env: FeatureEnvironment) -> SettingsPane? {
        SettingsPane(
            id: SettingsPane.fileSearchID, title: "File Search",
            systemImage: "doc.text.magnifyingglass", order: 60,
            makeView: { AnyView(FileSearchSettingsView(preferences: env.preferences)) })
    }

    func makeScreen(
        _ request: ScreenRequest, context: any ScreenContext, env: FeatureEnvironment
    ) -> ScreenSpec? {
        switch request.screen {
        case FileSearchSource.searchScreen:
            return makeSearchScreen(context: context, env: env)
        case FileSearchSource.openWithScreen:
            return makeOpenWithScreen(request, context: context, env: env)
        default:
            return nil
        }
    }

    private func makeSearchScreen(
        context: any ScreenContext, env: FeatureEnvironment
    ) -> ScreenSpec? {
        guard let search else { return nil }

        let model = FileSearchModel(
            search: { text in await search.search(text) }, context: context, host: env.workspace)
        // The detail view exists only while a row is selected, so the spec holds the model.
        return ScreenSpec(
            title: String(localized: "Search Files"),
            searchBar: .filter(placeholder: String(localized: "Search files by name…")),
            body: .list(detail: { selection in
                AnyView(FileDetailView(model: model, selection: selection))
            }),
            model: model)
    }

    private func makeOpenWithScreen(
        _ request: ScreenRequest, context: any ScreenContext, env: FeatureEnvironment
    ) -> ScreenSpec? {
        guard let filePath = request.argument else { return nil }

        let model = OpenWithModel(filePath: filePath, host: env.workspace, context: context)
        // A list without a detail view has no view at all to hold its model.
        return ScreenSpec(
            title: String(localized: "Open With"),
            searchBar: .filter(placeholder: String(localized: "Filter apps…")),
            body: .list(detail: nil), model: model)
    }
}
