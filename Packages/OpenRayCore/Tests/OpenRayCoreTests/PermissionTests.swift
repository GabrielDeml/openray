import Testing

import OpenRayCore

private let finder = Permission.automation(bundleID: "com.apple.finder")
private let systemEvents = Permission.automation(bundleID: "com.apple.systemevents")

@Suite struct PermissionGateTests {
    @Test(arguments: [Permission.accessibility, finder])
    func grantedPermissionLetsTheActionRun(_ permission: Permission) {
        #expect(PermissionGate.step(for: permission, state: .granted) == .proceed)
    }

    @Test func automationThatWasNeverAskedForIsRequested() {
        #expect(PermissionGate.step(for: finder, state: .notDetermined) == .request)
    }

    @Test func automationOfATargetThatIsNotRunningIsRequestedToo() {
        // System Events is usually not running. Requesting launches it.
        #expect(PermissionGate.step(for: systemEvents, state: .unknown) == .request)
    }

    @Test func deniedAutomationIsExplained() {
        #expect(PermissionGate.step(for: finder, state: .denied) == .explain)
    }

    @Test(arguments: [PermissionState.denied, .notDetermined, .unknown])
    func accessibilityThatIsNotGrantedIsExplained(_ state: PermissionState) {
        #expect(PermissionGate.step(for: .accessibility, state: state) == .explain)
    }
}

@Suite struct AutomationPermissionTests {
    @Test func statusCodesMapToStates() {
        #expect(AutomationPermission.state(forStatus: 0) == .granted)
        #expect(AutomationPermission.state(forStatus: -1743) == .denied)
        #expect(AutomationPermission.state(forStatus: -1744) == .notDetermined)
    }

    @Test func targetThatIsNotRunningAndUnexpectedCodesAreUnknown() {
        #expect(AutomationPermission.state(forStatus: -600) == .unknown)
        #expect(AutomationPermission.state(forStatus: -1712) == .unknown)
        #expect(AutomationPermission.state(forStatus: 1) == .unknown)
    }
}

@Suite struct PermissionScreenRequestTests {
    @Test(arguments: [Permission.accessibility, finder, systemEvents])
    func permissionSurvivesTheTripThroughAScreenRequest(_ permission: Permission) {
        let request = PermissionScreen.request(for: permission)

        #expect(request.feature == PermissionScreen.feature)
        #expect(request.screen == PermissionScreen.name)
        #expect(request.argument.flatMap(Permission.init(screenArgument:)) == permission)
    }

    @Test func argumentsAreStoredAsReadableText() {
        #expect(Permission.accessibility.screenArgument == "accessibility")
        #expect(finder.screenArgument == "automation:com.apple.finder")
    }

    @Test(arguments: ["", "automation:", "automation", "camera", "Accessibility"])
    func unknownArgumentIsNoPermission(_ argument: String) {
        #expect(Permission(screenArgument: argument) == nil)
    }
}

@Suite struct PermissionUseTests {
    private func command(_ title: String, needs permissions: Set<Permission>...) -> SearchItem {
        var actions: [ActionDescriptor] = []
        for (index, required) in permissions.enumerated() {
            let action = ActionDescriptor(
                id: ActionID(rawValue: "action-\(index)"), title: "Run",
                requiredPermissions: required
            ) { _ in .closeLauncher }
            actions.append(action)
        }
        return SearchItem(
            id: .system(title), title: title, icon: .symbol("gear"), kindLabel: "Command",
            actions: actions)
    }

