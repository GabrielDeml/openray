import Foundation

/// A named piece of plain text the user pastes from the launcher (docs/DESIGN.md §4.9).
public struct Snippet: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// A short word the snippet is also found by. nil for a snippet without one; no two
    /// snippets share a keyword.
    public var keyword: String?
    /// The text as the user wrote it, placeholders such as `{date}` included.
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), name: String, keyword: String? = nil, body: String, createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var itemID: ItemID { .snippet(id) }

    /// The first line of the text that has anything on it, for a row with room for one line.
    /// It is the text as written, placeholders and all: it says which snippet this is, not
    /// what would be pasted.
    public var firstLine: String {
        let lines = body.split(whereSeparator: \.isNewline)
        return String(lines.first ?? "")
    }
}
