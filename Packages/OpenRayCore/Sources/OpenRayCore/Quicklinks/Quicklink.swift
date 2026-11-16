import Foundation

/// A named URL the user opens from the launcher, optionally with an argument
/// (docs/DESIGN.md §4.2.9).
public struct Quicklink: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// The URL, with `{query}` where the argument goes.
    public var template: String
    /// The bundle identifier of the app to open the URL with. nil opens it with the default
    /// app for its scheme.
    public var openWith: String?
    /// An emoji, or `sf:` followed by an SF Symbol name. nil gives the default icon.
    public var icon: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(), name: String, template: String, openWith: String? = nil,
        icon: String? = nil, createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.template = template
        self.openWith = openWith
        self.icon = icon
        self.createdAt = createdAt
    }

    public var itemID: ItemID { .quicklink(id) }
}
