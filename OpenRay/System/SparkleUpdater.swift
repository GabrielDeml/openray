import Combine
import Foundation
import OpenRayCore
import Sparkle

/// The updater, through Sparkle (docs/DESIGN.md §6.4). No other file imports Sparkle.
///
/// Sparkle keeps the settings in the user defaults, schedules the checks and shows every
/// window of an update itself. What is left to OpenRay is to start it, and to say in its own
/// places that an update is waiting.
///
/// The user driver's delegate is the one protocol of the three that Sparkle's headers do not
/// mark for the main actor, hence `@preconcurrency`. Sparkle calls it on the main thread like
/// the others.
final class SparkleUpdater: NSObject, UpdateControlling, SPUUpdaterDelegate,
    @preconcurrency SPUStandardUserDriverDelegate
{
    /// Told when Sparkle's state has changed and when an update is waiting. `AppDelegate` sets
    /// it once both objects exist.
    weak var model: UpdatesModel?

    /// Shared with the launcher and Settings: Sparkle's windows activate OpenRay as those do.
    private let focusRestorer: FocusRestorer
    /// Whether the onboarding window of this launch has the Updates step. `start` sets it.
    private var onboardingAsksAboutUpdates = false

    // Sparkle holds both delegates weakly, and `AppDelegate` keeps this object.
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    private var canCheckSubscription: AnyCancellable?

    init(focusRestorer: FocusRestorer) {
        self.focusRestorer = focusRestorer
        super.init()
        // Sparkle turns this off while a check or a download runs in the background.
        canCheckSubscription = updater.publisher(for: \.canCheckForUpdates).sink { [weak self] _ in
            self?.model?.refresh()
        }
    }

    private var updater: SPUUpdater {
        controller.updater
    }

    /// From here on Sparkle schedules its checks. Only `AppDelegate` calls this, and only in a
    /// build that can update itself: started with the empty public key of a build from the
    /// repository, Sparkle shows an alert that is meant for developers.
    ///
    /// - Parameter onboardingAsksAboutUpdates: Whether the onboarding window that opens at
    ///   this launch has the Updates step. Sparkle then keeps its own question about
    ///   automatic checks back.
    func start(onboardingAsksAboutUpdates: Bool) {
        self.onboardingAsksAboutUpdates = onboardingAsksAboutUpdates
        controller.startUpdater()
    }

    // MARK: UpdateControlling

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    var canCheckForUpdates: Bool {
        updater.canCheckForUpdates
    }

    var lastUpdateCheckDate: Date? {
        updater.lastUpdateCheckDate
    }

    func checkForUpdates() {
        // Before Sparkle activates OpenRay for its window: afterwards OpenRay itself is the
        // frontmost app.
        focusRestorer.recordFrontmostApp()
        updater.checkForUpdates()
    }

    // MARK: SPUUpdaterDelegate

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        // Sparkle calls this a moment after every start for as long as automatic checks have
        // been neither allowed nor refused, and with this method here its own rule, to ask at
        // the second launch, no longer applies. The question is asked in one place at a time:
        // by the Updates step while onboarding still has it to show, and by Sparkle's prompt
        // for a user who closed onboarding before that step (docs/DESIGN.md §4.3.7).
        !onboardingAsksAboutUpdates
    }

    func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        // "No update found" arrives as an error too. A check the user asked for has shown its
        // result already; a scheduled one stays silent, and this line is all there is of it.
        if let error {
            Log.updates.notice(
                "An update check ended with: \(error.localizedDescription, privacy: .public)")
        }
        // The date of the last check is new.
        model?.refresh()
    }

    // MARK: SPUStandardUserDriverDelegate

    // Gentle reminders (https://sparkle-project.org/documentation/gentle-reminders). OpenRay has
    // no Dock icon and most of the time no window, so the alert of a scheduled check would
    // open behind whatever the user is working in. Without this, Sparkle also logs a warning
    // for an app that runs in the background.
    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Right after launch, or after a change to the update settings, Sparkle brings its
        // alert to the front, and that is fine. At any other time the alert is kept back and
        // OpenRay says "Update Available" in the menu-bar menu and in the launcher.
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate {
            model?.updateIsWaiting(version: update.displayVersionString)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        model?.updateWasSeen()
    }

    func standardUserDriverWillFinishUpdateSession() {
        model?.updateWasSeen()
        // Sparkle closes its windows right after this call, which can leave OpenRay the active
        // app with nowhere for typing to go, as closing Settings can. A turn later, because
        // the windows are still on screen now.
        Task { focusRestorer.restoreIfNeeded() }
    }
}
