import OpenRayCore

/// What a running action can ask of the launcher (docs/DESIGN.md §4.2.2). One is made for each
/// action that is performed, and one for each screen.
final class LauncherActionContext: ActionContext {
    /// The query of the frame the action was started from, as it was at that moment.
    let query: String
    /// The app the launcher was open over at that moment. An action that pastes after a
    /// wait, by which time the launcher may have been opened over another app, still means
    /// this one.
    let previousApp: AppRef?

    private weak var model: LauncherModel?
    private let pasteService: PasteService

    init(query: String, model: LauncherModel, pasteService: PasteService) {
        self.query = query
        self.model = model
        self.pasteService = pasteService
        previousApp = model.shell?.previousApp
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

    func copy(_ content: PasteContent) {
        pasteService.copy(content)
    }

    func paste(_ content: PasteContent) async -> PasteResult {
        await pasteService.paste(content, into: previousApp)
    }
}
