import Foundation
import Observation

/// Starts script commands and remembers the last one (docs/DESIGN.md §4.10).
///
/// The Scripts feature makes one and keeps it while the app runs. Nothing here runs a
/// script by itself: `start` is only ever reached from an action the user ran.
@MainActor @Observable public final class ScriptRuns {
    /// The run that was started last, whether it is over or not. Show Last Script Output
    /// shows it. It is kept in memory only, until the next run or until the app quits.
    public private(set) var last: ScriptRun?

    @ObservationIgnored private let runner: any ScriptRunning
    @ObservationIgnored private let environment: ShellEnvironment
    @ObservationIgnored private let appVersion: String

    /// - Parameter appVersion: What scripts find in `OPENRAY_VERSION`.
    public init(
        runner: any ScriptRunning, environment: ShellEnvironment,
        appVersion: String = AppInfo.version ?? ""
    ) {
        self.runner = runner
        self.environment = environment
        self.appVersion = appVersion
    }

    /// Whether the script may run now. The files are looked at afresh: the scan that listed
    /// the script may be old, and a mode or an owner can change without a rescan.
    ///
    /// Call this while the launcher is open. A file that macOS marked as downloaded is
    /// only run after the user said yes to it here, and a launcher that is hidden answers
    /// every question with no.
    ///
    /// - Returns: false when the user was asked and declined.
    /// - Throws: `ScriptSecurityProblem` when the file or one of its folders can be changed
    ///   by other users or is not the user's own, and `ScriptFileError` when the quarantine
    ///   could not be taken off.
    public func isCleared(
        _ script: ScriptCommand, context: any ActionContext
    ) async throws -> Bool {
        let check = await Self.check(script)
        if let problem = check.problem {
            throw problem
        }
        if !check.isQuarantined {
            return true
        }

        let confirmation = Confirmation(
            title: ScriptTitles.runQuestion(for: script),
            message: String(
                localized:
                    "“\(script.fileName)” was downloaded. It runs as you and can do anything you can do on this Mac. OpenRay does not ask about this file again.",
                bundle: .module,
                comment:
                    "The message of the confirmation before a downloaded script runs for the first time. The placeholder is the file's name."
            ),
            confirmTitle: ScriptTitles.run)
        let isConfirmed = await context.confirm(confirmation)
        if !isConfirmed {
            return false
        }

        // Only now, and the script does not run when this fails.
        try await Self.removeQuarantine(from: script.path)
        return true
    }

    /// Starts the script. The caller has asked `isCleared` first.
    ///
    /// - Parameter arguments: One for each argument the script declares, an empty text for
    ///   an optional one that was left out.
    public func start(_ script: ScriptCommand, arguments: [String]) -> ScriptRun {
        let run = ScriptRun(
            script: script, arguments: arguments, runner: runner, environment: environment,
            appVersion: appVersion)
        last = run
        return run
    }

    // MARK: The files

    // Both ask the file system, which can be slow for a folder on a network volume, so
    // neither runs on the main thread.

    @concurrent
    private static func check(
        _ script: ScriptCommand
    ) async -> (problem: ScriptSecurityProblem?, isQuarantined: Bool) {
        let problem = ScriptSecurity.problem(withScriptAt: script.path, inFolder: script.folder)
        let isQuarantined = ScriptSecurity.isQuarantined(script.path)
        return (problem, isQuarantined)
    }

    @concurrent
    private static func removeQuarantine(from path: String) async throws {
        try ScriptSecurity.removeQuarantine(from: path)
    }
}
