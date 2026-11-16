import Foundation
import Testing

import OpenRayCore

@Suite struct SpotlightQueryBuilderTests {
    private let noApplications = #"kMDItemContentTypeTree != "com.apple.application-bundle""#

    @Test func oneWordIsAPrefixInOnePassAndASubstringInTheOther() {
        #expect(
            SpotlightQueryBuilder.build("report", pass: .namePrefix)
                == #"kMDItemFSName == "report*"cd && "# + noApplications)
        #expect(
            SpotlightQueryBuilder.build("report", pass: .nameSubstring)
                == #"kMDItemFSName == "*report*"cd && "# + noApplications)
    }

    @Test func onlyTheFirstWordIsAPrefix() {
        #expect(
            SpotlightQueryBuilder.build("annual report", pass: .namePrefix)
                == #"kMDItemFSName == "annual*"cd && kMDItemFSName == "*report*"cd && "#
                + noApplications)
        #expect(
            SpotlightQueryBuilder.build("annual report", pass: .nameSubstring)
                == #"kMDItemFSName == "*annual*"cd && kMDItemFSName == "*report*"cd && "#
                + noApplications)
    }

    @Test func whitespaceAroundAndBetweenTheWordsIsNotSearchedFor() {
        let tidy = SpotlightQueryBuilder.build("annual report", pass: .namePrefix)

        #expect(SpotlightQueryBuilder.build("  annual \t  report\n", pass: .namePrefix) == tidy)
        #expect(SpotlightQueryBuilder.tokens(of: "  annual \t  report\n") == ["annual", "report"])
    }

    @Test func textWithoutAWordHasNoQuery() {
        #expect(SpotlightQueryBuilder.build("", pass: .namePrefix) == nil)
        #expect(SpotlightQueryBuilder.build("  \t ", pass: .nameSubstring) == nil)
    }

    @Test func quotesAsterisksAndBackslashesAreEscaped() {
        // A quote would end the value early, and an asterisk would match anything.
        #expect(
            SpotlightQueryBuilder.build(#"say"hi"#, pass: .nameSubstring)
                == #"kMDItemFSName == "*say\"hi*"cd && "# + noApplications)
        #expect(
            SpotlightQueryBuilder.build("a*b", pass: .nameSubstring)
                == #"kMDItemFSName == "*a\*b*"cd && "# + noApplications)
        #expect(
            SpotlightQueryBuilder.build(#"a\b"#, pass: .nameSubstring)
                == #"kMDItemFSName == "*a\\b*"cd && "# + noApplications)
    }

    @Test func backslashIsEscapedBeforeTheOthersAndOnlyOnce() {
        // A backslash in front of a quote: two for the backslash, then one more and the quote.
        #expect(
            SpotlightQueryBuilder.build(#"\""#, pass: .namePrefix)
                == #"kMDItemFSName == "\\\"*"cd && "# + noApplications)
    }

    @Test func applicationsAreLeftOutByTheLastClauseOfEveryQuery() throws {
        for pass in [SpotlightQueryBuilder.Pass.namePrefix, .nameSubstring] {
            let query = try #require(SpotlightQueryBuilder.build("one two three", pass: pass))
            #expect(query.hasSuffix(" && " + noApplications))
            #expect(query.components(separatedBy: " && ").count == 4)
        }
    }

    @Test func canaryAsksForApplications() {
        #expect(
            SpotlightQueryBuilder.canary
                == #"kMDItemContentTypeTree == "com.apple.application-bundle""#)
    }
}
