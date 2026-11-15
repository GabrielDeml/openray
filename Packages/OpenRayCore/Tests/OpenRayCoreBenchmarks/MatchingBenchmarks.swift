import Foundation
import Testing

@testable import OpenRayCore

extension Benchmarks {
    /// What a keystroke costs in the matcher: one query ranked against an index far larger than
    /// a Mac's apps and commands (docs/DESIGN.md §4.1.9, §4.2.5).
    @Suite struct MatchingBenchmarks {
        private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        // Every first word is paired with every second word, which gives about 5,000 names
        // that look like the names of apps. The lists are fixed, so every run ranks the same
        // index.
        private static let firstWords = [
            "Activity", "Air", "Atlas", "Audio", "Aurora", "Backup", "Beacon", "Binary",
            "Bright", "Calendar", "Canvas", "Cipher", "Cloud", "Color", "Copper", "Crystal",
            "Daily", "Delta", "Desk", "Digital", "Disk", "Echo", "Ember", "Falcon",
            "Field", "Final", "Focus", "Forest", "Frame", "Garden", "Ghost", "Glass",
            "Golden", "Harbor", "Hidden", "Hyper", "Index", "Iron", "Island", "Jade",
            "Karma", "Lantern", "Light", "Lunar", "Magic", "Maple", "Metro", "Mirror",
            "Night", "Noble", "Nova", "Ocean", "Open", "Paper", "Pixel", "Pocket",
            "Quick", "Quiet", "Rapid", "River", "Safe", "Secret", "Silver", "Smart",
            "Solar", "Stone", "Studio", "Swift", "Tiny", "Ultra", "Velvet", "Wild",
        ]
        private static let secondWords = [
            "Access", "Agent", "Analyzer", "Archive", "Assistant", "Board", "Book", "Browser",
            "Builder", "Capture", "Center", "Chat", "Clock", "Commander", "Composer", "Console",
            "Converter", "Dashboard", "Designer", "Diary", "Drive", "Editor", "Explorer", "Finder",
            "Gallery", "Guard", "Helper", "Hub", "Inspector", "Journal", "Keeper", "Lab",
            "Library", "Mail", "Manager", "Maps", "Messenger", "Mixer", "Monitor", "Music",
            "Notes", "Organizer", "Painter", "Player", "Preview", "Reader", "Recorder", "Remote",
            "Runner", "Scanner", "Scheduler", "Server", "Sheets", "Sketch", "Slides", "Space",
            "Stream", "Sync", "Tasks", "Terminal", "Timer", "Tracker", "Translator", "Tuner",
            "Utility", "Vault", "Viewer", "Wallet", "Weather", "Writer",
        ]

        private static func items() -> [SearchItem] {
            var items: [SearchItem] = []
            for firstWord in firstWords {
                for secondWord in secondWords {
                    let item = SearchItem(
                        id: .app(bundleID: "example.\(firstWord).\(secondWord)"),
                        title: "\(firstWord) \(secondWord)",
                        icon: .symbol("app"), kindLabel: "Application")
                    items.append(item)
                }
            }
            return items
        }

        /// Picks of every fiftieth item, so that frecency and query affinity have something to
        /// add for some rows and nothing for most, as in real use.
        private func sampleUsage(of items: [SearchItem]) -> UsageSnapshot {
            var usage = UsageSnapshot()
            for index in stride(from: 0, to: items.count, by: 50) {
                usage.record(pick: items[index].id, query: "st", at: now)
            }
            return usage
        }

        @Test func queriesOfOneToFiveCharacters() async throws {
            let items = Self.items()
            let snapshot = await IndexSnapshot.build(from: items)
            let usage = sampleUsage(of: items)
            let clock = ContinuousClock()

            // Each prefix is ranked against the whole index, as if it had been typed into an
            // empty field. That is the worst case: while the user types on, the search only
            // looks at the entries that survived the query before (§4.2.5).
            let typed = "studi"
            for length in 1...typed.count {
                let query = SearchQuery(String(typed.prefix(length)))
                var samples = BenchmarkSamples()
                var rowCount = 0

                for run in 0..<(Benchmarks.warmUpRuns + Benchmarks.measuredRuns) {
                    // `rank` runs off the caller's actor, so the time includes the way there
                    // and back, as it does for the search session.
                    let start = clock.now
                    let results = await snapshot.rank(query: query, usage: usage, now: now)
                    let elapsed = clock.now - start

                    rowCount = try #require(results).rows.count
                    if run >= Benchmarks.warmUpRuns {
                        samples.add(elapsed)
                    }
                }

                // A query that found nothing would have measured the scan and no ranking.
                #expect(rowCount > 0)
                let itemCount = snapshot.entries.count
                samples.report(
                    "ranking \"\(query.raw)\" over \(itemCount) items, \(rowCount) rows")
            }
        }
    }
}
