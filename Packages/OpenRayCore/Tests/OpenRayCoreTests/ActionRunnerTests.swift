import Testing

import OpenRayCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct ActionRunnerTests {
    private struct DiskFull: Error {}

    /// What happened, in order: what the action did, and what was asked of the launcher.
    @MainActor private final class Log {
        var events: [String] = []
    }

    private let context = FakeActionContext()
    private let checker = FakePermissionChecker()
    private let log = Log()

    private let finder = Permission.automation(bundleID: "com.apple.finder")
    private let emptyTheTrash = OpenRayCore.Confirmation(
        title: "Empty the Trash?", confirmTitle: "Empty")

    /// An action that records that it ran and returns `outcome`.
    private func action(
        confirmation: OpenRayCore.Confirmation? = nil, needs permissions: Set<Permission> = [],
        outcome: ActionOutcome = .closeLauncher
    ) -> ActionDescriptor {
        let log = log
        return ActionDescriptor(
            id: ActionID(rawValue: "run"), title: "Run", confirmation: confirmation,
            requiredPermissions: permissions
        ) { _ in
            log.events.append("performed")
            return outcome
        }
    }

    private func run(_ action: ActionDescriptor) async -> ActionRunner.Ending {
        let log = log
        return await ActionRunner.run(action, context: context, permissions: checker) {
            log.events.append("pick recorded")
        }
    }

    /// The outcome of a run that did not throw.
    private func outcome(of ending: ActionRunner.Ending) -> ActionOutcome? {
        if case .outcome(let outcome) = ending { return outcome }
        return nil
    }

    // MARK: Without conditions

    @Test func plainActionRecordsItsPickAndThenRuns() async {
        let ending = await run(action(outcome: .showHUD("Done")))

        #expect(outcome(of: ending) == .showHUD("Done"))
        #expect(log.events == ["pick recorded", "performed"])
        #expect(context.confirmations.isEmpty)
        #expect(context.closeLauncherCount == 0)
    }

    // MARK: Confirmation

    @Test func confirmedActionRuns() async {
        let ending = await run(action(confirmation: emptyTheTrash))

        #expect(context.confirmations == [emptyTheTrash])
        #expect(outcome(of: ending) == .closeLauncher)
        #expect(log.events == ["pick recorded", "performed"])
    }

    @Test func declinedActionDoesNotRunAndCountsNoPick() async {
        context.confirmationAnswer = false

        let ending = await run(action(confirmation: emptyTheTrash, needs: [finder]))

        #expect(outcome(of: ending) == .keepOpen)
        #expect(log.events.isEmpty)
        // The user said no before any permission was looked at.
        #expect(checker.requested.isEmpty)
    }

    // MARK: Permissions

    @Test func grantedPermissionLetsTheActionRunWithTheLauncherOpen() async {
        checker.states[finder] = .granted

        let ending = await run(action(needs: [finder]))

        #expect(outcome(of: ending) == .closeLauncher)
        #expect(log.events == ["pick recorded", "performed"])
        #expect(context.closeLauncherCount == 0)
        #expect(checker.requested.isEmpty)
    }

    @Test func undecidedPermissionIsRequestedWithTheLauncherClosedAndTheActionRunsIfGranted() async
    {
        checker.states[finder] = .notDetermined
        checker.stateAfterRequest = .granted

        let ending = await run(action(needs: [finder]))

        #expect(context.closeLauncherCount == 1)
        #expect(checker.requested == [finder])
        #expect(outcome(of: ending) == .closeLauncher)
        #expect(log.events == ["pick recorded", "performed"])
    }

    @Test func permissionRefusedAtThePromptStopsTheAction() async {
        checker.states[finder] = .notDetermined
        checker.stateAfterRequest = .denied

        let ending = await run(action(needs: [finder]))

        #expect(checker.requested == [finder])
        #expect(outcome(of: ending) == .keepOpen)
        #expect(log.events.isEmpty)
        // The user has just said no; there is nothing to add.
        #expect(context.hudMessages.isEmpty)
    }

    @Test func permissionThatCouldNotBeAskedForIsReportedInTheHUD() async {
        checker.states[finder] = .unknown
        checker.stateAfterRequest = .unknown

        let ending = await run(action(needs: [finder]))

        #expect(outcome(of: ending) == .keepOpen)
        #expect(log.events.isEmpty)
        #expect(
            context.hudMessages == ["OpenRay could not get the permission “Automation: Finder”."])
    }

    @Test func deniedPermissionLeadsToThePermissionScreenAndAsksNothing() async {
        checker.states[finder] = .denied

        let ending = await run(action(needs: [finder]))

        #expect(outcome(of: ending) == .push(PermissionScreen.request(for: finder)))
        #expect(checker.requested.isEmpty)
        #expect(context.closeLauncherCount == 0)
        #expect(log.events.isEmpty)
    }

    @Test func escapeWhileAPermissionIsReadStopsBeforeAnyPrompt() async {
        checker.states[finder] = .notDetermined
        // Esc cancels the task the action runs in.
        checker.whileReadingState = {
            withUnsafeCurrentTask { task in task?.cancel() }
        }
        let action = action(needs: [finder])

        // The run gets a task of its own to cancel; the test's task has to go on.
        let outcome = await Task { outcome(of: await run(action)) }.value

        #expect(outcome == .keepOpen)
        #expect(checker.requested.isEmpty)
        #expect(context.closeLauncherCount == 0)
        #expect(log.events.isEmpty)
    }

    // MARK: Errors

    @Test func errorFromTheActionIsHandedBackForTheLauncherToShow() async {
        let failing = ActionDescriptor(id: ActionID(rawValue: "save"), title: "Save") { _ in
            throw DiskFull()
        }

        let ending = await run(failing)

        guard case .failure(let error) = ending else {
            Issue.record("The run ended with an outcome, not with the action's error")
            return
        }
        #expect(error is DiskFull)
    }

    @Test func actionThatStopsBecauseItWasCancelledHasNotFailed() async {
        let cancelled = ActionDescriptor(id: ActionID(rawValue: "wait"), title: "Wait") { _ in
            throw CancellationError()
        }

        let ending = await run(cancelled)

        #expect(outcome(of: ending) == .keepOpen)
    }
}
