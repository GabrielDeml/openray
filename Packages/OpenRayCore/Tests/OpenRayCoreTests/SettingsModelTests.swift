import Foundation
import Testing

@testable import OpenRayCore

/// A login item that lives in the test and never registers anything with macOS.
@MainActor private final class FakeLoginItem: LoginItemControlling {
    struct RegistrationRefused: Error, LocalizedError {
        var errorDescription: String? { "The app has to be in the Applications folder." }
    }

    var status = LoginItemStatus.disabled
    /// What a successful registration leaves the status at.
    var statusOnceRegistered = LoginItemStatus.enabled
    var registrationFails = false
    private(set) var settingsOpenedCount = 0

    func setEnabled(_ on: Bool) throws {
        if registrationFails { throw RegistrationRefused() }
        status = on ? statusOnceRegistered : .disabled
    }

    func openSystemSettings() {
        settingsOpenedCount += 1
    }
}

@MainActor @Suite struct LoginItemModelTests {
    private let controller = FakeLoginItem()

    @Test func switchShowsWhatMacOSSays() {
        controller.status = .enabled

        let model = LoginItemModel(controller: controller)

        #expect(model.status == .enabled)
        #expect(model.isOn)
    }

    @Test func turningItOnRegistersAndReadsTheStatusBack() {
        let model = LoginItemModel(controller: controller)

        model.setEnabled(true)

        #expect(controller.status == .enabled)
        #expect(model.isOn)
        #expect(model.errorMessage == nil)

        model.setEnabled(false)

        #expect(model.status == .disabled)
        #expect(!model.isOn)
    }

    @Test func registrationThatFailsLeavesTheSwitchOffAndSaysWhy() {
        let model = LoginItemModel(controller: controller)
        controller.registrationFails = true

        model.setEnabled(true)

        #expect(!model.isOn)
        #expect(model.errorMessage == "The app has to be in the Applications folder.")

        // The next change that works clears the message.
        controller.registrationFails = false
        model.setEnabled(true)
        #expect(model.errorMessage == nil)
    }

    @Test func itemThatWaitsForApprovalCountsAsOn() {
        let model = LoginItemModel(controller: controller)
        controller.statusOnceRegistered = .requiresApproval

        model.setEnabled(true)

        #expect(model.status == .requiresApproval)
        #expect(model.isOn)
    }

    @Test func refreshPicksUpAChangeMadeInSystemSettings() {
        let model = LoginItemModel(controller: controller)

        controller.status = .enabled
        #expect(model.status == .disabled)
        model.refresh()

        #expect(model.status == .enabled)
    }

    @Test func switchThatCannotChangeNeverRegisters() {
        let model = LoginItemModel(controller: controller, canChange: false)

        model.setEnabled(true)

        #expect(controller.status == .disabled)
        #expect(!model.isOn)
    }

    @Test func openSystemSettingsIsPassedOn() {
        let model = LoginItemModel(controller: controller)

        model.openSystemSettings()

        #expect(controller.settingsOpenedCount == 1)
    }
}

@MainActor @Suite struct OnboardingModelTests {
    private let preferences = Preferences(store: InMemoryPreferencesStore())
    private let loginController = FakeLoginItem()
    private let updater = FakeUpdater()

    private func makeModel(
        updaterAvailability: UpdaterAvailability = .available
    ) -> OnboardingModel {
        OnboardingModel(
            preferences: preferences, loginItem: LoginItemModel(controller: loginController),
            updates: UpdatesModel(updater: updater, availability: updaterAvailability))
    }

    /// A model that is on the updates step, as a new user gets there.
    private func makeModelOnUpdatesStep(
        updaterAvailability: UpdaterAvailability = .available
    ) -> OnboardingModel {
        let model = makeModel(updaterAvailability: updaterAvailability)
        model.advance()
        model.advance()
        model.advance()
        return model
    }

    @Test func newUserSeesEveryStepInOrder() {
        let model = makeModel()

        #expect(OnboardingModel.isNeeded(completedVersion: 0))
        #expect(model.steps == [.welcome, .hotKey, .launchAtLogin, .updates, .permissions])
        #expect(model.currentStep == .welcome)
    }

