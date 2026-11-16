import Dispatch
import Foundation

/// Runs a file as a process of its own, with `posix_spawn` (docs/DESIGN.md §4.10).
///
/// `Foundation.Process` is not used, because it gives no say over the process group. Every
/// script leads a group of its own here, so that stopping it also stops what it started.
/// A process that leaves the group, as one that calls `setsid` does, is not reached by that
/// and runs on.
///
/// The file is started directly and never through a shell. The kernel reads its `#!` line,
/// and the arguments reach the script as they were typed.
public final class PosixScriptRunner: ScriptRunning {
    private let killDelay: Duration
    private let outputGrace: Duration

    /// - Parameters:
    ///   - killDelay: How long a script that is being stopped has to end by itself after
    ///     SIGTERM, before SIGKILL.
    ///   - outputGrace: How long the output is waited for after the script has exited,
    ///     when something the script started still holds the pipe open.
    public init(killDelay: Duration = .seconds(2), outputGrace: Duration = .seconds(1)) {
        self.killDelay = killDelay
        self.outputGrace = outputGrace
    }

    public func run(_ invocation: ScriptInvocation) -> AsyncThrowingStream<ScriptEvent, any Error> {
        let (events, continuation) = AsyncThrowingStream.makeStream(
            of: ScriptEvent.self, throwing: (any Error).self)

        let process = ScriptProcess(
            invocation: invocation, continuation: continuation, killDelay: killDelay,
            outputGrace: outputGrace)
        continuation.onTermination = { _ in
            process.readerWentAway()
        }
        process.start()
        return events
    }

    /// Whether a signal may be sent to this process group. Every `killpg` of the runner asks
    /// here first.
    ///
    /// The group of a script is never one of these, since its ID is the pid of a child. The
    /// check is for the day a mistake puts another number there: 0 would signal OpenRay's
    /// own group, 1 is launchd's, and a negative number means something else again to
    /// `kill`.
    static func maySignal(group: pid_t) -> Bool {
        if group <= 1 { return false }
        return group != getpgrp()
    }

    /// What `waitpid` reported about a process that is over, as a shell gives it in `$?`: the
    /// exit code, or 128 plus the number of the signal that killed it. The C macros that
    /// take the status apart do not exist in Swift.
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + signal
    }
}

/// One process, from its start until it has been reaped and its output read.
///
/// `@unchecked Sendable`: everything that changes is read and written on `queue` only, which
/// the compiler cannot see. The two functions that other threads call, `start` and
/// `readerWentAway`, do nothing but hand over to the queue.
///
/// The queue is the run's own because `waitpid` and `read` are system calls that must not
/// take up a thread of the cooperative pool, and because the dispatch sources need a queue
/// in any case.
private final class ScriptProcess: @unchecked Sendable {
    /// One of the two pipes the script writes to, as it is read here.
    private struct OutputPipe {
        let source: any DispatchSourceRead
        let descriptor: Int32
        let isStandardError: Bool
        var decoder = Utf8ChunkDecoder()
        /// Whether the source is taking its pause after a read.
        var isSuspended = false
        /// Whether reading is over, at the end of the output or because nobody wants it.
        var isClosed = false
    }

    /// The most that is read from a pipe at once. It is also how much a pipe holds.
    private static let readSize = 64 * 1024
    /// The pause after a read.
    private static let readPause = DispatchTimeInterval.milliseconds(10)

    private let invocation: ScriptInvocation
    private let continuation: AsyncThrowingStream<ScriptEvent, any Error>.Continuation
    private let killDelay: Duration
    private let outputGrace: Duration
    private let queue = DispatchQueue(label: "\(AppInfo.bundleIdentifier).script")

    /// The pid of the script, which is also the ID of its process group. 0 until it runs.
    private var leader: pid_t = 0
    private var exitSource: (any DispatchSourceProcess)?
    private var pipes: [OutputPipe] = []

