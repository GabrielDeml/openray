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

    private func makeModel(
        with furtherItems: [SearchItem] = [], followTime: Duration = .seconds(120)
    ) -> PermissionListModel {
        let items =
            [
                command("Empty Trash", needs: finder),
                command("Toggle Appearance", needs: systemEvents),
            ] + furtherItems
        return PermissionListModel(
            checker: checker, currentItems: { items }, followInterval: .milliseconds(1),
            followTime: followTime)
    }

    private func state(of permission: Permission, in model: PermissionListModel)
        -> PermissionState?
    {
        model.rows.first { $0.permission == permission }?.state
    }

    @Test func listIsEmptyUntilItIsRead() {
        #expect(makeModel().rows.isEmpty)
    }

    @Test func refreshListsEveryPermissionWithItsStateAndCommands() async {
        checker.states = [.accessibility: .denied, finder: .granted, systemEvents: .denied]
        let model = makeModel()

        await model.refresh()

        #expect(model.rows.map(\.permission) == [.accessibility, finder, systemEvents])
        #expect(model.rows.map(\.state) == [.denied, .granted, .denied])
        #expect(model.rows[1].commandTitles == ["Empty Trash"])
    }

    // Pasting uses Accessibility without requiring it, so no command brings it into the list.
    @Test func accessibilityIsListedForPastingThoughNoCommandRequiresIt() async {
        let model = makeModel()

        await model.refresh()

        let accessibility = model.rows.first
        #expect(accessibility?.permission == .accessibility)
        #expect(accessibility?.commandTitles == ["Pasting into the app you came from"])
    }

    @Test func commandsThatRequireAccessibilityShareItsRowWithPasting() async {
        let model = makeModel(with: [command("Left Half", needs: .accessibility)])

        await model.refresh()

        let accessibilityRows = model.rows.filter { $0.permission == .accessibility }
        #expect(accessibilityRows.count == 1)
        #expect(
            accessibilityRows.first?.commandTitles == [
                "Pasting into the app you came from", "Left Half",
            ])
    }

    // What the shipped commands bring into the row: Lock Screen and the window commands.
    @Test func accessibilityRowNamesLockScreenAndTheWindowCommandsAfterPasting() async throws {
        let systemCommands = SystemCommandSource(control: FakeSystemControl())
        let windowCommands = WindowCommandSource(
            host: FakeWindowHost(), preferences: InMemoryPreferencesStore())
        var systemItemSets = systemCommands.indexedItems().makeAsyncIterator()
        var windowItemSets = windowCommands.indexedItems().makeAsyncIterator()
        let systemItems = try #require(await systemItemSets.next())
        let windowItems = try #require(await windowItemSets.next())
        let model = PermissionListModel(
            checker: checker, currentItems: { systemItems + windowItems })

        await model.refresh()

        let uses = try #require(model.rows.first { $0.permission == .accessibility }).commandTitles
        #expect(
            uses.prefix(4) == [
                "Pasting into the app you came from", "Lock Screen", "Left Half", "Right Half",
            ])
        #expect(uses.last == "Restore Window")
    }

    // MARK: The summary of a row

    private func accessibilitySummary(withCommands titles: [String]) async -> String? {
        var commands: [SearchItem] = []
        for title in titles {
            commands.append(command(title, needs: .accessibility))
        }
        let model = makeModel(with: commands)
        await model.refresh()
        return model.rows.first { $0.permission == .accessibility }?.summary
    }

    @Test func summaryOfOneUseIsThatUse() async {
        let summary = await accessibilitySummary(withCommands: [])

        #expect(summary == "Pasting into the app you came from")
    }

    @Test func summaryNamesUpToThreeUses() async {
        let summary = await accessibilitySummary(withCommands: ["Left Half", "Right Half"])

        // The list is put together as the user's language does it, with or without a comma
        // before the "and".
        let named = ["Pasting into the app you came from", "Left Half", "Right Half"]
        #expect(summary == named.formatted(.list(type: .and)))
    }

    @Test func summaryNamesThreeUsesAndCountsTheRest() async {
        var titles: [String] = []
        for number in 1...19 {
            titles.append("Command \(number)")
        }

        let summary = await accessibilitySummary(withCommands: titles)

        let parts = ["Pasting into the app you came from", "Command 1", "Command 2", "17 more"]
        #expect(summary == parts.formatted(.list(type: .and)))
    }

    @Test func grantAsksForAPermissionThatWasNeverAskedFor() async {
        checker.states = [finder: .notDetermined]
        let model = makeModel()
        await model.refresh()

        await model.grant(finder)

        #expect(checker.requested == [finder])
        #expect(state(of: finder, in: model) == .granted)
    }

    @Test func accessibilityIsGrantedInSystemSettingsAndNeverRequested() async {
        checker.states = [.accessibility: .denied]
        let model = makeModel()
        await model.refresh()

        await model.grant(.accessibility)

        #expect(checker.openedSettingsFor == [.accessibility])
        #expect(checker.requested.isEmpty)
    }

    // Nothing tells an app that a permission was switched on in System Settings.
    @Test func rowFollowsThePermissionAfterTheUserWasSentToSystemSettings() async {
        checker.states = [.accessibility: .denied]
        let model = makeModel()
        await model.refresh()
        await model.grant(.accessibility)
        #expect(state(of: .accessibility, in: model) == .denied)

        checker.states[.accessibility] = .granted
        while state(of: .accessibility, in: model) != .granted {
            await Task.yield()
        }
    }

    @Test func followingEndsOnceThePermissionIsGranted() async {
        checker.states = [.accessibility: .denied]
        let model = makeModel()
        await model.refresh()
        await model.grant(.accessibility)
        checker.states[.accessibility] = .granted
        while state(of: .accessibility, in: model) != .granted {
            await Task.yield()
        }

        var readCount = 0
        checker.whileReadingState = { readCount += 1 }
        try? await Task.sleep(for: .milliseconds(20))

        #expect(readCount == 0)
    }

    @Test func everyPermissionTheUserWasSentToSettingsForIsFollowed() async {
        checker.states = [.accessibility: .denied, systemEvents: .denied]
        let model = makeModel()
        await model.refresh()

        await model.grant(.accessibility)
        await model.grant(systemEvents)
        checker.states = [.accessibility: .granted, systemEvents: .granted]

        // The second button does not end the following of the first.
        while state(of: .accessibility, in: model) != .granted
            || state(of: systemEvents, in: model) != .granted
        {
            await Task.yield()
        }
    }

    // A refresh takes as long as macOS takes to answer for every permission. If it kept what
    // it read to the end, it would put an old state back over one the row was given meanwhile.
    @Test func refreshShowsEachStateAsSoonAsItHasReadIt() async {
        checker.states = [.accessibility: .denied]
        let model = makeModel()
        await model.refresh()

        checker.states[.accessibility] = .granted
        var readCount = 0
        var accessibilityWhileTheNextWasRead: PermissionState?
        checker.whileReadingState = {
            readCount += 1
            // The second read is Finder's. Accessibility is listed first and has been read
            // by then.
            if readCount == 2 {
                accessibilityWhileTheNextWasRead = state(of: .accessibility, in: model)
            }
        }
        await model.refresh()

        #expect(accessibilityWhileTheNextWasRead == .granted)
    }

    @Test func rowIsNotFollowedForLongerThanTheFollowTime() async {
        checker.states = [.accessibility: .denied]
        let model = makeModel(followTime: .milliseconds(10))
        await model.refresh()
        await model.grant(.accessibility)

        try? await Task.sleep(for: .milliseconds(60))
        var readCount = 0
        checker.whileReadingState = { readCount += 1 }
        try? await Task.sleep(for: .milliseconds(20))

        #expect(readCount == 0)
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
