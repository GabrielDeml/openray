import Foundation
import Observation

/// The screen that asks for a quicklink's argument: the search field is its input line, and
/// Return opens the quicklink with what was typed (docs/DESIGN.md §4.2.9).
@MainActor @Observable public final class QuicklinkArgumentModel {
    public let quicklink: Quicklink
    /// What the search field is on this screen: the line the argument is typed into.
    public let searchBarMode: SearchBarMode
    /// What the field holds, kept here so that the screen's view redraws when it changes.
    public private(set) var argument: String

    @ObservationIgnored private var following: Task<Void, Never>?

    public init(quicklink: Quicklink, opener: any QuicklinkOpening, context: any ScreenContext) {
        self.quicklink = quicklink
        argument = context.searchText

        let placeholder = String(
            localized: "Type the text for \(quicklink.name)", bundle: .module,
            comment:
                "The placeholder of the search field while it takes the argument of a quicklink, which is named."
        )
        searchBarMode = .input(placeholder: placeholder)

        // The action reads the field when it runs, so one descriptor serves for whatever the
        // user goes on to type.
        let title = QuicklinkSource.openTitle
        let open = ActionDescriptor(id: ActionID(rawValue: "open"), title: title) {
            [weak context] actionContext in
            let typed = context?.searchText ?? ""
            let argument = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            try await QuicklinkSource.open(
                quicklink, argument: argument, opener: opener, context: actionContext)
            return .closeLauncher
        }
        context.setScreenActions([open])

        let changes = context.searchTextChanges()
        // The stream ends when the screen is popped, and the task with it.
        following = Task { [weak self] in
            for await text in changes {
                self?.argument = text
            }
        }
    }

    deinit {
        following?.cancel()
    }

    /// The URL that Return would open now, to show under the field. nil while the template
    /// does not make a URL with this argument.
    public var preview: String? {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = try? QuicklinkTemplate.url(for: quicklink, argument: trimmed)
        return url?.absoluteString
    }
}
