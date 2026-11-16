import AppKit
import IOKit.pwr_mgt
import OpenRayCore

/// What the system commands do to this Mac (docs/DESIGN.md §4.2.10): sleep through IOKit, the
/// power commands, Empty Trash and the appearance through Apple events, quitting through
/// `NSRunningApplication`, and Lock Screen through a key press that the paste host posts.
final class MacSystemControl: SystemControl {
    enum ControlError: Error, LocalizedError {
        case sleepRefused(IOReturn)
        /// System Events answered the question about dark mode with something else.
        case appearanceNotReadable

        var errorDescription: String? {
            switch self {
            case .sleepRefused(let status):
                return String(localized: "macOS did not go to sleep (error \(String(status))).")
            case .appearanceNotReadable:
                return String(localized: "macOS did not say which appearance is in use.")
            }
        }
    }

    private let appleEvents: AppleEventSender
    /// The one place key events are posted from. Lock Screen is a key press.
    private let pasteHost: any PasteHost

    init(appleEvents: AppleEventSender, pasteHost: any PasteHost) {
        self.appleEvents = appleEvents
        self.pasteHost = pasteHost
    }

    // MARK: Power, Trash, appearance

    func sleep() throws {
        let powerManagement = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        defer { IOServiceClose(powerManagement) }
        let status = IOPMSleepSystem(powerManagement)
        if status != kIOReturnSuccess {
            throw ControlError.sleepRefused(status)
        }
    }

    func lockScreen() {
        pasteHost.post(.lockScreen)
    }

    func restart() async throws {
        try await appleEvents.send(.restart)
    }

    func shutDown() async throws {
        try await appleEvents.send(.shutDown)
    }

    func logOut() async throws {
        try await appleEvents.send(.logOut)
    }

    func emptyTrash() async throws {
        try await appleEvents.send(.emptyTrash)
    }

    func toggleAppearance() async throws {
        guard let isDark = try await appleEvents.send(.getDarkMode) else {
            throw ControlError.appearanceNotReadable
        }
        try await appleEvents.send(.setDarkMode(!isDark))
    }

    // MARK: Running apps

    func runningApps() -> AsyncStream<[RunningApp]> {
        // Every element is the full list, so a consumer that falls behind needs only the newest.
        let (apps, continuation) = AsyncStream.makeStream(
            of: [RunningApp].self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(Self.regularApps())

        let center = NSWorkspace.shared.notificationCenter
        let changes = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        var observers: [NSObjectProtocol] = []
        for name in changes {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    _ = continuation.yield(Self.regularApps())
                }
            }
            observers.append(observer)
        }

        let observerTokens = ObserverTokens(observers)
        continuation.onTermination = { _ in
            observerTokens.remove(from: center)
        }
        return apps
    }

    /// The apps with a Dock icon, without OpenRay itself, ordered by name.
    private static func regularApps() -> [RunningApp] {
        var apps: [RunningApp] = []
        for app in NSWorkspace.shared.runningApplications {
            // An app that has just quit can still be in the list for a moment.
            if app.activationPolicy != .regular || app.isTerminated || app == .current { continue }
            guard let bundleID = app.bundleIdentifier else { continue }
            let runningApp = RunningApp(
                bundleID: bundleID, name: app.localizedName ?? bundleID,
                bundlePath: app.bundleURL?.path(percentEncoded: false))
            apps.append(runningApp)
        }
        apps.sort { first, second in
            first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
        return apps
    }

    func quit(_ app: RunningApp) {
        for runningCopy in NSRunningApplication.runningApplications(
            withBundleIdentifier: app.bundleID)
        {
            runningCopy.terminate()
        }
    }

    func forceQuit(_ app: RunningApp) {
        for runningCopy in NSRunningApplication.runningApplications(
            withBundleIdentifier: app.bundleID)
        {
            runningCopy.forceTerminate()
        }
    }

    func quitAllApps() {
        for app in NSWorkspace.shared.runningApplications {
            if app.activationPolicy != .regular || app == .current { continue }
            // Finder is not an app people mean by "all apps", and it restarts itself anyway.
            if app.bundleIdentifier == AppleEventDescription.finderBundleID { continue }
            app.terminate()
        }
    }
}

/// Notification observers that are removed from whatever thread the stream they feed ends on.
///
/// `@unchecked Sendable`: the tokens are opaque objects that are only ever handed back to the
/// notification center, whose `removeObserver` is safe to call from any thread.
private nonisolated final class ObserverTokens: @unchecked Sendable {
    private let observers: [NSObjectProtocol]

    init(_ observers: [NSObjectProtocol]) {
        self.observers = observers
    }

    func remove(from center: NotificationCenter) {
        for observer in observers {
            center.removeObserver(observer)
        }
    }
}