    @Test func userOfAnEarlierVersionSeesOnlyTheStepsAddedSince() {
        preferences.onboardingCompletedVersion = 1

        let model = makeModel()

        #expect(OnboardingModel.isNeeded(completedVersion: 1))
        #expect(model.steps == [.updates, .permissions])
    }

    @Test func userOfTheVersionBeforeSeesOnlyTheUpdatesStep() {
        preferences.onboardingCompletedVersion = 2

        let model = makeModel()

        #expect(OnboardingModel.isNeeded(completedVersion: 2))
        #expect(model.steps == [.updates])
        #expect(model.isOnLastStep)
    }

    @Test func userWhoHasCompletedThisVersionSeesNothing() {
        let completed = OnboardingModel.currentVersion

        #expect(!OnboardingModel.isNeeded(completedVersion: completed))
        #expect(OnboardingModel.steps(after: completed).isEmpty)
    }

    @Test func hotKeyStepPassesWhenTheHotKeyIsPressed() {
        let model = makeModel()
        model.advance()
        #expect(model.currentStep == .hotKey)
        #expect(!model.canContinue)

        let wasTaken = model.hotKeyPressed()

        #expect(wasTaken)
        #expect(model.canContinue)
    }

    @Test func hotKeyPressedOnAnotherStepBelongsToTheLauncher() {
        let model = makeModel()

        #expect(!model.hotKeyPressed())
        #expect(!model.hotKeyWasPressed)
    }

    @Test func recordingAnotherHotKeyAsksForItToBeTriedAgain() {
        let model = makeModel()
        model.advance()
        _ = model.hotKeyPressed()

        model.hotKeyChanged()

        #expect(!model.canContinue)
    }

    @Test func goingBackReturnsToTheStepBefore() {
        let model = makeModel()
        model.advance()

        model.goBack()
        #expect(model.currentStep == .welcome)
        model.goBack()
        #expect(model.currentStep == .welcome)
    }

    @Test func loginItemIsRegisteredByContinueOnItsStepAndNotByTheCheckbox() {
        let model = makeModel()
        model.advance()
        model.advance()
        #expect(model.currentStep == .launchAtLogin)

        model.wantsLaunchAtLogin = true
        // Ticking the box registers nothing.
        #expect(loginController.status == .disabled)

        model.advance()

        #expect(loginController.status == .enabled)
        #expect(model.currentStep == .updates)
    }

    @Test func goingBackAndClearingTheCheckboxTakesTheLoginItemAwayAgain() {
        let model = makeModel()
        model.advance()
        model.advance()
        model.wantsLaunchAtLogin = true
        model.advance()

        model.goBack()
        model.wantsLaunchAtLogin = false
        model.advance()

        #expect(loginController.status == .disabled)
    }

    @Test func checkboxStartsAsTheLoginItemIs() {
        loginController.status = .enabled

        let model = makeModel()
        #expect(model.wantsLaunchAtLogin)

        // Continue with the box as it was leaves the login item alone.
        for _ in model.steps {
            model.advance()
        }
        #expect(loginController.status == .enabled)
    }

