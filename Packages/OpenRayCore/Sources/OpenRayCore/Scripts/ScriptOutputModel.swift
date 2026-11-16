import Foundation
import Observation

/// The screen that shows what a script prints while it runs, and what the last script has
/// printed (docs/DESIGN.md §4.10): the run it shows, the actions it lists, and the keys it
/// takes.
///
/// The feature makes one each time the screen is pushed. A script that shows its output runs
/// for as long as this screen is on the launcher's stack and is stopped when the screen goes,
/// so that nothing without a timeout runs where it can be neither seen nor stopped.
@MainActor @Observable public final class ScriptOutputModel {
    /// Asks the view to scroll the output. `serial` makes two requests for the same distance
    /// distinct.
    public struct ScrollRequest: Equatable, Sendable {
        /// How far, in steps of the view's choosing: down when positive, up when negative.
        public let steps: Int
        public let serial: UInt64
    }

    /// The run on screen. nil when the screen was opened to show the last run and no script
    /// has run yet.
    public private(set) var run: ScriptRun?
    public private(set) var scrollRequest: ScrollRequest?

    @ObservationIgnored private let runs: ScriptRuns
    @ObservationIgnored private let host: any ScriptActionHost
    @ObservationIgnored private weak var context: (any ScreenContext)?
    /// The actions the screen has now, to tell when they have to be set again.
    @ObservationIgnored private var listedActions: [ActionID] = []
    /// Whether the screen was popped. The model can outlive it for a moment, and must not
    /// start a script then: nothing would be left to stop it.
    @ObservationIgnored private(set) var screenIsGone = false

    /// - Parameters:
    ///   - script: The script to start now, with `arguments`. nil shows the run that was
    ///     started last, whether it is over or not.
    ///   - arguments: One for each argument the script declares.
    public init(
        runs: ScriptRuns, host: any ScriptActionHost, context: any ScreenContext,
        starting script: ScriptCommand? = nil, arguments: [String] = []
    ) {
        self.runs = runs
        self.host = host
        self.context = context

        if let script {
            run = runs.start(script, arguments: arguments)
        } else {
            run = runs.last
        }
        followRun()

        let screenChanges = context.searchTextChanges()
        // The stream ends when the screen is popped. The task holds the model until then
        // and not weakly: SwiftUI may have let go of the view a moment before, and the
        // script still has to be stopped.
        Task {
            for await _ in screenChanges {}
            self.screenWasPopped()
        }
    }

    /// Where the run stands, as the line under its output. Without a run, it says that
    /// there is none.
    public var status: String {
        guard let run else {
            return String(
                localized: "No script has run yet.", bundle: .module,
                comment:
                    "Shown by the command Show Last Script Output when no script has run since OpenRay started."
            )
        }

        switch run.state {
        case .preparing:
            return String(
                localized: "Reading your shell environment…", bundle: .module,
                comment:
                    "Shown under a script's output before the script starts, while OpenRay asks the user's shell for its environment variables."
            )
        case .running:
            return String(
                localized: "Running…", bundle: .module,
                comment: "Shown under a script's output while the script runs.")
        case .exited(0):
            return String(
                localized: "Finished", bundle: .module,
                comment: "Shown under a script's output when the script ended without an error.")
        case .exited(let code):
            return String(
                localized: "Exit code \(Int(code))", bundle: .module,
                comment:
                    "Shown under a script's output when the script ended with an error. The placeholder is the number the script exited with."
            )
        case .timedOut, .stopped, .failed:
            // The words of the HUD say it for these three.
            return run.hudText
        }
    }

    // MARK: - Following the run

    /// Lists the actions for the run as it is now, and again after its state has changed or
    /// another run has taken its place.
    private func followRun() {
        withObservationTracking {
            listActions()
        } onChange: { [weak self] in
            // This runs just before the change. What it leads to is read a moment later.
            Task { @MainActor [weak self] in
                self?.followRun()
            }
        }
    }

    private func screenWasPopped() {
        screenIsGone = true

        guard let run, run.script.metadata.mode == .fullOutput else { return }
        // Does nothing when the script is over. A silent script that was looked at through
        // Show Last Script Output goes on: it has a timeout, and its HUD is still to come.
        run.stop()
    }

    // MARK: - Keys

