import Foundation
import Testing

@testable import OpenRayCore

// These tests start real processes. Each one runs a script that the test wrote into its own
// folder under the temporary directory, and the scripts only print, sleep, read their
// arguments and environment, and exit. Nothing waits for a fixed time and then looks: a test
// waits for the run to end, or for a process to be gone, and the time limit ends a test that
// would wait for ever. The suite is a class so that `deinit` can remove the folder.
@Suite(.timeLimit(.minutes(1))) final class PosixScriptRunnerTests: Sendable {
    private let folder: String

    init() throws {
        folder = NSTemporaryDirectory() + "OpenRayTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
    }

    // MARK: Fixtures

    /// Writes `body` under a `#!/bin/sh` line and returns the invocation that runs it. The
    /// environment is empty unless the test gives one, so nothing of the environment the
    /// tests run in reaches a script.
    private func makeInvocation(
        ofScript body: String, arguments: [String] = [], environment: [String: String] = [:],
        timeout: Duration? = nil, mergesStandardError: Bool = false
    ) throws -> ScriptInvocation {
        let path = "\(folder)/script.sh"
        try writeScript("#!/bin/sh\n\(body)\n", to: path)
        return ScriptInvocation(
            executable: URL(filePath: path), arguments: arguments, environment: environment,
            workingDirectory: URL(filePath: folder), timeout: timeout,
            mergesStandardError: mergesStandardError)
    }

    /// Runs the script with the runner as the app has it and reads the run to its end.
    private func outcome(
        ofScript body: String, arguments: [String] = [], environment: [String: String] = [:]
    ) async throws -> ScriptRunOutcome {
        let invocation = try makeInvocation(
            ofScript: body, arguments: arguments, environment: environment)
        return await readToEnd(PosixScriptRunner().run(invocation))
    }

    /// Reads a run in a task of its own, as the app does, and hands on every whole line of
    /// stdout. Cancelling the task is how a run is stopped.
    private func readLines(
        of events: AsyncThrowingStream<ScriptEvent, any Error>
    ) -> (reading: Task<Void, Never>, lines: AsyncStream<String>) {
        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        let reading = Task {
            var unfinishedLine = ""
            do {
                for try await event in events {
                    guard case .stdout(let text) = event else { continue }
                    unfinishedLine += text
                    while let lineEnd = unfinishedLine.firstIndex(of: "\n") {
                        continuation.yield(String(unfinishedLine[..<lineEnd]))
                        unfinishedLine.removeSubrange(...lineEnd)
                    }
                }
            } catch {
                // No test that reads this way expects the run to fail to start.
            }
            continuation.finish()
        }
        return (reading, lines)
    }

    /// The pids a script printed on one line, with spaces between them.
    private func pids(in line: String) -> [pid_t] {
        var pids: [pid_t] = []
        for word in line.split(separator: " ") {
            if let pid = pid_t(word) {
                pids.append(pid)
            }
        }
        return pids
    }

    // MARK: The exit

    @Test func exitCodeIsReported() async throws {
        let success = try await outcome(ofScript: "exit 0")
        #expect(success.events == [.exited(0)])
        #expect(success.error == nil)

        let failure = try await outcome(ofScript: "exit 3")
        #expect(failure.events == [.exited(3)])
    }

    // A script can be over before the runner has begun to watch for its exit.
    @Test func scriptThatExitsAtOnceReportsItsCodeEveryTime() async throws {
        let invocation = try makeInvocation(ofScript: "exit 7")
        let runner = PosixScriptRunner()

        for _ in 0..<50 {
            let result = await readToEnd(runner.run(invocation))
            #expect(result.events == [.exited(7)])
        }
    }

    @Test func waitStatusIsReadAsAShellReadsIt() {
        // An exit code is in the second byte of the status.
        #expect(PosixScriptRunner.exitCode(fromWaitStatus: 0) == 0)
        #expect(PosixScriptRunner.exitCode(fromWaitStatus: 3 << 8) == 3)
        #expect(PosixScriptRunner.exitCode(fromWaitStatus: 255 << 8) == 255)
        // A signal is in the low seven bits; the eighth says whether a core was dumped.
        #expect(PosixScriptRunner.exitCode(fromWaitStatus: SIGTERM) == 143)
        #expect(PosixScriptRunner.exitCode(fromWaitStatus: SIGKILL) == 137)
        #expect(PosixScriptRunner.exitCode(fromWaitStatus: SIGSEGV | 0x80) == 139)
    }

    // MARK: What the script is given

    @Test func argumentsArriveAsTheyWereGiven() async throws {
        let script = """
            echo "$#"
            for argument in "$@"; do
                echo "[$argument]"
            done
            """
        let arguments = ["two words", #"it's "quoted""#, "", "$HOME", "*", "; echo injected"]

        let result = try await outcome(ofScript: script, arguments: arguments)

        // Nothing was split, expanded or run, and the empty one kept its place.
        let expected = """
            6
            [two words]
            [it's "quoted"]
            []
            [$HOME]
            [*]
            [; echo injected]

            """
        #expect(result.standardOutput == expected)
        #expect(result.ending == .exited(0))
    }

    @Test func environmentIsTheInvocationsAndNothingElse() async throws {
        // USER and TMPDIR are in the environment of the tests themselves.
        let script = """
            echo "$OPENRAY_TEST_COLOUR"
            echo "${USER-not set}"
            echo "${TMPDIR-not set}"
            """

        let result = try await outcome(
            ofScript: script, environment: ["OPENRAY_TEST_COLOUR": "teal = blue and green"])

        #expect(result.standardOutput == "teal = blue and green\nnot set\nnot set\n")
    }

    @Test func standardInputIsEmpty() async throws {
        let script = """
            if read line; then
                echo "read a line"
            else
                echo "nothing to read"
            fi
            """

        let result = try await outcome(ofScript: script)

        #expect(result.standardOutput == "nothing to read\n")
    }

    @Test func scriptRunsInTheWorkingDirectory() async throws {
        let workingDirectory = "\(folder)/Elsewhere"
        try FileManager.default.createDirectory(
            atPath: workingDirectory, withIntermediateDirectories: true)
        var invocation = try makeInvocation(ofScript: "pwd -P")
        invocation.workingDirectory = URL(filePath: workingDirectory)

        let result = await readToEnd(PosixScriptRunner().run(invocation))

        // The temporary directory is reached through a link, which `pwd -P` follows.
        let resolved = try #require(realpath(workingDirectory, nil))
        defer { free(resolved) }
        #expect(result.standardOutput == String(cString: resolved) + "\n")
    }

    // MARK: Output

    @Test func bothStreamsArriveApart() async throws {
        let script = """
            echo "first out"
            echo "first error" >&2
            echo "second out"
            echo "second error" >&2
            """

        let result = try await outcome(ofScript: script)

        // Each stream is in order. Which of the two came first cannot be known.
        #expect(result.standardOutput == "first out\nsecond out\n")
        #expect(result.standardError == "first error\nsecond error\n")
        #expect(result.ending == .exited(0))
    }

    @Test func mergedStreamsArriveInTheOrderTheyWereWritten() async throws {
        let invocation = try makeInvocation(
            ofScript: "echo a; echo b >&2; echo c", mergesStandardError: true)

        let result = await readToEnd(PosixScriptRunner().run(invocation))

        #expect(result.standardOutput == "a\nb\nc\n")
        #expect(result.standardError == "")
    }

    // Whether the two halves really arrive in two reads is up to the system. The decoder's
    // own tests cut where they like; this one shows that the runner uses it.
    @Test func characterWrittenInTwoPartsArrivesWhole() async throws {
        let script = #"""
            printf 'caf\303'
            /bin/sleep 0.2
            printf '\251\n'
            """#

        let result = try await outcome(ofScript: script)

        #expect(result.standardOutput == "café\n")
    }

    @Test func largeOutputArrivesWholeAndInOrderBeforeTheExit() async throws {
        // 20 000 lines of 100 bytes: 2 MB, many times what a pipe holds.
        let padding = String(repeating: "x", count: 92)
        let script = """
            number=10000
            while [ $number -lt 30000 ]; do
                echo "$number \(padding)-"
                number=$((number + 1))
            done
            """

        let result = try await outcome(ofScript: script)

        var expected = ""
        for number in 10000..<30000 {
            expected += "\(number) \(padding)-\n"
        }
        #expect(expected.utf8.count == 2_000_000)
        // Not `==` on the texts: a failure would print both.
        #expect(result.standardOutput.utf8.count == expected.utf8.count)
        #expect(result.standardOutput.utf8.elementsEqual(expected.utf8))
        #expect(result.ending == .exited(0))
    }

    // MARK: Files that cannot be started

    @Test func fileWithoutPermissionToRunCannotBeStarted() async throws {
        let path = "\(folder)/not-executable.sh"
        try writeScript("#!/bin/sh\necho ran\n", to: path, permissions: 0o644)
        let invocation = ScriptInvocation(
            executable: URL(filePath: path), environment: [:],
            workingDirectory: URL(filePath: folder))

        let result = await readToEnd(PosixScriptRunner().run(invocation))

        #expect(result.events.isEmpty)
        #expect(result.error as? ScriptRunError == .cannotStart(file: path, code: EACCES))
    }

    @Test func scriptWhoseInterpreterIsMissingCannotBeStarted() async throws {
        let path = "\(folder)/no-interpreter.sh"
        try writeScript("#!\(folder)/no-such-interpreter\necho ran\n", to: path)
        let invocation = ScriptInvocation(
            executable: URL(filePath: path), environment: [:],
            workingDirectory: URL(filePath: folder))

        let result = await readToEnd(PosixScriptRunner().run(invocation))

        #expect(result.events.isEmpty)
        #expect(result.error as? ScriptRunError == .cannotStart(file: path, code: ENOENT))
    }

    @Test func textFileWithoutInterpreterLineCannotBeStarted() async throws {
        let path = "\(folder)/no-shebang.sh"
        try writeScript("echo ran\n", to: path)
        let invocation = ScriptInvocation(
            executable: URL(filePath: path), environment: [:],
            workingDirectory: URL(filePath: folder))

        let result = await readToEnd(PosixScriptRunner().run(invocation))

        // No shell steps in to run it, as one would in a terminal.
        #expect(result.events.isEmpty)
        #expect(result.error as? ScriptRunError == .cannotStart(file: path, code: ENOEXEC))
    }

    @Test func startErrorNamesTheFileAndNotItsFolder() {
        let missingProgram = ScriptRunError.cannotStart(
            file: "/Users/somebody/Scripts/wifi.sh", code: ENOENT)
        #expect(
            missingProgram.localizedDescription
                == "“wifi.sh” could not be started: No such file or directory. The program in its #! line may be missing."
        )

        let notAllowed = ScriptRunError.cannotStart(
            file: "/Users/somebody/Scripts/wifi.sh", code: EACCES)
        #expect(
            notAllowed.localizedDescription == "“wifi.sh” could not be started: Permission denied")
    }

    // MARK: Stopping

    @Test func timeoutEndsTheScriptAndWhatItStarted() async throws {
        let script = """
            /bin/sleep 600 &
            echo "$!"
            wait
            """
        let invocation = try makeInvocation(ofScript: script, timeout: .seconds(2))
        // The sleeper holds the pipe open. With a minute of grace, the end can only come in
        // time if the sleeper died with the script.
        let runner = PosixScriptRunner(outputGrace: .seconds(60))

        let result = await readToEnd(runner.run(invocation))

        #expect(result.ending == .timedOut)
        // A machine too slow to start the sleeper within the timeout has none to look for.
        let printedPids = pids(in: result.standardOutput.trimmingCharacters(in: .newlines))
        if let sleeper = printedPids.first {
            let sleeperIsGone = await holds(within: .seconds(20)) { isGone(sleeper) }
            #expect(sleeperIsGone)
        }
    }

    /// Starts a script that prints the pids of its processes on its first line, stops
    /// reading once that line has arrived, and says whether all of the processes were gone
    /// in time.
    private func processesAreGone(
        afterCancelling script: String, runner: PosixScriptRunner = PosixScriptRunner()
    ) async throws -> Bool {
        let invocation = try makeInvocation(ofScript: script)
        let (reading, lines) = readLines(of: runner.run(invocation))

        var lineIterator = lines.makeAsyncIterator()
        let firstLine = try #require(await lineIterator.next())
        let processes = pids(in: firstLine)
        try #require(!processes.isEmpty)

        reading.cancel()

        return await holds(within: .seconds(20)) {
            for process in processes {
                if !isGone(process) { return false }
            }
            return true
        }
    }

    @Test func cancellingTheReaderEndsTheScriptAndWhatItStarted() async throws {
        let script = """
            /bin/sleep 600 &
            echo "$$ $!"
            wait
            """

        #expect(try await processesAreGone(afterCancelling: script))
    }

    @Test func scriptThatIgnoresSIGTERMIsKilled() async throws {
        // What is ignored stays ignored in the sleeper, so SIGTERM ends neither of them.
        let script = """
            trap '' TERM
            /bin/sleep 600 &
            echo "$$ $!"
            wait
            """
        let runner = PosixScriptRunner(killDelay: .milliseconds(200))

        #expect(try await processesAreGone(afterCancelling: script, runner: runner))
    }

    @Test func whatOutlivesTheScriptIsKilledAsSoonAsTheScriptIsGone() async throws {
        // Only the sleeper ignores SIGTERM here. The script dies of it, and then the
        // sleeper is not given the minute of this runner: its group could not be signalled
        // any more once the script has been reaped.
        let script = """
            (trap '' TERM; exec /bin/sleep 600) &
            echo "$$ $!"
            wait
            """
        let runner = PosixScriptRunner(killDelay: .seconds(60))

        #expect(try await processesAreGone(afterCancelling: script, runner: runner))
    }

    @Test func scriptThatPrintsWithoutEndIsStoppedWithItsReader() async throws {
        let script = """
            echo "$$"
            while :; do
                echo "and so on and so on and so on and so on and so on and so on"
            done
            """

        #expect(try await processesAreGone(afterCancelling: script))
    }

    @Test func processLeftRunningDoesNotHoldUpTheEndAndIsLeftAlone() async throws {
        let script = """
            /bin/sleep 600 &
            echo "$$ $!"
            """
        let invocation = try makeInvocation(ofScript: script)
        // The sleeper holds the pipe open for ten minutes. The end can only come through
        // the grace.
        let runner = PosixScriptRunner(outputGrace: .milliseconds(500))

        let result = await readToEnd(runner.run(invocation))

        #expect(result.ending == .exited(0))
        let processes = pids(in: result.standardOutput.trimmingCharacters(in: .newlines))
        try #require(processes.count == 2)
        let group = processes[0]
        let sleeper = processes[1]

        // A script may start something on purpose, so after a normal exit nothing is
        // signalled. The sleeper is still there, and still in the group of the script.
        #expect(getpgid(sleeper) == group)

        // The test ends what it started, by the runner's own rule for signalling a group.
        if getpgid(sleeper) == group && PosixScriptRunner.maySignal(group: group) {
            killpg(group, SIGKILL)
        }
        let sleeperIsGone = await holds(within: .seconds(20)) { isGone(sleeper) }
        #expect(sleeperIsGone)
    }

    @Test func groupsThatAreNotAScriptsAreNeverSignalled() async throws {
        #expect(!PosixScriptRunner.maySignal(group: 0))
        #expect(!PosixScriptRunner.maySignal(group: 1))
        #expect(!PosixScriptRunner.maySignal(group: -1))
        #expect(!PosixScriptRunner.maySignal(group: getpgrp()))

        // The group of a script that is running may be. Nothing is sent here; the script
        // is stopped the usual way.
        let invocation = try makeInvocation(ofScript: "echo \"$$\"\n/bin/sleep 600")
        let (reading, lines) = readLines(of: PosixScriptRunner().run(invocation))
        var lineIterator = lines.makeAsyncIterator()
        let firstLine = try #require(await lineIterator.next())
        let process = try #require(pids(in: firstLine).first)

        #expect(getpgid(process) == process)
        #expect(PosixScriptRunner.maySignal(group: process))

        reading.cancel()
        let isOver = await holds(within: .seconds(20)) { isGone(process) }
        #expect(isOver)
    }
}
