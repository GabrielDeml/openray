import Testing

@testable import OpenRayCore

@Suite struct FuzzyMatcherTests {
    /// Matches `query`, folded as the search field folds it, against one name.
    private func match(_ query: String, in name: String) -> FuzzyMatch? {
        let folded = Array(SearchQuery(query).normalized.unicodeScalars)
        return FuzzyMatcher.match(folded, in: NormalizedName(name))
    }

    // MARK: Tiers

    @Test func nameEqualToTheQueryIsAnExactMatch() {
        let exact = match("safari", in: "Safari")

        #expect(exact?.quality == 1.0)
        #expect(exact?.matchedOffsets == [0, 1, 2, 3, 4, 5])
    }

    @Test func prefixQualityGrowsWithTheShareOfTheNameItCovers() {
        let inShortName = match("saf", in: "Safari")
        let inLongName = match("saf", in: "Safari Technology Preview")

        // 3 of 6 scalars, and 3 of 25.
        #expect(inShortName?.quality == 0.9 + 0.1 * (3.0 / 6.0))
        #expect(inLongName?.quality == 0.9 + 0.1 * (3.0 / 25.0))
        #expect(inShortName?.matchedOffsets == [0, 1, 2])
    }

    @Test func queryAtTheStartOfALaterWordIsAWordPrefix() {
        let wordPrefix = match("stu", in: "Visual Studio Code")

        #expect(wordPrefix?.quality == 0.8 + 0.1 * (3.0 / 18.0))
        #expect(wordPrefix?.matchedOffsets == [7, 8, 9])
    }

    @Test func wordPrefixTakesTheEarliestWordThatFits() {
        let wordPrefix = match("co", in: "Xcode Code Coverage")

        #expect(wordPrefix?.matchedOffsets == [6, 7])
    }

    @Test func initialsOfTheFirstWordsAreAnAcronym() {
        let acronym = match("vsc", in: "Visual Studio Code")

        #expect(acronym?.quality == 0.75)
        #expect(acronym?.matchedOffsets == [0, 7, 14])
    }

    @Test func acronymCountsACapitalInsideAWord() {
        let acronym = match("gh", in: "GitHub Desktop")

        #expect(acronym?.quality == 0.75)
        #expect(acronym?.matchedOffsets == [0, 3])
    }

    @Test func scatteredLettersAreAFuzzyMatchScoredByTheTable() {
        let fuzzy = match("sfr", in: "Safari")

        // "s" at the start of the name: 16 + 2 × 10. "f" and "r" each 16, and each after one
        // skipped letter, which costs 3. A prefix of three letters would score 88.
        #expect(fuzzy?.quality == 0.7 * 62.0 / 88.0)
        #expect(fuzzy?.matchedOffsets == [0, 2, 4])
    }

    // The next four tests pin the rest of the table's numbers. A prefix of two letters would
    // score 62, one of four letters 114.

    @Test func lettersInARowEarnTheConsecutiveBonus() {
        let fuzzy = match("fari", in: "Safari")

        // "f" is inside a word: 16 and no bonus. Each of the three letters after it follows a
        // match: 16 + 4.
        #expect(fuzzy?.quality == 0.7 * 76.0 / 114.0)
        #expect(fuzzy?.matchedOffsets == [2, 3, 4, 5])
    }

    @Test func gapCostsLessForEveryLetterAfterItsFirst() {
        let fuzzy = match("sr", in: "Safari")

        // "s" at the start of the name: 16 + 2 × 10. The three skipped letters cost 3, 1 and 1.
        // Then "r": 16.
        #expect(fuzzy?.quality == 0.7 * 47.0 / 62.0)
        #expect(fuzzy?.matchedOffsets == [0, 4])
    }

    @Test func wordStartEarnsTheBonusOfItsKind() {
        // In each name "x" scores 16 + 2 × 10, and the second letter 16 plus its bonus: 9 after a
        // delimiter, 7 for a capital inside a word, 8 for a CJK character. The gap before it
        // costs 3 for the first skipped scalar and 1 for each further one.
        #expect(match("xb", in: "x a-b")?.quality == 0.7 * 56.0 / 62.0)
        #expect(match("xh", in: "x gitHub")?.quality == 0.7 * 53.0 / 62.0)
        #expect(match("x信", in: "x 微信")?.quality == 0.7 * 56.0 / 62.0)
    }

    @Test func wordStartInsideARunBeginsARunOfItsOwn() {
        let fuzzy = match("e.js", in: "Node.js")

        // "e": 16. The dot follows it: 16 + 4. "j" starts a word after a delimiter and keeps
        // that bonus: 16 + 9. "s" follows "j" and is worth what the start of its run was: 16 + 9.
        // Had "j" stayed in the run that "e" began, "s" would have earned 16 + 4.
        #expect(fuzzy?.quality == 0.7 * 86.0 / 114.0)
        #expect(fuzzy?.matchedOffsets == [3, 4, 5, 6])
    }