    // The updater's own prompt and the Updates step ask the same question. Sparkle is told
    // to keep its prompt back for as long as onboarding still has the step to show.
    @Test func onboardingAsksAboutUpdatesUntilItsStepHasBeenShown() {
        #expect(OnboardingModel.asksAboutUpdates(completedVersion: 0))
        #expect(OnboardingModel.asksAboutUpdates(completedVersion: 1))
        #expect(OnboardingModel.asksAboutUpdates(completedVersion: 2))
        // Also when the window was closed before the step, which completes the version too.
        #expect(
            !OnboardingModel.asksAboutUpdates(completedVersion: OnboardingModel.currentVersion))
    }

    @Test func automaticUpdateChecksAreTurnedOnByContinueOnTheirStep() {
        let model = makeModelOnUpdatesStep()
        #expect(model.currentStep == .updates)
        // On unless the user says otherwise.
        #expect(model.wantsAutomaticUpdateChecks)

        model.advance()

        #expect(updater.automaticChecksWrites == [true])
        #expect(model.currentStep == .permissions)
    }

    // "No" is written too: Sparkle asks with a prompt of its own for as long as the setting
    // has no value.
    @Test func clearedCheckboxTurnsAutomaticUpdateChecksOff() {
        let model = makeModelOnUpdatesStep()

        model.wantsAutomaticUpdateChecks = false
        // The checkbox alone sets nothing.
        #expect(updater.automaticChecksWrites.isEmpty)
        model.advance()

        #expect(updater.automaticChecksWrites == [false])
    }

    @Test func closingTheWindowBeforeTheUpdatesStepWasConfirmedSetsNothing() {
        let model = makeModelOnUpdatesStep()

        model.dismiss()

        #expect(model.isFinished)
        #expect(updater.automaticChecksWrites.isEmpty)
    }

    @Test(arguments: [UpdaterAvailability.developmentBuild, .notConfigured])
    func buildThatCannotUpdateLeavesTheUpdaterAlone(_ availability: UpdaterAvailability) {
        let model = makeModelOnUpdatesStep(updaterAvailability: availability)
        // Nothing would check, so the box is not ticked. The view has it disabled.
        #expect(!model.wantsAutomaticUpdateChecks)

        model.wantsAutomaticUpdateChecks = true
        model.advance()

        #expect(updater.automaticChecksWrites.isEmpty)
        #expect(model.currentStep == .permissions)
    }

    @Test func finishingTheLastStepStoresTheVersion() {
        let model = makeModel()
        model.advance()
        model.advance()
        model.advance()
        model.advance()
        #expect(model.isOnLastStep)
        #expect(!model.isFinished)
        #expect(preferences.onboardingCompletedVersion == 0)

        model.advance()

        #expect(model.isFinished)
        #expect(loginController.status == .disabled)
        #expect(preferences.onboardingCompletedVersion == OnboardingModel.currentVersion)
    }

    @Test func closingTheWindowEndsOnboardingWithoutApplyingAnUnconfirmedChoice() {
        let model = makeModel()
        model.wantsLaunchAtLogin = true

        model.dismiss()

        #expect(model.isFinished)
        #expect(loginController.status == .disabled)
        #expect(preferences.onboardingCompletedVersion == OnboardingModel.currentVersion)
    }

    // Closing the window on a later page must not lose what Continue confirmed on the page
    // before.
    @Test func closingTheWindowOnALaterStepKeepsTheConfirmedChoice() {
        let model = makeModel()
        model.advance()
        model.advance()
        model.wantsLaunchAtLogin = true
        model.advance()

        model.dismiss()

        #expect(model.isFinished)
        #expect(loginController.status == .enabled)
    }

    @Test func hotKeyAfterTheEndIsTheLaunchersAgain() {
        let model = makeModel()
        model.advance()
        model.dismiss()

        #expect(!model.hotKeyPressed())
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct CommandsSettingsModelTests {
    private let safari = ItemID.app(bundleID: "com.apple.Safari")
    private let sleep = ItemID.system("sleep")
    private let trash = ItemID.system("emptyTrash")

    private func item(_ id: ItemID, _ title: String, kind: String) -> SearchItem {
        SearchItem(id: id, title: title, icon: .symbol("gear"), kindLabel: kind)
    }

    private var launcherItems: [SearchItem] {
        [
            item(safari, "Safari", kind: "Application"),
            item(trash, "Empty Trash", kind: "System"),
            item(sleep, "Sleep", kind: "System"),
        ]
    }

    /// A model that has read the store once.
    ///
    /// - Parameter furtherItems: What the launcher has besides `launcherItems`.
    private func makeModel(
        furtherItems: [SearchItem] = []
    ) async throws -> (model: CommandsSettingsModel, store: CommandStore) {
        let store = CommandStore(database: try AppDatabase.inMemory())
        let items = launcherItems + furtherItems
        let model = CommandsSettingsModel(commands: store, currentItems: { items })
        model.start()
        await wait { model.quicklinks.count == 2 }
        return (model, store)
    }

    /// The model hears of every change through the store's stream, a moment after the write.
    private func wait(until condition: () -> Bool) async {
        while !condition() {
            await Task.yield()
        }
    }

    // MARK: The list

    @Test func commandsAndApplicationsAreListedApartByTitle() async throws {
        let (model, _) = try await makeModel()

        #expect(model.rows.map(\.title) == ["Empty Trash", "Sleep"])

        model.scope = .applications
        #expect(model.rows.map(\.title) == ["Safari"])
    }

    @Test func filterNarrowsTheListLikeASearch() async throws {
        let (model, _) = try await makeModel()

        model.filter = "tra"

        #expect(model.rows.map(\.title) == ["Empty Trash"])
    }

    @Test func hidingAndDisablingShowUpInTheRow() async throws {
        let (model, store) = try await makeModel()

        await model.setHidden(true, for: sleep)
        await model.setEnabled(false, for: sleep)
        await wait { model.rows.last?.isEnabled == false }

        let row = try #require(model.rows.last)
        #expect(row.isHidden)
        #expect(!row.isEnabled)
        #expect(
            try await store.snapshot().overrides[sleep]
                == ItemOverride(hidden: true, disabled: true))

        // Changing one of the two keeps the other.
        await model.setHidden(false, for: sleep)
        await wait { model.rows.last?.isHidden == false }
        #expect(model.rows.last?.isEnabled == false)
    }

    @Test func aliasesAreEditedAsOneCommaSeparatedText() async throws {
        let (model, store) = try await makeModel()

        await model.setAliases("zz, Nap ,zz", for: sleep)
        await wait { model.rows.last?.aliasText == "nap, zz" }
        #expect(try await store.snapshot().aliases == ["zz": sleep, "nap": sleep])

        // What is no longer in the text is removed, and what stays is not written again.
        await model.setAliases("nap, rest", for: sleep)
        await wait { model.rows.last?.aliasText == "nap, rest" }
        #expect(try await store.snapshot().aliases == ["nap": sleep, "rest": sleep])

        await model.setAliases("", for: sleep)
        await wait { model.rows.last?.aliasText == "" }
        #expect(try await store.snapshot().aliases.isEmpty)
    }

    @Test func focusingAnItemShowsTheListOnIt() async throws {
        let (model, _) = try await makeModel()

        model.focus(on: safari)

        #expect(model.scope == .applications)
        #expect(model.filter == "Safari")
        #expect(model.itemToFocus == safari)
        #expect(model.rows.map(\.id) == [safari])
    }

    // MARK: Quicklinks

    @Test func quicklinkNeedsANameAndATemplateThatMakesAURL() async throws {
        let (model, _) = try await makeModel()
        let created = Date(timeIntervalSince1970: 1_780_000_000)

        let good = Quicklink(
            name: "Wiki", template: "https://wiki.example/{query}", createdAt: created)
        let unnamed = Quicklink(name: "  ", template: "https://wiki.example/", createdAt: created)
        let noURL = Quicklink(name: "Wiki", template: "wiki {query}", createdAt: created)

        #expect(model.problem(with: good) == nil)
        #expect(model.problem(with: unnamed) == "Give the quicklink a name.")
        #expect(model.problem(with: noURL)?.hasPrefix("The link has to be a URL") == true)
    }

    @Test func savedQuicklinkIsTrimmedAndListedUntilItIsDeleted() async throws {
        let (model, _) = try await makeModel()
        let wiki = Quicklink(
            name: " Wiki ", template: " https://wiki.example/{query} ",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000))

        await model.save(wiki)
        await wait { model.quicklinks.count == 3 }

        #expect(model.quicklinks.last?.name == "Wiki")
        #expect(model.quicklinks.last?.template == "https://wiki.example/{query}")

        await model.deleteQuicklink(wiki.id)
        await wait { model.quicklinks.count == 2 }
        #expect(model.quicklinks.map(\.name) == ["Google", "DuckDuckGo"])
    }

    // MARK: Fallback list

    @Test func fallbackListNamesWhatItCanAndKeepsWhatItCannot() async throws {
        let (model, _) = try await makeModel()

        #expect(model.fallbackRows.map(\.title) == ["Google", "DuckDuckGo", nil])
        #expect(model.fallbackRows.last?.id.rawValue == "command:files.search")
        // Both seeded quicklinks are on the list already.
        #expect(model.fallbackCandidates.isEmpty)
    }

    @Test func entriesCanBeRemovedAndAddedBack() async throws {
        let (model, _) = try await makeModel()
        let google = try #require(model.fallbackRows.first).id

        await model.removeFallback(google)
        await wait { model.fallbackRows.count == 2 }
        #expect(model.fallbackCandidates.map(\.title) == ["Google"])
        #expect(model.fallbackCandidates.map(\.id) == [google])

        await model.addFallback(google)
        await wait { model.fallbackRows.count == 3 }
        #expect(model.fallbackRows.map(\.title) == ["DuckDuckGo", nil, "Google"])
    }

    // "Search Files" is on the list of a new database before any feature provides it. Once
    // file search is there, the entry has a name and a Remove button, and has to be among
    // what Add offers, or removing it would be for good.

    private var searchFilesCommand: SearchItem {
        item(CommandSeeds.searchFiles, "Search Files", kind: "Command")
    }

    @Test func searchFilesIsNamedOnceItsCommandExists() async throws {
        let (model, _) = try await makeModel(furtherItems: [searchFilesCommand])

        #expect(model.fallbackRows.map(\.title) == ["Google", "DuckDuckGo", "Search Files"])
        // It is on the list already.
        #expect(model.fallbackCandidates.isEmpty)
    }

    @Test func searchFilesCanBeRemovedAndAddedBack() async throws {
        let (model, _) = try await makeModel(furtherItems: [searchFilesCommand])
        let searchFiles = CommandSeeds.searchFiles

        await model.removeFallback(searchFiles)
        await wait { model.fallbackRows.count == 2 }
        #expect(
            model.fallbackCandidates
                == [CommandsSettingsModel.FallbackCandidate(id: searchFiles, title: "Search Files")]
        )

        await model.addFallback(searchFiles)
        await wait { model.fallbackRows.count == 3 }
        #expect(model.fallbackRows.map(\.title) == ["Google", "DuckDuckGo", "Search Files"])
        #expect(model.fallbackCandidates.isEmpty)
    }

    @Test func quicklinksAreOfferedAheadOfSearchFiles() async throws {
        let (model, _) = try await makeModel(furtherItems: [searchFilesCommand])
        let google = try #require(model.fallbackRows.first).id

        await model.removeFallback(CommandSeeds.searchFiles)
        await model.removeFallback(google)
        await wait { model.fallbackRows.count == 1 }

        #expect(model.fallbackCandidates.map(\.title) == ["Google", "Search Files"])
    }

    @Test func searchFilesIsNotOfferedWhileNoFeatureProvidesIt() async throws {
        let (model, _) = try await makeModel()

        await model.removeFallback(CommandSeeds.searchFiles)
        await wait { model.fallbackRows.count == 2 }

        #expect(model.fallbackCandidates.isEmpty)
    }

    @Test(arguments: [
        // From the first row to the end, to the middle, and nowhere.
        (0, 3, ["DuckDuckGo", "files", "Google"]),
        (0, 2, ["DuckDuckGo", "Google", "files"]),
        (0, 1, ["Google", "DuckDuckGo", "files"]),
        // From the last row to the top.
        (2, 0, ["files", "Google", "DuckDuckGo"]),
    ])
    func movingAnEntryFollowsTheRulesOfAListMove(
        _ from: Int, _ to: Int, _ expected: [String]
    ) async throws {
        let (model, store) = try await makeModel()

        await model.moveFallback(fromOffsets: IndexSet(integer: from), toOffset: to)

        let namesByID = [
            CommandSeeds.google.itemID: "Google",
            CommandSeeds.duckDuckGo.itemID: "DuckDuckGo",
            CommandSeeds.searchFiles: "files",
        ]
        var names: [String] = []
        for id in try await store.snapshot().fallbackOrder {
            names.append(namesByID[id] ?? id.rawValue)
        }
        #expect(names == expected)
    }
}
