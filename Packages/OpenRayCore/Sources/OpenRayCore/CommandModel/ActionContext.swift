import Foundation

/// How a running action talks to the launcher shell.
@MainActor public protocol ActionContext: AnyObject {
    /// The app that was frontmost when the launcher opened.
    var previousApp: AppRef? { get }
    /// The current frame's query.
    var query: String { get }
    /// Call before opening any window outside the panel.
    func closeLauncher()
    /// Shows a transient message and leaves the launcher as it is.
    func showHUD(_ text: String)
    func confirm(_ confirmation: Confirmation) async -> Bool
    func copy(_ content: PasteContent)
    func paste(_ content: PasteContent) async -> PasteResult
    /// The plain text on the clipboard, or nil when it holds none. This reads the general
    /// pasteboard, which macOS may answer with a privacy alert, so an action asks only when
    /// what it does needs the text, and closes the launcher first (§4.9).
    func clipboardText() async -> String?
}

public struct AppRef: Sendable, Hashable {
    public var pid: pid_t
    public var bundleID: String?

    public init(pid: pid_t, bundleID: String?) {
        self.pid = pid
        self.bundleID = bundleID
    }
}

/// One pasteboard representation of a piece of content.
public struct ClipRepresentation: Sendable, Hashable {
    public var uti: String
    public var data: Data

    public init(uti: String, data: Data) {
        self.uti = uti
        self.data = data
    }
}

public enum PasteContent: Sendable, Hashable {
    /// - Parameter cursorOffsetFromEnd: How many characters before the end of the pasted text
    ///   the caret should end up.
    case text(String, cursorOffsetFromEnd: Int?)
    case representations([ClipRepresentation])
}

public enum PasteResult: Sendable, Equatable {
    case pasted
    /// The content is on the pasteboard but was not pasted.
    case copiedOnly(Reason)

    public enum Reason: Sendable, Equatable {
        case noAccessibility
        /// Another app became frontmost before the paste.
        case targetChanged
        case noTarget
    }
}