    @Test func permissionsAreCollectedFromTheActionsWithTheCommandsThatNeedThem() {
        let items = [
            command("Sleep", needs: []),
            command("Empty Trash", needs: [finder]),
            command("Toggle Appearance", needs: [systemEvents]),
            command("Eject All", needs: [], [finder]),
        ]

        let uses = PermissionUse.uses(in: items)

        #expect(
            uses == [
                PermissionUse(permission: finder, commandTitles: ["Empty Trash", "Eject All"]),
                PermissionUse(permission: systemEvents, commandTitles: ["Toggle Appearance"]),
            ])
    }

    @Test func commandIsNamedOnceEvenWhenTwoOfItsActionsNeedThePermission() {
        let items = [command("Empty Trash", needs: [finder], [finder])]

        #expect(PermissionUse.uses(in: items).first?.commandTitles == ["Empty Trash"])
    }

    @Test func accessibilityIsListedBeforeTheAutomationTargets() {
        let items = [command("Paste", needs: [systemEvents, .accessibility, finder])]

        let permissions = PermissionUse.uses(in: items).map(\.permission)

        #expect(permissions == [.accessibility, finder, systemEvents])
        #expect(Permission.sorted([systemEvents, .accessibility, finder]) == permissions)
    }

    @Test func itemsWithoutPermissionsGiveNoUses() {
        #expect(PermissionUse.uses(in: [command("Sleep", needs: [])]).isEmpty)
    }

    @Test func knownAutomationTargetsHaveNamesAndOthersTheirBundleID() {
        #expect(Permission.automationTargetName(forBundleID: "com.apple.finder") == "Finder")
        #expect(Permission.automationTargetName(forBundleID: "example.app") == "example.app")
        #expect(finder.title == "Automation: Finder")
        #expect(Permission.accessibility.title == "Accessibility")
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PermissionScreenModelTests {
    private let checker = FakePermissionChecker()
    private let context = FakeScreenContext(request: PermissionScreen.request(for: finder))

    private func makeModel() -> PermissionScreenModel {
        PermissionScreenModel(
            permission: finder, commandTitles: ["Empty Trash"], checker: checker,
            context: context)
    }

    private var actionTitles: [String] {
        context.screenActions.map(\.title)
    }

    @Test func screenStartsWithGrantUntilTheStateIsKnown() {
        let model = makeModel()

        #expect(model.state == .unknown)
        #expect(actionTitles == ["Grant"])
    }

    @Test func refreshReadsTheStateAndOffersWhatHelpsFromThere() async {
        let model = makeModel()

        checker.states[finder] = .denied
        await model.refresh()
        #expect(model.state == .denied)
        #expect(actionTitles == ["Open System Settings"])

        checker.states[finder] = .granted
        await model.refresh()
        #expect(model.state == .granted)
        #expect(actionTitles == ["Done"])
    }

    @Test func grantClosesTheLauncherBeforeItAsksAndTakesTheAnswer() async throws {
        let model = makeModel()
        checker.states[finder] = .notDetermined
        await model.refresh()
        let grant = try #require(context.screenActions.first)

        let outcome = try await grant.perform(context.fakeActionContext)

        #expect(outcome == .closeLauncher)
        #expect(context.fakeActionContext.closeLauncherCount == 1)
        #expect(checker.requested == [finder])
        #expect(model.state == .granted)
        #expect(actionTitles == ["Done"])
    }

    @Test func deniedPermissionLeadsToSystemSettings() async throws {
        let model = makeModel()
        checker.states[finder] = .denied
        await model.refresh()
        let openSettings = try #require(context.screenActions.first)

        let outcome = try await openSettings.perform(context.fakeActionContext)

        #expect(outcome == .closeLauncher)
        #expect(context.fakeActionContext.closeLauncherCount == 1)
        #expect(checker.openedSettingsFor == [finder])
        #expect(checker.requested.isEmpty)
    }

    @Test func doneGoesBackToTheRoot() async throws {
        let model = makeModel()
        checker.states[finder] = .granted
        await model.refresh()
        let done = try #require(context.screenActions.first)

        #expect(try await done.perform(context.fakeActionContext) == .popToRoot)
    }

    // Hiding the launcher pops nothing, so the screen can sit on the stack unseen.
    @Test func stateIsNotReadWhileTheScreenIsOffScreen() async {
        let model = makeModel()
        checker.states[finder] = .denied
        var readCount = 0
        checker.whileReadingState = { readCount += 1 }

        context.isOnScreen = false
        model.followState(every: .milliseconds(1))
        for _ in 1...50 {
            await Task.yield()
        }
        #expect(readCount == 0)
        #expect(model.state == .unknown)

        context.isOnScreen = true
        while model.state != .denied {
            await Task.yield()
        }
        #expect(readCount > 0)
    }

    @Test func explanationNamesTheCommandsAndTheTarget() {
        let model = makeModel()

        #expect(
            model.explanation
                == "Empty Trash works by sending a command to Finder, and macOS asks for your permission first."
        )
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PermissionListModelTests {
    private let checker = FakePermissionChecker()

    private func command(_ title: String, needs permission: Permission) -> SearchItem {
        let action = ActionDescriptor(
            id: ActionID(rawValue: "run"), title: title, requiredPermissions: [permission]
        ) { _ in .closeLauncher }
        return SearchItem(
            id: .system(title), title: title, icon: .symbol("gear"), kindLabel: "System",
            actions: [action])
    }

    private func makeModel() -> PermissionListModel {
        let items = [
            command("Empty Trash", needs: finder),
            command("Toggle Appearance", needs: systemEvents),
        ]
        return PermissionListModel(checker: checker, currentItems: { items })
    }

    @Test func listIsEmptyUntilItIsRead() {
        #expect(makeModel().rows.isEmpty)
    }

    @Test func refreshListsEveryPermissionWithItsStateAndCommands() async {
        checker.states = [finder: .granted, systemEvents: .denied]
        let model = makeModel()

        await model.refresh()

        #expect(model.rows.map(\.permission) == [finder, systemEvents])
        #expect(model.rows.map(\.state) == [.granted, .denied])
        #expect(model.rows.first?.commandTitles == ["Empty Trash"])
    }

    @Test func grantAsksForAPermissionThatWasNeverAskedFor() async {
        checker.states = [finder: .notDetermined]
        let model = makeModel()
        await model.refresh()

        await model.grant(finder)

        #expect(checker.requested == [finder])
        #expect(model.rows.first?.state == .granted)
    }

    @Test func grantOfADeniedPermissionLeadsToSystemSettings() async {
        checker.states = [systemEvents: .denied]
        let model = makeModel()
        await model.refresh()

        await model.grant(systemEvents)

        #expect(checker.openedSettingsFor == [systemEvents])
        #expect(checker.requested.isEmpty)
    }

    @Test func grantOfAGrantedPermissionDoesNothing() async {
        checker.states = [finder: .granted]
        let model = makeModel()
        await model.refresh()

        await model.grant(finder)

        #expect(checker.requested.isEmpty)
        #expect(checker.openedSettingsFor.isEmpty)
    }
}
