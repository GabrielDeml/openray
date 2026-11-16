import Foundation
import Testing

import OpenRayCore

/// The one test that runs a real Spotlight query. It runs only when the environment variable
/// `OPENRAY_SPOTLIGHT_TESTS` is `1`, as the benchmarks run only when theirs is set, so the
/// `swift test` that gates CI builds it and reports it as skipped.
///
/// This is not a member of the suite, because the attribute on that type could not refer to
/// it: the compiler calls that a circular reference.
private let spotlightTestsAreSwitchedOn =
    ProcessInfo.processInfo.environment["OPENRAY_SPOTLIGHT_TESTS"] == "1"

/// `SpotlightSearcher` against the real index (docs/DESIGN.md §5.4), scoped to
/// `/System/Applications`: a folder every Mac has, that holds nothing of the user's. Every
/// other test of file search uses `FakeFileSearcher`.
@Suite(.enabled(if: spotlightTestsAreSwitchedOn), .timeLimit(.minutes(1)))
struct SpotlightSearcherTests {
    @Test func canaryQueryReturnsNothingOutsideItsScopeAndNoMoreThanAsked() async {
        let systemApplications = FileScope(kind: .folders, folders: ["/System/Applications"])

        let hits = await SpotlightSearcher().hits(
            matching: SpotlightQueryBuilder.canary, in: systemApplications, limit: 5)

        // No hits at all is a pass too: a Mac whose index is off, or a CI runner without one.
        #expect(hits.count <= 5)
        for hit in hits {
            #expect(hit.path.hasPrefix("/System/Applications/"))
        }
        // Printed as the benchmarks print their timings: whoever asked for this test wants
        // to know whether Spotlight answered, and a pass does not say.
        print("[spotlight] \(hits.count) hits in /System/Applications")
    }
}
