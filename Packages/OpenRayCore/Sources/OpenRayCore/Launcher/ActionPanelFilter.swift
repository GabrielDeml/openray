/// Decides which actions the action panel lists for the text typed into its filter
/// (docs/DESIGN.md §4.1.6).
public enum ActionPanelFilter {
    /// The actions whose title matches `filter`, in the order they were given. An empty filter
    /// keeps them all.
    ///
    /// The order is not changed by how well a title matches: the list is a handful of rows, and
    /// the primary action staying first matters more than the best match rising.
    public static func actions(
        _ actions: [ActionDescriptor], matching filter: String
    ) -> [ActionDescriptor] {
        // Folded as a search query is, so the filter finds what the search field would.
        let foldedFilter = Array(SearchQuery(filter).normalized.unicodeScalars)
        if foldedFilter.isEmpty { return actions }

        var matching: [ActionDescriptor] = []
        for action in actions {
            let title = NormalizedName(action.title)
            if FuzzyMatcher.match(foldedFilter, in: title) != nil {
                matching.append(action)
            }
        }
        return matching
    }
}
