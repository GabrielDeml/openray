import OpenRayCore

/// What a running action can ask of the launcher (docs/DESIGN.md §4.2.2). One is made for each
/// action that is performed, and one for each screen.
///
/// `copy` and `paste` do nothing until `PasteService` exists; no action calls them yet.
final class LauncherActionContext: ActionContext {
    /// The query of the frame the action was started from, as it was at that moment.
    let query: String

    private weak var model: LauncherModel?

    init(query: String, model: LauncherModel) {
        self.query = query
        self.model = model
    }

    var previousApp: AppRef? {
        model?.shell?.previousApp
    }

    func closeLauncher() {
        model?.shell?.hide()
    }

    func showHUD(_ text: String) {
        model?.showHUD(text)
    }

    func confirm(_ confirmation: Confirmation) async -> Bool {
        // A launcher that is gone cannot ask, and what cannot be confirmed does not happen.
        guard let model else { return false }
        return await model.confirm(confirmation)
    }

    func copy(_ content: PasteContent) {}

    func paste(_ content: PasteContent) async -> PasteResult {
        // Nothing is pasted and nothing is copied either; the result only holds the place,
        // because `PasteResult` has no case for that.
        .copiedOnly(.noTarget)
    }
}
