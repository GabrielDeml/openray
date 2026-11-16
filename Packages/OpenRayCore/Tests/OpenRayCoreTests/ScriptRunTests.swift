import Foundation
import Testing

@testable import OpenRayCore

// No process is started here. The run talks to a fake runner whose events the test sends by
// hand, and its environment comes from a `ShellEnvironment` that has no shell to ask. No test
// sleeps to let a run settle: it waits for the run to show a state, or to be over.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ScriptRunTests {
    private let scriptPath = "/made-up/Scripts/Network/wifi.sh"

    private func makeScript(
        mode: ScriptMode = .silent, title: String = "Toggle Wi-Fi", timeout: Duration? = nil
    ) -> ScriptCommand {
        ScriptCommand(
            path: scriptPath, folder: "/made-up/Scripts", group: "Network",
            metadata: ScriptMetadata(title: title, mode: mode, timeout: timeout))
    }

    private func makeRun(
        of script: ScriptCommand, arguments: [String] = [], runner: FakeScriptRunner
    ) -> ScriptRun {
        ScriptRun(
            script: script, arguments: arguments, runner: runner,
            environment: makeShellEnvironmentWithoutShell(), appVersion: "9.8.7")
    }

    /// A silent run whose script prints `events` and then exits with 0, read to its end.
    private func finishedRun(printing events: [ScriptEvent]) async -> ScriptRun {
        let runner = FakeScriptRunner([FakeScriptRunner.Run(events: events + [.exited(0)])])
        let run = makeRun(of: makeScript(), runner: runner)
        await end(of: run)
        return run
    }

    /// Returns once the runner's stream has been ended by its reader.
    private func streamToBeCancelled(of runner: FakeScriptRunner) async {
        for await _ in runner.cancellations { break }
    }

    // MARK: States

    @Test func runGoesFromPreparingToRunningToExited() async {
        let runner = FakeScriptRunner([.open])
        let run = makeRun(of: makeScript(), runner: runner)

        #expect(run.state == .preparing)
        #expect(run.isRunning)

        await waitUntil { run.state == .running }
        #expect(run.isRunning)

        runner.send(.stdout("Wi-Fi is off\n"))
        runner.send(.exited(0))
        runner.finish()
        await end(of: run)

        #expect(run.state == .exited(0))
        #expect(!run.isRunning)
        #expect(run.output.text == "Wi-Fi is off")
    }

    @Test func exitCodeOtherThanZeroIsKept() async {
        let runner = FakeScriptRunner([
            FakeScriptRunner.Run(events: [.stderr("no such interface\n"), .exited(3)])
        ])
        let run = makeRun(of: makeScript(), runner: runner)
        await end(of: run)

        #expect(run.state == .exited(3))
        #expect(run.output.text == "no such interface")
    }

    @Test func timeoutIsAStateOfItsOwn() async {
        let runner = FakeScriptRunner([
            FakeScriptRunner.Run(events: [.stdout("waiting\n"), .timedOut])
        ])
        let run = makeRun(of: makeScript(), runner: runner)
        await end(of: run)

        #expect(run.state == .timedOut)
        #expect(!run.isRunning)
        #expect(run.output.text == "waiting")
    }

    @Test func scriptThatCannotBeStartedFailsWithTheReason() async {
        let error = ScriptRunError.cannotStart(file: scriptPath, code: ENOENT)
        let runner = FakeScriptRunner([FakeScriptRunner.Run(error: error)])
        let run = makeRun(of: makeScript(), runner: runner)
        await end(of: run)

        #expect(run.state == .failed(error.localizedDescription))
        #expect(!run.isRunning)
        #expect(run.hudText == error.localizedDescription)
    }

    @Test func runnerThatEndsWithoutSayingHowLeavesNoRunRunning() async {
        let runner = FakeScriptRunner([FakeScriptRunner.Run(events: [.stdout("half\n")])])
        let run = makeRun(of: makeScript(), runner: runner)
        await end(of: run)

        #expect(run.state == .stopped)
    }

    // MARK: Stopping

    @Test func stopEndsTheRunAtOnceAndTheRunnersStream() async {
        let runner = FakeScriptRunner([.open])
        let run = makeRun(of: makeScript(mode: .fullOutput), runner: runner)
        await waitUntil { run.state == .running }
        runner.send(.stdout("step 1\n"))
        await waitUntil { !run.output.isEmpty }

        run.stop()

        #expect(run.state == .stopped)
        #expect(!run.isRunning)
        // This is what makes the real runner kill the script.
        await streamToBeCancelled(of: runner)
        await end(of: run)

        // What was printed until then stays to be read.
        #expect(run.state == .stopped)
        #expect(run.output.text == "step 1")
    }

    @Test func stopWhileTheEnvironmentIsBeingReadStartsNothing() async {
        // A shell that takes its time: the capture stays open until the test ends it.
        let shellRunner = FakeScriptRunner { _ in .open }
        let environment = ShellEnvironment(
            runner: shellRunner, shellPath: "/made-up/bin/shell", inherited: [:],
            homeFolder: URL(filePath: NSTemporaryDirectory()))
        let runner = FakeScriptRunner([.printing("ran\n")])
        let run = ScriptRun(
            script: makeScript(), arguments: [], runner: runner, environment: environment,
            appVersion: "9.8.7")
        for await _ in shellRunner.starts { break }
        #expect(run.state == .preparing)

        run.stop()
        #expect(run.state == .stopped)

        // The shell gives up on both tries, and the run learns its environment too late
        // to use it.
        shellRunner.finish()
        for await _ in shellRunner.starts { break }
        shellRunner.finish()
        await end(of: run)

        #expect(run.state == .stopped)
        #expect(runner.invocations.isEmpty)
    }

    @Test func stopAfterTheEndChangesNothing() async {
        let run = await finishedRun(printing: [.stdout("done\n")])

        run.stop()

        #expect(run.state == .exited(0))
    }

    // MARK: The invocation

    @Test func silentScriptRunsWithATimeoutAndItsStreamsApart() async throws {
        let runner = FakeScriptRunner([.printing("")])
        let run = makeRun(of: makeScript(), arguments: ["office", ""], runner: runner)
        await end(of: run)

        let invocation = try #require(runner.invocations.first)
        #expect(invocation.executable.path(percentEncoded: false) == scriptPath)
        #expect(invocation.arguments == ["office", ""])
        // The folder the file is in, which for this one is a subfolder of the script folder.
        #expect(
            invocation.workingDirectory.path(percentEncoded: false) == "/made-up/Scripts/Network/")
        #expect(invocation.timeout == .seconds(30))
        #expect(!invocation.mergesStandardError)
    }

    @Test func outputScriptRunsWithoutATimeoutAndWithItsStreamsMerged() async throws {
        let runner = FakeScriptRunner([.printing("")])
        let run = makeRun(of: makeScript(mode: .fullOutput), runner: runner)
        await end(of: run)

        let invocation = try #require(runner.invocations.first)
        #expect(invocation.timeout == nil)
        #expect(invocation.mergesStandardError)
    }

    @Test func timeoutOfTheScriptWinsOverTheDefault() async throws {
        for mode in [ScriptMode.silent, ScriptMode.fullOutput] {
            let runner = FakeScriptRunner([.printing("")])
            let run = makeRun(of: makeScript(mode: mode, timeout: .seconds(5)), runner: runner)
            await end(of: run)

            let invocation = try #require(runner.invocations.first)
            #expect(invocation.timeout == .seconds(5))
        }
    }

    @Test func scriptGetsTheUsersEnvironmentAndOpenRaysVariables() async throws {
        let runner = FakeScriptRunner([.printing("")])
        let run = makeRun(of: makeScript(), runner: runner)
        await end(of: run)

        let environment = try #require(runner.invocations.first).environment
        // No shell answered, so the base is what the test passed as inherited, with
        // Homebrew's folders in front.
        #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        #expect(environment["OPENRAY"] == "1")
        #expect(environment["OPENRAY_VERSION"] == "9.8.7")
        #expect(environment["OPENRAY_SCRIPT_PATH"] == scriptPath)
        #expect(environment["NO_COLOR"] == "1")
        #expect(environment["TERM"] == "dumb")
    }

    // MARK: Output

    @Test func controlCodesAreTakenOutAlsoWhenAPieceCutsOne() async {
        let run = await finishedRun(printing: [
            .stdout("\u{1B}[1;3"), .stdout("1mred\u{1B}[0m and plain\n"),
        ])

        #expect(run.output.text == "red and plain")
    }

    @Test func eachStreamKeepsItsOwnPlaceInAControlCode() async {
        // The code that stdout began is finished by stdout, whatever stderr says between.
        let run = await finishedRun(printing: [
            .stdout("out \u{1B}["), .stderr("[error]\n"), .stdout("31mred\n"),
        ])

        #expect(run.output.text == "out [error]\nred")
    }

    // MARK: The HUD

    @Test func hudShowsTheLastLineOfStandardOutput() async {
        let run = await finishedRun(printing: [
            .stdout("Looking for networks\nConnected to "), .stdout("office\n"),
            .stderr("a warning that came last\n"),
        ])

        #expect(run.hudText == "Connected to office")
    }

    @Test func hudSkipsTheEmptyLinesAtTheEnd() async {
        let run = await finishedRun(printing: [.stdout("Wi-Fi is off\n\n   \n\t\n\n")])

        #expect(run.hudText == "Wi-Fi is off")
    }

    @Test func hudShowsALineWithoutItsLineEndToo() async {
        let run = await finishedRun(printing: [.stdout("first\nno line end")])

        #expect(run.hudText == "no line end")
    }

    @Test func hudCutsALongLineToEightyCharacters() async {
        let longLine = String(repeating: "abcdefghij", count: 12)
        let run = await finishedRun(printing: [.stdout(longLine + "\n")])

        #expect(run.hudText == String(repeating: "abcdefghij", count: 8))
    }

    @Test func hudShowsTheTitleWhenNothingWasPrinted() async {
        let nothing = await finishedRun(printing: [])
        #expect(nothing.hudText == "Toggle Wi-Fi")

        let onlyErrors = await finishedRun(printing: [.stderr("a warning\n")])
        #expect(onlyErrors.hudText == "Toggle Wi-Fi")
    }

    @Test func hudSaysWhenTheScriptFailedOrTimedOutOrWasStopped() async {
        let failingRunner = FakeScriptRunner([
            FakeScriptRunner.Run(events: [.stdout("half done\n"), .exited(1)])
        ])
        let failed = makeRun(of: makeScript(), runner: failingRunner)
        await end(of: failed)
        #expect(failed.hudText == "Script failed")

        let slowRunner = FakeScriptRunner([
            FakeScriptRunner.Run(events: [.stdout("half done\n"), .timedOut])
        ])
        let timedOut = makeRun(of: makeScript(), runner: slowRunner)
        await end(of: timedOut)
        #expect(timedOut.hudText == "Script timed out")

        let openRunner = FakeScriptRunner([.open])
        let stopped = makeRun(of: makeScript(), runner: openRunner)
        await waitUntil { stopped.state == .running }
        stopped.stop()
        #expect(stopped.hudText == "Script stopped")
    }
}
