public enum Placement: Sendable {
    /// Ordered by rank among the other results.
    case ranked
    /// Above the ranked results, whatever its rank.
    case pinnedTop
    /// In the fallback section, which is shown only when the ranked section is empty. The item
    /// acts on the whole query: "Search Google for …" (§4.2.9).
    case fallback
}

/// An item as the results list shows it.
public struct ScoredItem: Sendable {
    public var item: SearchItem
    /// Match quality, 0...1.
    public var quality: Double
    public var placement: Placement
    /// Character offsets into the item's title.
    public var highlights: [Range<Int>]

    public init(
        item: SearchItem,
        quality: Double,
        placement: Placement = .ranked,
        highlights: [Range<Int>] = []
    ) {
        self.item = item
        self.quality = quality
        self.placement = placement
        self.highlights = highlights
    }
}

public struct ResultSection: Sendable, Identifiable {
    public let id: String
    /// `nil` for a section without a header.
    public var title: String?
    public var rows: [ScoredItem]

    public init(id: String, title: String? = nil, rows: [ScoredItem]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

public struct SearchResults: Sendable {
    public var sections: [ResultSection]
    /// The `LauncherState.generation` of the query these results answer.
    public var generation: UInt64

    public init(sections: [ResultSection], generation: UInt64) {
        self.sections = sections
        self.generation = generation
    }
}
