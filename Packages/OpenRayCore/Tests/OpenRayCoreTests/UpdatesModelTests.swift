import Foundation
import Testing

@testable import OpenRayCore

@Suite struct UpdaterAvailabilityTests {
    private let feed = "https://example.com/appcast.xml"
    private let key = "a-public-key"

    @Test func releaseBuildWithAFeedAndAKeyCanUpdate() {
        let availability = UpdaterAvailability(isDebugBuild: false, feedURL: feed, publicKey: key)

        #expect(availability == .available)
    }

    @Test func debugBuildNeverUpdatesWhateverItsInfoPlistSays() {
        #expect(
            UpdaterAvailability(isDebugBuild: true, feedURL: feed, publicKey: key)
                == .developmentBuild)
        #expect(
            UpdaterAvailability(isDebugBuild: true, feedURL: nil, publicKey: nil)
                == .developmentBuild)
    }

    // The key is an empty string in the Info.plist until the owner has generated one, and
    // Sparkle must not be started with it.
    @Test(arguments: [nil, "", "   ", "\n"])
    func buildWithoutAKeyIsNotConfigured(_ missingKey: String?) {
        let availability = UpdaterAvailability(
            isDebugBuild: false, feedURL: feed, publicKey: missingKey)

        #expect(availability == .notConfigured)
    }

    @Test(arguments: [nil, "", " "])
    func buildWithoutAFeedIsNotConfigured(_ missingFeed: String?) {
        let availability = UpdaterAvailability(
            isDebugBuild: false, feedURL: missingFeed, publicKey: key)

        #expect(availability == .notConfigured)
    }
}

@MainActor @Suite struct UpdatesModelTests {
    private let updater = FakeUpdater()

    private func makeModel(_ availability: UpdaterAvailability = .available) -> UpdatesModel {
        UpdatesModel(updater: updater, availability: availability)
    }

    @Test func modelShowsWhatTheUpdaterSays() {
        let lastCheck = Date(timeIntervalSinceReferenceDate: 800_000_000)
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true
        updater.canCheckForUpdates = false
        updater.lastUpdateCheckDate = lastCheck

        let model = makeModel()

        #expect(model.isAvailable)
        #expect(model.checksAutomatically)
        #expect(model.installsAutomatically)
        #expect(!model.canCheck)
        #expect(model.lastCheck == lastCheck)
        #expect(model.waitingUpdateVersion == nil)
    }

    @Test func automaticChecksAreWrittenThroughAndReadBack() {
        let model = makeModel()

        model.setChecksAutomatically(true)

        #expect(updater.automaticallyChecksForUpdates)
        #expect(model.checksAutomatically)

        model.setChecksAutomatically(false)

        #expect(!updater.automaticallyChecksForUpdates)
        #expect(!model.checksAutomatically)
    }

    @Test func automaticInstallsAreWrittenThroughAndReadBack() {
        let model = makeModel()
        model.setChecksAutomatically(true)

        model.setInstallsAutomatically(true)

        #expect(updater.automaticallyDownloadsUpdates)
        #expect(model.installsAutomatically)

        model.setInstallsAutomatically(false)

        #expect(!updater.automaticallyDownloadsUpdates)
        #expect(!model.installsAutomatically)
    }

    // The updater has the last word: it installs nothing on its own while it does not check.
    @Test func automaticInstallsFollowAutomaticChecks() {
        let model = makeModel()

        model.setInstallsAutomatically(true)
        #expect(!model.installsAutomatically)

        model.setChecksAutomatically(true)
        model.setInstallsAutomatically(true)
        model.setChecksAutomatically(false)
        #expect(!model.installsAutomatically)

        // The updater kept the choice for when checks come back.
        model.setChecksAutomatically(true)
        #expect(model.installsAutomatically)
    }

    @Test(arguments: [UpdaterAvailability.developmentBuild, .notConfigured])
    func buildThatCannotUpdateWritesNothingAndChecksNothing(
        _ availability: UpdaterAvailability
    ) {
        let model = makeModel(availability)

        model.setChecksAutomatically(true)
        model.setInstallsAutomatically(true)
        model.checkForUpdates()

        #expect(!model.isAvailable)
        #expect(updater.automaticChecksWrites.isEmpty)
        #expect(!updater.automaticallyDownloadsUpdates)
        #expect(updater.checkCount == 0)
        // Its updater was never started, so there is nothing to check with.
        #expect(!model.canCheck)
    }

    @Test func refreshPicksUpWhatChangedBehindTheModelsBack() {
        let model = makeModel()
        let lastCheck = Date(timeIntervalSinceReferenceDate: 800_000_000)

        // As when the user answers Sparkle's own prompt, or a check runs in the background.
        updater.automaticallyChecksForUpdates = true
        updater.canCheckForUpdates = false
        updater.lastUpdateCheckDate = lastCheck
        #expect(!model.checksAutomatically)
        #expect(model.canCheck)

        model.refresh()

        #expect(model.checksAutomatically)
        #expect(!model.canCheck)
        #expect(model.lastCheck == lastCheck)
    }

    @Test func updateWaitsUntilItWasSeen() {
        let model = makeModel()

        model.updateIsWaiting(version: "0.2.0")
        #expect(model.waitingUpdateVersion == "0.2.0")

        model.updateWasSeen()
        #expect(model.waitingUpdateVersion == nil)

        model.updateIsWaiting(version: "0.3.0")
        #expect(model.waitingUpdateVersion == "0.3.0")
    }

    @Test func checkIsPassedOnOnce() {
        let model = makeModel()

        model.checkForUpdates()

        #expect(updater.checkCount == 1)
    }
}
