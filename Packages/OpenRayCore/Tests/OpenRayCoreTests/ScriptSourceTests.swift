import Foundation
import Testing

@testable import OpenRayCore

/// Counts how often "Add Script Folder…" asked for Settings.
@MainActor private final class FolderSettingsOpener {
    private(set) var openCount = 0

    func open() {
        openCount += 1
    }
}

// Every test writes its scripts into its own folder under the temporary directory, and none
// of them is ever run: the source talks to a fake runner, a fake watcher that the test fires
// by hand, and a shell environment that has no shell to ask. The suite is a class so that
// `deinit` can remove the folder whichever way the test ends.
@MainActor @Suite(.timeLimit(.minutes(1))) final class ScriptSourceTests {
    private let directoryPath: String
    private let preferences = InMemoryPreferencesStore()
    private let watcher = FakeScriptFolderWatcher()
    private let host = FakeScriptActionHost()
    private let environment = makeShellEnvironmentWithoutShell()
    private let folderSettings = FolderSettingsOpener()
    private let context = FakeActionContext()

    init() throws {
        directoryPath = NSTemporaryDirectory() + "OpenRayTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directoryPath, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: directoryPath)
    }

    // MARK: Fixtures

    private func path(_ relativePath: String) -> String {
        "\(directoryPath)/\(relativePath)"
    }

    /// The default Scripts folder of these tests. The source makes it when it is missing.
    private var scriptsFolder: String {
        path("Scripts")
    }

    private func makeSource(runner: FakeScriptRunner = FakeScriptRunner()) -> ScriptSource {
        let folderSettings = folderSettings
        return ScriptSource(
            defaultFolder: URL(filePath: scriptsFolder, directoryHint: .isDirectory),
            preferences: preferences, watcher: watcher,
            runs: ScriptRuns(runner: runner, environment: environment, appVersion: "9.8.7"),
            environment: environment, host: host,
            showFolderSettings: { folderSettings.open() })
    }

    /// Writes a script file with these `@openray.` lines under its `#!` line.
    ///
    /// - Parameter relativePath: From the test's folder, such as `Scripts/wifi.sh`.
    @discardableResult
    private func writeScriptFile(
        _ relativePath: String, title: String, mode: String = "silent", lines: [String] = [],
        permissions: mode_t = 0o755
    ) throws -> String {
        let filePath = path(relativePath)
        try FileManager.default.createDirectory(
            atPath: (filePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)

        var text = "#!/bin/sh\n"
        text += "# @openray.schemaVersion 1\n"
        text += "# @openray.title \(title)\n"
        text += "# @openray.mode \(mode)\n"
        for line in lines {
            text += "# @openray.\(line)\n"
        }
        text += "echo done\n"
        try writeScript(text, to: filePath, permissions: permissions)
        return filePath
    }

    /// A script as a scan would report it, for the tests that only look at its item.
    private func makeScript(
        at relativePath: String = "Scripts/wifi.sh", title: String = "Toggle Wi-Fi",
        mode: ScriptMode = .silent, arguments: [ScriptArgument] = [],
        needsConfirmation: Bool = false, isExecutable: Bool = true
    ) -> ScriptCommand {
        ScriptCommand(
            path: path(relativePath), folder: scriptsFolder,
            metadata: ScriptMetadata(
                title: title, mode: mode, arguments: arguments,
                needsConfirmation: needsConfirmation),
            isExecutable: isExecutable)
    }

    private func ids(of items: [SearchItem]) -> [String] {
        var ids: [String] = []
        for item in items {
            ids.append(item.id.rawValue)
        }
        return ids
    }

    /// The titles of the scripts in a list, which come after the commands.
    private func scriptTitles(in items: [SearchItem]) -> [String] {
        var titles: [String] = []
        for item in items where item.id.namespace == .script {
            titles.append(item.title)
        }
        return titles
    }

    private func action(_ id: String, of item: SearchItem) throws -> ActionDescriptor {
        try #require(item.actions.first { $0.id.rawValue == id })
    }

    private func command(_ name: String, of source: ScriptSource) async throws -> SearchItem {
        var iterator = source.indexedItems().makeAsyncIterator()
        let commands = try #require(await iterator.next())
        return try #require(commands.first { $0.id.rawValue == "command:scripts.\(name)" })
    }

    private let commandIDs = [
        "command:scripts.openFolder", "command:scripts.addFolder",
        "command:scripts.reloadEnvironment", "command:scripts.lastOutput",
        "command:scripts.diagnostics",
    ]

    // MARK: The stream

    @Test func commandsAreYieldedAloneBeforeAnyFolderIsRead() async throws {
        try writeScriptFile("Scripts/wifi.sh", title: "Toggle Wi-Fi")
        var iterator = makeSource().indexedItems().makeAsyncIterator()

        let first = try #require(await iterator.next())
        #expect(ids(of: first) == commandIDs)
        #expect(
            first.map(\.title) == [
                "Open Scripts Folder", "Add Script Folder…", "Reload Shell Environment",
                "Show Last Script Output", "Script Diagnostics",
            ])
        for command in first {
            #expect(command.kindLabel == "Command")
        }

        let second = try #require(await iterator.next())
        #expect(ids(of: second) == commandIDs + ["script:\(path("Scripts/wifi.sh"))"])
    }

    @Test func scriptsOfTheFolderAndOfItsSubfoldersBecomeItems() async throws {
        try writeScriptFile(
            "Scripts/wifi.sh", title: "Toggle Wi-Fi",
            lines: ["description Turns Wi-Fi on or off", "keywords network hotspot", "icon 📶"])
        try writeScriptFile("Scripts/Work/vpn.sh", title: "Connect VPN", mode: "fullOutput")
        var iterator = makeSource().indexedItems().makeAsyncIterator()
        _ = await iterator.next()

        let items = try #require(await iterator.next())
        let scripts = items.filter { $0.id.namespace == .script }
        #expect(scripts.count == 2)

        // In name order, where capital letters come first: "Work" before "wifi.sh".
        let wifi = try #require(scripts.last)
        #expect(wifi.id == .script(path: path("Scripts/wifi.sh")))
        #expect(wifi.title == "Toggle Wi-Fi")
        #expect(wifi.subtitle == "Turns Wi-Fi on or off")
        #expect(wifi.alternateNames == [.keyword("network"), .keyword("hotspot")])
        #expect(wifi.icon == .emoji("📶"))
        #expect(wifi.kindLabel == "Script")
        #expect(wifi.accessories.isEmpty)
        #expect(wifi.tabTarget == nil)

        let vpn = try #require(scripts.first)
        #expect(vpn.id == .script(path: path("Scripts/Work/vpn.sh")))
        #expect(vpn.subtitle == nil)
        #expect(vpn.accessories == ["Work"])
        #expect(vpn.icon == .symbol("terminal"))
    }

    @Test func defaultFolderIsMadeForTheUserAloneWhenItIsMissing() async throws {
        #expect(!FileManager.default.fileExists(atPath: scriptsFolder))
        var iterator = makeSource().indexedItems().makeAsyncIterator()
        _ = await iterator.next()

        // The scan comes after the folder was made, and finds nothing wrong with it.
        let afterScan = try #require(await iterator.next())
        #expect(ids(of: afterScan) == commandIDs)

        let status = try #require(ScriptFileStatus(ofItemAt: scriptsFolder))
        #expect(status.kind == .folder)
        #expect(status.permissions == 0o700)
    }

    @Test func foldersAreWatchedBeforeTheyAreRead() async throws {
        try writeScriptFile("Scripts/wifi.sh", title: "Toggle Wi-Fi")
        var iterator = makeSource().indexedItems().makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()

        #expect(watcher.watchedFolders == [[scriptsFolder]])
        #expect(watcher.stopCount == 0)
    }

    @Test func changeTheWatcherReportsIsFollowed() async throws {
        try writeScriptFile("Scripts/wifi.sh", title: "Toggle Wi-Fi")
        let source = makeSource()
        var iterator = source.indexedItems().makeAsyncIterator()
        _ = await iterator.next()
        let atLaunch = try #require(await iterator.next())
        #expect(scriptTitles(in: atLaunch) == ["Toggle Wi-Fi"])

        // A file is added.
        try writeScriptFile("Scripts/bluetooth.sh", title: "Toggle Bluetooth")
        watcher.fire()
        let withBluetooth = try #require(await iterator.next())
        #expect(scriptTitles(in: withBluetooth) == ["Toggle Bluetooth", "Toggle Wi-Fi"])
        #expect(source.script(atPath: path("Scripts/bluetooth.sh"))?.metadata.title != nil)

        // Its title is changed.
        try writeScriptFile("Scripts/bluetooth.sh", title: "Bluetooth On or Off")
        watcher.fire()
        let renamed = try #require(await iterator.next())
        #expect(scriptTitles(in: renamed) == ["Bluetooth On or Off", "Toggle Wi-Fi"])

        // The other file is removed.
        try FileManager.default.removeItem(atPath: path("Scripts/wifi.sh"))
        watcher.fire()
        let withoutWifi = try #require(await iterator.next())
        #expect(scriptTitles(in: withoutWifi) == ["Bluetooth On or Off"])
        #expect(source.script(atPath: path("Scripts/wifi.sh")) == nil)

        // The watching went on through all of it.
        #expect(watcher.watchedFolders.count == 1)
    }

    // FSEvents reports everything below a script folder: an editor's swap file, a `.git`
    // folder, a log a script writes beside itself. Most reports change no script.
    @Test func reportThatChangesNoScriptYieldsNoNewList() async throws {
        try writeScriptFile("Scripts/wifi.sh", title: "Toggle Wi-Fi")
        try writeScriptFile("Extra/backup.sh", title: "Back Up")
        var iterator = makeSource().indexedItems().makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()

        // A file that is no script, and a report about nothing at all.
        try writeScript("#!/bin/sh\necho helper\n", to: path("Scripts/helper.sh"))
        watcher.fire()
        watcher.fire()
        // The requests are answered in order, and the two reports are scanned with the
        // folders as they were. Had either yielded a list, it would come next and would be
        // without the script of the folder that is added only now.
        preferences.set([path("Extra")], for: .scriptFolders)

        let next = try #require(await iterator.next())
        #expect(scriptTitles(in: next) == ["Toggle Wi-Fi", "Back Up"])
    }

    @Test func addingAndRemovingAFolderIsFollowedWithoutARestart() async throws {
        try writeScriptFile("Scripts/wifi.sh", title: "Toggle Wi-Fi")
        try writeScriptFile("Extra/backup.sh", title: "Back Up")
        var iterator = makeSource().indexedItems().makeAsyncIterator()
        _ = await iterator.next()
        let atLaunch = try #require(await iterator.next())
        #expect(scriptTitles(in: atLaunch) == ["Toggle Wi-Fi"])

        // With a slash at the end, as an open panel reports a folder.
        preferences.set([path("Extra") + "/"], for: .scriptFolders)
        let withFolder = try #require(await iterator.next())
        #expect(scriptTitles(in: withFolder) == ["Toggle Wi-Fi", "Back Up"])

        preferences.set([], for: .scriptFolders)
        let withoutFolder = try #require(await iterator.next())
        #expect(scriptTitles(in: withoutFolder) == ["Toggle Wi-Fi"])

        // Each list of folders got a watching of its own.
        #expect(
            watcher.watchedFolders == [
                [scriptsFolder], [scriptsFolder, path("Extra")], [scriptsFolder],
            ])
        #expect(watcher.stopCount == 2)
    }

    @Test func rescanReadsTheFoldersAgainAndWatchesThemAfresh() async throws {
        let source = makeSource()
        var iterator = source.indexedItems().makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()

        // This folder did not exist when the watching began, so nothing reports it.
        preferences.set([path("Later")], for: .scriptFolders)
        _ = await iterator.next()
        try writeScriptFile("Later/backup.sh", title: "Back Up")
        source.rescan()

        let afterRescan = try #require(await iterator.next())
        #expect(scriptTitles(in: afterRescan) == ["Back Up"])
        #expect(watcher.watchedFolders.count == 3)
        #expect(watcher.stopCount == 2)
    }

    // The registry takes the stream once. A source must not depend on that: the queue of
    // rescan requests ends with the stream it belongs to, and the next stream needs its own.
    @Test func streamTakenAfterAnEarlierOneHasEndedFollowsChangesToo() async throws {
        let source = makeSource()
        do {
            var earlier = source.indexedItems().makeAsyncIterator()
            _ = await earlier.next()
        }

        var iterator = source.indexedItems().makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        try writeScriptFile("Scripts/wifi.sh", title: "Toggle Wi-Fi")
        watcher.fire()

        let afterChange = try #require(await iterator.next())
        #expect(scriptTitles(in: afterChange) == ["Toggle Wi-Fi"])
    }

    @Test func fileThatIsRefusedOrBrokenIsADiagnosticAndNoItem() async throws {
        try writeScriptFile("Scripts/good.sh", title: "Good")
        try writeScriptFile("Scripts/open-to-all.sh", title: "Open to All", permissions: 0o757)
        try writeScriptFile("Scripts/broken.sh", title: "Broken", mode: "loud")
        // A helper without `@openray.` lines is neither.
        try writeScript("#!/bin/sh\necho helper\n", to: path("Scripts/helper.sh"))
        let source = makeSource()
        var iterator = source.indexedItems().makeAsyncIterator()
        _ = await iterator.next()

        let items = try #require(await iterator.next())
        #expect(scriptTitles(in: items) == ["Good"])

        #expect(
            source.diagnostics == [
                ScriptDiagnostic(
                    path: path("Scripts/broken.sh"), problem: .parse(.invalidValue(key: "mode"))),
                ScriptDiagnostic(
                    path: path("Scripts/open-to-all.sh"),
                    problem: .security(
                        .worldWritable(path: path("Scripts/open-to-all.sh"), isFolder: false))),
            ])
        #expect(source.script(atPath: path("Scripts/broken.sh")) == nil)
    }

    // The security rule of §4.10 that matters most: reading, watching, rescanning and
    // looking a script up never start a process, and never ask the shell either.
    @Test func nothingRunsWithoutAnAction() async throws {
        try writeScriptFile("Scripts/wifi.sh", title: "Toggle Wi-Fi")
        try writeScriptFile(
            "Scripts/build.sh", title: "Build", mode: "fullOutput",
            lines: ["argument1 {\"placeholder\":\"Target\"}"])
        try writeScriptFile("Scripts/later.sh", title: "Later", permissions: 0o644)
        let runner = FakeScriptRunner()
        let source = makeSource(runner: runner)
        var iterator = source.indexedItems().makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()

        // Neither of these finds anything new, so neither yields a list. They are answered
        // before the change of the folders, which does.
        watcher.fire()
        source.rescan()
        preferences.set([path("Extra")], for: .scriptFolders)
        let items = try #require(await iterator.next())
        #expect(scriptTitles(in: items) == ["Build", "Later", "Toggle Wi-Fi"])
        _ = source.script(atPath: path("Scripts/wifi.sh"))
        _ = source.diagnostics

        #expect(runner.invocations.isEmpty)
        #expect(await environment.cached == nil)
    }

    // MARK: Icons

    @Test func iconIsTheOneTheScriptNames() {
        var script = makeScript()
        #expect(ScriptSource.icon(of: script) == .symbol("terminal"))

        script.metadata.icon = .emoji("📶")
        #expect(ScriptSource.icon(of: script) == .emoji("📶"))

        script.metadata.icon = .symbol("wifi")
        #expect(ScriptSource.icon(of: script) == .symbol("wifi"))
    }

    @Test func imageIsLookedForBesideTheScript() {
        var script = makeScript(at: "Scripts/Network/wifi.sh")

        script.metadata.icon = .image(relativePath: "wifi.png")
        #expect(ScriptSource.icon(of: script) == .image(path: path("Scripts/Network/wifi.png")))

        script.metadata.icon = .image(relativePath: "icons/wifi.png")
        #expect(
            ScriptSource.icon(of: script) == .image(path: path("Scripts/Network/icons/wifi.png")))
    }

    @Test(arguments: ["/etc/hosts.png", "../wifi.png", "icons/../../wifi.png", "..", "/"])
    func imageOutsideTheScriptsFolderIsRefused(_ relativePath: String) {
        var script = makeScript()
        script.metadata.icon = .image(relativePath: relativePath)

        #expect(ScriptSource.icon(of: script) == .symbol("terminal"))
    }

    // MARK: Running

    @Test func silentScriptClosesTheLauncherRunsAndShowsItsLastLine() async throws {
        let runner = FakeScriptRunner([.open])
        let script = makeScript()
        let item = makeSource(runner: runner).item(for: script)
        #expect(
            item.actions.map(\.id.rawValue) == [
                "run", "open-in-editor", "show-in-finder", "copy-path",
            ])
        let run = try #require(item.actions.first)
        #expect(run.title == "Run")
        #expect(run.confirmation == nil)

        let context = context
        let performing = Task { () -> ActionOutcome in
            try await run.perform(context)
        }
        for await _ in runner.starts { break }

        // The launcher went before the script started, and nobody was asked anything.
        #expect(context.calls == [.closeLauncher])
        #expect(context.confirmations.isEmpty)
        #expect(runner.invocations.count == 1)
        #expect(runner.invocations.first?.executable.path(percentEncoded: false) == script.path)
        #expect(runner.invocations.first?.arguments == [])

        runner.send(.stdout("Scanning…\nWi-Fi is off\n"))
        runner.send(.exited(0))
        runner.finish()

        let outcome = try await performing.value
        #expect(outcome == .showHUD("Wi-Fi is off"))
        #expect(context.closeLauncherCount == 1)
    }

    @Test func silentScriptThatFailsOrTimesOutSaysSoInTheHUD() async throws {
        let runner = FakeScriptRunner([
            FakeScriptRunner.Run(events: [.stdout("half done\n"), .exited(2)]),
            FakeScriptRunner.Run(events: [.timedOut]),
            FakeScriptRunner.Run(error: ScriptRunError.cannotStart(file: "wifi.sh", code: EACCES)),
        ])
        let run = try #require(makeSource(runner: runner).item(for: makeScript()).actions.first)

        #expect(try await run.perform(context) == .showHUD("Script failed"))
        #expect(try await run.perform(context) == .showHUD("Script timed out"))
        // A file that was removed or changed between the scan and Return.
        #expect(
            try await run.perform(context)
                == .showHUD("“wifi.sh” could not be started: Permission denied"))
    }

    // Esc cancels an action that is under way (§4.1.4), and looking at the files can take
    // a while on a network volume.
    @Test func runThatWasCancelledWhileTheFilesWereLookedAtStartsNothing() async throws {
        let runner = FakeScriptRunner([.printing("never")])
        let run = try #require(makeSource(runner: runner).item(for: makeScript()).actions.first)

        let context = context
        let performing = Task { () -> ActionOutcome in
            try await run.perform(context)
        }
        // Before the task has got anywhere: it runs on the main actor, as this test does.
        performing.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await performing.value
        }
        #expect(context.calls.isEmpty)
        #expect(runner.invocations.isEmpty)
    }

    @Test func scriptThatOthersCanChangeIsRefusedWithTheLauncherStillOpen() async throws {
        let filePath = try writeScriptFile(
            "Scripts/wifi.sh", title: "Toggle Wi-Fi", permissions: 0o757)
        let runner = FakeScriptRunner([.printing("never")])
        let run = try #require(makeSource(runner: runner).item(for: makeScript()).actions.first)

        await #expect(
            throws: ScriptSecurityProblem.worldWritable(path: filePath, isFolder: false)
        ) {
            _ = try await run.perform(self.context)
        }

        #expect(context.calls.isEmpty)
        #expect(runner.invocations.isEmpty)
    }

    @Test func downloadedScriptIsAskedAboutBeforeAnythingElse() async throws {
        let filePath = try writeScriptFile("Scripts/wifi.sh", title: "Toggle Wi-Fi")
        try markAsDownloaded(filePath)
        let runner = FakeScriptRunner([.printing("Wi-Fi is off\n")])
        let run = try #require(makeSource(runner: runner).item(for: makeScript()).actions.first)

        context.confirmationAnswer = false
        #expect(try await run.perform(context) == .keepOpen)
        #expect(context.confirmations.map(\.title) == ["Run “Toggle Wi-Fi”?"])
        #expect(context.calls.isEmpty)
        #expect(runner.invocations.isEmpty)

        context.confirmationAnswer = true
        #expect(try await run.perform(context) == .showHUD("Wi-Fi is off"))
        #expect(context.calls == [.closeLauncher])
        #expect(runner.invocations.count == 1)
        #expect(!ScriptSecurity.isQuarantined(filePath))
    }

    @Test func scriptThatShowsItsOutputPushesTheOutputScreenAndStartsNothingItself() async throws {
        let runner = FakeScriptRunner([.printing("never")])
        let script = makeScript(mode: .fullOutput)
        let run = try #require(makeSource(runner: runner).item(for: script).actions.first)

        let outcome = try await run.perform(context)

        let request = ScriptSource.outputScreenRequest(running: script, arguments: [])
        #expect(outcome == .push(request))
        #expect(request.feature == ScriptSource.feature)
        #expect(request.screen == "output")
        #expect(
            ScriptSource.runRequest(in: request)
                == ScriptRunRequest(path: script.path, arguments: []))
        // The screen starts the script, and the launcher stays for it.
        #expect(context.calls.isEmpty)
        #expect(runner.invocations.isEmpty)
    }

    @Test func outputRequestCarriesTheArgumentsAsTheyWereTyped() {
        let script = makeScript(mode: .fullOutput)
        let arguments = ["two words", "", "quote \" and \\ and 📶"]

        let request = ScriptSource.outputScreenRequest(running: script, arguments: arguments)

        #expect(
            ScriptSource.runRequest(in: request)
                == ScriptRunRequest(path: script.path, arguments: arguments))
        #expect(request == ScriptSource.outputScreenRequest(running: script, arguments: arguments))
    }

    @Test func requestForTheLastOutputNamesNoRun() {
        let request = ScriptSource.lastOutputScreenRequest

        #expect(request == ScreenRequest(feature: ScriptSource.feature, screen: "output"))
        #expect(ScriptSource.runRequest(in: request) == nil)

        var unreadable = request
        unreadable.argument = "not JSON"
        #expect(ScriptSource.runRequest(in: unreadable) == nil)
    }

    @Test func scriptWithArgumentsLeadsToTheArgumentScreenOnReturnAndOnTab() async throws {
        let runner = FakeScriptRunner([.printing("never")])
        let script = makeScript(
            arguments: [ScriptArgument(placeholder: "SSID", isOptional: false)],
            needsConfirmation: true)
        let item = makeSource(runner: runner).item(for: script)
        let run = try #require(item.actions.first)

        let outcome = try await run.perform(context)

        let request = ScreenRequest(
            feature: ScriptSource.feature, screen: "arguments", argument: script.path)
        #expect(outcome == .push(request))
        #expect(item.tabTarget == request)
        #expect(run.id.rawValue == "run")
        // The question comes at the last argument, not before the first.
        #expect(run.confirmation == nil)
        #expect(context.calls.isEmpty)
        #expect(runner.invocations.isEmpty)
    }

    @Test func scriptThatWantsToBeConfirmedAsksBeforeItRuns() throws {
        let script = makeScript(needsConfirmation: true)

        let run = try #require(makeSource().item(for: script).actions.first)

        #expect(
            run.confirmation
                == Confirmation(title: "Run “Toggle Wi-Fi”?", confirmTitle: "Run"))
    }

    // MARK: Make Executable

    @Test func scriptThatMayNotBeRunYetOffersToBeMadeExecutable() async throws {
        let filePath = try writeScriptFile(
            "Scripts/wifi.sh", title: "Toggle Wi-Fi",
            lines: ["argument1 {\"placeholder\":\"SSID\"}"], permissions: 0o640)
        let runner = FakeScriptRunner()
        let source = makeSource(runner: runner)
        var iterator = source.indexedItems().makeAsyncIterator()
        _ = await iterator.next()
        let items = try #require(await iterator.next())
        let item = try #require(items.last)

        #expect(item.id == .script(path: filePath))
        #expect(
            item.actions.map(\.id.rawValue) == [
                "make-executable", "open-in-editor", "show-in-finder", "copy-path",
            ])
        // Nothing to give arguments to yet.
        #expect(item.tabTarget == nil)
        let makeExecutable = try #require(item.actions.first)
        #expect(makeExecutable.title == "Make Executable")

        let outcome = try await makeExecutable.perform(context)

        #expect(outcome == .keepOpen)
        #expect(context.hudMessages == ["“wifi.sh” can be run now"])
        #expect(context.calls.isEmpty)
        // The owner's bit and no other.
        #expect(ScriptFileStatus(ofItemAt: filePath)?.permissions == 0o740)

        // The action asked for a rescan, which brings the item that can be run.
        let rescanned = try #require(await iterator.next())
        let runnable = try #require(rescanned.last)
        #expect(runnable.id == .script(path: filePath))
        #expect(runnable.actions.first?.id.rawValue == "run")
        #expect(runnable.tabTarget != nil)
        #expect(runner.invocations.isEmpty)
    }

    @Test func fileThatOthersCanChangeIsNotMadeExecutable() async throws {
        let filePath = try writeScriptFile(
            "Scripts/wifi.sh", title: "Toggle Wi-Fi", permissions: 0o646)
        let item = makeSource().item(for: makeScript(isExecutable: false))
        let makeExecutable = try action("make-executable", of: item)

        await #expect(
            throws: ScriptSecurityProblem.worldWritable(path: filePath, isFolder: false)
        ) {
            _ = try await makeExecutable.perform(self.context)
        }

        #expect(ScriptFileStatus(ofItemAt: filePath)?.permissions == 0o646)
        #expect(context.hudMessages.isEmpty)
    }

    // MARK: The file's actions

    @Test func openInEditorClosesTheLauncherAndHandsTheFileToTheHost() async throws {
        let script = makeScript()
        let openInEditor = try action("open-in-editor", of: makeSource().item(for: script))

        let outcome = try await openInEditor.perform(context)

        #expect(outcome == .closeLauncher)
        #expect(context.calls == [.closeLauncher])
        #expect(host.calls == [.openInEditor(URL(filePath: script.path))])
        #expect(openInEditor.title == "Open in Editor")
        #expect(
            openInEditor.shortcut
                == KeyChord(keyCode: VirtualKey.ansiO, modifiers: [.command], characters: "o"))
    }

    @Test func openInEditorThrowsWhenNoAppTakesTheFile() async throws {
        host.hasNoEditor = true
        let openInEditor = try action("open-in-editor", of: makeSource().item(for: makeScript()))

        await #expect(throws: FakeScriptActionHost.NoEditor.self) {
            _ = try await openInEditor.perform(self.context)
        }
    }

    @Test func showInFinderClosesTheLauncherAndRevealsTheFile() async throws {
        let script = makeScript()
        let showInFinder = try action("show-in-finder", of: makeSource().item(for: script))

        let outcome = try await showInFinder.perform(context)

        #expect(outcome == .closeLauncher)
        #expect(context.calls == [.closeLauncher])
        #expect(host.calls == [.showInFinder(URL(filePath: script.path))])
    }

    @Test func copyPathCopiesThePathTheScriptWasFoundUnder() async throws {
        let script = makeScript()
        let copyPath = try action("copy-path", of: makeSource().item(for: script))

        let outcome = try await copyPath.perform(context)

        #expect(outcome == .copiedToClipboard)
        #expect(context.copied == [.text(script.path, cursorOffsetFromEnd: nil)])
        #expect(host.calls.isEmpty)
    }

    // MARK: The commands

    @Test func openScriptsFolderClosesTheLauncherAndOpensTheDefaultFolder() async throws {
        let source = makeSource()
        let open = try #require(try await command("openFolder", of: source).actions.first)

        let outcome = try await open.perform(context)

        #expect(outcome == .closeLauncher)
        #expect(context.calls == [.closeLauncher])
        #expect(
            host.calls == [.openFolder(URL(filePath: scriptsFolder, directoryHint: .isDirectory))])
    }

    @Test func openScriptsFolderMakesAFolderThatWasRemovedAndHasItWatchedAgain() async throws {
        let source = makeSource()
        var iterator = source.indexedItems().makeAsyncIterator()
        let commands = try #require(await iterator.next())
        _ = await iterator.next()
        let open = try #require(commands.first?.actions.first)
        try FileManager.default.removeItem(atPath: scriptsFolder)

        _ = try await open.perform(context)

        #expect(FileManager.default.fileExists(atPath: scriptsFolder))
        // The new folder is as empty as the old one was, so the rescan yields no list that
        // could be waited for.
        let folderWatcher = watcher
        let isWatchedAgain = await holds(within: .seconds(30)) {
            folderWatcher.watchedFolders.count == 2
        }
        #expect(isWatchedAgain)
        #expect(watcher.watchedFolders == [[scriptsFolder], [scriptsFolder]])
    }

    @Test func addScriptFolderClosesTheLauncherAndAsksSettingsForAFolder() async throws {
        let add = try #require(try await command("addFolder", of: makeSource()).actions.first)

        let outcome = try await add.perform(context)

        #expect(outcome == .closeLauncher)
        #expect(context.calls == [.closeLauncher])
        #expect(folderSettings.openCount == 1)
        // The folder is chosen in Settings. Nothing is added here.
        #expect(preferences.value(for: .scriptFolders).isEmpty)
    }

    @Test func reloadShellEnvironmentAsksTheShellAndSaysHowItWent() async throws {
        let reload = try #require(
            try await command("reloadEnvironment", of: makeSource()).actions.first)
        #expect(await environment.cached == nil)

        let outcome = try await reload.perform(context)

        // The stand-in for the shell cannot be started, so the environment is the fallback.
        #expect(
            outcome
                == .showHUD(
                    "shell did not report its environment. Scripts run with the one OpenRay was started with."
                ))
        #expect(context.calls == [.closeLauncher])
        #expect(await environment.cached?.origin == .inherited)
    }

    @Test func showLastScriptOutputPushesTheOutputScreenWithoutARun() async throws {
        let item = try await command("lastOutput", of: makeSource())
        let show = try #require(item.actions.first)

        let outcome = try await show.perform(context)

        #expect(outcome == .push(ScriptSource.lastOutputScreenRequest))
        #expect(item.tabTarget == ScriptSource.lastOutputScreenRequest)
        #expect(context.calls.isEmpty)
    }

    @Test func scriptDiagnosticsPushesItsListOnReturnAndOnTab() async throws {
        let item = try await command("diagnostics", of: makeSource())
        let show = try #require(item.actions.first)

        let outcome = try await show.perform(context)

        let request = ScreenRequest(feature: ScriptSource.feature, screen: "diagnostics")
        #expect(outcome == .push(request))
        #expect(item.tabTarget == request)
        #expect(context.calls.isEmpty)
    }

    // MARK: In root search

    /// Everything a session publishes, for a test to take one by one.
    private func resultsPublished(by session: SearchSession) -> AsyncStream<SearchResults> {
        let (published, continuation) = AsyncStream.makeStream(of: SearchResults.self)
        session.onResults = { results in
            continuation.yield(results)
        }
        return published
    }

    @Test(arguments: ["toggle wi", "airport"])
    func scriptIsFoundByItsTitleAndByAKeyword(_ query: String) async throws {
        try writeScriptFile(
            "Scripts/wifi.sh", title: "Toggle Wi-Fi", lines: ["keywords network airport"])
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let registry = CommandRegistry(sources: [makeSource()])
        let session = SearchSession(registry: registry, usage: InMemoryUsageStore(), now: { now })
        let published = resultsPublished(by: session)

        session.update(query: query, generation: 1)

        // The first answers can come before the folder was read, and have no script then.
        let script = ItemID.script(path: path("Scripts/wifi.sh"))
        for await results in published {
            var found: [ItemID] = []
            for section in results.sections where section.id == "results" {
                for row in section.rows {
                    found.append(row.item.id)
                }
            }
            if !found.contains(script) { continue }

            // None of the five commands is called anything like it.
            #expect(found == [script])
            break
        }
    }

    // MARK: The real watcher

    /// Whether the stream yields before the time is up.
    ///
    /// Swift Testing counts time limits in minutes, so the wait is raced against a sleep.
    private func hasElement(in reports: AsyncStream<Void>, within timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in reports { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }

            let firstAnswer = await group.next() ?? false
            // Ends the task that is still waiting.
            group.cancelAll()
            return firstAnswer
        }
    }

    // The one test that depends on FSEvents delivering an event, which takes a moment.
    @Test func fileWrittenIntoAWatchedFolderIsReported() async throws {
        try FileManager.default.createDirectory(
            atPath: path("Watched"), withIntermediateDirectories: true)
        let (reports, continuation) = AsyncStream.makeStream(of: Void.self)

        // A folder that does not exist is passed over and does not stop the others.
        let stopWatching = FSEventsScriptFolderWatcher().startWatching(
            [path("Missing"), path("Watched")]
        ) {
            continuation.yield()
        }
        defer { stopWatching() }

        try writeScriptFile("Watched/wifi.sh", title: "Toggle Wi-Fi")

        let wasReported = await hasElement(in: reports, within: .seconds(10))
        #expect(wasReported, "No file-system event was reported within 10 seconds")
    }
}
