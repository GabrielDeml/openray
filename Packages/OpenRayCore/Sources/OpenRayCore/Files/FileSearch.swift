import Foundation

/// One search of "Search Files" from the text to the list (docs/DESIGN.md §4.8): two
/// Spotlight queries, their hits merged and ranked, and, when there are none, the question
/// whether Spotlight is on at all.
///
/// The feature makes one and keeps it, so that what it has learned about Spotlight outlives
/// the screen. Everything it does to the Mac goes through `FileSearching` and the walk it is
/// handed, which is how it is tested without a single real query.
public actor FileSearch {
    public enum Answer: Sendable, Equatable {
        /// Spotlight's hits, best first. Never empty.
        case found([FileHit])
        /// Spotlight is on and has no file of that name.
        case nothingFound
        /// Spotlight seems to have no index, and the slower search is not switched on.
        case spotlightLooksOff
        /// Spotlight seems to have no index. These are the hits of the walk through the
        /// folders, best first, and there may be none.
        case foundByWalking([FileHit])
    }

    /// Reads folders without Spotlight: `FolderWalk.hits(matching:in:limit:)`.
    public typealias Walk =
        @Sendable (_ text: String, _ folders: [String], _ limit: Int) async -> [FileHit]

    // Spotlight picks which matches it returns under a limit, and has been seen to pick the
    // most recently used. So each pass asks for more than the list shows, and the ranker
    // chooses among them.
    static let namePrefixLimit = 100
    static let nameSubstringLimit = 200
    /// How many hits the list shows.
    static let resultLimit = 60

    /// A Mac with an index has apps to report from here.
    static let canaryScope = FileScope(kind: .folders, folders: ["/System/Applications"])
    /// How long an answer about the index is good for. Without this, every search that finds
    /// nothing would cost a third query, and indexing is not switched on or off from one
    /// keystroke to the next.
    static let canaryLifetime: TimeInterval = 5 * 60

    private let spotlight: any FileSearching
    private let walk: Walk
    private let preferences: any PreferencesStore
    private let usage: any UsageStore
    private let homeFolder: String
    private let now: @Sendable () -> Date

    /// Whether Spotlight looked off when it was last asked, and when that was.
    private var canary: (looksOff: Bool, askedAt: Date)?

    /// - Parameter homeFolder: What the walk reads when the scope names no folders.
    public init(
        spotlight: any FileSearching, walk: @escaping Walk, preferences: any PreferencesStore,
        usage: any UsageStore, homeFolder: String = NSHomeDirectory(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.spotlight = spotlight
        self.walk = walk
        self.preferences = preferences
        self.usage = usage
        self.homeFolder = homeFolder
        self.now = now
    }

    /// - Parameter text: The search field's text, as typed.
    public func search(_ text: String) async -> Answer {
        guard
            let prefixQuery = SpotlightQueryBuilder.build(text, pass: .namePrefix),
            let substringQuery = SpotlightQueryBuilder.build(text, pass: .nameSubstring)
        else {
            return .nothingFound
        }
        let scope = preferences.value(for: .fileScope).searched

        let prefixHits = await spotlight.hits(
            matching: prefixQuery, in: scope, limit: Self.namePrefixLimit)
        let substringHits = await spotlight.hits(
            matching: substringQuery, in: scope, limit: Self.nameSubstringLimit)

        // A name that starts with the text is in both.
        var hits: [FileHit] = []
        var seenPaths: Set<String> = []
        for hit in prefixHits + substringHits {
            let isNew = seenPaths.insert(hit.path).inserted
            if isNew {
                hits.append(hit)
            }
        }
        if !hits.isEmpty {
            // Spotlight has just answered, so it is on, whatever the canary said a minute
            // ago: the next search that finds nothing must not blame the index.
            canary = (looksOff: false, askedAt: now())
            return .found(await best(of: hits, for: text))
        }

        // Nothing of that name, or no index to find it in.
        if !(await spotlightLooksOff()) {
            return .nothingFound
        }
        if !preferences.value(for: .fileFallbackWalk) {
            return .spotlightLooksOff
        }

        // Without an index "everywhere" is the whole disk, of which the walk's few thousand
        // files would be an arbitrary corner. It reads the home folder instead.
        let folders = scope.kind == .folders ? scope.folders : [homeFolder]
        let walked = await walk(text, folders, Self.nameSubstringLimit)
        return .foundByWalking(await best(of: walked, for: text))
    }

    private func best(of hits: [FileHit], for text: String) async -> [FileHit] {
        let ranked = FileRanker.rank(hits, query: text, usage: await usage.snapshot(), now: now())
        return Array(ranked.prefix(Self.resultLimit))
    }

    /// Asks Spotlight for one app in `/System/Applications`, at most once in five minutes.
    /// Having none is the sign of a Mac without an index: `mdutil -i off`, or a volume that
    /// is still being indexed for the first time.
    private func spotlightLooksOff() async -> Bool {
        if let canary {
            // A negative age means the clock was set back, and the answer is asked for anew.
            let age = now().timeIntervalSince(canary.askedAt)
            if age >= 0 && age < Self.canaryLifetime {
                return canary.looksOff
            }
        }

        let apps = await spotlight.hits(
            matching: SpotlightQueryBuilder.canary, in: Self.canaryScope, limit: 1)
        let looksOff = apps.isEmpty
        if looksOff {
            Log.files.info("Spotlight found no app in /System/Applications: its index looks off")
        }
        canary = (looksOff, now())
        return looksOff
    }
}
