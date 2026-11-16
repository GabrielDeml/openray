import OpenRayCore
import SwiftUI

/// Script commands (docs/DESIGN.md §4.10): the scripts and their five commands in search, the
/// screens for a script's arguments, for its output and for the files that are no scripts,
/// and the Scripts pane of Settings. What a script is, how it runs and what every action does
/// are Core's; this hands them the runner, the folder watcher, the workspace and the views.
final class ScriptsFeature: Feature {
    let id = ScriptSource.feature

    /// Made with the source and kept for the screens and the pane. The runs are kept while
    /// the app runs, so that Show Last Script Output finds the last one.
    private var source: ScriptSource?
    private var runs: ScriptRuns?
    /// The pane's model. "Add Script Folder…" in the launcher asks for a folder through it.
    private var settings: ScriptsSettingsModel?

    func makeSources(_ env: FeatureEnvironment) -> [any SearchSource] {
        let runner = PosixScriptRunner()
        // Nothing starts the shell here. It is asked when the first script runs.
        let environment = ShellEnvironment(runner: runner)
        let runs = ScriptRuns(runner: runner, environment: environment)
        let defaultFolder = AppPaths().scriptsDirectory

        let settings = ScriptsSettingsModel(
            defaultFolder: defaultFolder, preferences: env.preferences, environment: environment)
        let showSettings = env.showSettings
        let source = ScriptSource(
            defaultFolder: defaultFolder, preferences: env.preferencesStore,
            watcher: FSEventsScriptFolderWatcher(), runs: runs, environment: environment,
            host: env.workspace
        ) {
            settings.requestFolderPicker()
            showSettings(SettingsPane.scriptsID)
        }

        self.source = source
        self.runs = runs
        self.settings = settings
        return [source]
    }

    func settingsPane(_ env: FeatureEnvironment) -> SettingsPane? {
        // The sources are made before the panes, so the model is there.
        guard let settings else { return nil }
        return SettingsPane(
            id: SettingsPane.scriptsID, title: "Scripts", systemImage: "terminal", order: 80,
            makeView: { AnyView(ScriptsSettingsView(model: settings)) })
    }

    /// FSEvents reports nothing for the time the Mac was asleep.
    func systemDidWake() {
        source?.rescan()
    }

    func makeScreen(
        _ request: ScreenRequest, context: any ScreenContext, env: FeatureEnvironment
    ) -> ScreenSpec? {
        guard let source, let runs else { return nil }

        switch request.screen {
        case ScriptSource.argumentsScreen:
            return makeArgumentsScreen(request, context: context, source: source, runs: runs)
        case ScriptSource.outputScreen:
            return makeOutputScreen(
                request, context: context, source: source, runs: runs, env: env)
        case ScriptSource.diagnosticsScreen:
            let model = ScriptDiagnosticsModel(
                diagnostics: source.diagnostics, host: env.workspace, context: context)
            // The detail view exists only while a row is selected, so the spec holds the
            // model.
            return ScreenSpec(
                title: String(localized: "Script Diagnostics"),
                searchBar: .filter(placeholder: String(localized: "Filter problems…")),
                body: .list(detail: { selection in
                    let diagnostic = model.diagnostic(for: selection)
                    return AnyView(ScriptDiagnosticDetailView(diagnostic: diagnostic))
                }),
                model: model)
        default:
            return nil
        }
    }

    private func makeArgumentsScreen(
        _ request: ScreenRequest, context: any ScreenContext, source: ScriptSource,
        runs: ScriptRuns
    ) -> ScreenSpec? {
        // The request names the script by its path. A file that was removed or changed
        // while the launcher was open may no longer be a script that asks for arguments.
        guard let path = request.argument, let script = source.script(atPath: path),
            script.isExecutable, !script.metadata.arguments.isEmpty
        else { return nil }

        let model = ScriptArgumentModel(script: script, runs: runs, context: context)
        return .custom(
            title: script.metadata.title, searchBar: model.searchBarMode,
            view: ScriptArgumentView(model: model))
    }

    private func makeOutputScreen(
        _ request: ScreenRequest, context: any ScreenContext, source: ScriptSource,
        runs: ScriptRuns, env: FeatureEnvironment
    ) -> ScreenSpec? {
        let model: ScriptOutputModel
        if request.argument == nil {
            // Show Last Script Output.
            model = ScriptOutputModel(runs: runs, host: env.workspace, context: context)
        } else {
            // The model starts the script, so everything is looked at before it is made:
            // the script has to be there still, and to take the arguments it is handed.
            guard let runRequest = ScriptSource.runRequest(in: request),
                let script = source.script(atPath: runRequest.path), script.isExecutable,
                runRequest.arguments.count == script.metadata.arguments.count
            else { return nil }

            model = ScriptOutputModel(
                runs: runs, host: env.workspace, context: context, starting: script,
                arguments: runRequest.arguments)
        }

        let title = model.run?.script.metadata.title ?? String(localized: "Script Output")
        return ScreenSpec(
            title: title, searchBar: .hidden,
            body: .custom(AnyView(ScriptOutputView(model: model)), handleIntent: model.handleIntent)
        )
    }
}

/// The selected problem beside the list of "Script Diagnostics": the file or folder, where
/// it lies, and the whole sentence about it. A row has one line for that sentence, and the
/// longer ones say what to do only at their end. Nothing here can be selected; the keyboard
/// stays with the search field.
private struct ScriptDiagnosticDetailView: View {
    /// nil for a selection that is none of the list's rows.
    let diagnostic: ScriptDiagnostic?

    var body: some View {
        ScrollView {
            if let diagnostic {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: diagnostic.name)
                        .font(.system(size: 15, weight: .semibold))
                    Text(verbatim: (diagnostic.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Divider()
                    Text(verbatim: diagnostic.message)
                        .font(.system(size: 13))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }
}
