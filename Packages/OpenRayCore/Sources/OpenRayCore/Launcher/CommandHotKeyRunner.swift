import Foundation
import os

/// What a press of a command's hotkey needs from the launcher's window. The app target's
/// controller is the implementation; the tests of `CommandHotKeyRunner` put a fake here, as
/// those of the paste path do with `PasteHost`.
@MainActor public protocol HotKeyPressHost: AnyObject {
    var isLauncherVisible: Bool { get }
    /// How often the launcher has been shown, by whatever showed it. A press reads it twice
    /// to tell whether the launcher on screen is still the one it knows.
    var launcherShowCount: Int { get }
    /// The screen on top in the launcher; nil at root search.
    var screenOnTop: ScreenRequest? { get }
    /// Shows the launcher at root search, as its own hotkey does.
    func showLauncher()
    /// Shows the launcher anew, with this screen on top of root search.
    func showLauncher(on screen: ScreenRequest)
    /// Shows the launcher at root search with this text in the search field.
    func showLauncher(replacingQueryWith text: String)
    func hideLauncher()
    func showHUD(_ text: String)
    /// A context for an action that starts without the launcher: its `previousApp` is the app
    /// that is in front now, and its query is empty.
    func makeActionContext() -> any ActionContext
}

/// Runs an item's primary action for a press of its hotkey, as Return on the item in root
/// search would, and shows the launcher only where the action needs it.
@MainActor public final class CommandHotKeyRunner {
    private let host: any HotKeyPressHost
    private let permissions: any PermissionChecking
    /// The items whose action a press has started and that has not ended yet.
    private var runningItems: Set<ItemID> = []

    public init(host: any HotKeyPressHost, permissions: any PermissionChecking) {
        self.host = host
        self.permissions = permissions
    }

    public func press(_ item: SearchItem) async {
        guard let action = item.actions.first else { return }

        // A hotkey is pressed blind, and a second press while the first is still at work (a
        // script that runs, an app that is starting, a question that is up) is far more often
        // impatience than a wish for two runs. From the launcher a second run stays possible.
        if runningItems.contains(item.id) {
            Log.launcher.debug("Ignored a hotkey whose command is still running")
            return
        }
        runningItems.insert(item.id)
        defer { runningItems.remove(item.id) }

        let context = PressContext(host: host)
        // A press is not a pick. Ranking answers what someone looks for in the launcher, and
        // an item with a hotkey is one they no longer look for there: counting presses would
        // fill the suggestions of the empty field with what is pressed fifty times a day.
        let ending = await ActionRunner.run(
            action, context: context, permissions: permissions, recordPick: {})

        switch ending {
        case .outcome(let outcome):
            apply(outcome, context: context)
        case .failure(let error):
            if context.launcherWasShownToAsk {
                hideLauncher(knownTo: context)
            }
            host.showHUD(error.localizedDescription)
        }
    }

    /// Does for a press what the launcher does with the outcome of Return on the item.
    ///
    /// A launcher that was hidden at the press and came up only for a confirmation goes again
    /// unless the outcome needs it, so that Esc on "Shut Down?" leads straight back to the
    /// app.
    private func apply(_ outcome: ActionOutcome, context: PressContext) {
        switch outcome {
        case .closeLauncher:
            hideLauncher(knownTo: context)
        case .showHUD(let text):
            hideLauncher(knownTo: context)
            host.showHUD(text)
        case .push(let screen):
            // The screen is up already, as after an earlier press of the same hotkey: a
            // fullOutput script that is running, an argument that is half typed. Showing it
            // anew would stop the one and empty the other.
            if host.isLauncherVisible && host.screenOnTop == screen { return }
            // Otherwise anew, so that the launcher ends up on root search plus this screen
            // whatever it held before.
            host.showLauncher(on: screen)
        case .replaceQuery(let text):
            host.showLauncher(replacingQueryWith: text)
        case .keepOpen, .popToRoot:
            if context.launcherWasShownToAsk {
                hideLauncher(knownTo: context)
            }
        }
    }

    /// Hides the launcher, unless it was shown again since the press. An action can end
    /// long after its press (a script that runs, an app that is starting), and a launcher
    /// that was opened in that time is in use for something else. The launcher drops the late
    /// outcome of Return in the same way.
    private func hideLauncher(knownTo context: PressContext) {
        if context.launcherWasShownAgain { return }
        host.hideLauncher()
    }
}

/// The context of an action that a hotkey started. It is the host's context in everything
/// but `confirm`, which shows the launcher first when it is hidden.
///
/// The launcher's own context answers no while the panel is hidden. That is right for an
/// action that outlived its launcher and wrong for one that never had one. The question can
/// also come from inside the action (a script that has not been cleared to run asks there),
/// so looking at the descriptor's confirmation before the run would not be enough.
@MainActor private final class PressContext: ActionContext {
    private let host: any HotKeyPressHost
    private let hostContext: any ActionContext
    private(set) var launcherWasShownToAsk = false
    /// `host.launcherShowCount` at the press, or after this context has shown the launcher
    /// itself to ask.
    private var knownShowCount: Int

    init(host: any HotKeyPressHost) {
        self.host = host
        hostContext = host.makeActionContext()
        knownShowCount = host.launcherShowCount
    }

    /// Whether something else has shown the launcher since: its own hotkey, the menu-bar
    /// item, another press.
    var launcherWasShownAgain: Bool {
        host.launcherShowCount != knownShowCount
    }

    var previousApp: AppRef? { hostContext.previousApp }
    var query: String { hostContext.query }
    var startedByHotKey: Bool { true }

    func closeLauncher() {
        hostContext.closeLauncher()
    }

    func showHUD(_ text: String) {
        hostContext.showHUD(text)
    }

    func confirm(_ confirmation: Confirmation) async -> Bool {
        if !host.isLauncherVisible {
            host.showLauncher()
            knownShowCount = host.launcherShowCount
            launcherWasShownToAsk = true
        }
        return await hostContext.confirm(confirmation)
    }

    func copy(_ content: PasteContent) {
        hostContext.copy(content)
    }

    func paste(_ content: PasteContent) async -> PasteResult {
        await hostContext.paste(content)
    }

    func clipboardText() async -> String? {
        await hostContext.clipboardText()
    }
}
