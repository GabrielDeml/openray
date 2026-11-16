import Foundation

/// The environment the user's scripts run in, asked from their login shell once and then
/// kept (docs/DESIGN.md §4.10).
///
/// An app that was opened from Finder has little more than `/usr/bin:/bin` in its `PATH`,
/// and none of what the user's shell sets up. A script would find neither Homebrew's tools
/// nor anything else it finds in a terminal. So the shell is started the way a terminal
/// starts it and asked to print its environment.
///
/// The values are the user's and may be secrets. They are kept in memory only. Nothing here
/// logs one, and nothing here reports what the shell wrote besides.
public actor ShellEnvironment {
    public enum Origin: Sendable, Equatable {
        /// The shell, started as a terminal window starts it.
        case interactiveLoginShell
        /// The shell without what it only does for a person at a prompt. Tried when the
        /// first way did not print the environment.
        case loginShell
        /// Neither way worked: what OpenRay itself was started with, and Homebrew's folders
        /// in front of `PATH`.
        case inherited
    }

    public struct Captured: Sendable {
        public var variables: [String: String]
        public var origin: Origin
        /// The shell that was asked, as the last part of its path: "zsh".
        public var shellName: String

        /// Where the environment came from and how large it is, as a sentence for the HUD
        /// and for Settings. It names no variable.
        public var summary: String {
            switch origin {
            case .interactiveLoginShell, .loginShell:
                return String(
                    localized:
                        "Scripts run with the environment of \(shellName): \(variables.count) variables.",
                    bundle: .module,
                    comment:
                        "Says that scripts get the environment variables of the user's shell. The first placeholder is the shell's name, such as zsh, the second the number of variables."
                )
            case .inherited:
                return String(
                    localized:
                        "\(shellName) did not report its environment. Scripts run with the one OpenRay was started with.",
                    bundle: .module,
                    comment:
                        "Says that the user's shell could not be asked for its environment variables. The placeholder is the shell's name, such as zsh."
                )
            }
        }
    }

    private let runner: any ScriptRunning
    /// The shell to ask. nil for the user's own, which `capture` finds.
    private let shellPath: String?
    private let inherited: [String: String]
    private let homeFolder: URL
    private let timeout: Duration

    private var captured: Captured?
    /// The capture that is under way. Everybody who asks meanwhile waits for this one.
    private var capturing: Task<Captured, Never>?

    /// - Parameters:
    ///   - runner: What starts the shell. A test passes a fake, or a shell of its own.
    ///   - shellPath: The shell to ask. nil for the user's own.
    ///   - inherited: The environment OpenRay was started with. The shell is started with
    ///     it, and it is what scripts get when the shell does not answer.
    ///   - timeout: How long one start of the shell may take.
    public init(
        runner: any ScriptRunning, shellPath: String? = nil,
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        homeFolder: URL = .homeDirectory, timeout: Duration = .seconds(5)
    ) {
        self.runner = runner
        self.shellPath = shellPath
        self.inherited = inherited
        self.homeFolder = homeFolder
        self.timeout = timeout
    }

    /// The environment as it was last captured. nil when the shell has not been asked yet.
    public var cached: Captured? {
        captured
    }

    /// The environment, captured now if it has not been. The first call of a session can
    /// take as long as two timeouts.
    ///
    /// Cancelling the caller does not cancel the capture: others may be waiting for it, and
    /// the next script wants it too.
    public func current() async -> Captured {
        if let captured { return captured }
        if let capturing { return await capturing.value }
        return await startCapture().value
    }

    /// Asks the shell again, for when the user has changed their rc files.
    public func reload() async -> Captured {
        // A capture that is under way is as new as one that would start now.
        if let capturing { return await capturing.value }
        captured = nil
        return await startCapture().value
    }

    private func startCapture() -> Task<Captured, Never> {
        let task = Task { () -> Captured in
            let result = await self.capture()
            self.captured = result
            self.capturing = nil
            return result
        }
        capturing = task
        return task
    }

    // MARK: Asking the shell

    private func capture() async -> Captured {
        let start = ContinuousClock.now
        // Found here and not when the environment is made, which the app does on the main
        // actor while it starts: the user database is asked through another process.
        let shellPath =
            self.shellPath
            ?? Self.loginShell(inherited: inherited, accountShell: Self.accountShell())
        let shellName = (shellPath as NSString).lastPathComponent

        var result = Captured(
            variables: ScriptEnvironment.fallback(inherited: inherited), origin: .inherited,
            shellName: shellName)

        // `-i` makes zsh read `.zshrc` and bash `.bashrc`, where most people set their
        // `PATH`. It also makes some setups wait for a terminal that is not there, so the
        // second try does without it.
        if let variables = await variablesPrinted(by: shellPath, with: ["-l", "-i"]) {
            result.variables = variables
            result.origin = .interactiveLoginShell
        } else if let variables = await variablesPrinted(by: shellPath, with: ["-l"]) {
            result.variables = variables
            result.origin = .loginShell
        }

        let seconds = (ContinuousClock.now - start).inSeconds
        // How many, and never which: a name can say a lot, and a value everything.
        Log.scripts.info(
            "Shell environment from \(String(describing: result.origin), privacy: .public): \(result.variables.count, privacy: .public) variables after \(seconds, format: .fixed(precision: 1), privacy: .public) s"
        )
        return result
    }

    /// Starts the shell once. nil when it did not print its environment whole.
    private func variablesPrinted(
        by shellPath: String, with options: [String]
    ) async -> [String: String]? {
        // The rc files may print anything before and after. Two sentinels that nothing
        // else can have printed say where the environment is.
        let identifier = UUID().uuidString
        let startSentinel = "openray-environment-start-\(identifier)"
        let endSentinel = "openray-environment-end-\(identifier)"
        // Written so that zsh, bash and fish all read it the same way. `env -0` ends each
        // variable with a NUL, since a value can have line ends in it.
        let command =
            "printf '%s' '\(startSentinel)'; /usr/bin/env -0; printf '%s' '\(endSentinel)'"

        let invocation = ScriptInvocation(
            executable: URL(filePath: shellPath), arguments: options + ["-c", command],
            environment: inherited, workingDirectory: homeFolder, timeout: timeout)

        var output = ""
        do {
            for try await event in runner.run(invocation) {
                if case .stdout(let text) = event {
                    output += text
                }
            }
        } catch {
            // The shell could not be started. The caller goes on to the next way.
            return nil
        }

        // How the shell ended does not matter. One that printed everything and then hung
        // until the timeout has still answered.
        return ShellEnvironmentParser.variables(
            in: output, start: startSentinel, end: endSentinel)
    }

    // MARK: Which shell

    /// - Parameter accountShell: The login shell the user database has for the user.
    static func loginShell(inherited: [String: String], accountShell: String?) -> String {
        // An app opened from Finder may not have `SHELL` at all, hence the other two.
        if let shell = inherited["SHELL"], shell.hasPrefix("/") {
            return shell
        }
        if let accountShell, accountShell.hasPrefix("/") {
            return accountShell
        }
        return "/bin/zsh"
    }

    private static func accountShell() -> String? {
        var entry = passwd()
        var found: UnsafeMutablePointer<passwd>?
        var texts = [CChar](repeating: 0, count: 4096)

        // The entry's texts lie in the array, so they are read while it is held still.
        return texts.withUnsafeMutableBufferPointer { buffer -> String? in
            let errorCode = getpwuid_r(
                getuid(), &entry, buffer.baseAddress, buffer.count, &found)
            guard errorCode == 0, found != nil, let shell = entry.pw_shell else { return nil }
            return String(cString: shell)
        }
    }
}
