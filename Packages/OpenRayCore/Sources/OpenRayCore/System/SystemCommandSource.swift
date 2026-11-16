import Foundation

/// The system commands as items for root search (docs/DESIGN.md §4.2.10): the fixed ones, such
/// as Sleep and Empty Trash, and a Quit and a Force Quit command for every app that is running.
///
/// The source only describes the commands. What they do to the Mac goes through `SystemControl`.
public final class SystemCommandSource: SearchSource {
    public let id = SourceID(rawValue: "system")
    public let latency = SourceLatency.inline

    private let control: any SystemControl

    public init(control: any SystemControl) {
        self.control = control
    }

    public func indexedItems() -> AsyncStream<[SearchItem]> {
        // Every element is the full list, so a consumer that falls behind needs only the newest.
        let (items, continuation) = AsyncStream.makeStream(
            of: [SearchItem].self, bufferingPolicy: .bufferingNewest(1))
        let control = control

        let following = Task { @MainActor in
            let fixedCommands = Self.fixedCommands(control: control)
            // At once: Sleep does not have to wait for the list of running apps.
            continuation.yield(fixedCommands)
            for await apps in control.runningApps() {
                let quitCommands = Self.quitCommands(for: apps, control: control)
                continuation.yield(fixedCommands + quitCommands)
            }
        }
        continuation.onTermination = { _ in
            following.cancel()
        }
        return items
    }

    // MARK: Fixed commands

    private static var kindLabel: String {
        String(
            localized: "System", bundle: .module,
            comment: "The kind of a search result that is a system command, such as Sleep.")
    }

    /// The warning under the confirmations of commands that close apps.
    private static var unsavedChangesNote: String {
        String(
            localized: "Apps with unsaved changes may ask before they quit.", bundle: .module,
            comment:
                "The message of the confirmation before restarting, shutting down, logging out or quitting all apps."
        )
    }

    private static func fixedCommands(control: any SystemControl) -> [SearchItem] {
        [
            sleep(using: control), lockScreen(using: control), restart(using: control),
            shutDown(using: control), logOut(using: control), emptyTrash(using: control),
            toggleAppearance(using: control), quitAllApps(using: control),
        ]
    }

    /// A command with one action, which is what every system command is.
    private static func command(
        _ name: String, title: String, keywords: [String] = [], symbol: String,
        action: ActionDescriptor
    ) -> SearchItem {
        var alternateNames: [NameVariant] = []
        for keyword in keywords {
            alternateNames.append(.keyword(keyword))
        }
        return SearchItem(
            id: .system(name), title: title, alternateNames: alternateNames,
            icon: .symbol(symbol), kindLabel: kindLabel, actions: [action])
    }

    private static func sleep(using control: any SystemControl) -> SearchItem {
        let title = String(
            localized: "Sleep", bundle: .module, comment: "The command that puts the Mac to sleep.")
        let action = ActionDescriptor(id: ActionID(rawValue: "sleep"), title: title) { context in
            // First, so that the panel is not what the Mac wakes up to.
            context.closeLauncher()
            try control.sleep()
            return .closeLauncher
        }
        return command("sleep", title: title, symbol: "moon.fill", action: action)
    }

    private static func lockScreen(using control: any SystemControl) -> SearchItem {
        let title = String(
            localized: "Lock Screen", bundle: .module,
            comment: "The command that locks the screen.")
        // The shortcut is a key press that OpenRay makes, and macOS drops those without the
        // Accessibility permission.
        let action = ActionDescriptor(
            id: ActionID(rawValue: "lock-screen"), title: title,
            requiredPermissions: [.accessibility]
        ) { context in
            context.closeLauncher()
            control.lockScreen()
            return .closeLauncher
        }
        let keywords = [
            String(
                localized: "Lock", bundle: .module,
                comment: "Another word the Lock Screen command is found by.")
        ]
        return command(
            "lockScreen", title: title, keywords: keywords, symbol: "lock.fill", action: action)
    }