    /// nil until the script has been reaped with `waitpid`.
    private var exitCode: Int32?
    /// Whether the group has been sent SIGTERM, for a timeout or because the reader left.
    private var isEnding = false
    private var hasTimedOut = false
    private var readerIsGone = false
    /// Whether the stream has been ended. Nothing happens after that.
    private var hasFinished = false

    init(
        invocation: ScriptInvocation,
        continuation: AsyncThrowingStream<ScriptEvent, any Error>.Continuation,
        killDelay: Duration, outputGrace: Duration
    ) {
        self.invocation = invocation
        self.continuation = continuation
        self.killDelay = killDelay
        self.outputGrace = outputGrace
    }

    func start() {
        queue.async {
            self.launch()
        }
    }

    /// The stream is no longer read. This is also called when the stream ended because the
    /// run did, and then there is nothing left to do.
    func readerWentAway() {
        queue.async {
            self.stopForMissingReader()
        }
    }

    // MARK: Starting

    private func launch() {
        var outputPipe: [Int32] = [-1, -1]
        var errorPipe: [Int32] = [-1, -1]

        var errorCode = Self.openPipe(&outputPipe)
        if errorCode == 0 && !invocation.mergesStandardError {
            errorCode = Self.openPipe(&errorPipe)
        }

        var pid: pid_t = 0
        if errorCode == 0 {
            let errorWriteEnd = invocation.mergesStandardError ? outputPipe[1] : errorPipe[1]
            errorCode = Self.spawn(
                invocation, standardOutput: outputPipe[1], standardError: errorWriteEnd,
                pid: &pid)
        }

        // The child has its own copies of the write ends. As long as OpenRay holds one too,
        // the pipe never reports that the script is done writing.
        Self.closeIfOpen(outputPipe[1])
        Self.closeIfOpen(errorPipe[1])

        if errorCode != 0 {
            Self.closeIfOpen(outputPipe[0])
            Self.closeIfOpen(errorPipe[0])

            let path = invocation.executable.path(percentEncoded: false)
            Log.scripts.error(
                "Could not start \(path, privacy: .private): error \(errorCode, privacy: .public)")
            hasFinished = true
            continuation.finish(throwing: ScriptRunError.cannotStart(file: path, code: errorCode))
            return
        }

        leader = pid
        startReading(outputPipe[0], isStandardError: false)
        if !invocation.mergesStandardError {
            startReading(errorPipe[0], isStandardError: true)
        }
        watchForExit()
        startTimeout()
    }

