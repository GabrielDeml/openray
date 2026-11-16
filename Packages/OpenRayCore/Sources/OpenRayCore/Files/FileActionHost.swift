import Foundation

/// An app that can open a file, as the "Open With" list shows it.
public struct OpenWithApp: Sendable, Hashable {
    /// Where the app's bundle is.
    public var url: URL
    public var name: String
    /// Whether this is the app that opens the file when the user just opens it.
    public var isDefault: Bool

    public init(url: URL, name: String, isDefault: Bool) {
        self.url = url
        self.name = name
        self.isDefault = isDefault
    }

    /// The bundle's path, without the slash that the path of a folder's URL ends in.
    var path: String {
        let path = url.path(percentEncoded: false)
        if path.count > 1 && path.hasSuffix("/") {
            return String(path.dropLast())
        }
        return path
    }
}

/// What the actions of a found file ask of the app target, which has `NSWorkspace`
/// (docs/DESIGN.md §4.8). Tests put a fake in its place, so that no test opens, reveals or
/// trashes a real file.
@MainActor public protocol FileActionHost: AnyObject, Sendable {
    /// Opens the file with its default app.
    func open(_ url: URL) async throws
    func showInFinder(_ url: URL)
    /// Asynchronous because macOS may ask about the file's folder first, and the launcher
    /// has to go on answering its keys while it does.
    func moveToTrash(_ url: URL) async throws
    /// Every app that says it can open the file, in no particular order.
    func appsAbleToOpen(_ url: URL) -> [OpenWithApp]
    func open(_ url: URL, withAppAt appURL: URL) async throws
}