    @Test func fuzzyMatchPrefersWordStartsToLettersInsideWords() {
        // The first "m" is inside "Simulator", the second starts "Manager".
        let fuzzy = match("sma", in: "Simulator Manager")

        #expect(fuzzy?.matchedOffsets == [0, 10, 11])
    }

    // MARK: Order between tiers

    @Test func prefixBeatsFuzzyForTheSameQuery() throws {
        let prefix = try #require(match("saf", in: "Safari"))
        let fuzzy = try #require(match("saf", in: "Salesforce"))

        #expect(prefix.quality > fuzzy.quality)
        #expect(fuzzy.quality <= 0.7)
    }

    @Test func tighterFuzzyMatchBeatsALooserOne() throws {
        let tight = try #require(match("sfr", in: "Safari"))
        let loose = try #require(match("sfr", in: "System Preferences"))

        #expect(tight.quality > loose.quality)
    }

    @Test func fuzzyMatchThatIsTooLooseIsDropped() {
        // The two "c"s are 23 letters apart and neither starts a word: 16 of 62 points.
        let name = NormalizedName("Activity Monitor Preferences")
        let query = Array("cc".unicodeScalars)

        #expect(FuzzyMatcher.isSubsequence(query, of: name))
        #expect(FuzzyMatcher.match(query, in: name) == nil)
    }

    @Test func queryThatIsNotASubsequenceDoesNotMatch() {
        #expect(match("sfx", in: "Safari") == nil)
        #expect(match("irafas", in: "Safari") == nil)
    }

    // MARK: Folding

    @Test func highlightsPointAtOriginalCharactersWhenFoldingChangesTheLength() {
        // "ß" folds to "ss": the name has five characters and six folded scalars.
        let whole = match("grosse", in: "Größe")
        let part = match("gros", in: "Größe")

        #expect(whole?.quality == 1.0)
        #expect(whole?.matchedOffsets == [0, 1, 2, 3, 4])
        #expect(part?.matchedOffsets == [0, 1, 2, 3])
    }

    @Test func fullWidthQueryMatchesLikeItsPlainForm() {
        let fullWidth = match("ＳＡＦ", in: "Safari")

        #expect(fullWidth == match("saf", in: "Safari"))
        #expect(fullWidth?.matchedOffsets == [0, 1, 2])
    }

    // The German name of System Settings comes with one from macOS.
    @Test func softHyphenInANameIsSkipped() {
        let prefix = match("systemeinst", in: "System\u{AD}einstellungen")

        // 11 of the 19 letters. The hyphen is the character at offset 6.
        #expect(prefix?.quality == 0.9 + 0.1 * (11.0 / 19.0))
        #expect(prefix?.matchedOffsets == [0, 1, 2, 3, 4, 5, 7, 8, 9, 10, 11])
    }

