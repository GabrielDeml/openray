import Foundation
import Synchronization
import Testing

import OpenRayCore

// Shared by the tests of running scripts. A test only ever runs a file it wrote itself, into
// a folder it made under the temporary directory, and such a file does nothing but print,
// sleep, read its arguments and environment, and exit.

/// Writes a script into a folder the test made.
func writeScript(_ text: String, to path: String, permissions: mode_t = 0o755) throws {
    try Data(text.utf8).write(to: URL(filePath: path))
    try #require(chmod(path, permissions) == 0)
}

/// Marks the file the way a browser marks a download: flags, a date, the app's name.
func markAsDownloaded(_ path: String) throws {
    let value = Array("0083;00000000;OpenRayTests;".utf8)
    try #require(setxattr(path, "com.apple.quarantine", value, value.count, 0, 0) == 0)
}

/// Everything one run reported.
struct ScriptRunOutcome {
    var events: [ScriptEvent] = []
    /// What the stream threw, when it did not end well.
    var error: (any Error)?

    /// The text of all `.stdout` events, joined.
    var standardOutput: String {
        var text = ""
        for event in events {
            if case .stdout(let piece) = event {
                text += piece
            }
        }
        return text
    }

    /// The text of all `.stderr` events, joined.
    var standardError: String {
        var text = ""
        for event in events {
            if case .stderr(let piece) = event {
                text += piece
            }
        }
        return text
    }

    /// The event the run ended with. Output never comes after it.
    var ending: ScriptEvent? {
        switch events.last {
        case .exited, .timedOut: return events.last
        case .stdout, .stderr, nil: return nil
        }
    }
}

/// Reads a run to its end.
func readToEnd(_ events: AsyncThrowingStream<ScriptEvent, any Error>) async -> ScriptRunOutcome {
    var outcome = ScriptRunOutcome()
    do {
        for try await event in events {
            outcome.events.append(event)
        }
    } catch {
        outcome.error = error
    }
    return outcome
}

