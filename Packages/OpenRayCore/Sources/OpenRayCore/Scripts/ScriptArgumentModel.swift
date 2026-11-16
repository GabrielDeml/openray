import Foundation
import Observation

/// The screen that asks for a script's arguments, one after the other: the search field is
/// its input line, and Return takes what was typed and goes on to the next argument
/// (docs/DESIGN.md §4.10). After the last one the script runs.
///
/// It is the same kind of screen as the one for a quicklink's argument and a model of its
/// own, because it steps through up to three fields where that one previews a URL.
@MainActor @Observable public final class ScriptArgumentModel {
    public let script: ScriptCommand
    /// What the search field is when the screen opens: the line the first argument is typed
    /// into. For the arguments after it the model changes the placeholder itself.
    public let searchBarMode: SearchBarMode
    /// What was entered so far, in the order of the script's arguments. The argument that is
    /// asked for now is the one after these.
    public private(set) var values: [String] = []
    /// Why Return did not go on: an argument the script needs was left empty.
    public private(set) var notice: String?

    /// Whether the argument that is asked for now may be left empty.
    public var currentArgumentIsOptional: Bool {
        script.metadata.arguments[values.count].isOptional
    }

    @ObservationIgnored private let runs: ScriptRuns
    @ObservationIgnored private weak var context: (any ScreenContext)?
    @ObservationIgnored private var following: Task<Void, Never>?

    /// - Parameter script: A script with at least one argument.
    public init(script: ScriptCommand, runs: ScriptRuns, context: any ScreenContext) {
        self.script = script
        self.runs = runs
        self.context = context
        searchBarMode = .input(placeholder: Self.label(ofArgumentAt: 0, of: script))

        context.setScreenActions([action(forArgumentAt: 0)])

        let changes = context.searchTextChanges()
        // The stream ends when the screen is popped, and the task with it.
        following = Task { [weak self] in
            for await _ in changes {
                // The user is doing something about it.
                self?.notice = nil
            }
        }
    }

    deinit {
        following?.cancel()
    }

    /// What an argument is called: its placeholder, or its number when the script gives it
    /// none.
    public static func label(ofArgumentAt index: Int, of script: ScriptCommand) -> String {
        let placeholder = script.metadata.arguments[index].placeholder
        if !placeholder.isEmpty {
            return placeholder
        }
        return String(
            localized: "Argument \(index + 1)", bundle: .module,
            comment:
                "What an argument of a script is called when the script gives it no name. The placeholder is its number, 1 to 3."
        )
    }

    // MARK: Steps

    /// The one action of the screen, which Return runs. It reads the field when it runs.
    private func action(forArgumentAt index: Int) -> ActionDescriptor {
        let isLast = index == script.metadata.arguments.count - 1
        let id: ActionID
        let title: String
        if isLast {
            id = ActionID(rawValue: "run")
            title = ScriptTitles.run
        } else {
            id = ActionID(rawValue: "continue")
            title = String(
                localized: "Continue", bundle: .module,
                comment:
                    "The action that takes what was typed for one argument of a script and asks for the next."
            )
        }

        return ActionDescriptor(id: id, title: title) { [weak self] actionContext in
            guard let self else { return .keepOpen }
            return try await self.enterValue(actionContext)
        }
    }

    private func enterValue(_ actionContext: any ActionContext) async throws -> ActionOutcome {
        guard let context else { return .keepOpen }
        let index = values.count
        let argument = script.metadata.arguments[index]

        let value = context.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty && !argument.isOptional {
            let label = Self.label(ofArgumentAt: index, of: script)
            notice = String(
                localized: "\(label) is required", bundle: .module,
                comment:
                    "Shown when Return was pressed without a text for an argument a script needs. The placeholder is what the script calls the argument."
            )
            return .keepOpen
        }

        let isLast = index == script.metadata.arguments.count - 1
        if !isLast {
            // An optional argument that was left out is an empty text, so that the ones
            // after it keep their places.
            values.append(value)
            showCurrentStep()
            return .keepOpen
        }

        // Asked here and not by the action's own confirmation, which would come before the
        // look at what was typed.
        if script.metadata.needsConfirmation {
            let isConfirmed = await actionContext.confirm(ScriptTitles.runConfirmation(for: script))
            if !isConfirmed { return .keepOpen }
        }

        let outcome = try await ScriptSource.run(
            script, arguments: values + [value], runs: runs, context: actionContext)
        if case .push = outcome {
            // The output screen goes on top of this one. Whoever comes back from it finds
            // an empty form and not the last argument of the run before.
            values = []
            showCurrentStep()
        }
        return outcome
    }

    /// Empties the field and brings its placeholder and the screen's action in line with the
    /// argument that is asked for now.
    private func showCurrentStep() {
        guard let context else { return }
        let index = values.count

        context.setSearchText("")
        context.setSearchBarMode(
            .input(placeholder: Self.label(ofArgumentAt: index, of: script)))
        context.setScreenActions([action(forArgumentAt: index)])
    }
}
