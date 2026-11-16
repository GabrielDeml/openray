// Scoring scheme and constants from fzf (MIT licence), github.com/junegunn/fzf, src/algo/algo.go

/// A query found in one name.
struct FuzzyMatch: Sendable, Equatable {
    /// How good the match is, 0...1. See the tiers of `FuzzyMatcher.match`.
    var quality: Double
    /// Offsets of the matched characters in the original name, strictly increasing.
    var matchedOffsets: [Int]
}

/// Matches a folded query against a folded name (docs/DESIGN.md §4.2.6).
enum FuzzyMatcher {
    // The quality of each tier. Prefix and word-prefix matches add up to `coverageShare` for the
    // part of the name the query covers, so that "saf" ranks Safari above Safari Technology
    // Preview.
    private static let exactQuality = 1.0
    private static let prefixQuality = 0.9
    private static let wordPrefixQuality = 0.8
    private static let acronymQuality = 0.75
    private static let bestFuzzyQuality = 0.7
    private static let coverageShare = 0.1

    /// The tiers are tried from best to worst, and the first that applies gives the quality:
    /// the name equals the query; starts with it; has it at the start of a later word; has it as
    /// the initials of its first words ("vsc" in Visual Studio Code); contains it as a
    /// subsequence, scored by how well the letters sit together.
    ///
    /// - Parameter query: The folded query, one element per unicode scalar
    ///   (`SearchQuery.normalized`).
    /// - Returns: nil when the query is empty, is not a subsequence of the name, or matches too
    ///   loosely to be worth showing.
    static func match(_ query: [Unicode.Scalar], in name: NormalizedName) -> FuzzyMatch? {
        let queryLength = query.count
        let nameLength = name.scalars.count
        if queryLength == 0 || queryLength > nameLength { return nil }

        let coverage = Double(queryLength) / Double(nameLength)

        if name.scalars == query {
            return FuzzyMatch(
                quality: exactQuality,
                matchedOffsets: characterOffsets(of: Array(0..<nameLength), in: name))
        }

        if name.scalars.starts(with: query) {
            return FuzzyMatch(
                quality: prefixQuality + coverageShare * coverage,
                matchedOffsets: characterOffsets(of: Array(0..<queryLength), in: name))
        }

        if let start = wordPrefixStart(of: query, in: name) {
            return FuzzyMatch(
                quality: wordPrefixQuality + coverageShare * coverage,
                matchedOffsets: characterOffsets(
                    of: Array(start..<start + queryLength), in: name))
        }

        if let initials = acronymPositions(of: query, in: name) {
            return FuzzyMatch(
                quality: acronymQuality,
                matchedOffsets: characterOffsets(of: initials, in: name))
        }

        guard let alignment = bestAlignment(of: query, in: name) else { return nil }
        let bestPossibleScore = maximumScore(queryLength: queryLength)
        let quality = bestFuzzyQuality * Double(alignment.score) / Double(bestPossibleScore)
        if quality < RankingTuning.minimumFuzzyQuality { return nil }
        return FuzzyMatch(
            quality: quality,
            matchedOffsets: characterOffsets(of: alignment.positions, in: name))
    }

    /// Whether the scalars of `query` appear in `name` in the same order, with anything in
    /// between. Every match is such a subsequence, but one that is spread too thinly over the
    /// name is not a match.
    static func isSubsequence(_ query: [Unicode.Scalar], of name: NormalizedName) -> Bool {
        var found = 0
        for scalar in name.scalars {
            if found == query.count { break }
            if scalar == query[found] { found += 1 }
        }
        return found == query.count
    }

    /// Turns positions in the folded name into offsets of the original characters. One character
    /// can fold to several scalars ("ß" to "ss"), so an offset can come up twice in a row.
    private static func characterOffsets(of positions: [Int], in name: NormalizedName) -> [Int] {
        var offsets: [Int] = []
        for position in positions {
            let offset = name.characterOffsets[position]
            if offsets.last != offset { offsets.append(offset) }
        }
        return offsets
    }

    // MARK: Word prefix and acronym

    /// The earliest word start at which the whole query follows without a gap.
    private static func wordPrefixStart(
        of query: [Unicode.Scalar], in name: NormalizedName
    ) -> Int? {
        let lastStart = name.scalars.count - query.count
        for start in 0...lastStart {
            guard name.isWordStart(at: start) else { continue }
            let candidate = name.scalars[start..<start + query.count]
            if candidate.elementsEqual(query) { return start }
        }
        return nil
    }

    /// The positions of the name's first word starts when the query spells their scalars:
    /// "gh" finds the G and the H of GitHub Desktop.
    private static func acronymPositions(
        of query: [Unicode.Scalar], in name: NormalizedName
    ) -> [Int]? {
        var positions: [Int] = []
        for position in name.scalars.indices {
            guard name.isWordStart(at: position) else { continue }
            let expected = query[positions.count]
            if name.scalars[position] != expected { return nil }
            positions.append(position)
            if positions.count == query.count { return positions }
        }
        return nil
    }

    // MARK: Fuzzy

    // fzf's constants. A match earns points, and more at a word start or right after another
    // match. Every name scalar skipped between two matches costs points.
    private static let matchPoints = 16
    private static let gapStartPenalty = 3
    private static let gapExtensionPenalty = 1
    private static let boundaryBonus = 8
    private static let whitespaceBoundaryBonus = 10
    private static let delimiterBoundaryBonus = 9
    private static let caseOrDigitChangeBonus = 7
    private static let consecutiveBonus = 4
    private static let firstMatchBonusMultiplier = 2

