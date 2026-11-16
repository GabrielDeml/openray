import Foundation
import Observation

/// What Settings › Updates, the menu-bar menu, the launcher and onboarding show and do about
/// updates (docs/DESIGN.md §6.4). The settings themselves live with the updater.
@MainActor @Observable public final class UpdatesModel {
    /// Why this build can or cannot update itself. It never changes while the app runs.
    nonisolated public let availability: UpdaterAvailability

    public private(set) var checksAutomatically = false
    /// Whether updates are downloaded and installed without asking. Only on while
    /// `checksAutomatically` is.
    public private(set) var installsAutomatically = false
    /// Whether "Check for Updates…" can be chosen right now.
    public private(set) var canCheck = false
    public private(set) var lastCheck: Date?
    /// The version of an update that a scheduled check found and that the user has not looked
    /// at yet. While it is set, the menu-bar menu and the launcher say that an update is
    /// available.
    public private(set) var waitingUpdateVersion: String?

    @ObservationIgnored private let updater: any UpdateControlling

    public init(updater: any UpdateControlling, availability: UpdaterAvailability) {
        self.updater = updater
        self.availability = availability
        refresh()
    }

    /// False in a build whose updater is never started. Nothing is written to the updater
    /// then, and no check is passed on.
    public var isAvailable: Bool {
        availability == .available
    }

    /// Reads everything again. The pane calls this when it appears and the updater when its
    /// state changes: the updater can ask the user about automatic checks with a prompt of
    /// its own, and the answer changes the setting without going through this model.
    public func refresh() {
        checksAutomatically = updater.automaticallyChecksForUpdates
        installsAutomatically = updater.automaticallyDownloadsUpdates
        canCheck = isAvailable && updater.canCheckForUpdates
        lastCheck = updater.lastUpdateCheckDate
    }

    public func setChecksAutomatically(_ on: Bool) {
        guard isAvailable else { return }
        updater.automaticallyChecksForUpdates = on
        // Both, because the updater installs nothing on its own while it does not check.
        refresh()
    }

    public func setInstallsAutomatically(_ on: Bool) {
        guard isAvailable else { return }
        updater.automaticallyDownloadsUpdates = on
        refresh()
    }

    /// "Check for Updates…" and "Update Available…": the updater shows what it finds, or the
    /// update that is waiting.
    public func checkForUpdates() {
        guard isAvailable else { return }
        updater.checkForUpdates()
    }

    /// A scheduled check found an update and the updater has left it to OpenRay to say so.
    public func updateIsWaiting(version: String) {
        waitingUpdateVersion = version
    }

    /// The user has looked at the update, or the updater is done with it.
    public func updateWasSeen() {
        waitingUpdateVersion = nil
    }
}
