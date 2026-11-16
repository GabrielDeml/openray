import Foundation

/// Orders what Spotlight found (docs/DESIGN.md §4.8). Spotlight returns a subset it chooses
/// itself, most recently used first, so the order that matters to the user is made here: how
/// well the name fits, how recently the file was used, how often it was picked in OpenRay,
/// and where it lies.
public enum FileRanker {
    /// The numbers the ranking is tuned with. They are first guesses: nothing here has seen
    /// the files of a real home folder yet (§8, item 17).
    enum Tuning {
        /// The most a recently used file gains over one that was never opened.
        static let recencyWeight = 0.1
        /// After this many days without being opened, a file gains half of that.
        static let recencyHalfLifeInDays = 30.0

        /// Folders whose contents are rarely what someone searches for by name: settings and
        /// caches, dependencies, the insides of a repository, and what was thrown away.
        static let noisyFolders: Set<String> = ["Library", "node_modules", ".git", ".Trash"]
        /// The two folders of a Library that hold the user's own documents: iCloud Drive, and
        /// the drives of Dropbox, OneDrive and their like. What lies in them is not noise.
        static let cloudFoldersOfLibrary: Set<String> = ["Mobile Documents", "CloudStorage"]
        /// What a file inside a noisy folder loses: enough to put a name that starts with the
        /// query below a name elsewhere that has it at the start of a later word.
        static let noisyFolderPenalty = 0.3

        /// A path of this many parts costs nothing: `/Users/name/Documents/Taxes/2026.pdf`.
        static let freeDepth = 5
        /// What every part beyond that costs.
        static let depthPenalty = 0.01
    }

    /// - Parameter query: The text of the search field, as typed.
    /// - Returns: The hits, best first.
    public static func rank(
        _ hits: [FileHit], query: String, usage: UsageSnapshot, now: Date
    ) -> [FileHit] {
        var foldedTokens: [[Unicode.Scalar]] = []
        for token in SpotlightQueryBuilder.tokens(of: query) {
            foldedTokens.append(Array(SearchQuery(token).normalized.unicodeScalars))
        }
        // The form picks are stored under (§4.2.7).
        let foldedQuery = SearchQuery(query).normalized

        var ranked: [(hit: FileHit, rank: Double)] = []
        for hit in hits {
            let id = hit.itemID
            var rank = RankedRow.finalRank(
                quality: nameQuality(of: hit.name, for: foldedTokens),
                frecency: usage.frecency(of: id, at: now),
                affinity: usage.affinity(of: id, query: foldedQuery, at: now))
            rank += recencyShare(of: hit.lastUsed, at: now)
            rank -= pathPenalty(of: hit.path)
            ranked.append((hit, rank))
        }

        ranked.sort { first, second in
            if first.rank != second.rank { return first.rank > second.rank }
            // The shorter path, then the path itself, so that the order is the same on
            // every run.
            let firstPath = first.hit.path
            let secondPath = second.hit.path
            if firstPath.count != secondPath.count { return firstPath.count < secondPath.count }
            return firstPath < secondPath
        }
        return ranked.map(\.hit)
    }

    /// How well the name fits the words of the query: the mean of what the matcher of root
    /// search makes of each word. Each word is matched on its own, so "annual report" finds
    /// `report-annual.pdf` as well as `annual-report.pdf`.
    private static func nameQuality(of name: String, for tokens: [[Unicode.Scalar]]) -> Double {
        if tokens.isEmpty { return 0 }

        let normalizedName = NormalizedName(name)
        var sum = 0.0
        for token in tokens {
            // Spotlight said the word is in the name. Where the matcher finds the match too
            // loose to count, the word adds nothing, and the file stays in the list.
            sum += FuzzyMatcher.match(token, in: normalizedName)?.quality ?? 0
        }
        return sum / Double(tokens.count)
    }

    private static func recencyShare(of lastUsed: Date?, at now: Date) -> Double {
        guard let lastUsed else { return 0 }
        // A date in the future, after the clock was set back, counts as now.
        let ageInDays = max(0, now.timeIntervalSince(lastUsed)) / (24 * 60 * 60)
        return Tuning.recencyWeight * pow(2, -ageInDays / Tuning.recencyHalfLifeInDays)
    }

    private static func pathPenalty(of path: String) -> Double {
        let parts = path.split(separator: "/")
        var penalty = 0.0

        // The folders the file lies in. A folder named Library is itself a fair thing to
        // search for.
        let foldersAbove = Array(parts.dropLast())
        if liesInNoisyFolder(foldersAbove) {
            penalty += Tuning.noisyFolderPenalty
        }

        let partsBeyondFreeDepth = max(0, parts.count - Tuning.freeDepth)
        penalty += Double(partsBeyondFreeDepth) * Tuning.depthPenalty
        return penalty
    }

    private static func liesInNoisyFolder(_ foldersAbove: [Substring]) -> Bool {
        for (index, folder) in foldersAbove.enumerated() {
            guard Tuning.noisyFolders.contains(String(folder)) else { continue }

            // `~/Library/Mobile Documents` is iCloud Drive: documents, although the path
            // goes through a Library.
            let nextIndex = index + 1
            if folder == "Library" && nextIndex < foldersAbove.count {
                let folderBelow = String(foldersAbove[nextIndex])
                if Tuning.cloudFoldersOfLibrary.contains(folderBelow) { continue }
            }
            return true
        }
        return false
    }
}