    private static func restart(using control: any SystemControl) -> SearchItem {
        let title = String(
            localized: "Restart", bundle: .module, comment: "The command that restarts the Mac.")
        let confirmation = Confirmation(
            title: String(
                localized: "Restart this Mac?", bundle: .module,
                comment: "The title of the confirmation before restarting."),
            message: unsavedChangesNote, confirmTitle: title)
        let action = ActionDescriptor(
            id: ActionID(rawValue: "restart"), title: title, isDestructive: true,
            confirmation: confirmation,
            requiredPermissions: [AppleEventDescription.restart.permission]
        ) { context in
            context.closeLauncher()
            try await control.restart()
            return .closeLauncher
        }
        let keywords = [
            String(
                localized: "Reboot", bundle: .module,
                comment: "Another word the Restart command is found by.")
        ]
        return command(
            "restart", title: title, keywords: keywords, symbol: "arrow.clockwise", action: action)
    }

    private static func shutDown(using control: any SystemControl) -> SearchItem {
        let title = String(
            localized: "Shut Down", bundle: .module, comment: "The command that turns the Mac off.")
        let confirmation = Confirmation(
            title: String(
                localized: "Shut down this Mac?", bundle: .module,
                comment: "The title of the confirmation before shutting down."),
            message: unsavedChangesNote, confirmTitle: title)
        let action = ActionDescriptor(
            id: ActionID(rawValue: "shut-down"), title: title, isDestructive: true,
            confirmation: confirmation,
            requiredPermissions: [AppleEventDescription.shutDown.permission]
        ) { context in
            context.closeLauncher()
            try await control.shutDown()
            return .closeLauncher
        }
        let keywords = [
            String(
                localized: "Power Off", bundle: .module,
                comment: "Another name the Shut Down command is found by."),
            String(
                localized: "Turn Off", bundle: .module,
                comment: "Another name the Shut Down command is found by."),
        ]
        return command(
            "shutDown", title: title, keywords: keywords, symbol: "power", action: action)
    }

    private static func logOut(using control: any SystemControl) -> SearchItem {
        let title = String(
            localized: "Log Out", bundle: .module, comment: "The command that logs the user out.")
        let confirmation = Confirmation(
            title: String(
                localized: "Log out?", bundle: .module,
                comment: "The title of the confirmation before logging out."),
            message: unsavedChangesNote, confirmTitle: title)
        let action = ActionDescriptor(
            id: ActionID(rawValue: "log-out"), title: title, isDestructive: true,
            confirmation: confirmation,
            requiredPermissions: [AppleEventDescription.logOut.permission]
        ) { context in
            context.closeLauncher()
            try await control.logOut()
            return .closeLauncher
        }
        let keywords = [
            String(
                localized: "Sign Out", bundle: .module,
                comment: "Another name the Log Out command is found by.")
        ]
        return command(
            "logOut", title: title, keywords: keywords,
            symbol: "rectangle.portrait.and.arrow.right", action: action)
    }

    private static func emptyTrash(using control: any SystemControl) -> SearchItem {
        let title = String(
            localized: "Empty Trash", bundle: .module,
            comment: "The command that empties the Trash.")
        let confirmation = Confirmation(
            title: String(
                localized: "Empty the Trash?", bundle: .module,
                comment: "The title of the confirmation before emptying the Trash."),
            message: String(
                localized: "The items in the Trash are deleted for good.", bundle: .module,
                comment: "The message of the confirmation before emptying the Trash."),
            confirmTitle: title)
        let action = ActionDescriptor(
            id: ActionID(rawValue: "empty-trash"), title: title, isDestructive: true,
            confirmation: confirmation,
            requiredPermissions: [AppleEventDescription.emptyTrash.permission]
        ) { context in
            context.closeLauncher()
            try await control.emptyTrash()
            // Finder has been asked and is at work; a full Trash takes it a while.
            let message = String(
                localized: "Emptying the Trash", bundle: .module,
                comment: "Shown briefly after the Empty Trash command was sent to Finder.")
            return .showHUD(message)
        }
        return command("emptyTrash", title: title, symbol: "trash.fill", action: action)
    }

