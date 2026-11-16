import Foundation

/// What a running script reports, in the order it happens (docs/DESIGN.md §4.10).
///
/// There is no event for a run that was cancelled: cancelling means that the reader stopped
/// reading, and a reader that has stopped cannot be told anything.
public enum ScriptEvent: Sendable, Equatable {
    /// The next piece of what the script printed. A piece ends wherever a read ended, not at
    /// a line end.
    case stdout(String)
    case stderr(String)
    /// The script ended by itself, with this exit code. A script that was killed by a signal
    /// reports 128 plus the signal's number, as a shell does.
    case exited(Int32)
    /// The script ran for longer than its timeout and was killed.
    case timedOut
}

/// One run of a program: what to start, and how.
public struct ScriptInvocation: Sendable {
    public var executable: URL
    /// Handed to the program as they are, after its own path. They never pass through a
    /// shell, so nothing in them is expanded, and an empty one keeps its place.
    public var arguments: [String]
    /// The whole environment of the program. Nothing is added from OpenRay's own.
    public var environment: [String: String]
    public var workingDirectory: URL
    /// How long the program may run. nil lets it run until it ends or its reader goes away.
    public var timeout: Duration?
    /// Whether what the program writes to stderr arrives as `.stdout`, in the order the
    /// program wrote the two. With two pipes that order cannot be known, so this gives both
    /// streams the same pipe.
    public var mergesStandardError: Bool

    public init(
        executable: URL, arguments: [String] = [], environment: [String: String],
        workingDirectory: URL, timeout: Duration? = nil, mergesStandardError: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.mergesStandardError = mergesStandardError
    }
}

/// Runs programs. `PosixScriptRunner` is the one that does; tests use a fake.
public protocol ScriptRunning: Sendable {
    /// Starts the program and reports what it does.
    ///
    /// The stream ends after `.exited` or `.timedOut`, or by throwing `ScriptRunError` when
    /// the program could not be started. When the stream's reader is cancelled the program
    /// is killed.
    func run(_ invocation: ScriptInvocation) -> AsyncThrowingStream<ScriptEvent, any Error>
}

public enum ScriptRunError: LocalizedError, Equatable, Sendable {
    /// - Parameters:
    ///   - file: The path of the file that was to be run.
    ///   - code: What `posix_spawn` returned, an `errno` value.
    case cannotStart(file: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .cannotStart(let file, let code):
            let fileName = (file as NSString).lastPathComponent
            let reason = String(cString: strerror(code))

            switch code {
            case ENOENT:
                // The file was there a moment ago, when it was listed. What the system
                // most often fails to find is the program the script asks to be run with.
                return String(
                    localized:
                        "“\(fileName)” could not be started: \(reason). The program in its #! line may be missing.",
                    bundle: .module,
                    comment:
                        "Shown when a script cannot be run. The first placeholder is the file's name, the second the system's description of the error. “#!” is typed as it stands; it begins the line that names a script's interpreter."
                )
            case ENOEXEC:
                return String(
                    localized:
                        "“\(fileName)” could not be started: \(reason). It may be missing its #! line.",
                    bundle: .module,
                    comment:
                        "Shown when a script cannot be run. The first placeholder is the file's name, the second the system's description of the error. “#!” is typed as it stands; it begins the line that names a script's interpreter."
                )
            default:
                return String(
                    localized: "“\(fileName)” could not be started: \(reason)",
                    bundle: .module,
                    comment:
                        "Shown when a script cannot be run. The first placeholder is the file's name, the second the system's description of the error."
                )
            }
        }
    }
}
