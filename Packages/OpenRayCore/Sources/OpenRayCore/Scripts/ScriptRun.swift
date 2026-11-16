import Foundation
import Observation

/// One run of a script command: where it stands, what it has printed and how it ended
/// (docs/DESIGN.md §4.10).
///
/// A run starts when it is made and is over when its state is no longer `preparing` or
/// `running`. It is never started twice; Run Again makes a new one.
@MainActor @Observable public final class ScriptRun {
    public enum State: Equatable, Sendable {
        /// The user's shell is being asked for its environment. Only the first script after
        /// OpenRay started waits here for longer than a moment.
        case preparing
        case running
        case exited(Int32)
        case timedOut
        /// The user stopped it.
        case stopped
        /// The script could not be started. The text says why.
        case failed(String)
    }

    /// How long a silent script may run when it does not say itself. Nobody is watching
    /// one, so it must not hang for ever. A script with an output screen has Stop instead.
    static let silentTimeout: Duration = .seconds(30)
    /// How much of a line the HUD shows.
    private static let hudLineLength = 80

    public let script: ScriptCommand
    /// One for each argument the script declares, in their order. An optional one that was
    /// left out is an empty text, so that the ones after it keep their places.
    public let arguments: [String]

    public private(set) var state = State.preparing
    /// Everything the script printed, to stdout and to stderr, without the terminal's
    /// control codes.
    public private(set) var output = ScriptOutputBuffer()

    /// The end of what went to stdout alone. The HUD shows its last line, and all that is
    /// kept is enough to be sure of having that one.
    @ObservationIgnored private var standardOutput = ScriptOutputBuffer(capacity: 16 * 1024)
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        script: ScriptCommand, arguments: [String], runner: any ScriptRunning,
        environment: ShellEnvironment, appVersion: String
    ) {
        self.script = script
        self.arguments = arguments

        // The task holds the run until the script is over. A silent script goes on behind
        // the closed launcher also when nothing else remembers its run.
        task = Task {
            await self.run(with: runner, environment: environment, appVersion: appVersion)
        }
    }

    public var isRunning: Bool {
        switch state {
        case .preparing, .running: return true
        case .exited, .timedOut, .stopped, .failed: return false
        }
    }

    /// Stops the script and everything it started. Does nothing once the run is over.
    public func stop() {
        guard isRunning else { return }
        // The runner kills the script when its events are no longer read.
        task?.cancel()
        state = .stopped
        logEnd()
    }

    /// Returns once the run is over and nothing about it changes any more.
    public func waitUntilFinished() async {
        await task?.value
    }

    /// What the HUD says about a silent script once it is over.
    public var hudText: String {
        switch state {
        case .preparing, .running:
            return script.metadata.title
        case .exited(0):
            guard let line = lastPrintedLine else { return script.metadata.title }
            return String(line.prefix(Self.hudLineLength))
        case .exited:
            return String(
                localized: "Script failed", bundle: .module,
                comment:
                    "Shown in the HUD when a script ended with an error. Its output can be read with the command Show Last Script Output."
            )
        case .timedOut:
            return String(
                localized: "Script timed out", bundle: .module,
                comment:
                    "Shown in the HUD, and under a script's output, when a script ran for too long and was stopped."
            )
        case .stopped:
            return String(
                localized: "Script stopped", bundle: .module,
                comment:
                    "Shown in the HUD, and under a script's output, when the user stopped a script."
            )
        case .failed(let message):
            return message
        }
    }

    /// The last line on stdout that is more than whitespace. Of a line so long that the
    /// buffer keeps it as several, this is the last part.
    private var lastPrintedLine: String? {
        for line in standardOutput.lines.reversed() {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }

    // MARK: Running

    private func run(
        with runner: any ScriptRunning, environment: ShellEnvironment, appVersion: String
    ) async {
        let shellEnvironment = await environment.current()
        // Stopped while the shell was being asked.
        if Task.isCancelled { return }

        let invocation = Self.invocation(
            for: script, arguments: arguments, base: shellEnvironment.variables,
            appVersion: appVersion)
        state = .running

        // A control code can be cut by the end of a piece, so each stream has a stripper
        // that remembers where it was.
        var standardOutputStripper = AnsiStripper()
        var standardErrorStripper = AnsiStripper()
        do {
            for try await event in runner.run(invocation) {
                // `stop()` has set the state. What was on its way is not wanted.
                if Task.isCancelled { return }

                switch event {
                case .stdout(let text):
                    let plainText = standardOutputStripper.strip(text)
                    output.append(plainText)
                    standardOutput.append(plainText)
                case .stderr(let text):
                    output.append(standardErrorStripper.strip(text))
                case .exited(let code):
                    state = .exited(code)
                case .timedOut:
                    state = .timedOut
                }
            }
        } catch {
            if Task.isCancelled { return }
            state = .failed(error.localizedDescription)
        }

        if Task.isCancelled { return }
        if isRunning {
            // A runner ends with one of the two events or with an error. One that does
            // neither must not leave the run looking as if it went on.
            state = .stopped
        }
        logEnd()
    }

    static func invocation(
        for script: ScriptCommand, arguments: [String], base: [String: String],
        appVersion: String
    ) -> ScriptInvocation {
        let file = URL(filePath: script.path)

        var timeout = script.metadata.timeout
        if timeout == nil && script.metadata.mode == .silent {
            timeout = silentTimeout
        }

        return ScriptInvocation(
            executable: file,
            arguments: arguments,
            environment: ScriptEnvironment.variables(
                for: script.path, base: base, appVersion: appVersion),
            // The folder the file is in, so that a script finds what lies next to it.
            workingDirectory: file.deletingLastPathComponent(),
            timeout: timeout,
            // The output screen shows one text, in the order the script wrote it. The HUD
            // of a silent script wants the last line of stdout alone.
            mergesStandardError: script.metadata.mode == .fullOutput)
    }

    private func logEnd() {
        let path = script.path
        switch state {
        case .preparing, .running:
            break
        case .exited(let code):
            Log.scripts.info(
                "\(path, privacy: .private) exited with \(code, privacy: .public)")
        case .timedOut:
            Log.scripts.info("\(path, privacy: .private) timed out")
        case .stopped:
            Log.scripts.info("\(path, privacy: .private) was stopped")
        case .failed:
            // The runner has logged why.
            break
        }
    }
}
