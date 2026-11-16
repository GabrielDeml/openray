import Foundation
import Testing

import OpenRayCore

// The folders are made in the test's own folder under the temporary directory. The shell
// environment has no shell to ask, or a fake one that answers from the test. The suite is a
// class so that `deinit` can remove the folder whichever way the test ends.
@MainActor @Suite(.timeLimit(.minutes(1))) final class ScriptsSettingsModelTests {
    private let directoryPath: String
    private let preferences = Preferences(store: InMemoryPreferencesStore())
    /// The home folder the protected places are looked for in. Nothing is read there.
    private let home = "/Users/ada"

    init() throws {
        directoryPath = NSTemporaryDirectory() + "OpenRayTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: path("Scripts"), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: directoryPath)
    }

    private func path(_ relativePath: String) -> String {
        "\(directoryPath)/\(relativePath)"
    }

    private func makeModel(
        environment: ShellEnvironment = makeShellEnvironmentWithoutShell()
    ) -> ScriptsSettingsModel {
        ScriptsSettingsModel(
            defaultFolder: URL(filePath: path("Scripts"), directoryHint: .isDirectory),
            preferences: preferences, environment: environment,
            homeFolder: URL(filePath: home, directoryHint: .isDirectory))
    }

    /// A shell, played by a fake runner, that has two variables to print.
    private func makeEnvironmentWithFakeShell() -> (
        environment: ShellEnvironment, runner: FakeScriptRunner
    ) {
        makeShellEnvironmentWithFakeShell(
            printing: ["PATH=/opt/homebrew/bin:/usr/bin", "EDITOR=vim"])
    }

    // MARK: Folders

    @Test func defaultFolderIsFirstAndTheAddedOnesFollow() {
        preferences.scriptFolders = [path("Extra"), path("More")]

        let folders = makeModel().folders

        #expect(folders.map(\.path) == [path("Scripts"), path("Extra"), path("More")])
        #expect(folders.map(\.isDefault) == [true, false, false])
    }

    @Test func addedFolderIsWrittenToThePreferenceWithoutItsSlash() {
        let model = makeModel()

        // As an open panel reports a folder.
        model.add(folder: URL(filePath: path("Extra"), directoryHint: .isDirectory))

        #expect(preferences.scriptFolders == [path("Extra")])
        #expect(model.folders.map(\.path) == [path("Scripts"), path("Extra")])
    }

    @Test func folderThatIsInTheListAlreadyIsNotAddedAgain() {
        preferences.scriptFolders = [path("Extra") + "/"]
        let model = makeModel()

        model.add(folder: URL(filePath: path("Extra")))
        model.add(folder: URL(filePath: path("Scripts"), directoryHint: .isDirectory))

        #expect(preferences.scriptFolders == [path("Extra") + "/"])
        #expect(model.folders.count == 2)
    }

    @Test func removingAFolderTakesItOutOfThePreference() throws {
        // One of them with a slash at its end, as a path written into the preference by hand
        // may have.
        preferences.scriptFolders = [path("Extra") + "/", path("More")]
        let model = makeModel()
        let extra = try #require(model.folders.first { $0.path == path("Extra") })

        model.remove(extra)

        #expect(preferences.scriptFolders == [path("More")])
        #expect(model.folders.map(\.path) == [path("Scripts"), path("More")])
    }

    @Test func defaultFolderCannotBeRemoved() throws {
        preferences.scriptFolders = [path("Extra")]
        let model = makeModel()
        let defaultFolder = try #require(model.folders.first)

        model.remove(defaultFolder)

        #expect(model.folders.count == 2)
        #expect(preferences.scriptFolders == [path("Extra")])
    }

    @Test func folderInAPlaceMacOSAsksAboutIsMarked() {
        preferences.scriptFolders = [
            "\(home)/Desktop/Scripts", "\(home)/Documents", "\(home)/Downloads/tools/bin",
            "\(home)/Library/Mobile Documents/com~apple~CloudDocs/Scripts", "\(home)/Code/scripts",
        ]

        let folders = makeModel().folders

        #expect(
            folders.map(\.protectedLocation) == [
                nil, .desktop, .documents, .downloads, .iCloudDrive, nil,
            ])
    }

    @Test func refreshSaysWhatIsWrongWithAFolder() async throws {
        try FileManager.default.createDirectory(
            atPath: path("Open"), withIntermediateDirectories: true)
        try #require(chmod(path("Open"), 0o777) == 0)
        try Data().write(to: URL(filePath: path("a-file")))
        preferences.scriptFolders = [path("Open"), path("Missing"), path("a-file")]
        let model = makeModel()
        // Nothing is known before the folders were looked at.
        #expect(model.folders.map(\.problem) == [nil, nil, nil, nil])

        await model.refresh()

        let problems = model.folders.map(\.problem)
        #expect(problems[0] == nil)
        #expect(
            problems[1]
                == "Every user of this Mac can change the folder “Open”, so OpenRay runs no script in it. To fix that, run chmod o-w on the folder."
        )
        #expect(problems[2] == "This folder does not exist.")
        // A file is no folder to read scripts from.
        #expect(problems[3] == "This folder does not exist.")

        // The folder is put right, and the next look finds it so.
        try #require(chmod(path("Open"), 0o755) == 0)
        await model.refresh()
        #expect(model.folders[1].problem == nil)
    }

    // MARK: Asking for a folder

    @Test func folderPickerIsAskedForThroughTheModel() {
        let model = makeModel()
        #expect(!model.isChoosingFolder)

        model.requestFolderPicker()
        #expect(model.isChoosingFolder)
    }

    // MARK: The shell environment

    @Test func environmentThatWasNotReadYetIsSaidToBeSoAndIsNotReadByThePane() async {
        let (environment, runner) = makeEnvironmentWithFakeShell()
        let model = makeModel(environment: environment)
        let notReadYet = "Not read yet. OpenRay asks your shell before it runs the first script."
        #expect(model.environmentStatus == notReadYet)

        await model.refresh()

        // The pane appearing never starts the shell.
        #expect(model.environmentStatus == notReadYet)
        #expect(runner.invocations.isEmpty)
    }

    @Test func environmentOfTheShellIsNamedWithItsSize() async {
        let (environment, _) = makeEnvironmentWithFakeShell()
        // As the first script of the session reads it.
        _ = await environment.current()
        let model = makeModel(environment: environment)

        await model.refresh()

        #expect(
            model.environmentStatus == "Scripts run with the environment of zsh: 2 variables.")
    }

    @Test func environmentThatTheShellDidNotGiveIsSaidToBeOpenRaysOwn() async {
        let environment = makeShellEnvironmentWithoutShell()
        _ = await environment.current()
        let model = makeModel(environment: environment)

        await model.refresh()

        #expect(
            model.environmentStatus
                == "shell did not report its environment. Scripts run with the one OpenRay was started with."
        )
    }

    @Test func reloadAsksTheShellOnceAndShowsWhatCame() async {
        let (environment, runner) = makeEnvironmentWithFakeShell()
        let model = makeModel(environment: environment)

        await model.reloadEnvironment()

        #expect(runner.invocations.count == 1)
        #expect(
            model.environmentStatus == "Scripts run with the environment of zsh: 2 variables.")
        #expect(!model.isReloadingEnvironment)

        // What was read stays known to the pane when it appears again.
        await model.refresh()
        #expect(runner.invocations.count == 1)
        #expect(
            model.environmentStatus == "Scripts run with the environment of zsh: 2 variables.")
    }
}
