import Foundation
import Testing

@testable import OpenRayCore

// No process is started here. The model talks to a fake runner whose events the test sends
// by hand. One test writes a file, into its own folder under the temporary directory, to
// have something whose permissions it can change; that file is never run either. No test
// sleeps to let the model settle: it waits for the model or the run to show what it expects.
@MainActor @Suite(.timeLimit(.minutes(1))) final class ScriptOutputModelTests {
    private let folder: String
    private let context = FakeScreenContext(request: ScriptSource.lastOutputScreenRequest)
    private let host = FakeScriptActionHost()

    init() throws {
        folder = NSTemporaryDirectory() + "OpenRayTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
    }

    // MARK: Fixtures

    private var scriptPath: String {
        "\(folder)/build.sh"
    }

    private func makeScript(
        mode: ScriptMode = .fullOutput, needsConfirmation: Bool = false
    ) -> ScriptCommand {
        ScriptCommand(
            path: scriptPath, folder: folder,
            metadata: ScriptMetadata(
                title: "Build", mode: mode, needsConfirmation: needsConfirmation))
    }

    private func makeRuns(_ runner: FakeScriptRunner) -> ScriptRuns {
        ScriptRuns(
            runner: runner, environment: makeShellEnvironmentWithoutShell(), appVersion: "9.8.7")
    }

    /// The model as the feature makes it: with a script to start, or without one to show the
    /// last run.
    private func makeModel(
        runs: ScriptRuns, starting script: ScriptCommand? = nil, arguments: [String] = []
    ) -> ScriptOutputModel {
        ScriptOutputModel(
            runs: runs, host: host, context: context, starting: script, arguments: arguments)
    }

    private func listedActions() -> [String] {
        context.screenActions.map(\.id.rawValue)
    }

    /// The model lists its actions a moment after the run has changed.
    private func waitForActions(_ ids: [String]) async {
        while listedActions() != ids {
            await Task.yield()
        }
    }

    private func action(_ id: String) throws -> ActionDescriptor {
        try #require(context.screenActions.first { $0.id.rawValue == id })
    }

    /// The chord each listed action answers to, as the launcher works it out.
    private func listedShortcuts() -> [KeyChord?] {
        var shortcuts: [KeyChord?] = []
        for index in context.screenActions.indices {
            shortcuts.append(
                ActionShortcuts.shortcut(ofActionAt: index, in: context.screenActions))
        }
        return shortcuts
    }

    private let whileRunning = ["copy-output", "stop", "open-in-editor"]
    private let onceOver = ["copy-output", "run-again", "open-in-editor"]

    private let copyChord = KeyChord(
        keyCode: VirtualKey.ansiC, modifiers: [.command, .shift], characters: "c")
    private let stopChord = KeyChord(
        keyCode: VirtualKey.ansiPeriod, modifiers: [.command], characters: ".")
    private let runAgainChord = KeyChord(
        keyCode: VirtualKey.ansiR, modifiers: [.command], characters: "r")
    private let editorChord = KeyChord(
        keyCode: VirtualKey.ansiO, modifiers: [.command], characters: "o")

    // MARK: Starting and following a run

    @Test func screenOpenedForAScriptStartsItOnceWithItsArguments() async throws {
        let runner = FakeScriptRunner([.open])
        let runs = makeRuns(runner)

        let model = makeModel(runs: runs, starting: makeScript(), arguments: ["release", ""])

        let run = try #require(model.run)
        #expect(run === runs.last)
        #expect(run.arguments == ["release", ""])

        for await _ in runner.starts { break }
        #expect(runner.invocations.count == 1)
        #expect(runner.invocations.first?.arguments == ["release", ""])
        #expect(runner.invocations.first?.executable.path(percentEncoded: false) == scriptPath)
    }

    @Test func linesAndStatusFollowTheRun() async throws {
        let runner = FakeScriptRunner([.open])
        let model = makeModel(runs: makeRuns(runner), starting: makeScript())
        let run = try #require(model.run)

        #expect(model.status == "Reading your shell environment…")

        await waitUntil { run.state == .running }
        #expect(model.status == "Running…")
        #expect(run.output.isEmpty)

        runner.send(.stdout("Compiling\nLink"))
        await waitUntil { run.output.lines.count == 2 }
        runner.send(.stdout("ing\n"))
        await waitUntil { run.output.lines.last?.text == "Linking" }
        #expect(run.output.lines.map(\.text) == ["Compiling", "Linking"])

        runner.send(.exited(0))
        runner.finish()
        await end(of: run)
        #expect(model.status == "Finished")
    }

    @Test func statusSaysHowTheRunEnded() async throws {
        let cannotStart = ScriptRunError.cannotStart(file: scriptPath, code: ENOEXEC)
        let runner = FakeScriptRunner([
            FakeScriptRunner.Run(events: [.exited(3)]),
            FakeScriptRunner.Run(events: [.timedOut]),
            FakeScriptRunner.Run(error: cannotStart),
        ])
        let runs = makeRuns(runner)

        let failed = makeModel(runs: runs, starting: makeScript())
        try await end(of: #require(failed.run))
        #expect(failed.status == "Exit code 3")

        let timedOut = makeModel(runs: runs, starting: makeScript())
        try await end(of: #require(timedOut.run))
        #expect(timedOut.status == "Script timed out")

        let notStarted = makeModel(runs: runs, starting: makeScript())
        try await end(of: #require(notStarted.run))
        #expect(
            notStarted.status
                == "“build.sh” could not be started: Exec format error. It may be missing its #! line."
        )
    }

    @Test func screenOpenedWithoutAScriptShowsTheLastRunWhileItGoesOn() async throws {
        let runner = FakeScriptRunner([.open])
        let runs = makeRuns(runner)
        // As the Run action of a silent script starts it, behind the closed launcher.
        let silentRun = runs.start(makeScript(mode: .silent), arguments: [])

        let model = makeModel(runs: runs)

        #expect(model.run === silentRun)
        await waitUntil { silentRun.state == .running }
        #expect(model.status == "Running…")

        runner.send(.stdout("Synced 3 files\n"))
        await waitUntil { !silentRun.output.isEmpty }
        #expect(model.run?.output.text == "Synced 3 files")
        #expect(runner.invocations.count == 1)
    }

    @Test func screenOpenedBeforeAnyScriptRanSaysSo() async {
        let runner = FakeScriptRunner()

        let model = makeModel(runs: makeRuns(runner))

        #expect(model.run == nil)
        #expect(model.status == "No script has run yet.")
        #expect(context.screenActions.isEmpty)
        // Esc leaves the screen, as on any other.
        #expect(!model.handleIntent(.escape))
        #expect(runner.invocations.isEmpty)
    }

    // MARK: Keys

    @Test func escStopsARunningScriptAndIsLeftAloneOnceItIsOver() async throws {
        let runner = FakeScriptRunner([.open])
        let model = makeModel(runs: makeRuns(runner), starting: makeScript())
        let run = try #require(model.run)
        await waitUntil { run.state == .running }

        #expect(model.handleIntent(.escape))

        #expect(run.state == .stopped)
        #expect(model.status == "Script stopped")
        // The runner kills the script when its events are no longer read.
        for await _ in runner.cancellations { break }

        // The next Esc is the launcher's, which leaves the screen.
        #expect(!model.handleIntent(.escape))
    }

    // The field is hidden and so always empty, which makes Delete mean "back" at once.
    @Test func deleteAndCommandBracketStopARunningScriptBeforeTheyLeaveTheScreen() async throws {
        let runner = FakeScriptRunner([.open])
        let model = makeModel(runs: makeRuns(runner), starting: makeScript())
        let run = try #require(model.run)
        await waitUntil { run.state == .running }

        #expect(model.handleIntent(.back))

        #expect(run.state == .stopped)
        for await _ in runner.cancellations { break }
        // With the script over, the next one goes back as on any screen.
        #expect(!model.handleIntent(.back))
    }

    @Test func arrowsScrollTheOutput() {
        let model = makeModel(runs: makeRuns(FakeScriptRunner([.open])), starting: makeScript())
        #expect(model.scrollRequest == nil)

        #expect(model.handleIntent(.moveSelection(1)))
        let down = model.scrollRequest
        #expect(down?.steps == 1)

        // A second press is a request of its own, though it asks for the same.
        #expect(model.handleIntent(.moveSelection(1)))
        let downAgain = model.scrollRequest
        #expect(downAgain?.steps == 1)
        #expect(downAgain != down)

        #expect(model.handleIntent(.moveSelection(-1)))
        #expect(model.scrollRequest?.steps == -1)
    }

    @Test func otherKeysAreLeftToTheLauncher() {
        let model = makeModel(runs: makeRuns(FakeScriptRunner([.open])), starting: makeScript())

        // Return runs the screen's first action, as on every screen.
        #expect(!model.handleIntent(.performPrimary))
        #expect(!model.handleIntent(.tabComplete))
        #expect(!model.handleIntent(.activateIndex(1)))
    }

    // MARK: Actions

    @Test func actionsFollowTheRunAndAreSetOnlyWhenTheyChange() async throws {
        let runner = FakeScriptRunner([.open])
        let model = makeModel(runs: makeRuns(runner), starting: makeScript())
        let run = try #require(model.run)

        // Set while the model was built, with the run not yet started.
        #expect(listedActions() == whileRunning)
        #expect(listedShortcuts() == [copyChord, stopChord, editorChord])
        #expect(context.screenActions.map(\.title) == ["Copy Output", "Stop", "Open in Editor"])
        #expect(context.screenActionsSetCount == 1)

        // Starting and printing change the run and not what can be done with it.
        await waitUntil { run.state == .running }
        runner.send(.stdout("Compiling\n"))
        await waitUntil { !run.output.isEmpty }

        runner.send(.exited(0))
        runner.finish()
        await end(of: run)
        await waitForActions(onceOver)

        #expect(listedShortcuts() == [copyChord, runAgainChord, editorChord])
        #expect(
            context.screenActions.map(\.title) == ["Copy Output", "Run Again", "Open in Editor"])
        // Once at first and once for the end, however much happened in between.
        #expect(context.screenActionsSetCount == 2)
    }

    @Test func copyOutputKeepsTheLauncherOpenOnlyWhileTheScriptRuns() async throws {
        let runner = FakeScriptRunner([.open])
        let model = makeModel(runs: makeRuns(runner), starting: makeScript())
        let run = try #require(model.run)
        let actionContext = context.fakeActionContext
        await waitUntil { run.state == .running }
        runner.send(.stdout("Compiling\n"))
        await waitUntil { !run.output.isEmpty }

        // Return is Copy Output: it is the first action in every state.
        let copyWhileRunning = try #require(context.screenActions.first)
        #expect(try await copyWhileRunning.perform(actionContext) == .keepOpen)
        #expect(actionContext.copied == [.text("Compiling", cursorOffsetFromEnd: nil)])
        #expect(actionContext.hudMessages == ["Copied to Clipboard"])

        runner.send(.stdout("Linking\n"))
        runner.send(.exited(0))
        runner.finish()
        await end(of: run)
        await waitForActions(onceOver)

        let copyOnceOver = try #require(context.screenActions.first)
        #expect(try await copyOnceOver.perform(actionContext) == .copiedToClipboard)
        #expect(actionContext.copied.last == .text("Compiling\nLinking", cursorOffsetFromEnd: nil))
        // The outcome brings the HUD this time.
        #expect(actionContext.hudMessages.count == 1)
    }

    @Test func stopActionStopsTheScript() async throws {
        let runner = FakeScriptRunner([.open])
        let model = makeModel(runs: makeRuns(runner), starting: makeScript())
        let run = try #require(model.run)
        await waitUntil { run.state == .running }

        let outcome = try await action("stop").perform(context.fakeActionContext)

        #expect(outcome == .keepOpen)
        #expect(run.state == .stopped)
        await waitForActions(onceOver)
    }

    @Test func runAgainStartsASecondRunWithTheSameArgumentsAndShowsIt() async throws {
        let runner = FakeScriptRunner([.printing("first\n"), .open])
        let runs = makeRuns(runner)
        let model = makeModel(runs: runs, starting: makeScript(), arguments: ["release"])
        let firstRun = try #require(model.run)
        await end(of: firstRun)
        await waitForActions(onceOver)
        let runAgain = try action("run-again")
        #expect(runAgain.confirmation == nil)

        let outcome = try await runAgain.perform(context.fakeActionContext)

        #expect(outcome == .keepOpen)
        let secondRun = try #require(model.run)
        #expect(secondRun !== firstRun)
        #expect(secondRun === runs.last)
        #expect(secondRun.arguments == ["release"])
        await waitUntil { secondRun.state == .running }
        #expect(runner.invocations.count == 2)
        #expect(runner.invocations.last?.arguments == ["release"])

        // The screen is on the new run: its output, and Stop in place of Run Again.
        runner.send(.stdout("second\n"))
        await waitUntil { !secondRun.output.isEmpty }
        #expect(model.run?.output.text == "second")
        await waitForActions(whileRunning)
    }

    @Test func runAgainLooksAtTheFileAfreshAndStartsNothingWhenItIsRefused() async throws {
        try writeScript("#!/bin/sh\necho built\n", to: scriptPath)
        let runner = FakeScriptRunner([.printing("first\n"), .printing("never\n")])
        let model = makeModel(runs: makeRuns(runner), starting: makeScript())
        let firstRun = try #require(model.run)
        await end(of: firstRun)
        await waitForActions(onceOver)
        // Somebody opened the file to everyone after the first run.
        try #require(chmod(scriptPath, 0o757) == 0)
        let runAgain = try action("run-again")

        await #expect(
            throws: ScriptSecurityProblem.worldWritable(path: scriptPath, isFolder: false)
        ) {
            _ = try await runAgain.perform(self.context.fakeActionContext)
        }

        #expect(model.run === firstRun)
        #expect(runner.invocations.count == 1)
    }

    // Run Again looks at the file off the main actor, and a second ⌘R can arrive meanwhile.
    @Test func runAgainPressedTwiceStartsOneRun() async throws {
        let runner = FakeScriptRunner([.printing("first\n"), .open, .printing("never\n")])
        let model = makeModel(runs: makeRuns(runner), starting: makeScript())
        let firstRun = try #require(model.run)
        await end(of: firstRun)
        await waitForActions(onceOver)
        let runAgain = try action("run-again")
        let actionContext = context.fakeActionContext

        async let once = runAgain.perform(actionContext)
        async let twice = runAgain.perform(actionContext)
        let firstOutcome = try await once
        let secondOutcome = try await twice

        #expect(firstOutcome == .keepOpen)
        #expect(secondOutcome == .keepOpen)
        let secondRun = try #require(model.run)
        #expect(secondRun !== firstRun)
        await waitUntil { secondRun.state == .running }
        #expect(runner.invocations.count == 2)
    }

    // Esc cancels an action that is under way (§4.1.4).
    @Test func runAgainThatWasCancelledStartsNothing() async throws {
        let runner = FakeScriptRunner([.printing("first\n"), .printing("never\n")])
        let model = makeModel(runs: makeRuns(runner), starting: makeScript())
        let firstRun = try #require(model.run)
        await end(of: firstRun)
        await waitForActions(onceOver)
        let runAgain = try action("run-again")
        let actionContext = context.fakeActionContext

        let performing = Task { () -> ActionOutcome in
            try await runAgain.perform(actionContext)
        }
        // Before the task has got anywhere: it runs on the main actor, as this test does.
        performing.cancel()
        let outcome = try await performing.value

        #expect(outcome == .keepOpen)
        #expect(model.run === firstRun)
        #expect(runner.invocations.count == 1)
    }

    @Test func runAgainAsksFirstForAScriptThatWantsToBeConfirmed() async throws {
        let runner = FakeScriptRunner([.printing("first\n")])
        let script = makeScript(needsConfirmation: true)
        let model = makeModel(runs: makeRuns(runner), starting: script)
        try await end(of: #require(model.run))
        await waitForActions(onceOver)

        #expect(
            try action("run-again").confirmation
                == Confirmation(title: "Run “Build”?", confirmTitle: "Run"))
    }

    @Test func openInEditorHandsTheScriptsFileToTheHost() async throws {
        let model = makeModel(runs: makeRuns(FakeScriptRunner([.open])), starting: makeScript())
        #expect(model.run != nil)

        let outcome = try await action("open-in-editor").perform(context.fakeActionContext)

        #expect(outcome == .closeLauncher)
        #expect(context.fakeActionContext.calls == [.closeLauncher])
        #expect(host.calls == [.openInEditor(URL(filePath: scriptPath))])
    }

    // MARK: The screen goes

    @Test func scriptThatShowsItsOutputIsStoppedWhenItsScreenIsPopped() async throws {
        let runner = FakeScriptRunner([.open])
        let model = makeModel(runs: makeRuns(runner), starting: makeScript())
        let run = try #require(model.run)
        await waitUntil { run.state == .running }

        context.close()

        await waitUntil { run.state == .stopped }
        for await _ in runner.cancellations { break }
    }

    // SwiftUI may let go of the screen's view, and with it of the model, before the launcher
    // pops the screen.
    @Test func scriptIsStoppedAlsoWhenNothingElseHoldsTheModelAnyMore() async throws {
        let runner = FakeScriptRunner([.open])
        let runs = makeRuns(runner)
        _ = makeModel(runs: runs, starting: makeScript())
        let run = try #require(runs.last)
        await waitUntil { run.state == .running }

        context.close()

        await waitUntil { run.state == .stopped }
    }

    // The view, and with it the model and its actions, can be there a moment longer than
    // the screen.
    @Test func runAgainStartsNothingOnceTheScreenIsPopped() async throws {
        let runner = FakeScriptRunner([.printing("first\n"), .printing("never\n")])
        let model = makeModel(runs: makeRuns(runner), starting: makeScript())
        let firstRun = try #require(model.run)
        await end(of: firstRun)
        await waitForActions(onceOver)
        let runAgain = try action("run-again")

        context.close()
        while !model.screenIsGone {
            await Task.yield()
        }
        let outcome = try await runAgain.perform(context.fakeActionContext)

        #expect(outcome == .keepOpen)
        #expect(model.run === firstRun)
        #expect(runner.invocations.count == 1)
    }

    @Test func silentScriptGoesOnWhenTheScreenThatShowedItIsPopped() async throws {
        let runner = FakeScriptRunner([.open])
        let runs = makeRuns(runner)
        let silentRun = runs.start(makeScript(mode: .silent), arguments: [])
        weak var weakModel: ScriptOutputModel?
        do {
            let model = makeModel(runs: runs)
            weakModel = model
        }
        await waitUntil { silentRun.state == .running }

        context.close()
        // The model is let go once it has dealt with the end of its screen.
        while weakModel != nil {
            await Task.yield()
        }

        #expect(silentRun.state == .running)
        runner.send(.stdout("Synced 3 files\n"))
        runner.send(.exited(0))
        runner.finish()
        await end(of: silentRun)
        #expect(silentRun.hudText == "Synced 3 files")
    }
}