    private static func toggleAppearance(using control: any SystemControl) -> SearchItem {
        let title = String(
            localized: "Toggle Appearance", bundle: .module,
            comment: "The command that switches between the light and the dark appearance.")
        let action = ActionDescriptor(
            id: ActionID(rawValue: "toggle-appearance"), title: title,
            requiredPermissions: [AppleEventDescription.getDarkMode.permission]
        ) { context in
            context.closeLauncher()
            try await control.toggleAppearance()
            return .closeLauncher
        }
        let keywords = [
            String(
                localized: "Dark Mode", bundle: .module,
                comment: "Another name the Toggle Appearance command is found by."),
            String(
                localized: "Light Mode", bundle: .module,
                comment: "Another name the Toggle Appearance command is found by."),
        ]
        return command(
            "toggleAppearance", title: title, keywords: keywords,
            symbol: "circle.lefthalf.filled", action: action)
    }

    private static func quitAllApps(using control: any SystemControl) -> SearchItem {
        let title = String(
            localized: "Quit All Apps", bundle: .module,
            comment: "The command that quits every running app.")
        let confirmation = Confirmation(
            title: String(
                localized: "Quit all apps?", bundle: .module,
                comment: "The title of the confirmation before quitting every running app."),
            message: unsavedChangesNote,
            confirmTitle: String(
                localized: "Quit All", bundle: .module,
                comment: "The button that confirms quitting every running app."))
        let action = ActionDescriptor(
            id: ActionID(rawValue: "quit-all"), title: title, isDestructive: true,
            confirmation: confirmation
        ) { _ in
            control.quitAllApps()
            return .closeLauncher
        }
        return command("quitAll", title: title, symbol: "xmark.square.fill", action: action)
    }

    // MARK: Running apps

    /// A Quit and a Force Quit command for each app. Two copies of one app that are both
    /// running share their commands, which act on both.
    private static func quitCommands(
        for apps: [RunningApp], control: any SystemControl
    ) -> [SearchItem] {
        var items: [SearchItem] = []
        var seenBundleIDs: Set<String> = []
        for app in apps {
            let isNewApp = seenBundleIDs.insert(app.bundleID).inserted
            if !isNewApp { continue }
            items.append(quit(app, using: control))
            items.append(forceQuit(app, using: control))
        }
        return items
    }

    private static func icon(of app: RunningApp) -> IconSource {
        if let bundlePath = app.bundlePath {
            return .file(path: bundlePath)
        }
        return .symbol("xmark.circle.fill")
    }

    private static func quit(
        _ app: RunningApp, using control: any SystemControl
    ) -> SearchItem {
        let title = String(
            localized: "Quit \(app.name)", bundle: .module,
            comment: "The command that quits a running app, which is named.")
        let action = ActionDescriptor(id: ActionID(rawValue: "quit"), title: title) { _ in
            control.quit(app)
            return .closeLauncher
        }
        return SearchItem(
            id: .system("quit.\(app.bundleID)"), title: title, icon: icon(of: app),
            kindLabel: kindLabel, actions: [action])
    }

    private static func forceQuit(
        _ app: RunningApp, using control: any SystemControl
    ) -> SearchItem {
        let title = String(
            localized: "Force Quit \(app.name)", bundle: .module,
            comment: "The command that ends a running app at once. The app is named.")
        let confirmation = Confirmation(
            title: String(
                localized: "Force quit \(app.name)?", bundle: .module,
                comment: "The title of the confirmation before force quitting an app."),
            message: String(
                localized: "Changes that were not saved are lost.", bundle: .module,
                comment: "The message of the confirmation before force quitting an app."),
            confirmTitle: String(
                localized: "Force Quit", bundle: .module,
                comment: "The button that confirms force quitting an app."))
        let action = ActionDescriptor(
            id: ActionID(rawValue: "force-quit"), title: title, isDestructive: true,
            confirmation: confirmation
        ) { _ in
            control.forceQuit(app)
            return .closeLauncher
        }
        return SearchItem(
            id: .system("forceQuit.\(app.bundleID)"), title: title, icon: icon(of: app),
            kindLabel: kindLabel, actions: [action])
    }
}
