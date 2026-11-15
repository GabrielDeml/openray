import OpenRayCore

/// What a running action can ask of the launcher (docs/DESIGN.md §4.2.2). One is made for each
/// action that is performed.
///
/// Opening an app is the only action so far, and it needs `closeLauncher()` and nothing else.
/// The members that wait for a later milestone say so; nothing calls them yet.
final class LauncherActionContext: ActionContext {
    /// The query of the frame the action was started from, as it was at that moment.
    let query: String

    private weak var shell: (any LauncherShell)?

    init(query: String, shell: (any LauncherShell)?) {
        self.query = query
        self.shell = shell
    }

    var previousApp: AppRef? {
        shell?.previousApp
    }

    func closeLauncher() {
        shell?.hide()
    }

    func showHUD(_ text: String) {
        // `HUDController` arrives with milestone 3. Until then the message only reaches the log.
        Log.launcher.info("HUD message with nowhere to show it: \(text)")
    }

    func confirm(_ confirmation: Confirmation) async -> Bool {
        // The in-panel confirmation arrives with milestone 3. Until then nobody can say yes.
        false
    }

    func copy(_ content: PasteContent) {
        // `PasteService`, the only writer of the pasteboard, arrives with milestone 4.
    }

    func paste(_ content: PasteContent) async -> PasteResult {
        // `PasteService` arrives with milestone 4. Until then nothing is pasted and nothing is
        // copied either; the result only holds the place, because `PasteResult` has no case
        // for that.
        .copiedOnly(.noTarget)
    }
}