    /// Makes a pipe whose read end does not block. Returns 0, or the `errno` value.
    private static func openPipe(_ ends: inout [Int32]) -> Int32 {
        if pipe(&ends) != 0 { return errno }

        // Without this, a process that any other part of the app starts in the meantime
        // would inherit the ends, and a write end held elsewhere keeps the pipe open after
        // the script is gone.
        _ = fcntl(ends[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(ends[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(ends[0], F_SETFL, O_NONBLOCK)
        return 0
    }

    private static func closeIfOpen(_ descriptor: Int32) {
        if descriptor >= 0 {
            close(descriptor)
        }
    }

    /// Returns 0 and the pid of the new process, or the `errno` value.
    private static func spawn(
        _ invocation: ScriptInvocation, standardOutput: Int32, standardError: Int32,
        pid: inout pid_t
    ) -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // Group 0 means a new group whose ID is the child's pid.
        posix_spawnattr_setpgroup(&attributes, 0)

        // An app may ignore signals, SIGPIPE above all, and a child inherits what is
        // ignored. The script starts with every signal as a shell would give it.
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        // POSIX_SPAWN_CLOEXEC_DEFAULT: the child gets the three descriptors below and none
        // of the files OpenRay has open.
        let flags =
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, standardOutput, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, standardError, STDERR_FILENO)
        posix_spawn_file_actions_addchdir(
            &fileActions, invocation.workingDirectory.path(percentEncoded: false))

        let path = invocation.executable.path(percentEncoded: false)
        let arguments = makeCStrings([path] + invocation.arguments)
        defer { freeCStrings(arguments) }

        var variables: [String] = []
        for name in invocation.environment.keys.sorted() {
            let value = invocation.environment[name] ?? ""
            variables.append("\(name)=\(value)")
        }
        let environment = makeCStrings(variables)
        defer { freeCStrings(environment) }

        return posix_spawn(&pid, path, &fileActions, &attributes, arguments, environment)
    }

    /// The texts as C strings, and the nil after them that marks the end of the list.
    private static func makeCStrings(_ texts: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var strings: [UnsafeMutablePointer<CChar>?] = []
        for text in texts {
            strings.append(strdup(text))
        }
        strings.append(nil)
        return strings
    }

    private static func freeCStrings(_ strings: [UnsafeMutablePointer<CChar>?]) {
        for string in strings {
            free(string)
        }
    }

    // MARK: Reading

    private func startReading(_ descriptor: Int32, isStandardError: Bool) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let index = pipes.count
        pipes.append(
            OutputPipe(source: source, descriptor: descriptor, isStandardError: isStandardError))

        source.setEventHandler {
            self.readOutput(ofPipeAt: index)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
    }

    /// Reads once, and then leaves the pipe alone for a moment.
    ///
    /// The pause is what keeps a script that prints without end from filling OpenRay's
    /// memory: the stream behind this has no limit and cannot say that its reader is busy.
    /// So no more than `readSize` is taken in every `readPause`, about 6 MB in a second.
    /// What is not taken stays in the pipe, and when that is full the script waits in its
    /// `write`.
    private func readOutput(ofPipeAt index: Int) {
        var buffer = [UInt8](repeating: 0, count: Self.readSize)
        let count = read(pipes[index].descriptor, &buffer, buffer.count)

        if count < 0 && (errno == EAGAIN || errno == EINTR) {
            // Nothing to read after all. The source reports again when there is.
            return
        }
        if count <= 0 {
            // The end of the output: every write end is closed. An error that is not one
            // of the two above ends the reading as well, since nothing more will come.
            report(pipes[index].decoder.finish(), fromPipeAt: index)
            stopReading(pipeAt: index)
            finishIfOutputHasEnded()
            return
        }

        let text = pipes[index].decoder.decode(buffer[..<count])
        report(text, fromPipeAt: index)

        pipes[index].source.suspend()
        pipes[index].isSuspended = true
        queue.asyncAfter(deadline: .now() + Self.readPause) {
            self.resumeReading(pipeAt: index)
        }
    }

    private func report(_ text: String, fromPipeAt index: Int) {
        if text.isEmpty { return }
        continuation.yield(pipes[index].isStandardError ? .stderr(text) : .stdout(text))
    }

    private func resumeReading(pipeAt index: Int) {
        if !pipes[index].isSuspended { return }
        pipes[index].isSuspended = false
        pipes[index].source.resume()
    }

    private func stopReading(pipeAt index: Int) {
        if pipes[index].isClosed { return }
        pipes[index].isClosed = true

        pipes[index].source.cancel()
        // A suspended source does not get to its cancel handler, which is what closes the
        // descriptor.
        resumeReading(pipeAt: index)
    }

    private func stopReadingAllPipes() {
        for index in pipes.indices {
            stopReading(pipeAt: index)
        }
    }

    // MARK: The exit

    private func watchForExit() {
        let source = DispatchSource.makeProcessSource(
            identifier: leader, eventMask: .exit, queue: queue)
        source.setEventHandler {
            self.leaderExited()
        }
        exitSource = source
        source.resume()

        // A script can be over before the source began to watch it. Whether the source
        // reports such an exit is not something to rely on, so this looks once itself.
        var status: Int32 = 0
        if waitpid(leader, &status, WNOHANG) == leader {
            leaderWasReaped(exitCode: PosixScriptRunner.exitCode(fromWaitStatus: status))
        }
    }

    /// The source says that the script is exiting.
    private func leaderExited() {
        // The look in `watchForExit` was faster.
        if exitCode != nil { return }

        if isEnding {
            // The script went, and what it started may not have. This is the last moment
            // the group can be signalled, so there is no waiting for `killDelay`.
            signalGroup(SIGKILL)
        }

        // Without WNOHANG: the source can report the exit a moment before the process can
        // be reaped, and then a look that does not wait would find nothing and never be
        // repeated.
        var status: Int32 = 0
        var result = waitpid(leader, &status, 0)
        while result == -1 && errno == EINTR {
            result = waitpid(leader, &status, 0)
        }
        if result == leader {
            leaderWasReaped(exitCode: PosixScriptRunner.exitCode(fromWaitStatus: status))
        } else {
            // Somebody else reaped it, and how it ended is lost.
            Log.scripts.error("waitpid failed for a script: error \(errno, privacy: .public)")
            leaderWasReaped(exitCode: -1)
        }
    }

    private func leaderWasReaped(exitCode code: Int32) {
        exitCode = code
        exitSource?.cancel()

        if readerIsGone {
            finish()
            return
        }

        // What the script printed last may still be in the pipes, so the end is reported
        // once they have been read to their end. Something the script started and left
        // running can hold a pipe open for as long as it likes, hence the limit.
        finishIfOutputHasEnded()
        if !hasFinished {
            queue.asyncAfter(deadline: .now() + outputGrace.inSeconds) {
                self.finish()
            }
        }
    }

    private func finishIfOutputHasEnded() {
        if exitCode == nil { return }
        for pipe in pipes {
            if !pipe.isClosed { return }
        }
        finish()
    }

    /// Reports how the run ended and ends the stream. Only called once the script has been
    /// reaped.
    private func finish() {
        guard !hasFinished, let exitCode else { return }
        hasFinished = true
        stopReadingAllPipes()

        // Without a reader these two do nothing.
        continuation.yield(hasTimedOut ? .timedOut : .exited(exitCode))
        continuation.finish()
    }

    // MARK: Stopping

    // A signal is only ever sent between `posix_spawn` and the `waitpid` that reaps the
    // script. For that long the script's pid is taken, also while the script is dead and
    // not reaped yet, and so no other process and no other group can have been given the
    // number. After the `waitpid` the system is free to use it again, and a signal could hit
    // a stranger.

    private func startTimeout() {
        guard let timeout = invocation.timeout else { return }

        // Weak, so that a run that ended long before its timeout is not kept until then.
        queue.asyncAfter(deadline: .now() + timeout.inSeconds) { [weak self] in
            self?.timeoutPassed()
        }
    }

    private func timeoutPassed() {
        // The script exited in time, or is being stopped already.
        if exitCode != nil || isEnding { return }

        Log.scripts.info("Process \(self.leader, privacy: .public) ran into its timeout")
        hasTimedOut = true
        endGroup()
    }

    private func stopForMissingReader() {
        if hasFinished { return }
        readerIsGone = true

        // Nobody wants the output any more. Closing the pipes also means that a script
        // which goes on printing is ended by SIGPIPE.
        stopReadingAllPipes()

        if exitCode != nil {
            // The script was over, and only its output was still waited for.
            finish()
            return
        }
        if !isEnding {
            endGroup()
        }
    }

    /// Asks the script and everything in its group to end, and makes them after
    /// `killDelay`.
    private func endGroup() {
        isEnding = true
        signalGroup(SIGTERM)

        queue.asyncAfter(deadline: .now() + killDelay.inSeconds) {
            // After the script was reaped this does nothing: `leaderExited` has dealt with
            // the rest of the group.
            self.signalGroup(SIGKILL)
        }
    }

    private func signalGroup(_ signal: Int32) {
        // The rule above: not once the script has been reaped.
        if exitCode != nil { return }

        guard PosixScriptRunner.maySignal(group: leader) else {
            Log.scripts.error(
                "Refused to signal the process group \(self.leader, privacy: .public)")
            return
        }
        // Fails when nobody is left in the group, which is as good.
        killpg(leader, signal)
    }
}

extension Duration {
    /// As a number of seconds, for a deadline of Dispatch and for a log line.
    var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
