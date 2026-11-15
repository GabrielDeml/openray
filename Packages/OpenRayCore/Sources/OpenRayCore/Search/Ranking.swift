import Foundation

/// The numbers ranking is tuned with (docs/DESIGN.md §4.2.6 and §4.2.7). They are the design's
/// first guesses. §8 item 9 still wants them tuned against real sessions, and they are kept
/// together so that this can happen in one place.
enum RankingTuning {
    /// How long it takes a usage score to halve.
    static let halfLife: TimeInterval = 7 * 24 * 60 * 60

    /// The most that frecency adds to the final rank.
    static let frecencyWeight = 0.15
    /// The frecency that earns all of `frecencyWeight`. The share grows with the logarithm of
    /// the frecency: the first picks of an item say more than the hundredth.
    static let fullFrecency = 16.0

    /// The most that query affinity adds to the final rank.
    static let affinityWeight = 0.25
    /// The affinity that earns all of `affinityWeight`.
    static let fullAffinity = 3.0

    /// Fuzzy matches below this quality are not shown.
    static let minimumFuzzyQuality = 0.2

    /// How many items the empty search field suggests.
    static let suggestionCount = 8
}

/// A row of the ranked section together with the value it is ordered by.
struct RankedRow: Sendable {
    var scored: ScoredItem
    /// For a query the final rank, for the suggestions of the empty field the item's frecency.
    var rank: Double

    /// The match quality plus what usage adds to it. Quality stays dominant: learning can
    /// overturn a near tie, but not lift a loose match over a good one.
    static func finalRank(quality: Double, frecency: Double, affinity: Double) -> Double {
        let fullFrecencyLog = log(1 + RankingTuning.fullFrecency)
        let frecencyShare = min(1, log(1 + frecency) / fullFrecencyLog)
        let affinityShare = min(1, affinity / RankingTuning.fullAffinity)
        return quality
            + RankingTuning.frecencyWeight * frecencyShare
            + RankingTuning.affinityWeight * affinityShare
    }

    /// Gives a row of the ranked section the value it is ordered by. The matcher's rows and the
    /// rows a source returns both get theirs here, so that the two sort as one list.
    static func ranked(
        _ scored: ScoredItem, query: SearchQuery, usage: UsageSnapshot, now: Date
    ) -> RankedRow {
        let id = scored.item.id
        let frecency = usage.frecency(of: id, at: now)
        // The suggestions for the empty field are ordered by frecency alone.
        if query.normalized.isEmpty {
            return RankedRow(scored: scored, rank: frecency)
        }
        let affinity = usage.affinity(of: id, query: query.normalized, at: now)
        let rank = finalRank(quality: scored.quality, frecency: frecency, affinity: affinity)
        return RankedRow(scored: scored, rank: rank)
    }

    /// Whether `first` goes above `second`: by rank, then the shorter title, then the title's
    /// place in the user's alphabet, then the ID, so that the order is the same on every run.
    static func isOrderedBefore(_ first: RankedRow, _ second: RankedRow) -> Bool {
        if first.rank != second.rank { return first.rank > second.rank }

        let firstTitle = first.scored.item.title
        let secondTitle = second.scored.item.title
        if firstTitle.count != secondTitle.count { return firstTitle.count < secondTitle.count }

        let titleOrder = firstTitle.localizedStandardCompare(secondTitle)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }

        return first.scored.item.id.rawValue < second.scored.item.id.rawValue
    }
}

/// What `IndexSnapshot.rank` found for one query.
struct RankedResults: Sendable {
    /// Best first.
    var rows: [RankedRow]
    /// Indices into `entries` of every entry with a name that contains the query as a
    /// subsequence. That is more than `rows`: a match too loose to show for "ab" can be good
    /// enough for "abc". When the next query extends this one, only these need to be looked at.
    var survivors: [Int]
}

