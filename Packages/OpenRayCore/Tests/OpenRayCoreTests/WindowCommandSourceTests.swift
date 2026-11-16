import CoreGraphics
import Testing

import OpenRayCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct WindowCommandSourceTests {
    private let host = FakeWindowHost()
    private let preferences = InMemoryPreferencesStore()
    private let context = FakeActionContext()

    private let safari = AppRef(pid: 4711, bundleID: "com.apple.Safari")

    private func commands() async throws -> [SearchItem] {
        let source = WindowCommandSource(host: host, preferences: preferences)
        var itemSets = source.indexedItems().makeAsyncIterator()
        return try #require(await itemSets.next())
    }

    /// The one action of the command for `action`.
    private func descriptor(for action: WindowAction) async throws -> ActionDescriptor {
        let id = ItemID(rawValue: "command:window.\(action.rawValue)")
        let item = try #require(try await commands().first { $0.id == id })
        #expect(item.actions.count == 1)
        return try #require(item.actions.first)
    }

    /// Runs the command as Return does once its permission is there.
    private func run(_ action: WindowAction) async throws -> ActionOutcome {
        try await descriptor(for: action).perform(context)
    }

    // MARK: The commands

    @Test func everyWindowActionIsACommand() async throws {
        let commands = try await commands()

        #expect(
            commands.map(\.id.rawValue) == [
                "command:window.leftHalf", "command:window.rightHalf", "command:window.topHalf",
                "command:window.bottomHalf", "command:window.topLeft", "command:window.topRight",
                "command:window.bottomLeft", "command:window.bottomRight",
                "command:window.firstThird", "command:window.centerThird",
                "command:window.lastThird", "command:window.firstTwoThirds",
                "command:window.lastTwoThirds", "command:window.maximize",
                "command:window.almostMaximize", "command:window.center",
                "command:window.nextDisplay", "command:window.previousDisplay",
                "command:window.restore",
            ])
        #expect(
            commands.map(\.title) == [
                "Left Half", "Right Half", "Top Half", "Bottom Half", "Top Left Quarter",
                "Top Right Quarter", "Bottom Left Quarter", "Bottom Right Quarter", "First Third",
                "Center Third", "Last Third", "First Two Thirds", "Last Two Thirds",
                "Maximize Window", "Almost Maximize Window", "Center Window",
                "Move Window to Next Display", "Move Window to Previous Display",
                "Restore Window",
            ])
        #expect(commands.allSatisfy { $0.kindLabel == "Window" })
    }

    // "Left Half" says nothing of windows, so the commands are also found by what they are.
    @Test func commandsAreFoundByWindowTileAndSnap() async throws {
        for command in try await commands() {
            #expect(command.alternateNames.map(\.text) == ["Window", "Tile", "Snap"])
        }
    }

    @Test func commandsNeedAccessibilityAndHaveNoShortcut() async throws {
        for command in try await commands() {
            #expect(command.actions.count == 1)
            for action in command.actions {
                #expect(action.requiredPermissions == [.accessibility])
                #expect(action.shortcut == nil)
                #expect(action.confirmation == nil)
            }
        }
    }

    @Test func itemsAreYieldedOnce() async throws {
        let source = WindowCommandSource(host: host, preferences: preferences)
        var itemSets = source.indexedItems().makeAsyncIterator()

        #expect(await itemSets.next()?.count == WindowAction.allCases.count)
        #expect(await itemSets.next() == nil)
    }

    // MARK: Running a command

    @Test func commandClosesTheLauncherAndMovesTheWindowOfTheAppItWasOpenedOver() async throws {
        context.previousApp = safari
        host.displays = [TestDisplays.primary, TestDisplays.lowerLeft]
        preferences.set(12, for: .windowGap)

        let outcome = try await run(.leftHalf)

        #expect(outcome == .closeLauncher)
        #expect(context.closeLauncherCount == 1)
        #expect(context.hudMessages.isEmpty)
        #expect(
            host.calls == [
                FakeWindowHost.Call(
                    action: .leftHalf, pid: 4711,
                    displays: [TestDisplays.primary, TestDisplays.lowerLeft], gap: 12,
                    stageStripInset: 0, isDockOnTheLeft: false)
            ])
    }

    @Test func hostIsToldThatTheDockIsOnTheLeft() async throws {
        context.previousApp = safari
        host.isDockOnTheLeft = true

        _ = try await run(.leftHalf)

        #expect(host.calls.map(\.isDockOnTheLeft) == [true])
    }

    @Test func stageStripInsetCountsWhileStageManagerIsOn() async throws {
        context.previousApp = safari
        preferences.set(64, for: .windowStageStripInset)

        host.isStageManagerOn = true
        _ = try await run(.maximize)
        host.isStageManagerOn = false
        _ = try await run(.maximize)

        #expect(host.calls.map(\.stageStripInset) == [64, 0])
    }

    @Test func gapAndInsetAreZeroUntilTheyAreSet() async throws {
        context.previousApp = safari
        host.isStageManagerOn = true

        _ = try await run(.maximize)

        #expect(host.calls.map(\.gap) == [0])
        #expect(host.calls.map(\.stageStripInset) == [0])
    }

    // The launcher was opened over the desktop of a Mac that had just started, say.
    @Test func commandWithoutAnAppToActOnSaysSoAndAsksNothingOfTheHost() async throws {
        context.previousApp = nil

        let outcome = try await run(.leftHalf)

        #expect(outcome == .showHUD("No window to move"))
        #expect(host.calls.isEmpty)
    }

    // MARK: What a command says when it moved nothing

    @Test(arguments: [
        (WindowError.noWindow, "No window to move"),
        (.appNotResponding, "App not responding"),
        (.fullScreen, "Full-screen windows cannot be moved"),
        (.notTrusted, "Accessibility is no longer allowed. Grant it in Settings › General."),
    ])
    func failureIsReportedInTheHUD(_ error: WindowError, _ message: String) async throws {
        context.previousApp = safari
        host.error = error

        #expect(try await run(.leftHalf) == .showHUD(message))
    }

    // Restore is among them: a window that is back where it was has nothing to say either.
    @Test(arguments: [WindowAction.leftHalf, .maximize, .center, .nextDisplay, .restore])
    func windowThatIsInPlaceAlreadyIsLeftWithoutAWord(_ action: WindowAction) async throws {
        context.previousApp = safari
        host.error = .unchanged

        #expect(try await run(action) == .closeLauncher)
    }

    @Test func restoreWithNothingToGoBackToSaysSo() async throws {
        context.previousApp = safari
        host.error = .nothingToRestore

        #expect(try await run(.restore) == .showHUD("No earlier position to restore"))
    }

    @Test(arguments: [WindowAction.nextDisplay, .previousDisplay])
    func displayMoveWithoutAnotherDisplaySaysSo(_ action: WindowAction) async throws {
        context.previousApp = safari
        host.error = .noOtherDisplay

        #expect(try await run(action) == .showHUD("No other display"))
    }

    // MARK: Without the permission

    @Test func commandWithoutAccessibilityLeadsToThePermissionScreenAndMovesNothing() async throws {
        context.previousApp = safari
        let checker = FakePermissionChecker()
        checker.states[.accessibility] = .denied
        let action = try await descriptor(for: .leftHalf)

        let ending = await ActionRunner.run(
            action, context: context, permissions: checker, recordPick: {})

        guard case .outcome(let outcome) = ending else {
            Issue.record("The command threw")
            return
        }
        #expect(outcome == .push(PermissionScreen.request(for: .accessibility)))
        #expect(host.calls.isEmpty)
        // Accessibility is granted in System Settings and never asked for with a prompt.
        #expect(checker.requested.isEmpty)
    }
}
