import Foundation

/// "Search Files" without Spotlight (docs/DESIGN.md §4.8): reads folders one by one and keeps
/// the files whose names contain every word of the search.
///
/// It is the slower search the user can switch on for a Mac whose Spotlight index is off, and
/// it is bounded so that it ends on any disk: it goes a few folders deep and gives up after a
/// fixed number of files. What lies beyond is not found.
public struct FolderWalk: Sendable {
    /// How many folders deep a file may lie below the folder the walk starts from.
    public var maximumDepth = 6
    /// How many files and folders the walk looks at in all.
    public var maximumEntries = 20_000

    public init() {}

    /// - Parameters:
    ///   - folders: Where to look, as absolute paths.
    ///   - limit: The walk ends once it has this many hits.
    /// - Returns: The hits in the order they were come across. `lastUsed` is nil for all of
    ///   them: that date is Spotlight's.
    @concurrent
    public func hits(matching text: String, in folders: [String], limit: Int) async -> [FileHit] {
        var foldedTokens: [String] = []
        for token in SpotlightQueryBuilder.tokens(of: text) {
            foldedTokens.append(SearchQuery(token).normalized)
        }
        if foldedTokens.isEmpty { return [] }

        // Level by level and not folder by folder to the bottom: the files near the top are
        // the likelier ones, and they should be seen before the entries run out. `level` is
        // how deep the entries of a folder lie: 1 for the folders the walk starts from.
        var foldersToRead: [(path: String, level: Int)] = []
        // One chosen folder may lie inside another, or be listed twice. Each folder is read
        // once, or the files in it would be found twice.
        var queuedPaths: Set<String> = []
        for folder in folders {
            let path = Self.withoutTrailingSlash(folder)
            let isNew = queuedPaths.insert(path).inserted
            if isNew {
                foldersToRead.append((path, 1))
            }
        }
        var nextFolder = 0
        var entriesSeen = 0
        var hits: [FileHit] = []

        while nextFolder < foldersToRead.count {
            if Task.isCancelled { return hits }
            let folder = foldersToRead[nextFolder]
            nextFolder += 1

            for entry in Self.visibleEntries(ofFolder: folder.path) {
                entriesSeen += 1
                if entriesSeen > maximumEntries { return hits }

                let name = entry.lastPathComponent
                // Applications are root search's, as in the Spotlight query.
                if name.hasSuffix(".app") { continue }

                let path = (folder.path as NSString).appendingPathComponent(name)
                // A symbolic link to a folder is not a folder here, so the walk follows none
                // and cannot go in circles.
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                let isFolder = values?.isDirectory == true && values?.isPackage != true

                if Self.name(name, containsAll: foldedTokens) {
                    let contentType = isFolder ? FileHit.folderType : nil
                    hits.append(FileHit(path: path, contentType: contentType))
                    if hits.count >= limit { return hits }
                }

                // A package, such as a `.photoslibrary`, is one file to the user: it can be
                // found, and what is inside it cannot.
                if isFolder && folder.level < maximumDepth {
                    let isNew = queuedPaths.insert(path).inserted
                    if isNew {
                        foldersToRead.append((path, folder.level + 1))
                    }
                }
            }
        }
        return hits
    }

    /// The path as the walk builds the paths below it. A folder picked in Settings is stored
    /// with a slash at its end.
    private static func withoutTrailingSlash(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// What Finder shows in the folder: no dot files and nothing flagged as hidden, which
    /// keeps the walk out of `~/Library`. A folder that cannot be read has no entries.
    private static func visibleEntries(ofFolder path: String) -> [URL] {
        let folder = URL(filePath: path, directoryHint: .isDirectory)
        let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles])
        return entries ?? []
    }

    /// Folds the name as the words of the search were folded, so that case and accents do
    /// not keep the two apart.
    private static func name(_ name: String, containsAll foldedTokens: [String]) -> Bool {
        let foldedName = SearchQuery(name).normalized
        for token in foldedTokens {
            if !foldedName.contains(token) { return false }
        }
        return true
    }
}
