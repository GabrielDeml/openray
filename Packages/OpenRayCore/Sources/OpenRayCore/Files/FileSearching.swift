/// What "Search Files" asks of Spotlight (docs/DESIGN.md §4.8). `SpotlightSearcher` answers
/// with an `MDQuery`; tests put a fake in its place, so that no test ever searches the
/// files of whoever runs it.
public protocol FileSearching: Sendable {
    /// Runs one Spotlight query.
    ///
    /// - Parameters:
    ///   - queryString: The query in Spotlight's own syntax (`SpotlightQueryBuilder`).
    ///   - limit: The most hits to return. Which of the matches those are is Spotlight's
    ///     choice.
    /// - Returns: The hits, most recently used first. Empty when nothing matches, and also
    ///   when Spotlight could not be asked.
    func hits(matching queryString: String, in scope: FileScope, limit: Int) async -> [FileHit]
}
