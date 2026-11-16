import Observation
import OpenRayCore

/// What a pushed screen and the launcher know about each other (docs/DESIGN.md §4.2.2). The
/// screen's feature talks to it as a `ScreenContext`; the model and the views read what the
/// screen has set.
@Observable
final class LauncherScreenContext: ScreenContext {
    let request: ScreenRequest
    let actionContext: any ActionContext

    private(set) var searchText = ""
    /// What the screen has made of the search bar since it was pushed. nil leaves the bar as
    /// the screen's `ScreenSpec` asked for it.
    private(set) var searchBarMode: SearchBarMode?
    /// The rows of a list screen.
    private(set) var sections: [ResultSection] = []
    /// The search text `sections` answer. nil until the screen has set rows, which a custom
    /// screen never does.
    private(set) var answeredQuery: String?
    private(set) var screenActions: [ActionDescriptor] = []

    @ObservationIgnored private weak var model: LauncherModel?
    @ObservationIgnored private var searchTextContinuations: [AsyncStream<String>.Continuation] =
        []

    init(request: ScreenRequest, model: LauncherModel, actionContext: any ActionContext) {
        self.request = request
        self.model = model
        self.actionContext = actionContext
    }

    // MARK: ScreenContext

    var isOnScreen: Bool {
        model?.isShowing(self) ?? false
    }

    func searchTextChanges() -> AsyncStream<String> {
        let (changes, continuation) = AsyncStream.makeStream(of: String.self)
        searchTextContinuations.append(continuation)
        return changes
    }

    func setSearchText(_ text: String) {
        model?.screen(self, wantsSearchText: text)
    }

    func setSearchBarMode(_ mode: SearchBarMode) {
        searchBarMode = mode
        model?.screenDidChangeSearchBar(self)
    }

    func setSections(_ sections: [ResultSection], answering query: String) {
        // Rows for a text the field has moved on from are not drawn, as the reducer does not
        // take them. It is still told of them: that is how it learns that this screen answers
        // its queries at all.
        if query == searchText {
            self.sections = sections
            answeredQuery = query
        }
        model?.screen(self, didAnswer: query, with: sections)
    }

    func setScreenActions(_ actions: [ActionDescriptor]) {
        screenActions = actions
        model?.screenDidSetActions(self)
    }

    // MARK: For the launcher

    /// The user typed on this screen.
    func receiveSearchText(_ text: String) {
        searchText = text
        for continuation in searchTextContinuations {
            continuation.yield(text)
        }
    }

    /// The screen was popped. Ends the streams its feature may still be reading.
    func close() {
        for continuation in searchTextContinuations {
            continuation.finish()
        }
        searchTextContinuations = []
    }
}
