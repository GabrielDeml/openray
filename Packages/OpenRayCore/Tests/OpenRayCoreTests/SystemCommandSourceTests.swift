import Testing

@testable import OpenRayCore

/// Records what the system commands ask for and does none of it.
@MainActor private final class FakeSystemControl: SystemControl {
    struct SleepRefused: Error {}

    private(set) var calls: [String] = []
    var sleepFails = false

    private let apps: AsyncStream<[RunningApp]>
    private let appsContinuation: AsyncStream<[RunningApp]>.Continuation

    init() {
        (apps, appsContinuation) = AsyncStream.makeStream(of: [RunningApp].self)
    }

    /// What the workspace does when an app launches or quits.
    func report(runningApps: [RunningApp]) {
        appsContinuation.yield(runningApps)
    }

    func sleep() throws {
        if sleepFails { throw SleepRefused() }
        calls.append("sleep")
    }

    func restart() async throws { calls.append("restart") }
    func shutDown() async throws { calls.append("shutDown") }
    func logOut() async throws { calls.append("logOut") }
    func emptyTrash() async throws { calls.append("emptyTrash") }
    func toggleAppearance() async throws { calls.append("toggleAppearance") }

    func runningApps() -> AsyncStream<[RunningApp]> { apps }

    func quit(_ app: RunningApp) { calls.append("quit \(app.bundleID)") }
    func forceQuit(_ app: RunningApp) { calls.append("forceQuit \(app.bundleID)") }
    func quitAllApps() { calls.append("quitAll") }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct SystemCommandSourceTests {
    private let control = FakeSystemControl()
    private let context = FakeActionContext()

    private let safari = RunningApp(
        bundleID: "com.apple.Safari", name: "Safari", bundlePath: "/Applications/Safari.app")
    private let notes = RunningApp(bundleID: "com.apple.Notes", name: "Notes", bundlePath: nil)

    private let loginWindow = Permission.automation(bundleID: "com.apple.loginwindow")
    private let finder = Permission.automation(bundleID: "com.apple.finder")
    private let systemEvents = Permission.automation(bundleID: "com.apple.systemevents")

    /// The commands that exist whatever is running.
    private func fixedCommands() async throws -> [SearchItem] {
        let source = SystemCommandSource(control: control)
        var itemSets = source.indexedItems().makeAsyncIterator()
        return try #require(await itemSets.next())
    }

    private func command(_ name: String) async throws -> SearchItem {
        let commands = try await fixedCommands()
        return try #require(commands.first { $0.id == .system(name) })
    }

    private func onlyAction(of item: SearchItem) throws -> ActionDescriptor {
        #expect(item.actions.count == 1)
        return try #require(item.actions.first)
    }

    // MARK: The fixed commands

    @Test func fixedCommandsAreYieldedBeforeAnyAppIsKnown() async throws {
        let commands = try await fixedCommands()

        #expect(
            commands.map(\.id.rawValue) == [
                "system:sleep", "system:restart", "system:shutDown", "system:logOut",
                "system:emptyTrash", "system:toggleAppearance", "system:quitAll",
            ])
        #expect(commands.allSatisfy { $0.kindLabel == "System" })
    }

    @Test func sleepRunsWithoutAskingAndClosesTheLauncherFirst() async throws {
        let action = try onlyAction(of: try await command("sleep"))

        #expect(action.confirmation == nil)
        #expect(action.requiredPermissions.isEmpty)

        let outcome = try await action.perform(context)

        #expect(outcome == .closeLauncher)
        #expect(context.closeLauncherCount == 1)
        #expect(control.calls == ["sleep"])
    }