    /// Takes the keys that mean something else here than in a list.
    public func handleIntent(_ intent: LauncherIntent) -> Bool {
        switch intent {
        case .escape, .back:
            // Esc stops the script, and only the next one leaves the screen. Delete and ⌘[
            // do the same: the field is hidden and so always empty, and one stray press
            // must not end a long run and take its screen away at once.
            guard let run, run.isRunning else { return false }
            run.stop()
            return true

        case .moveSelection(let steps):
            // There are no rows to move through, so the arrows scroll: long output has to be
            // readable without a mouse.
            let previousSerial = scrollRequest?.serial ?? 0
            scrollRequest = ScrollRequest(steps: steps, serial: previousSerial + 1)
            return true

        default:
            return false
        }
    }

    // MARK: - Actions

    /// Brings the screen's actions in line with the run.
    private func listActions() {
        let actions = makeActions()
        // The actions read the run when they run, so a list of the same actions is the same
        // list. It changes when the script starts or ends, not with what it prints.
        let ids = actions.map(\.id)
        if ids == listedActions { return }
        listedActions = ids
        context?.setScreenActions(actions)
    }

    private func makeActions() -> [ActionDescriptor] {
        guard let run else { return [] }

        // Return runs the first action, which is Copy Output in every state.
        var actions = [copyOutputAction()]
        if run.isRunning {
            actions.append(stopAction())
        } else {
            actions.append(runAgainAction(for: run.script))
        }
        actions.append(ScriptFileActions.openInEditor(run.script.path, host: host))
        return actions
    }

    private func copyOutputAction() -> ActionDescriptor {
        let title = String(
            localized: "Copy Output", bundle: .module,
            comment: "The action that copies everything a script has printed to the clipboard.")
        let shortcut = KeyChord(
            keyCode: VirtualKey.ansiC, modifiers: [.command, .shift], characters: "c")

        return ActionDescriptor(
            id: ActionID(rawValue: "copy-output"), title: title, icon: .symbol("doc.on.doc"),
            shortcut: shortcut
        ) { [weak self] actionContext in
            guard let run = self?.run else { return .keepOpen }
            actionContext.copy(.text(run.output.text, cursorOffsetFromEnd: nil))

            if run.isRunning {
                // The launcher stays: the user is watching the script, and more is to come.
                actionContext.showHUD(ActionOutcome.copiedToClipboardMessage)
                return .keepOpen
            }
            return .copiedToClipboard
        }
    }

    /// Only listed once the run is over. The new run takes its place on this screen.
    private func runAgainAction(for script: ScriptCommand) -> ActionDescriptor {
        let title = String(
            localized: "Run Again", bundle: .module,
            comment:
                "The action that runs the script whose output is shown once more, with the same arguments."
        )
        let shortcut = KeyChord(keyCode: VirtualKey.ansiR, modifiers: [.command], characters: "r")
        var confirmation: Confirmation?
        if script.metadata.needsConfirmation {
            confirmation = ScriptTitles.runConfirmation(for: script)
        }

        return ActionDescriptor(
            id: ActionID(rawValue: "run-again"), title: title,
            icon: .symbol("arrow.clockwise"), shortcut: shortcut, confirmation: confirmation
        ) { [weak self] actionContext in
            guard let self, let finishedRun = self.run, !finishedRun.isRunning else {
                return .keepOpen
            }
            // The file may have changed hands since the run before.
            let isCleared = try await self.runs.isCleared(
                finishedRun.script, context: actionContext)
            if !isCleared || self.screenIsGone { return .keepOpen }
            // Esc while the files were being looked at calls the action off. And when
            // another Run Again got there first, its run is the one on screen: a second one
            // would have no screen that stops it.
            if Task.isCancelled || self.run !== finishedRun { return .keepOpen }

            self.run = self.runs.start(finishedRun.script, arguments: finishedRun.arguments)
            return .keepOpen
        }
    }

    /// Only listed while the script runs. Esc stops it too.
    private func stopAction() -> ActionDescriptor {
        let shortcut = KeyChord(
            keyCode: VirtualKey.ansiPeriod, modifiers: [.command], characters: ".")

        return ActionDescriptor(
            id: ActionID(rawValue: "stop"), title: ActionTitles.stop,
            icon: .symbol("stop.circle"), shortcut: shortcut
        ) { [weak self] _ in
            self?.run?.stop()
            return .keepOpen
        }
    }
}
