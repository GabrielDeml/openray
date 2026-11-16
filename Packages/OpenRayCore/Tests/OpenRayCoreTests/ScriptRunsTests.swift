import Foundation
import Testing

import OpenRayCore

// The files are written by the test into its own folder under the temporary directory. Only
// the last test runs one, and that one prints two lines. The suite is a class so that
// `deinit` can remove the folder whichever way the test ends.
@Suite(.timeLimit(.minutes(1))) final class ScriptRunsTests: Sendable {
    private let folder: String

    init() throws {
        folder = NSTemporaryDirectory() + "OpenRayTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
    }

    // MARK: Fixtures

    /// Writes a script that says hello to its first argument and returns its command.
    private func makeScript(
        named name: String = "greet.sh", permissions: mode_t = 0o755
    ) throws -> ScriptCommand {
        let path = "\(folder)/\(name)"
        let text = """
            #!/bin/sh
            echo "Hello, $1"
            echo "Run by OpenRay $OPENRAY_VERSION"

            """
        try writeScript(text, to: path, permissions: permissions)
        return ScriptCommand(
            path: path, folder: folder, metadata: ScriptMetadata(title: "Greet", mode: .silent))
    }

    @MainActor private func makeRuns(runner: any ScriptRunning = FakeScriptRunner()) -> ScriptRuns {
        ScriptRuns(
            runner: runner, environment: makeShellEnvironmentWithoutShell(), appVersion: "9.8.7")
    }

    // MARK: Before a run

    @Test @MainActor func scriptThatIsInOrderIsClearedWithoutAQuestion() async throws {
        let script = try makeScript()
        let context = FakeActionContext()

        let mayRun = try await makeRuns().isCleared(script, context: context)

        #expect(mayRun)
        #expect(context.confirmations.isEmpty)
    }

    @Test @MainActor func scriptThatOthersCanChangeIsRefusedWithoutAQuestion() async throws {
        let script = try makeScript(permissions: 0o757)
        // Downloaded as well: the refusal comes first, and nothing is asked.
        try markAsDownloaded(script.path)
        let context = FakeActionContext()
        let runs = makeRuns()

        await #expect(
            throws: ScriptSecurityProblem.worldWritable(path: script.path, isFolder: false)
        ) {
            _ = try await runs.isCleared(script, context: context)
        }
        #expect(context.confirmations.isEmpty)
        #expect(ScriptSecurity.isQuarantined(script.path))
    }

    // The scan checked the folder when it listed the script, and that may be long ago.
    @Test @MainActor func scriptInAFolderThatOthersCanChangeIsRefused() async throws {
        let script = try makeScript()
        try #require(chmod(folder, 0o777) == 0)
        let runs = makeRuns()

        await #expect(
            throws: ScriptSecurityProblem.worldWritable(path: folder, isFolder: true)
        ) {
            _ = try await runs.isCleared(script, context: FakeActionContext())
        }
    }

    @Test @MainActor func downloadedScriptIsAskedAboutAndStaysMarkedAfterANo() async throws {
        let script = try makeScript()
        try markAsDownloaded(script.path)
        let context = FakeActionContext()
        context.confirmationAnswer = false

        let mayRun = try await makeRuns().isCleared(script, context: context)

        #expect(!mayRun)
        #expect(ScriptSecurity.isQuarantined(script.path))

        #expect(context.confirmations.count == 1)
        let confirmation = try #require(context.confirmations.first)
        #expect(confirmation.title == "Run “Greet”?")
        #expect(confirmation.message?.contains("“greet.sh” was downloaded") == true)
        #expect(confirmation.confirmTitle == "Run")
    }

    @Test @MainActor func downloadedScriptIsUnmarkedAfterAYesAndNotAskedAboutAgain() async throws {
        let script = try makeScript()
        try markAsDownloaded(script.path)
        let context = FakeActionContext()
        context.confirmationAnswer = true
        let runs = makeRuns()

        let mayRun = try await runs.isCleared(script, context: context)

        #expect(mayRun)
        #expect(!ScriptSecurity.isQuarantined(script.path))
        #expect(context.confirmations.count == 1)

        let mayRunAgain = try await runs.isCleared(script, context: context)
        #expect(mayRunAgain)
        #expect(context.confirmations.count == 1)
    }

    @Test @MainActor func downloadedScriptOfAnActionThatWasCalledOffIsNotAskedAbout() async throws {
        let script = try makeScript()
        try markAsDownloaded(script.path)
        let context = FakeActionContext()
        context.confirmationAnswer = true
        let runs = makeRuns()

        // Esc cancels the task an action runs in.
        let calledOff = Task { () async throws -> Bool in
            withUnsafeCurrentTask { task in task?.cancel() }
            return try await runs.isCleared(script, context: context)
        }
        let mayRun = try await calledOff.value

        #expect(!mayRun)
        #expect(context.confirmations.isEmpty)
        #expect(ScriptSecurity.isQuarantined(script.path))
    }

    // MARK: Runs

    @Test @MainActor func startedRunIsTheLastOne() async throws {
        let script = try makeScript()
        let runner = FakeScriptRunner([.printing("first\n"), .printing("second\n")])
        let runs = makeRuns(runner: runner)
        #expect(runs.last == nil)

        let first = runs.start(script, arguments: ["one"])
        #expect(runs.last === first)
        await first.waitUntilFinished()

        let second = runs.start(script, arguments: ["two"])
        #expect(runs.last === second)
        await second.waitUntilFinished()

        // The first run is over and unchanged by the second.
        #expect(first.output.text == "first")
        #expect(second.output.text == "second")
        #expect(second.arguments == ["two"])
    }

    // The whole way once: a file on the disk, cleared, started as a process, read to its end.
    @Test @MainActor func scriptIsRunAndItsOutputKept() async throws {
        let script = try makeScript()
        let runs = makeRuns(runner: PosixScriptRunner())
        let context = FakeActionContext()
        try #require(try await runs.isCleared(script, context: context))

        let run = runs.start(script, arguments: ["world"])
        await run.waitUntilFinished()

        #expect(run.state == .exited(0))
        #expect(run.output.text == "Hello, world\nRun by OpenRay 9.8.7")
        #expect(run.hudText == "Run by OpenRay 9.8.7")
        #expect(runs.last === run)
    }
}
