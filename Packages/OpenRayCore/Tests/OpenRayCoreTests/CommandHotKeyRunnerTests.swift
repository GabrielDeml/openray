import Foundation
import Testing

import OpenRayCore

// A press runs against `FakeHotKeyPressHost`, which stands for the launcher's window: nothing
// is shown, pasted or asked of macOS.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CommandHotKeyRunnerTests {
    private struct DiskFull: LocalizedError {
        var errorDescription: String? { "The disk is full." }
    }

    /// How often the actions of the test's items ran, and what the last one saw.
    @MainActor private final class Runs {
        var count = 0
        /// The IDs of the actions that ran, for the test that tells them apart.
        var ranActions: [String] = []
        var previousApp: AppRef?
        var query: String?
    }

    /// An item whose action the test can hold open.
    private struct HeldItem {
        let item: SearchItem
        /// Gets an element each time the action has started.
        let started: AsyncStream<Void>
        /// An element lets one run of the action return.
        let release: AsyncStream<Void>.Continuation
    }

    private let host = FakeHotKeyPressHost()
    private let checker = FakePermissionChecker()
    private let runs = Runs()
    private let runner: CommandHotKeyRunner

    private let sleep = ItemID.system("sleep")
    private let finder = Permission.automation(bundleID: "com.apple.finder")
    private let shutDown = OpenRayCore.Confirmation(title: "Shut Down?", confirmTitle: "Shut Down")
    private let argumentScreen = ScreenRequest(
        feature: FeatureID(rawValue: "quicklinks"), screen: "argument", argument: "wiki")
    private let outputScreen = ScreenRequest(
        feature: FeatureID(rawValue: "scripts"), screen: "output", argument: "/tmp/backup.sh")

    init() {
        runner = CommandHotKeyRunner(host: host, permissions: checker)
    }

    private func item(_ id: ItemID, actions: [ActionDescriptor]) -> SearchItem {
        SearchItem(
            id: id, title: "Command", icon: .symbol("gear"), kindLabel: "Command",
            actions: actions)
    }

    /// An item whose primary action counts that it ran and returns `outcome`.
    private func item(
        confirmation: OpenRayCore.Confirmation? = nil, needs permissions: Set<Permission> = [],
        outcome: ActionOutcome = .closeLauncher
    ) -> SearchItem {
        let runs = runs
        let action = ActionDescriptor(
            id: ActionID(rawValue: "run"), title: "Run", confirmation: confirmation,
            requiredPermissions: permissions
        ) { _ in
            runs.count += 1
            return outcome
        }
        return item(sleep, actions: [action])
    }

    // MARK: Outcomes

    @Test func actionThatClosesTheLauncherRunsWithoutItEverShowing() async {
        await runner.press(item(outcome: .closeLauncher))

        #expect(runs.count == 1)
        #expect(host.calls == [.hideLauncher])
        #expect(host.contexts.count == 1)
    }

    @Test func hudTextIsShownAfterTheLauncherIsHidden() async {
        await runner.press(item(outcome: .showHUD("Moved to the left half")))

        #expect(host.calls == [.hideLauncher, .showHUD("Moved to the left half")])
    }

    @Test func actionThatPushesAScreenShowsTheLauncherOnIt() async {
        await runner.press(item(outcome: .push(argumentScreen)))

        #expect(runs.count == 1)
        #expect(host.calls == [.showLauncherOnScreen(argumentScreen)])
    }

    // With the launcher open on something else, the screen still has to end up on top of
    // root search, so the host is asked the same way.
    @Test func screenIsShownAnewWhenTheLauncherIsOpenOnSomethingElse() async {
        host.showLauncher(on: outputScreen)

        await runner.press(item(outcome: .push(argumentScreen)))

        #expect(
            host.calls == [
                .showLauncherOnScreen(outputScreen), .showLauncherOnScreen(argumentScreen),
            ])
    }

    // The second press of a fullOutput script's hotkey. Its output screen is up and the
    // script runs there; showing the screen anew would stop the script and start it again.
    @Test func screenThatIsAlreadyOnTopIsLeftAsItIs() async {
        await runner.press(item(outcome: .push(outputScreen)))

        await runner.press(item(outcome: .push(outputScreen)))

        #expect(runs.count == 2)
        #expect(host.calls == [.showLauncherOnScreen(outputScreen)])
    }

    // The launcher keeps its screens while it is hidden, so what is on top there does not
    // count.
    @Test func screenOfAHiddenLauncherIsShownAnew() async {
        await runner.press(item(outcome: .push(outputScreen)))
        host.hideLauncher()

        await runner.press(item(outcome: .push(outputScreen)))

        #expect(
            host.calls == [
                .showLauncherOnScreen(outputScreen), .hideLauncher,
                .showLauncherOnScreen(outputScreen),
            ])
    }

    @Test func actionThatReplacesTheQueryShowsTheLauncherWithTheText() async {
        await runner.press(item(outcome: .replaceQuery("2 + 2")))

        #expect(host.calls == [.showLauncherWithQuery("2 + 2")])
    }

    @Test(arguments: [ActionOutcome.keepOpen, .popToRoot])
    func outcomeThatLeavesTheLauncherAloneAsksNothingOfTheHost(outcome: ActionOutcome) async {
        await runner.press(item(outcome: outcome))

        #expect(runs.count == 1)
        #expect(host.calls.isEmpty)

        // The same with the launcher open: it stays as it is.
        host.isLauncherVisible = true
        await runner.press(item(outcome: outcome))

        #expect(host.calls.isEmpty)
    }

    @Test func onlyThePrimaryActionRuns() async {
        let runs = runs
        let primary = ActionDescriptor(id: ActionID(rawValue: "open"), title: "Open") { _ in
            runs.ranActions.append("open")
            return .closeLauncher
        }
        let secondary = ActionDescriptor(id: ActionID(rawValue: "trash"), title: "Trash") { _ in
            runs.ranActions.append("trash")
            return .closeLauncher
        }

        await runner.press(item(sleep, actions: [primary, secondary]))

        #expect(runs.ranActions == ["open"])
    }

    @Test func itemWithoutActionsDoesNothing() async {
        await runner.press(item(sleep, actions: []))

        #expect(host.calls.isEmpty)
        #expect(host.contexts.isEmpty)
    }

    // MARK: Confirmations

    @Test func confirmationBringsTheLauncherUpBeforeItAsks() async {
        await runner.press(item(confirmation: shutDown, outcome: .closeLauncher))

        #expect(host.calls == [.showLauncher, .askedToConfirm, .hideLauncher])
        #expect(host.contexts.first?.confirmations == [shutDown])
        #expect(runs.count == 1)
    }

    @Test func launcherThatCameUpToAskGoesAgainAfterANo() async {
        host.confirmationAnswer = false

        await runner.press(item(confirmation: shutDown))

        #expect(runs.count == 0)
        #expect(host.calls == [.showLauncher, .askedToConfirm, .hideLauncher])
    }

    @Test func launcherThatCameUpToAskGoesAgainWhenTheOutcomeDoesNotNeedIt() async {
        await runner.press(item(confirmation: shutDown, outcome: .keepOpen))

        #expect(runs.count == 1)
        #expect(host.calls == [.showLauncher, .askedToConfirm, .hideLauncher])
    }

    @Test func openLauncherIsAskedInAndLeftAsItIsAfterANo() async {
        host.isLauncherVisible = true
        host.confirmationAnswer = false

        await runner.press(item(confirmation: shutDown))

        #expect(runs.count == 0)
        #expect(host.calls == [.askedToConfirm])
        #expect(host.isLauncherVisible)
    }

    // A script that has not been cleared to run asks from inside its action, where the
    // descriptor says nothing about a confirmation.
    @Test func questionAskedFromInsideTheActionBringsTheLauncherUpToo() async {
        host.confirmationAnswer = false
        let question = shutDown
        let asking = ActionDescriptor(id: ActionID(rawValue: "run"), title: "Run") { context in
            let isConfirmed = await context.confirm(question)
            return isConfirmed ? .closeLauncher : .keepOpen
        }

        await runner.press(item(sleep, actions: [asking]))

        #expect(host.calls == [.showLauncher, .askedToConfirm, .hideLauncher])
        #expect(host.contexts.first?.confirmations == [shutDown])
    }

    // MARK: Permissions

    @Test func missingAccessibilityPermissionShowsTheLauncherOnThePermissionScreen() async {
        checker.states[.accessibility] = .denied

        await runner.press(item(needs: [.accessibility]))

        #expect(runs.count == 0)
        #expect(
            host.calls == [.showLauncherOnScreen(PermissionScreen.request(for: .accessibility))])
    }

    @Test func permissionGrantedAtThePromptLetsTheActionRunWithoutTheLauncher() async {
        checker.states[finder] = .notDetermined
        checker.stateAfterRequest = .granted

        await runner.press(item(needs: [finder], outcome: .showHUD("Trash emptied")))

        #expect(checker.requested == [finder])
        #expect(runs.count == 1)
        #expect(host.calls == [.hideLauncher, .showHUD("Trash emptied")])
    }

    @Test func permissionRefusedAtThePromptEndsThePressQuietly() async {
        checker.states[finder] = .notDetermined
        checker.stateAfterRequest = .denied

        await runner.press(item(needs: [finder]))

        #expect(runs.count == 0)
        #expect(host.calls.isEmpty)
    }

    // MARK: Errors

    @Test func errorFromTheActionIsShownInTheHUD() async {
        let failing = ActionDescriptor(id: ActionID(rawValue: "save"), title: "Save") { _ in
            throw DiskFull()
        }

        await runner.press(item(sleep, actions: [failing]))

        #expect(host.calls == [.showHUD("The disk is full.")])
    }

    @Test func errorAfterAConfirmationHidesTheLauncherThatCameUpToAsk() async {
        let failing = ActionDescriptor(
            id: ActionID(rawValue: "save"), title: "Save", confirmation: shutDown
        ) { _ in
            throw DiskFull()
        }

        await runner.press(item(sleep, actions: [failing]))

        #expect(
            host.calls == [
                .showLauncher, .askedToConfirm, .hideLauncher, .showHUD("The disk is full."),
            ])
    }

    @Test func cancelledActionShowsNothing() async {
        let cancelled = ActionDescriptor(id: ActionID(rawValue: "run"), title: "Run") { _ in
            throw CancellationError()
        }

        await runner.press(item(sleep, actions: [cancelled]))

        #expect(host.calls.isEmpty)
    }

    // MARK: The context of the action

    @Test func actionSeesTheAppThatWasInFrontAtThePress() async {
        let textEdit = AppRef(pid: 4_242, bundleID: "com.apple.TextEdit")
        host.frontmostApp = textEdit
        let runs = runs
        let looking = ActionDescriptor(id: ActionID(rawValue: "run"), title: "Run") { context in
            runs.previousApp = context.previousApp
            runs.query = context.query
            return .keepOpen
        }

        await runner.press(item(sleep, actions: [looking]))

        #expect(runs.previousApp == textEdit)
        #expect(runs.query == "")
    }

    @Test func whatTheActionAsksOfItsContextReachesTheHostsContext() async throws {
        let text = PasteContent.text("Kind regards", cursorOffsetFromEnd: nil)
        let pasting = ActionDescriptor(id: ActionID(rawValue: "paste"), title: "Paste") {
            context in
            context.closeLauncher()
            _ = await context.clipboardText()
            context.copy(text)
            _ = await context.paste(text)
            context.showHUD("Pasted")
            return .keepOpen
        }

        await runner.press(item(sleep, actions: [pasting]))

        let context = try #require(host.contexts.first)
        #expect(context.calls == [.closeLauncher, .readClipboard, .copy, .paste])
        #expect(context.copied == [text])
        #expect(context.pasted == [text])
        #expect(context.hudMessages == ["Pasted"])
    }

    // MARK: Presses that overlap

    /// An item whose action waits inside `perform` until the test lets it go, and then
    /// returns `outcome`. It copies its own ID first, so that a test sees which context it
    /// was given.
    private func heldItem(
        _ id: ItemID, confirmation: OpenRayCore.Confirmation? = nil,
        outcome: ActionOutcome = .keepOpen
    ) -> HeldItem {
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (releases, release) = AsyncStream.makeStream(of: Void.self)
        let runs = runs

        let action = ActionDescriptor(
            id: ActionID(rawValue: "run"), title: "Run", confirmation: confirmation
        ) { context in
            runs.count += 1
            context.copy(.text(id.rawValue, cursorOffsetFromEnd: nil))
            startedContinuation.yield()
            for await _ in releases { break }
            return outcome
        }
        return HeldItem(item: item(id, actions: [action]), started: started, release: release)
    }

    @Test func secondPressIsIgnoredWhileTheFirstIsStillRunning() async {
        let script = heldItem(.script(path: "/tmp/backup.sh"))
        let runner = runner

        let firstPress = Task { await runner.press(script.item) }
        for await _ in script.started { break }

        await runner.press(script.item)
        #expect(runs.count == 1)
        #expect(host.contexts.count == 1)

        script.release.yield()
        await firstPress.value

        // Once the first has ended, a press runs the action again.
        script.release.yield()
        await runner.press(script.item)
        #expect(runs.count == 2)
    }

    @Test func twoItemsRunSideBySideEachWithAContextOfItsOwn() async {
        let backup = heldItem(.script(path: "/tmp/backup.sh"))
        let upload = heldItem(.script(path: "/tmp/upload.sh"))
        let runner = runner

        let backupPress = Task { await runner.press(backup.item) }
        for await _ in backup.started { break }
        let uploadPress = Task { await runner.press(upload.item) }
        for await _ in upload.started { break }

        // Both are inside their actions now.
        #expect(runs.count == 2)
        #expect(host.contexts.count == 2)
        #expect(
            host.contexts[0].copied == [.text(backup.item.id.rawValue, cursorOffsetFromEnd: nil)])
        #expect(
            host.contexts[1].copied == [.text(upload.item.id.rawValue, cursorOffsetFromEnd: nil)])

        backup.release.yield()
        upload.release.yield()
        await backupPress.value
        await uploadPress.value
    }

    // MARK: A launcher that was opened while the action ran

    // An action can end long after the press. Whoever opened the launcher in that time is
    // using it for something else.

    @Test func launcherShownWhileTheActionRanIsNotHiddenWhenTheActionEnds() async {
        let app = heldItem(.app(bundleID: "com.apple.Safari"), outcome: .closeLauncher)
        let runner = runner

        let press = Task { await runner.press(app.item) }
        for await _ in app.started { break }
        host.showLauncher()
        app.release.yield()
        await press.value

        #expect(host.calls == [.showLauncher])
        #expect(host.isLauncherVisible)
    }

    @Test func hudTextIsStillShownOverALauncherThatWasShownMeanwhile() async {
        let script = heldItem(
            .script(path: "/tmp/backup.sh"), outcome: .showHUD("Backup finished"))
        let runner = runner

        let press = Task { await runner.press(script.item) }
        for await _ in script.started { break }
        host.showLauncher()
        script.release.yield()
        await press.value

        #expect(host.calls == [.showLauncher, .showHUD("Backup finished")])
        #expect(host.isLauncherVisible)
    }

    // The launcher came up to ask, the answer was yes, Esc hid it while the action ran, and
    // it was then opened again.
    @Test func launcherThatCameUpToAskIsNotHiddenOnceItWasShownAgain() async {
        let script = heldItem(.script(path: "/tmp/backup.sh"), confirmation: shutDown)
        let runner = runner

        let press = Task { await runner.press(script.item) }
        for await _ in script.started { break }
        host.hideLauncher()
        host.showLauncher()
        script.release.yield()
        await press.value

        #expect(
            host.calls == [.showLauncher, .askedToConfirm, .hideLauncher, .showLauncher])
        #expect(host.isLauncherVisible)
    }

    // The launcher was open at the press and nothing showed it again: it is the one the
    // press knows, and the ending hides it as Return's would.
    @Test func launcherThatWasOpenAtThePressIsHiddenWhenALateActionEnds() async {
        host.showLauncher()
        let app = heldItem(.app(bundleID: "com.apple.Safari"), outcome: .closeLauncher)
        let runner = runner

        let press = Task { await runner.press(app.item) }
        for await _ in app.started { break }
        app.release.yield()
        await press.value

        #expect(host.calls == [.showLauncher, .hideLauncher])
    }
}
