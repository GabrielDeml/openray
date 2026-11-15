import Foundation

public enum SourceLatency: Sendable {
    /// Answers in under 5 ms.
    case inline
    case slow
}

public struct SearchQuery: Sendable, Hashable {
    /// The text as typed.
    public var raw: String
    /// `raw` without surrounding whitespace, folded for case, diacritics and width.
    public var normalized: String
    /// The first whitespace-separated token of `raw`.
    public var head: String
    /// Everything after `head`, without surrounding whitespace.
    public var tail: String

    public init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let headEnd = trimmed.firstIndex(where: \.isWhitespace) ?? trimmed.endIndex

        self.raw = raw
        normalized = trimmed.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        head = String(trimmed[..<headEnd])
        tail = trimmed[headEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Where items come from. A source can contribute indexed items, query-specific results, or both.
public protocol SearchSource: Sendable {
    var id: SourceID { get }
    var latency: SourceLatency { get }
    /// Items matched and ranked centrally. Yields the full set on start and again on every change.
    func indexedItems() -> AsyncStream<[SearchItem]>
    /// Results computed from the query (calculator answer, "Quit <app>"). nil = nothing to add.
    func results(for query: SearchQuery) async throws -> [ScoredItem]?
}

extension SearchSource {
    public func indexedItems() -> AsyncStream<[SearchItem]> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    public func results(for query: SearchQuery) async throws -> [ScoredItem]? {
        nil
    }
}
