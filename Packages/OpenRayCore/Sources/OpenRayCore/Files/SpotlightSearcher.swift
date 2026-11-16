import CoreServices
import Foundation

/// Spotlight behind `FileSearching` (docs/DESIGN.md §4.8): one synchronous `MDQuery` per call.
///
/// `MDQueryExecute` blocks until Spotlight has gathered the results, and it cannot be
/// cancelled. So the searcher is an actor on a queue of its own, where a slow query holds up
/// neither the main thread nor a thread of the cooperative pool, and its callers take care
/// never to have more than one query waiting.
///
/// `NSMetadataQuery` is not used: it has no limit on the number of results, needs a run
/// loop, and is not `Sendable`.
public actor SpotlightSearcher: FileSearching {
    private let queue = DispatchSerialQueue(label: "\(AppInfo.bundleIdentifier).spotlight")

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    public init() {}

    public func hits(matching queryString: String, in scope: FileScope, limit: Int) -> [FileHit] {
        let sortingAttributes = [kMDItemLastUsedDate] as CFArray
        guard
            let query = MDQueryCreate(
                kCFAllocatorDefault, queryString as CFString, nil, sortingAttributes)
        else {
            // Spotlight could not read the query string.
            return []
        }
        MDQuerySetSearchScope(query, Self.searchScopes(for: scope) as CFArray, 0)
        MDQuerySetMaxCount(query, limit)
        // Newest first. Without the flag the order is ascending.
        MDQuerySetSortOptionFlagsForAttribute(
            query, kMDItemLastUsedDate, kMDQueryReverseSortOrderFlag.rawValue)

        let didStart = MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue))
        if !didStart { return [] }

        var hits: [FileHit] = []
        for index in 0..<MDQueryGetResultCount(query) {
            guard let pointer = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(pointer).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }

            let lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            let contentType = MDItemCopyAttribute(item, kMDItemContentType) as? String
            hits.append(FileHit(path: path, lastUsed: lastUsed, contentType: contentType))
        }
        return hits
    }

    /// The scope as `MDQuerySetSearchScope` takes it: folder paths, or one of the names
    /// Spotlight has for the home folder and for everything it has indexed.
    private static func searchScopes(for scope: FileScope) -> [String] {
        // `searched`, so that an empty list of folders can never reach Spotlight, which
        // might take no scope at all to mean the whole computer.
        let searched = scope.searched
        switch searched.kind {
        case .home: return [kMDQueryScopeHome as String]
        case .folders: return searched.folders
        case .everywhere: return [kMDQueryScopeComputerIndexed as String]
        }
    }
}