    @Test func namesFoldCharacterByCharacterToWhatTheQueryFoldsTo() {
        let names = ["Größe", "Café Müller", "ＳＡＦＡＲＩ", "İstanbul", "がぎぐ", "한글", "微信 Привет"]

        for name in names {
            // Scalar by scalar, as the matcher compares them. Two strings are already equal
            // when they only look the same.
            let queryScalars = Array(SearchQuery(name).normalized.unicodeScalars)
            let nameScalars = NormalizedName(name).scalars
            // A failure here is rare and depends on the name, so the message carries the
            // name and both foldings.
            #expect(
                nameScalars == queryScalars,
                "\(name): the name folds to \(hex(nameScalars)), the query to \(hex(queryScalars))")
        }
    }

    private func hex(_ scalars: [Unicode.Scalar]) -> [String] {
        scalars.map { scalar in String(scalar.value, radix: 16) }
    }

    // A file name is listed from the disk in decomposed form, and an input method types
    // composed text. Folding alone does not bring the two together for Hangul and voiced kana.
    @Test func decomposedTextFoldsToTheSameScalarsAsComposedText() {
        let names = ["한글 뷰어", "ポケモン", "がぎぐ", "Café Müller", "İstanbul"]

        for name in names {
            let composed = name.precomposedStringWithCanonicalMapping
            let decomposed = name.decomposedStringWithCanonicalMapping
            let expectedScalars = NormalizedName(composed).scalars

            #expect(NormalizedName(decomposed).scalars == expectedScalars)
            #expect(Array(SearchQuery(decomposed).normalized.unicodeScalars) == expectedScalars)
        }
    }

    @Test func composedQueryMatchesADecomposedName() {
        let name = "ポケモン".decomposedStringWithCanonicalMapping
        let query = "ポケ".precomposedStringWithCanonicalMapping

        let prefix = match(query, in: name)

        // "ポ" is two scalars in the name and still one character to highlight.
        #expect(prefix?.quality == 0.9 + 0.1 * (2.0 / 4.0))
        #expect(prefix?.matchedOffsets == [0, 1])
    }

    // MARK: Word starts

    @Test func capitalAfterASmallLetterStartsAWord() {
        let name = NormalizedName("GitHub")

        #expect(name.wordStarts == [.afterWhitespace, nil, nil, .caseOrDigitChange, nil, nil])
    }

    @Test func changeBetweenLettersAndDigitsStartsAWord() {
        let name = NormalizedName("mp3 4K")

        #expect(
            name.wordStarts == [
                .afterWhitespace, nil, .caseOrDigitChange, nil,
                .afterWhitespace, .caseOrDigitChange,
            ])
    }

    @Test func characterAfterASeparatorStartsAWordAndTheSeparatorDoesNot() {
        let name = NormalizedName("a-b.c (d)")

        #expect(
            name.wordStarts == [
                .afterWhitespace, nil, .afterDelimiter, nil, .afterDelimiter, nil,
                nil, .afterDelimiter, nil,
            ])
    }

    @Test func everyCJKCharacterStartsAWord() {
        #expect(NormalizedName("微信").wordStarts == [.afterWhitespace, .cjk])
        #expect(NormalizedName("かな").wordStarts == [.afterWhitespace, .cjk])
        #expect(NormalizedName("한글").wordStarts == [.afterWhitespace, .cjk])
    }

    @Test func onlyTheFirstScalarOfAFoldedCharacterStartsAWord() {
        let name = NormalizedName("a ßb")

        #expect(name.characterOffsets == [0, 1, 2, 2, 3])
        #expect(name.wordStarts == [.afterWhitespace, nil, .afterWhitespace, nil, nil])
    }

    // MARK: Input that must not crash

    @Test func emptyQueryAndEmptyNameMatchNothing() {
        #expect(match("", in: "Safari") == nil)
        #expect(match("safari", in: "") == nil)
        #expect(match("", in: "") == nil)
    }

    @Test func queryLongerThanTheNameMatchesNothing() {
        #expect(match("safari browser", in: "Safari") == nil)
        #expect(match(String(repeating: "a", count: 10_000), in: "aaa") == nil)
    }

    @Test func veryLongNameIsCutOffAndStillMatches() {
        let longName = "Report " + String(repeating: "x", count: 5_000) + " final"

        #expect(NormalizedName(longName).scalars.count == NormalizedName.maximumLength)
        #expect(match("rep", in: longName)?.matchedOffsets == [0, 1, 2])
        #expect(match("rx", in: longName) != nil)
        // "final" lies behind the cut.
        #expect(match("final", in: longName) == nil)
        #expect(match(longName, in: longName) == nil)
    }

    @Test func brokenAndUnusualTextDoesNotCrash() {
        // A lone surrogate cannot live in a String; decoding turns it into U+FFFD.
        let loneSurrogate = String(decoding: [0xD83D, 0x0041] as [UInt16], as: UTF16.self)
        let names = [
            loneSurrogate, "\u{301}", "\u{301}abc", "👨‍👩‍👧 Family", "\r\n", "a\u{0}b", "ﬃ", "ǅ",
        ]
        let queries = ["a", "abc", loneSurrogate, "\u{301}", "👨‍👩‍👧", "ffi", "\u{0}"]

        for name in names {
            for query in queries {
                _ = match(query, in: name)
            }
        }
    }

    // MARK: Property

    /// SplitMix64: a few lines, and the same sequence on every run and every machine.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }
    }

    @Test func subsequenceOfANameMatchesWithHighlightsThatSpellTheQuery() throws {
        // Every one of these folds to exactly one scalar, so the highlighted characters can be
        // compared with the query one to one.
        let alphabet = Array("abcdeABCDE0123 -_.éÜñ微信")
        var generator = SeededGenerator(state: 2026)

        for _ in 0..<500 {
            // Up to 10 characters: in a name that short no subsequence is spread thinly enough
            // to fall under the fuzzy threshold.
            let length = Int.random(in: 1...10, using: &generator)
            var name: [Character] = []
            for _ in 0..<length {
                name.append(alphabet.randomElement(using: &generator)!)
            }

            // The search field trims its text, so a query never starts or ends with a space.
            // Leaving spaces out altogether is the simplest way to build one that survives.
            var picked: [Character] = []
            for character in name {
                if character == " " { continue }
                if Bool.random(using: &generator) { picked.append(character) }
            }
            if picked.isEmpty { continue }

            let query = SearchQuery(String(picked)).normalized
            let found = try #require(
                match(query, in: String(name)),
                "\"\(query)\" should match \"\(String(name))\"")

            let offsets = found.matchedOffsets
            for (earlier, later) in zip(offsets, offsets.dropFirst()) {
                #expect(earlier < later)
            }
            let inBounds = offsets.allSatisfy { offset in offset >= 0 && offset < name.count }
            try #require(inBounds)

            var highlighted: [Character] = []
            for offset in offsets {
                highlighted.append(name[offset])
            }
            #expect(SearchQuery(String(highlighted)).normalized == query)
        }
    }
}