extension IndexSnapshot {
    /// Matches every entry against the query and orders the matches (docs/DESIGN.md §4.2.5 to
    /// §4.2.7). An empty query gives the most-used items instead.
    ///
    /// - Parameter candidates: The `survivors` of a ranking of this same snapshot for a query
    ///   that the new one extends, to look at those entries only. nil looks at every entry.
    /// - Returns: nil when the task was cancelled before the ranking was complete.
    @concurrent
    func rank(
        query: SearchQuery, usage: UsageSnapshot, now: Date, candidates: [Int]? = nil
    ) async -> RankedResults? {
        if Task.isCancelled { return nil }

        let queryScalars = Array(query.normalized.unicodeScalars)
        if queryScalars.isEmpty {
            return RankedResults(rows: suggestions(usage: usage, now: now), survivors: [])
        }

        let indicesToScan = candidates ?? Array(entries.indices)
        var rows: [RankedRow] = []
        var survivors: [Int] = []

        for (scanned, entryIndex) in indicesToScan.enumerated() {
            // The next keystroke cancels this search. Looking every 256 entries stops it soon
            // enough without asking for every entry.
            if scanned.isMultiple(of: 256) && Task.isCancelled { return nil }

            let entry = entries[entryIndex]
            let match = bestMatch(of: queryScalars, in: entry)
            if match.isSurvivor {
                survivors.append(entryIndex)
            }
            guard let quality = match.quality else { continue }

            let scored = ScoredItem(
                item: entry.item, quality: quality, placement: .ranked,
                highlights: match.titleHighlights)
            rows.append(RankedRow.ranked(scored, query: query, usage: usage, now: now))
        }

        rows.sort(by: RankedRow.isOrderedBefore)
        return RankedResults(rows: rows, survivors: survivors)
    }

    private struct EntryMatch {
        /// Whether any name contains the query as a subsequence, shown or not.
        var isSurvivor = false
        /// The best quality among the names, each multiplied by its weight. nil when no name
        /// matches well enough.
        var quality: Double?
        /// Where the query sits in the title. Empty when the entry was only found by another
        /// name: offsets into a transliteration mean nothing in the title.
        var titleHighlights: [Range<Int>] = []
    }

    private func bestMatch(of query: [Unicode.Scalar], in entry: Entry) -> EntryMatch {
        var best = EntryMatch()
        for name in entry.names {
            guard FuzzyMatcher.isSubsequence(query, of: name.normalized) else { continue }
            best.isSurvivor = true

            guard let match = FuzzyMatcher.match(query, in: name.normalized) else { continue }
            let weighted = match.quality * name.weight
            let bestSoFar = best.quality ?? 0
            if weighted > bestSoFar {
                best.quality = weighted
            }
            if name.isTitle {
                best.titleHighlights = Self.ranges(ofSortedOffsets: match.matchedOffsets)
            }
        }
        return best
    }

    /// Joins neighbouring offsets into ranges: 0, 1, 2, 5, 6 become 0..<3 and 5..<7.
    private static func ranges(ofSortedOffsets offsets: [Int]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for offset in offsets {
            if let last = ranges.last, last.upperBound == offset {
                ranges[ranges.count - 1] = last.lowerBound..<offset + 1
            } else {
                ranges.append(offset..<offset + 1)
            }
        }
        return ranges
    }

    /// The rows for the empty search field: the most-used items, most frecent first. Items that
    /// were never picked are left out, so a fresh install suggests nothing instead of eight
    /// arbitrary apps.
    private func suggestions(usage: UsageSnapshot, now: Date) -> [RankedRow] {
        var rows: [RankedRow] = []
        for entry in entries {
            let frecency = usage.frecency(of: entry.item.id, at: now)
            if frecency <= 0 { continue }
            let scored = ScoredItem(item: entry.item, quality: 0, placement: .ranked)
            rows.append(RankedRow(scored: scored, rank: frecency))
        }
        rows.sort(by: RankedRow.isOrderedBefore)
        return Array(rows.prefix(RankingTuning.suggestionCount))
    }
}
