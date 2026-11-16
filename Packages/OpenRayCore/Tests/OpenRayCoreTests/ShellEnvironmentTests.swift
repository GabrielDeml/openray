import Foundation
import Testing

@testable import OpenRayCore

// No test here starts a login shell. All but one talk to a fake runner that plays what a
// shell would print. The one that starts a process starts a stand-in the test wrote itself,
// with a made-up environment. Every value in this file is made up.

/// A shell that exists nowhere. The fake runner starts nothing, so it is only a name.
private let madeUpShell = "/made-up/bin/zsh"

/// What OpenRay is taken to have been started with.
private let inherited = ["PATH": "/usr/bin:/bin", "OPENRAY_TEST_ORIGIN": "inherited"]

private func isInteractive(_ invocation: ScriptInvocation) -> Bool {
    invocation.arguments.contains("-i")
}

@Suite(.timeLimit(.minutes(1))) final class ShellEnvironmentTests: Sendable {
    private let folder: String

    init() throws {
        folder = NSTemporaryDirectory() + "OpenRayTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func makeEnvironment(runner: FakeScriptRunner) -> ShellEnvironment {
        ShellEnvironment(
            runner: runner, shellPath: madeUpShell, inherited: inherited,
            homeFolder: URL(filePath: folder))
    }

    /// Returns once the runner has been asked to run something.
    private func firstStart(of runner: FakeScriptRunner) async {
        for await _ in runner.starts { break }
    }

    // MARK: The three ways

    @Test func shellIsAskedAsATerminalStartsIt() async throws {
        let runner = FakeScriptRunner { invocation in
            let text = printedEnvironment(
                ["PATH=/opt/tools/bin:/usr/bin:/bin", "EDITOR=made-up-editor"], for: invocation)
            return .printing(text)
        }
        let environment = makeEnvironment(runner: runner)

        let captured = await environment.current()

        #expect(captured.origin == .interactiveLoginShell)
        #expect(captured.shellName == "zsh")
        #expect(
            captured.variables
                == ["PATH": "/opt/tools/bin:/usr/bin:/bin", "EDITOR": "made-up-editor"])

        #expect(runner.invocations.count == 1)
        let invocation = try #require(runner.invocations.first)
        #expect(invocation.executable.path(percentEncoded: false) == madeUpShell)
        #expect(invocation.arguments.count == 4)
        #expect(Array(invocation.arguments.prefix(3)) == ["-l", "-i", "-c"])
        let (start, end) = sentinels(of: invocation)
        #expect(
            invocation.arguments.last
                == "printf '%s' '\(start)'; /usr/bin/env -0; printf '%s' '\(end)'")
        #expect(invocation.timeout == .seconds(5))
        #expect(invocation.environment == inherited)
        #expect(invocation.workingDirectory == URL(filePath: folder))
        #expect(!invocation.mergesStandardError)
    }

    @Test func shellThatFailsInteractivelyIsAskedWithoutThat() async throws {
        let runner = FakeScriptRunner { invocation in
            if isInteractive(invocation) {
                // A shell that waits for a terminal and is ended by the timeout.
                return FakeScriptRunner.Run(events: [.stderr("no terminal\n"), .timedOut])
            }
            return .printing(printedEnvironment(["EDITOR=made-up-editor"], for: invocation))
        }
        let environment = makeEnvironment(runner: runner)

        let captured = await environment.current()

        #expect(captured.origin == .loginShell)
        #expect(captured.variables == ["EDITOR": "made-up-editor"])
        #expect(runner.invocations.count == 2)
        let second = try #require(runner.invocations.last)
        #expect(Array(second.arguments.prefix(2)) == ["-l", "-c"])
        #expect(second.arguments.count == 3)
        #expect(second.timeout == .seconds(5))
    }

    @Test func shellThatNeverPrintsItsEnvironmentLeavesTheInheritedOne() async {
        let runner = FakeScriptRunner { _ in
            FakeScriptRunner.Run(events: [.stdout("Welcome back!\n"), .exited(1)])
        }
        let environment = makeEnvironment(runner: runner)

        let captured = await environment.current()

        #expect(captured.origin == .inherited)
        #expect(
            captured.variables == [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                "OPENRAY_TEST_ORIGIN": "inherited",
            ])
        #expect(runner.invocations.count == 2)
    }

    @Test func shellThatCannotBeStartedLeavesTheInheritedOne() async {
        // A runner with nothing set up throws for every run.
        let runner = FakeScriptRunner()
        let environment = makeEnvironment(runner: runner)

        let captured = await environment.current()

        #expect(captured.origin == .inherited)
        #expect(captured.variables["OPENRAY_TEST_ORIGIN"] == "inherited")
        #expect(runner.invocations.count == 2)
    }

    // MARK: What counts as an answer

    @Test func shellThatHangsAfterPrintingHasStillAnswered() async {
        let runner = FakeScriptRunner { invocation in
            let text = printedEnvironment(["EDITOR=made-up-editor"], for: invocation)
            return FakeScriptRunner.Run(events: [.stdout(text), .timedOut])
        }
        let environment = makeEnvironment(runner: runner)

        let captured = await environment.current()

        #expect(captured.origin == .interactiveLoginShell)
        #expect(captured.variables == ["EDITOR": "made-up-editor"])
        #expect(runner.invocations.count == 1)
    }

    @Test func shellThatFailsAfterPrintingHasStillAnswered() async {
        let runner = FakeScriptRunner { invocation in
            let text = printedEnvironment(["EDITOR=made-up-editor"], for: invocation)
            return FakeScriptRunner.Run(events: [.stdout(text), .exited(127)])
        }
        let environment = makeEnvironment(runner: runner)

        let captured = await environment.current()

        #expect(captured.origin == .interactiveLoginShell)
        #expect(captured.variables == ["EDITOR": "made-up-editor"])
    }

    @Test func outputArrivesInPiecesAmongWhatRcFilesPrint() async {
        let runner = FakeScriptRunner { invocation in
            let text = printedEnvironment(
                ["EDITOR=made-up-editor", "NOTE=two\nlines"], for: invocation,
                before: "Welcome back!\nFAKE=1\0", after: "\nlogout\n")

            // Cut wherever a read might end, also inside a sentinel.
            var events: [ScriptEvent] = []
            var rest = Substring(text)
            while !rest.isEmpty {
                events.append(.stdout(String(rest.prefix(7))))
                events.append(.stderr("a warning on the other stream\n"))
                rest = rest.dropFirst(7)
            }
            events.append(.exited(0))
            return FakeScriptRunner.Run(events: events)
        }
        let environment = makeEnvironment(runner: runner)

        let captured = await environment.current()

        #expect(captured.variables == ["EDITOR": "made-up-editor", "NOTE": "two\nlines"])
    }

    @Test func variablesOfTheCapturingShellAreLeftOut() async {
        let runner = FakeScriptRunner { invocation in
            let entries = ["EDITOR=made-up-editor", "SHLVL=2", "PWD=/somewhere", "_=/usr/bin/env"]
            return .printing(printedEnvironment(entries, for: invocation))
        }
        let environment = makeEnvironment(runner: runner)

        let captured = await environment.current()

        #expect(captured.variables == ["EDITOR": "made-up-editor"])
    }

    // MARK: Once, and again when asked

    @Test func environmentIsCapturedOnceAndKept() async {
        let runner = FakeScriptRunner { invocation in
            .printing(printedEnvironment(["EDITOR=made-up-editor"], for: invocation))
        }
        let environment = makeEnvironment(runner: runner)
        #expect(await environment.cached == nil)

        let first = await environment.current()
        let second = await environment.current()

        #expect(first.variables == second.variables)
        #expect(await environment.cached?.variables == first.variables)
        #expect(runner.invocations.count == 1)
    }

    @Test func callersDuringACaptureWaitForTheSameOne() async {
        let runner = FakeScriptRunner { _ in .open }
        let environment = makeEnvironment(runner: runner)

        async let first = environment.current()
        async let second = environment.current()
        await firstStart(of: runner)
        let invocation = runner.invocations[0]
        runner.send(.stdout(printedEnvironment(["EDITOR=made-up-editor"], for: invocation)))
        runner.send(.exited(0))
        runner.finish()

        // Whichever of the two came second found the capture under way, or done.
        #expect(await first.variables == ["EDITOR": "made-up-editor"])
        #expect(await second.variables == ["EDITOR": "made-up-editor"])
        #expect(runner.invocations.count == 1)
    }

    @Test func cancellingACallerDoesNotCancelTheCapture() async {
        let runner = FakeScriptRunner { _ in .open }
        let environment = makeEnvironment(runner: runner)

        let impatientCaller = Task { () -> ShellEnvironment.Origin in
            let captured = await environment.current()
            return captured.origin
        }
        await firstStart(of: runner)
        impatientCaller.cancel()

        // The shell answers after the caller has given up.
        let invocation = runner.invocations[0]
        runner.send(.stdout(printedEnvironment(["EDITOR=made-up-editor"], for: invocation)))
        runner.send(.exited(0))
        runner.finish()

        #expect(await impatientCaller.value == .interactiveLoginShell)
        #expect(await environment.current().variables == ["EDITOR": "made-up-editor"])
        #expect(runner.invocations.count == 1)
    }

    @Test func reloadAsksTheShellAgain() async {
        let runner = FakeScriptRunner { invocation in
            .printing(printedEnvironment(["EDITOR=made-up-editor"], for: invocation))
        }
        let environment = makeEnvironment(runner: runner)
        _ = await environment.current()

        let reloaded = await environment.reload()

        #expect(reloaded.variables == ["EDITOR": "made-up-editor"])
        #expect(runner.invocations.count == 2)
        // New sentinels each time, so that old output can never be taken for new.
        #expect(
            sentinels(of: runner.invocations[0]).start
                != sentinels(of: runner.invocations[1]).start)

        _ = await environment.current()
        #expect(runner.invocations.count == 2)
    }

    // MARK: Which shell

    @Test func shellIsTheOneInTheEnvironmentThenTheAccountsThenZsh() {
        #expect(
            ShellEnvironment.loginShell(
                inherited: ["SHELL": "/opt/tools/bin/fish"], accountShell: "/bin/bash")
                == "/opt/tools/bin/fish")
        #expect(
            ShellEnvironment.loginShell(inherited: [:], accountShell: "/bin/bash") == "/bin/bash")
        #expect(ShellEnvironment.loginShell(inherited: [:], accountShell: nil) == "/bin/zsh")

        // A name without a path says nothing about which file to start.
        #expect(
            ShellEnvironment.loginShell(inherited: ["SHELL": "fish"], accountShell: "/bin/bash")
                == "/bin/bash")
        #expect(
            ShellEnvironment.loginShell(inherited: ["SHELL": ""], accountShell: "") == "/bin/zsh")
    }

    @Test func shellFromTheEnvironmentIsTheOneThatIsStarted() async throws {
        let runner = FakeScriptRunner { invocation in
            .printing(printedEnvironment(["EDITOR=made-up-editor"], for: invocation))
        }
        let environment = ShellEnvironment(
            runner: runner, inherited: ["SHELL": "/made-up/bin/fish"],
            homeFolder: URL(filePath: folder))

        let captured = await environment.current()

        #expect(captured.shellName == "fish")
        let invocation = try #require(runner.invocations.first)
        #expect(invocation.executable.path(percentEncoded: false) == "/made-up/bin/fish")
    }

    // MARK: A process

    // The whole way once, with the real runner: the command as OpenRay writes it, run by
    // `/bin/sh`, and `env -0` read from a pipe.
    @Test func standInShellIsAskedForItsEnvironment() async throws {
        // What a login shell does, as far as it matters here: its rc file prints a
        // greeting and sets up the environment, and then the shell runs the command.
        let standInShell = """
            #!/bin/sh
            echo "Welcome back!"
            export OPENRAY_TEST_EDITOR="made-up editor"
            export PATH="/made-up/tools:$PATH"
            while [ "$1" = "-l" ] || [ "$1" = "-i" ]; do
                shift
            done
            if [ "$1" = "-c" ]; then
                eval "$2"
            fi
            echo "logout"

            """
        let shellPath = "\(folder)/standinsh"
        try writeScript(standInShell, to: shellPath)

        // A timeout the stand-in cannot run into on a slow machine. If it did, the second
        // way of asking would answer, and the origin below would be another.
        let environment = ShellEnvironment(
            runner: PosixScriptRunner(), shellPath: shellPath, inherited: inherited,
            homeFolder: URL(filePath: folder), timeout: .seconds(60))

        let captured = await environment.current()

        #expect(captured.origin == .interactiveLoginShell)
        #expect(captured.shellName == "standinsh")
        #expect(
            captured.variables == [
                "PATH": "/made-up/tools:/usr/bin:/bin",
                "OPENRAY_TEST_ORIGIN": "inherited",
                "OPENRAY_TEST_EDITOR": "made-up editor",
            ])
    }
}

/// Whether the suite below runs. Declared outside it, because the attribute on the type could
/// not refer to a member: the compiler calls that a circular reference.
private let shellEnvironmentTestsAreSwitchedOn =
    ProcessInfo.processInfo.environment["OPENRAY_SHELL_ENV_TESTS"] == "1"

/// The one test that starts the login shell of whoever runs it, rc files and all. It runs
/// only when the environment variable `OPENRAY_SHELL_ENV_TESTS` is `1`, so the `swift test`
/// that gates CI builds it and reports it as skipped.
///
/// It prints where the environment came from and how many variables it has, and nothing
/// else: the values are the user's own, and some of them are secrets.
@Suite(.enabled(if: shellEnvironmentTestsAreSwitchedOn), .timeLimit(.minutes(1)))
struct RealShellEnvironmentTests {
    @Test func loginShellPrintsAnEnvironmentWithAPath() async {
        let environment = ShellEnvironment(runner: PosixScriptRunner())

        let captured = await environment.current()

        print(
            "Shell environment: \(captured.origin) from \(captured.shellName), \(captured.variables.count) variables"
        )
        #expect(captured.origin != .inherited)
        #expect(captured.variables.keys.contains("PATH"))
    }
}