    private static func bonus(for wordStart: WordStart?) -> Int {
        switch wordStart {
        case nil: return 0
        case .afterWhitespace: return whitespaceBoundaryBonus
        case .afterDelimiter: return delimiterBoundaryBonus
        case .cjk: return boundaryBonus
        case .caseOrDigitChange: return caseOrDigitChangeBonus
        }
    }

    /// What a query of this length scores as the prefix of a name: every scalar matches, the
    /// first with the doubled bonus of the name's start, the others inheriting that bonus as
    /// part of one run.
    private static func maximumScore(queryLength: Int) -> Int {
        let firstMatch = matchPoints + firstMatchBonusMultiplier * whitespaceBoundaryBonus
        let laterMatch = matchPoints + whitespaceBoundaryBonus
        return firstMatch + laterMatch * (queryLength - 1)
    }

    private struct Alignment {
        var score: Int
        /// Where each query scalar sits in the folded name.
        var positions: [Int]
    }

    /// The best-scoring way to lay the query over the name as a subsequence, or nil when it is
    /// not one. This follows the dynamic programme of fzf's `FuzzyMatchV2`: a table with a row
    /// per query scalar and a column per name scalar, filled from the top left.
    private static func bestAlignment(
        of query: [Unicode.Scalar], in name: NormalizedName
    ) -> Alignment? {
        // Row `r` starts at the leftmost column where query[r] can sit. Left of it no alignment
        // of query[0...r] exists, and starting there keeps such cells out of the table.
        guard let firstColumns = leftmostPositions(of: query, in: name) else { return nil }

        let rowCount = query.count
        let columnCount = name.scalars.count
        // `scores`: the best score of matching query[0...row] somewhere in name[0...column].
        // `runLengths`: how many matches in a row end in this cell, or 0 when the best way to
        // this cell skips its name scalar.
        var scores = [Int](repeating: 0, count: rowCount * columnCount)
        var runLengths = [Int](repeating: 0, count: rowCount * columnCount)

        for row in 0..<rowCount {
            let firstColumn = firstColumns[row]
            for column in firstColumn..<columnCount {
                let cell = row * columnCount + column

                // Skipping this name scalar continues from the cell on the left.
                var gapScore = 0
                if column > firstColumn {
                    let leftCell = cell - 1
                    let leftIsGap = runLengths[leftCell] == 0
                    let penalty = leftIsGap ? gapExtensionPenalty : gapStartPenalty
                    gapScore = scores[leftCell] - penalty
                }

                // Matching it continues from the cell up and to the left: the previous query
                // scalar, matched somewhere before this column.
                var matchScore = 0
                var runLength = 0
                if name.scalars[column] == query[row] {
                    var scoreBefore = 0
                    var runBefore = 0
                    if row > 0 {
                        let diagonalCell = cell - columnCount - 1
                        scoreBefore = scores[diagonalCell]
                        runBefore = runLengths[diagonalCell]
                    }

                    var matchBonus = bonus(for: name.wordStarts[column])
                    runLength = runBefore + 1
                    if runLength > 1 {
                        let runStart = column - runLength + 1
                        let runStartBonus = bonus(for: name.wordStarts[runStart])
                        if matchBonus >= boundaryBonus && matchBonus > runStartBonus {
                            // A stronger word start than the one the run began at. It begins
                            // a run of its own and keeps its bonus.
                            runLength = 1
                        } else {
                            // Inside a run every match is worth at least what its start was.
                            matchBonus = max(matchBonus, consecutiveBonus, runStartBonus)
                        }
                    }
                    if row == 0 {
                        matchBonus *= firstMatchBonusMultiplier
                    }

                    matchScore = scoreBefore + matchPoints + matchBonus
                    if matchScore < gapScore {
                        runLength = 0
                    }
                }

                scores[cell] = max(matchScore, gapScore, 0)
                runLengths[cell] = runLength
            }
        }

        // The leftmost of the best cells in the last row. A best cell is always a match: a
        // skipped cell scores less than its left neighbour.
        let lastRow = (rowCount - 1) * columnCount
        var bestColumn = firstColumns[rowCount - 1]
        for column in bestColumn..<columnCount {
            if scores[lastRow + column] > scores[lastRow + bestColumn] {
                bestColumn = column
            }
        }

        // Walk back from there: up and left through a match, left through a skipped scalar.
        // The walk cannot leave the table, because the first cell of every row is a match.
        var positions: [Int] = []
        var row = rowCount - 1
        var column = bestColumn
        while row >= 0 {
            if runLengths[row * columnCount + column] > 0 {
                positions.append(column)
                row -= 1
            }
            column -= 1
        }
        positions.reverse()

        return Alignment(score: scores[lastRow + bestColumn], positions: positions)
    }

    /// The linear check that runs before the table is built: the leftmost position each query
    /// scalar can take in the name, or nil when the query is not a subsequence of it.
    private static func leftmostPositions(
        of query: [Unicode.Scalar], in name: NormalizedName
    ) -> [Int]? {
        var positions: [Int] = []
        for (position, scalar) in name.scalars.enumerated() {
            if scalar != query[positions.count] { continue }
            positions.append(position)
            if positions.count == query.count { return positions }
        }
        return nil
    }
}