/// Asks again and again until `condition` holds or the time is up, and says which it was.
///
/// For what happens in another process, where there is nothing to await. The limit is only
/// there to end a test that would otherwise wait for ever, so it can be generous.
func holds(within limit: Duration, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        if Task.isCancelled || ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

/// Whether there is no process with this pid. Signal 0 sends nothing; it only asks.
func isGone(_ pid: pid_t) -> Bool {
    kill(pid, 0) == -1 && errno == ESRCH
}

/// Returns once the run is over.
///
/// `waitUntilFinished` alone goes on waiting when the test is cancelled, which is what a
/// time limit does to it. Here the run is stopped with the test, so that a run that never
/// ends fails its test and does not hang all of them.
@MainActor func end(of run: ScriptRun) async {
    await withTaskCancellationHandler {
        await run.waitUntilFinished()
    } onCancel: {
        Task { @MainActor in run.stop() }
    }
}

/// Stands in for the runner. No process is started: each call to `run` is answered from
/// what the test set up, and every invocation is kept to be looked at.
final class FakeScriptRunner: ScriptRunning {
    /// What one call to `run` delivers.
    struct Run: Sendable {
        var events: [ScriptEvent] = []
        /// Thrown after the events.
        var error: (any Error)?
        /// The stream does not end after its events. The test goes on with `send`, `finish`
        /// and `fail`, or leaves the run hanging.
        var staysOpen = false
    }

    private struct State {
        var plannedRuns: [Run]
        var invocations: [ScriptInvocation] = []
        var latestStream: AsyncThrowingStream<ScriptEvent, any Error>.Continuation?
    }

    private let state: Mutex<State>
    private let answer: (@Sendable (ScriptInvocation) -> Run)?

    /// One element for every call to `run`.
    let starts: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation

    /// One element for every stream that its reader ended before the runner did, which is
    /// how the real runner learns that it has to kill the script.
    let cancellations: AsyncStream<Void>
    private let cancellationContinuation: AsyncStream<Void>.Continuation

    /// A runner that delivers these runs, one for each call, in order. A call that none is
    /// left for throws, as a runner does that cannot start the file.
    convenience init(_ plannedRuns: [Run] = []) {
        self.init(plannedRuns: plannedRuns, answer: nil)
    }

    /// A runner that makes up each run from its invocation, for tests in which what is
    /// printed depends on what was asked.
    convenience init(answer: @escaping @Sendable (ScriptInvocation) -> Run) {
        self.init(plannedRuns: [], answer: answer)
    }

    private init(plannedRuns: [Run], answer: (@Sendable (ScriptInvocation) -> Run)?) {
        state = Mutex(State(plannedRuns: plannedRuns))
        self.answer = answer
        (starts, startContinuation) = AsyncStream.makeStream(of: Void.self)
        (cancellations, cancellationContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    /// The invocations so far, in the order they were run.
    var invocations: [ScriptInvocation] {
        state.withLock { $0.invocations }
    }

    func run(_ invocation: ScriptInvocation) -> AsyncThrowingStream<ScriptEvent, any Error> {
        let (events, continuation) = AsyncThrowingStream.makeStream(
            of: ScriptEvent.self, throwing: (any Error).self)
        let cancellations = cancellationContinuation
        continuation.onTermination = { termination in
            if case .cancelled = termination {
                cancellations.yield()
            }
        }

        let planned: Run? = state.withLock { state in
            state.invocations.append(invocation)
            state.latestStream = continuation
            return state.plannedRuns.isEmpty ? nil : state.plannedRuns.removeFirst()
        }
        startContinuation.yield()

        guard let run = answer?(invocation) ?? planned else {
            continuation.finish(throwing: UnplannedRun())
            return events
        }

        for event in run.events {
            continuation.yield(event)
        }
        if let error = run.error {
            continuation.finish(throwing: error)
        } else if !run.staysOpen {
            continuation.finish()
        }
        return events
    }

    /// Adds an event to the run that was started last.
    func send(_ event: ScriptEvent) {
        latestStream?.yield(event)
    }

    /// Ends the run that was started last.
    func finish() {
        latestStream?.finish()
    }

    /// Ends the run that was started last with an error.
    func fail(_ error: any Error) {
        latestStream?.finish(throwing: error)
    }

    private var latestStream: AsyncThrowingStream<ScriptEvent, any Error>.Continuation? {
        state.withLock { $0.latestStream }
    }

    struct UnplannedRun: Error {}
}

extension FakeScriptRunner.Run {
    /// A run that the test delivers by hand.
    static var open: Self {
        Self(staysOpen: true)
    }

    /// A run that prints this and exits with 0.
    static func printing(_ text: String) -> Self {
        Self(events: [.stdout(text), .exited(0)])
    }
}

/// An environment for scripts that never starts a shell: its runner cannot start anything,
/// so the capture ends with what the test passes as inherited. Without this a test would
/// run the login shell of whoever runs the tests.
func makeShellEnvironmentWithoutShell(
    inherited: [String: String] = ["PATH": "/usr/bin:/bin"]
) -> ShellEnvironment {
    ShellEnvironment(
        runner: FakeScriptRunner(), shellPath: "/made-up/bin/shell", inherited: inherited,
        homeFolder: URL(filePath: NSTemporaryDirectory()))
}

/// The two sentinels of the command a shell was asked to run. They are new for every
/// capture, so a fake shell has to read them out of the command as a real one would.
func sentinels(of invocation: ScriptInvocation) -> (start: String, end: String) {
    // printf '%s' '<start>'; /usr/bin/env -0; printf '%s' '<end>'
    let command = invocation.arguments.last ?? ""
    let start = command.firstMatch(of: /openray-environment-start-[0-9A-F-]+/)
    let end = command.firstMatch(of: /openray-environment-end-[0-9A-F-]+/)
    return (
        String(start?.output ?? "no start sentinel"), String(end?.output ?? "no end sentinel")
    )
}

/// What a shell prints for the command: the entries as `env -0` prints them, between the
/// command's sentinels.
func printedEnvironment(
    _ entries: [String], for invocation: ScriptInvocation, before: String = "",
    after: String = ""
) -> String {
    let (start, end) = sentinels(of: invocation)
    var text = before + start
    for entry in entries {
        text += entry + "\0"
    }
    return text + end + after
}

/// An environment for scripts whose shell is played by a fake runner: asked for its
/// environment, it prints these entries. No shell is started, and the runner keeps how often
/// it was asked.
func makeShellEnvironmentWithFakeShell(
    printing entries: [String]
) -> (environment: ShellEnvironment, runner: FakeScriptRunner) {
    let runner = FakeScriptRunner { invocation in
        let output = printedEnvironment(entries, for: invocation)
        return FakeScriptRunner.Run(events: [.stdout(output), .exited(0)])
    }
    let environment = ShellEnvironment(
        runner: runner, shellPath: "/made-up/bin/zsh", inherited: ["PATH": "/usr/bin:/bin"],
        homeFolder: URL(filePath: NSTemporaryDirectory()))
    return (environment, runner)
}

/// Stands in for FSEvents. It watches nothing: the test says when something has changed.
final class FakeScriptFolderWatcher: ScriptFolderWatching {
    private struct State {
        var watchedFolders: [[String]] = []
        var stopCount = 0
        /// What each watching that is under way wants called, by its number. A source can
        /// have two for a moment: the one of a stream that was dropped ends late.
        var handlers: [Int: @Sendable () -> Void] = [:]
    }

    private let state = Mutex(State())

    /// The folders of every watching that was begun, in order.
    var watchedFolders: [[String]] {
        state.withLock { $0.watchedFolders }
    }

    /// How many watchings were ended.
    var stopCount: Int {
        state.withLock { $0.stopCount }
    }

    func startWatching(
        _ folders: [String], onChange: @escaping @Sendable () -> Void
    ) -> () -> Void {
        let number: Int = state.withLock { state in
            state.watchedFolders.append(folders)
            state.handlers[state.watchedFolders.count] = onChange
            return state.watchedFolders.count
        }
        // Ends this watching and no other.
        return {
            self.state.withLock { state in
                state.stopCount += 1
                state.handlers[number] = nil
            }
        }
    }

    /// Reports a change, as FSEvents does after a file was written.
    func fire() {
        let handlers: [@Sendable () -> Void] = state.withLock { state in
            Array(state.handlers.values)
        }
        for handler in handlers {
            handler()
        }
    }
}

/// Stands in for the workspace. It opens nothing and keeps what it was asked for.
@MainActor final class FakeScriptActionHost: ScriptActionHost {
    enum Call: Equatable {
        case openInEditor(URL)
        case openFolder(URL)
        case showInFinder(URL)
    }

    struct NoEditor: Error, LocalizedError {
        var errorDescription: String? { "No app can edit this file." }
    }

    /// Makes `openInEditor` throw `NoEditor`.
    var hasNoEditor = false

    private(set) var calls: [Call] = []

    func openInEditor(_ file: URL) async throws {
        calls.append(.openInEditor(file))
        if hasNoEditor { throw NoEditor() }
    }

    func openFolder(_ folder: URL) {
        calls.append(.openFolder(folder))
    }

    func showInFinder(_ url: URL) {
        calls.append(.showInFinder(url))
    }
}
