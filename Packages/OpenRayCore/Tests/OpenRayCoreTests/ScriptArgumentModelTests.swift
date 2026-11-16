import Foundation
import Testing

import OpenRayCore

// No process is started here: the model talks to a fake runner, and the script's file does
// not exist. The search field is `FakeScreenContext`'s.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ScriptArgumentModelTests {
    private let context = FakeScreenContext(
        request: ScreenRequest(
            feature: ScriptSource.feature, screen: "arguments",
            argument: "/made-up/Scripts/join.sh"))

    private let network = ScriptArgument(placeholder: "Network", isOptional: false)
    private let password = ScriptArgument(placeholder: "Password", isOptional: true)
    /// A script may leave an argument without a name.
    private let unnamed = ScriptArgument(placeholder: "", isOptional: false)

    private func makeScript(
        mode: ScriptMode = .silent, arguments: [ScriptArgument], needsConfirmation: Bool = false
    ) -> ScriptCommand {
        ScriptCommand(
            path: "/made-up/Scripts/join.sh", folder: "/made-up/Scripts",
            metadata: ScriptMetadata(
                title: "Join Network", mode: mode, arguments: arguments,
                needsConfirmation: needsConfirmation))
    }

    @discardableResult
    private func makeModel(
        for script: ScriptCommand, runner: FakeScriptRunner = FakeScriptRunner()
    ) -> ScriptArgumentModel {
        let runs = ScriptRuns(
            runner: runner, environment: makeShellEnvironmentWithoutShell(), appVersion: "9.8.7")
        let model = ScriptArgumentModel(script: script, runs: runs, context: context)
        context.model = model
        return model
    }

    /// Types the text and presses Return, which runs the screen's one action.
    private func enter(_ text: String) async throws -> ActionOutcome {
        context.type(text)
        let action = try #require(context.screenActions.first)
        return try await action.perform(context.fakeActionContext)
    }

    private func placeholders() -> [String] {
        var placeholders: [String] = []
        for mode in context.searchBarModes {
            if case .input(let placeholder) = mode {
                placeholders.append(placeholder)
            }
        }
        return placeholders
    }

    // MARK: Steps

    @Test func screenOpensOnTheFirstArgument() {
        let model = makeModel(for: makeScript(arguments: [network, password]))

        #expect(model.searchBarMode == .input(placeholder: "Network"))
        #expect(model.values.isEmpty)
        #expect(model.notice == nil)
        #expect(context.screenActions.map(\.title) == ["Continue"])
        // The field is not the screen's to write while the screen is being built.
        #expect(context.searchBarModes.isEmpty)
        #expect(context.searchText == "")
    }

    @Test func returnTakesTheValueEmptiesTheFieldAndAsksForTheNextArgument() async throws {
        let model = makeModel(for: makeScript(arguments: [network, unnamed, password]))

        #expect(try await enter("Lantern") == .keepOpen)
        #expect(model.values == ["Lantern"])
        #expect(context.searchText == "")
        #expect(placeholders() == ["Argument 2"])
        #expect(!model.currentArgumentIsOptional)
        #expect(context.screenActions.map(\.title) == ["Continue"])

        #expect(try await enter("5 GHz") == .keepOpen)
        #expect(model.values == ["Lantern", "5 GHz"])
        #expect(context.searchText == "")
        #expect(placeholders() == ["Argument 2", "Password"])
        #expect(model.currentArgumentIsOptional)
        // The last argument is the one Return runs the script from.
        #expect(context.screenActions.map(\.title) == ["Run"])
    }

    @Test func scriptWithOneArgumentOffersToRunAtOnce() {
        makeModel(for: makeScript(arguments: [network]))

        #expect(context.screenActions.map(\.id.rawValue) == ["run"])
    }

    @Test func argumentTheScriptNeedsCannotBeLeftEmpty() async throws {
        let runner = FakeScriptRunner([.printing("never")])
        let model = makeModel(for: makeScript(arguments: [network]), runner: runner)

        #expect(try await enter("   ") == .keepOpen)

        #expect(model.notice == "Network is required")
        #expect(model.values.isEmpty)
        #expect(runner.invocations.isEmpty)
        #expect(context.fakeActionContext.calls.isEmpty)

        // The notice goes when the user types.
        context.type("L")
        await waitUntil { model.notice == nil }
    }

    @Test func argumentWithoutANameIsCalledByItsNumberInTheNotice() async throws {
        let model = makeModel(for: makeScript(arguments: [unnamed]))

        _ = try await enter("")

        #expect(model.notice == "Argument 1 is required")
    }

    // MARK: Running

    @Test func silentScriptClosesTheLauncherAndRunsWithEveryValue() async throws {
        let runner = FakeScriptRunner([.printing("Joined Lantern\n")])
        makeModel(
            for: makeScript(arguments: [network, password, unnamed]), runner: runner)

        _ = try await enter("  Lantern ")
        // Left out. It still has its place among the arguments.
        _ = try await enter("")
        let outcome = try await enter("5 GHz")

        #expect(outcome == .showHUD("Joined Lantern"))
        #expect(context.fakeActionContext.calls == [.closeLauncher])
        #expect(runner.invocations.count == 1)
        #expect(runner.invocations.first?.arguments == ["Lantern", "", "5 GHz"])
    }

    @Test func scriptThatShowsItsOutputPushesTheOutputScreenAndStartsOver() async throws {
        let runner = FakeScriptRunner([.printing("never")])
        let script = makeScript(mode: .fullOutput, arguments: [network, password])
        let model = makeModel(for: script, runner: runner)

        _ = try await enter("Lantern")
        let outcome = try await enter("hunter2")

        let request = ScriptSource.outputScreenRequest(
            running: script, arguments: ["Lantern", "hunter2"])
        #expect(outcome == .push(request))
        // The output screen starts the script.
        #expect(runner.invocations.isEmpty)
        #expect(context.fakeActionContext.calls.isEmpty)

        // Whoever comes back from the output finds the form as it was at first.
        #expect(model.values.isEmpty)
        #expect(context.searchText == "")
        #expect(placeholders().last == "Network")
        #expect(context.screenActions.map(\.title) == ["Continue"])
    }

    @Test func scriptThatWantsToBeConfirmedAsksAfterTheLastArgument() async throws {
        let runner = FakeScriptRunner([.printing("Joined\n")])
        let script = makeScript(arguments: [network, password], needsConfirmation: true)
        let model = makeModel(for: script, runner: runner)
        let actionContext = context.fakeActionContext

        _ = try await enter("Lantern")
        #expect(actionContext.confirmations.isEmpty)
        for action in context.screenActions {
            // Asked by the model, after it has looked at what was typed.
            #expect(action.confirmation == nil)
        }

        actionContext.confirmationAnswer = false
        #expect(try await enter("hunter2") == .keepOpen)
        #expect(
            actionContext.confirmations
                == [Confirmation(title: "Run “Join Network”?", confirmTitle: "Run")])
        #expect(runner.invocations.isEmpty)
        // Nothing is lost by saying no: the form is still on its last argument.
        #expect(model.values == ["Lantern"])
        #expect(context.searchText == "hunter2")

        actionContext.confirmationAnswer = true
        #expect(try await enter("hunter2") == .showHUD("Joined"))
        #expect(runner.invocations.first?.arguments == ["Lantern", "hunter2"])
    }

    @Test func emptyLastArgumentIsRefusedBeforeAnyQuestion() async throws {
        let script = makeScript(arguments: [network], needsConfirmation: true)
        let model = makeModel(for: script)

        #expect(try await enter("") == .keepOpen)

        #expect(model.notice == "Network is required")
        #expect(context.fakeActionContext.confirmations.isEmpty)
    }

    // MARK: Lifetime

    @Test func modelGoesWithItsScreen() async throws {
        weak var weakModel: ScriptArgumentModel?
        do {
            let model = makeModel(for: makeScript(arguments: [network, password]))
            weakModel = model
            _ = try await enter("Lantern")
        }
        #expect(weakModel != nil)

        context.close()

        #expect(weakModel == nil)
    }
}