    @Test func failureToSleepIsThrownToTheLauncher() async throws {
        control.sleepFails = true
        let action = try onlyAction(of: try await command("sleep"))

        await #expect(throws: FakeSystemControl.SleepRefused.self) {
            _ = try await action.perform(context)
        }
    }

    @Test(arguments: ["restart", "shutDown", "logOut"])
    func powerCommandsAskFirstAndNeedTheLoginWindow(_ name: String) async throws {
        let action = try onlyAction(of: try await command(name))

        #expect(action.confirmation != nil)
        #expect(action.confirmation?.confirmTitle == action.title)
        #expect(action.isDestructive)
        #expect(action.requiredPermissions == [loginWindow])

        let outcome = try await action.perform(context)

        #expect(outcome == .closeLauncher)
        #expect(control.calls == [name])
    }

    @Test func emptyTrashAsksFirstNeedsFinderAndReportsInTheHUD() async throws {
        let action = try onlyAction(of: try await command("emptyTrash"))

        #expect(action.confirmation?.title == "Empty the Trash?")
        #expect(action.requiredPermissions == [finder])

        let outcome = try await action.perform(context)

        #expect(outcome == .showHUD("Emptying the Trash"))
        #expect(control.calls == ["emptyTrash"])
    }

    @Test func toggleAppearanceNeedsSystemEventsAndNoConfirmation() async throws {
        let item = try await command("toggleAppearance")
        let action = try onlyAction(of: item)

        #expect(action.confirmation == nil)
        #expect(action.requiredPermissions == [systemEvents])
        // Found by what people call it.
        #expect(item.alternateNames.map(\.text) == ["Dark Mode", "Light Mode"])

        _ = try await action.perform(context)

        #expect(control.calls == ["toggleAppearance"])
    }

    @Test func quitAllAsksFirstAndNeedsNoPermission() async throws {
        let action = try onlyAction(of: try await command("quitAll"))

        #expect(action.confirmation?.confirmTitle == "Quit All")
        #expect(action.requiredPermissions.isEmpty)

        _ = try await action.perform(context)

        #expect(control.calls == ["quitAll"])
    }

    // MARK: Running apps

    @Test func everyRunningAppGetsAQuitAndAForceQuitCommand() async throws {
        let source = SystemCommandSource(control: control)
        var itemSets = source.indexedItems().makeAsyncIterator()
        let fixed = try #require(await itemSets.next())

        control.report(runningApps: [safari, notes])
        let items = try #require(await itemSets.next())

        let appCommands = Array(items.dropFirst(fixed.count))
        #expect(
            appCommands.map(\.title) == [
                "Quit Safari", "Force Quit Safari", "Quit Notes", "Force Quit Notes",
            ])
        #expect(
            appCommands.map(\.id.rawValue) == [
                "system:quit.com.apple.Safari", "system:forceQuit.com.apple.Safari",
                "system:quit.com.apple.Notes", "system:forceQuit.com.apple.Notes",
            ])
        #expect(appCommands[0].icon == .file(path: "/Applications/Safari.app"))
        #expect(appCommands[2].icon == .symbol("xmark.circle.fill"))
    }

    @Test func appThatQuitLosesItsCommands() async throws {
        let source = SystemCommandSource(control: control)
        var itemSets = source.indexedItems().makeAsyncIterator()
        let fixed = try #require(await itemSets.next())

        control.report(runningApps: [safari, notes])
        _ = await itemSets.next()
        control.report(runningApps: [notes])
        let items = try #require(await itemSets.next())

        #expect(items.dropFirst(fixed.count).map(\.title) == ["Quit Notes", "Force Quit Notes"])
    }

    @Test func twoRunningCopiesOfOneAppShareTheirCommands() async throws {
        let source = SystemCommandSource(control: control)
        var itemSets = source.indexedItems().makeAsyncIterator()
        let fixed = try #require(await itemSets.next())

        control.report(runningApps: [safari, safari])
        let items = try #require(await itemSets.next())

        #expect(items.count == fixed.count + 2)
    }

    @Test func quitRunsAtOnceAndForceQuitAsksFirst() async throws {
        let source = SystemCommandSource(control: control)
        var itemSets = source.indexedItems().makeAsyncIterator()
        _ = await itemSets.next()
        control.report(runningApps: [safari])
        let items = try #require(await itemSets.next())
        let quit = try onlyAction(of: try #require(items.first { $0.title == "Quit Safari" }))
        let forceQuit = try onlyAction(
            of: try #require(items.first { $0.title == "Force Quit Safari" }))

        #expect(quit.confirmation == nil)
        #expect(forceQuit.confirmation?.title == "Force quit Safari?")
        #expect(forceQuit.isDestructive)

        #expect(try await quit.perform(context) == .closeLauncher)
        #expect(try await forceQuit.perform(context) == .closeLauncher)
        #expect(control.calls == ["quit com.apple.Safari", "forceQuit com.apple.Safari"])
    }
}

@Suite struct AppleEventTests {
    @Test func fourCharacterCodesAreTheBytesOfTheirText() {
        #expect(AppleEventDescription.code("aevt") == 0x6165_7674)
        #expect(AppleEventDescription.code("----") == 0x2D2D_2D2D)
    }

    @Test func powerEventsGoToTheLoginWindowAndDoNotWaitForIt() {
        let events = [AppleEventDescription.restart, .shutDown, .logOut]

        #expect(events.map(\.eventID) == ["rest", "shut", "rlgo"].map { fourCharacterCode($0) })
        for event in events {
            #expect(event.targetBundleID == "com.apple.loginwindow")
            #expect(event.eventClass == fourCharacterCode("aevt"))
            #expect(event.parameters.isEmpty)
            #expect(!event.waitsForReply)
            #expect(event.permission == .automation(bundleID: "com.apple.loginwindow"))
        }
    }

    @Test func emptyTrashIsFindersEmptyCommand() {
        let event = AppleEventDescription.emptyTrash

        #expect(event.targetBundleID == "com.apple.finder")
        #expect(event.eventClass == fourCharacterCode("fndr"))
        #expect(event.eventID == fourCharacterCode("empt"))
        #expect(!event.waitsForReply)
    }

    @Test func darkModeIsReadAndWrittenThroughSystemEvents() {
        let darkMode = AppleEventDescription.Value.property(
            path: [fourCharacterCode("thme"), fourCharacterCode("aprp")])
        let get = AppleEventDescription.getDarkMode
        let set = AppleEventDescription.setDarkMode(true)

        #expect(get.targetBundleID == "com.apple.systemevents")
        #expect(get.eventClass == fourCharacterCode("core"))
        #expect(get.eventID == fourCharacterCode("getd"))
        #expect(get.waitsForReply)
        #expect(
            get.parameters == [
                AppleEventDescription.Parameter(keyword: fourCharacterCode("----"), value: darkMode)
            ])

        #expect(set.eventID == fourCharacterCode("setd"))
        #expect(
            set.parameters == [
                AppleEventDescription.Parameter(
                    keyword: fourCharacterCode("----"), value: darkMode),
                AppleEventDescription.Parameter(
                    keyword: fourCharacterCode("data"), value: .boolean(true)),
            ])
        #expect(AppleEventDescription.setDarkMode(false).parameters.last?.value == .boolean(false))
    }

    /// The code written out byte by byte, independently of `AppleEventDescription.code`.
    private func fourCharacterCode(_ text: String) -> UInt32 {
        var code: UInt32 = 0
        for byte in text.utf8 {
            code = code * 256 + UInt32(byte)
        }
        return code
    }
}
