/// How a pushed screen talks to the launcher shell (docs/DESIGN.md §4.2.2). The shell makes one
/// for each screen and keeps it for as long as the screen is on the stack.
@MainActor public protocol ScreenContext: AnyObject {
    /// The request the screen was pushed with.
    var request: ScreenRequest { get }
    /// Whether the user is looking at this screen: it is on top of the stack and the launcher
    /// is showing. A screen that keeps itself current by polling stops while this is false;
    /// hiding the launcher pops nothing, so a screen can stay on the stack unseen for hours.
    var isOnScreen: Bool { get }
    /// What the search field holds for this screen.
    var searchText: String { get }
    /// The search text after every change, for as long as the screen is on the stack. The
    /// stream ends when the screen is popped.
    func searchTextChanges() -> AsyncStream<String>
    func setSearchText(_ text: String)
    func setSearchBarMode(_ mode: SearchBarMode)
    /// The rows of a list screen.
    ///
    /// - Parameter query: The search text these rows answer. A list screen calls this once for
    ///   the empty text it starts with and once for every change of the search text, also when
    ///   its rows stay the same. Rows for a text the field has moved on from are dropped, and
    ///   Return pressed after a change waits for the rows that answer it (§4.1.4).
    func setSections(_ sections: [ResultSection], answering query: String)
    /// The actions of a custom screen, listed by ⌘K. Return runs the first of them unless the
    /// screen handles Return itself.
    func setScreenActions(_ actions: [ActionDescriptor])
    /// For what a screen does outside an action: closing the launcher, showing the HUD.
    var actionContext: any ActionContext { get }
}
