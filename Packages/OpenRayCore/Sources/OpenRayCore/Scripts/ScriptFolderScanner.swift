import Foundation

/// What a scan took from the beginning of one file.
struct ScriptHead: Sendable {
    var metadata: Result<ScriptMetadata, ScriptParseError>
    /// Whether the file begins with `#!`, so that the kernel knows what to run it with once
    /// it is executable.
    var hasShebang: Bool
}

/// What the scans read so far, so that a file that has not changed is not opened again. The
/// one who scans keeps it and hands it to the next scan.
public struct ScriptParseCache: Sendable {
    struct Entry: Sendable {
        var modificationTime: ScriptFileStatus.Timestamp
        var size: Int64
        var head: ScriptHead
    }

    /// By the file's path. Files without metadata are in here too: they are the ones that
    /// would otherwise be read on every scan to learn that they are no scripts.
    var entries: [String: Entry] = [:]
    /// How many files the scan that returned this cache had to open. The tests of the cache
    /// read it.
    var filesRead = 0

    public init() {}
}

/// Finds the scripts in the script folders (docs/DESIGN.md §4.10).
///
/// It reads the files directly in a script folder and those one folder below, where the
/// subfolder's name becomes the scripts' group. It only ever reads: nothing is run, changed or
/// asked about its extended attributes here.
public struct ScriptFolderScanner: Sendable {
    /// How much of a file is read for its metadata.
    static let headLength = 8 * 1024

    /// How many files and folders of one folder are looked at. A folder with more gets a
    /// diagnostic and is read up to here, so a script folder that turns out to be a photo
    /// library does not hold a scan up.
    public var maximumEntriesPerFolder = 500

    public init() {}

    /// - Parameters:
    ///   - folders: The script folders as absolute paths, as `ScriptFolders.all` gives them.
    ///   - cache: What the scan before this one returned.
    /// - Returns: The scripts and the diagnostics, and the cache for the next scan. It holds
    ///   the files this scan saw and no others.
    @concurrent
    public func scan(
        folders: [String], cache: ScriptParseCache
    ) async -> (scan: ScriptScan, cache: ScriptParseCache) {
        var pass = Pass(
            previousEntries: cache.entries, maximumEntriesPerFolder: maximumEntriesPerFolder,
            currentUser: getuid())
        for folder in folders {
            let root = ScriptFolders.withoutTrailingSlash(folder)
            pass.readFolder(root, root: root, group: nil)
        }

        var newCache = ScriptParseCache()
        newCache.entries = pass.entries
        newCache.filesRead = pass.filesRead
        return (ScriptScan(scripts: pass.scripts, diagnostics: pass.diagnostics), newCache)
    }

    /// What keeps a folder from being read for scripts at all: it is not there, is no folder,
    /// or is refused by the security rule. The scan reports it, and Settings shows it under
    /// the folder's path.
    static func problem(
        withFolderAt path: String, currentUser: uid_t
    ) -> ScriptDiagnostic.Problem? {
        guard let status = ScriptFileStatus(ofItemAt: path), status.kind == .folder else {
            return .folderMissing
        }
        let securityProblem = ScriptSecurity.problem(
            with: status, path: path, isFolder: true, currentUser: currentUser)
        if let securityProblem {
            return .security(securityProblem)
        }
        return nil
    }

    /// One scan: what it was given and what it has found so far.
    private struct Pass {
        let previousEntries: [String: ScriptParseCache.Entry]
        let maximumEntriesPerFolder: Int
        let currentUser: uid_t

        var scripts: [ScriptCommand] = []
        var diagnostics: [ScriptDiagnostic] = []
        var entries: [String: ScriptParseCache.Entry] = [:]
        var filesRead = 0
        /// A folder may be listed twice, or be a subfolder of another script folder. Each is
        /// read once, or its scripts would be commands twice.
        var foldersRead: Set<String> = []

        /// - Parameters:
        ///   - root: The script folder `folder` is, or is in.
        ///   - group: nil for the script folder itself, and the name of a subfolder.
        mutating func readFolder(_ folder: String, root: String, group: String?) {
            let isNew = foldersRead.insert(folder).inserted
            if !isNew { return }

            let folderProblem = ScriptFolderScanner.problem(
                withFolderAt: folder, currentUser: currentUser)
            if let folderProblem {
                report(folderProblem, at: folder)
                return
            }

            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: folder)
            } catch {
                report(.folderUnreadable, at: folder)
                return
            }

            var entriesSeen = 0
            // Sorted, so that two scans of an unchanged folder give the same list, and so
            // that a folder over the limit always loses the same files.
            for name in names.sorted() {
                if name.hasPrefix(".") { continue }

                entriesSeen += 1
                if entriesSeen > maximumEntriesPerFolder {
                    report(.tooManyFiles(limit: maximumEntriesPerFolder), at: folder)
                    break
                }

                let path = "\(folder)/\(name)"
                // This follows a symbolic link, so a link to a script is a script. One that
                // points nowhere has no status and is passed over.
                guard let entryStatus = ScriptFileStatus(ofItemAt: path) else { continue }

                switch entryStatus.kind {
                case .file:
                    // A file that iCloud Drive has moved away is passed over. Reading its
                    // head would make macOS fetch all of it, for every such file in the
                    // folder and at every launch, and the scan would wait for that. The
                    // first scan after the file is back on this Mac reads it.
                    if entryStatus.isDataless { continue }
                    readFile(at: path, status: entryStatus, root: root, group: group)
                case .folder:
                    // Only one level down, and not through a link: a link to a folder could
                    // lead anywhere, also back up.
                    let isInScriptFolder = group == nil
                    if isInScriptFolder && Self.isRealFolder(path) {
                        readFolder(path, root: root, group: name)
                    }
                case .other:
                    break
                }
            }
        }

        private mutating func readFile(
            at path: String, status: ScriptFileStatus, root: String, group: String?
        ) {
            guard let head = cachedOrFreshHead(ofFileAt: path, status: status) else {
                report(.fileUnreadable, at: path)
                return
            }

            let metadata: ScriptMetadata
            switch head.metadata {
            case .success(let parsed):
                metadata = parsed
            case .failure(.noMetadata):
                // A helper, a data file, a README: not every file in the folder is meant to
                // be a command, and those that are not get no diagnostic.
                return
            case .failure(let error):
                report(.parse(error), at: path)
                return
            }

            // The owner and the mode are today's, from the `stat` of this scan. They are
            // never taken from the cache: `chmod` does not change a file's modification time.
            let securityProblem = ScriptSecurity.problem(
                with: status, path: path, isFolder: false, currentUser: currentUser)
            if let securityProblem {
                report(.security(securityProblem), at: path)
                return
            }

            let isExecutable = status.permissions & S_IXUSR != 0
            if !isExecutable && !head.hasShebang {
                report(.noShebang, at: path)
                return
            }

            scripts.append(
                ScriptCommand(
                    path: path, folder: root, group: group, metadata: metadata,
                    isExecutable: isExecutable))
        }

        /// The file's head from the cache when the file is as it was, and read from the disk
        /// otherwise. nil for a file that cannot be read.
        private mutating func cachedOrFreshHead(
            ofFileAt path: String, status: ScriptFileStatus
        ) -> ScriptHead? {
            if let cached = previousEntries[path],
                cached.modificationTime == status.modificationTime, cached.size == status.size
            {
                entries[path] = cached
                return cached.head
            }

            guard let head = Self.readHead(ofFileAt: path) else { return nil }
            filesRead += 1
            entries[path] = ScriptParseCache.Entry(
                modificationTime: status.modificationTime, size: status.size, head: head)
            return head
        }

        private static func readHead(ofFileAt path: String) -> ScriptHead? {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }

            // One byte more than is used, to learn whether the file goes on after the head.
            let data: Data?
            do {
                data = try handle.read(upToCount: ScriptFolderScanner.headLength + 1)
            } catch {
                return nil
            }
            var bytes = data ?? Data()

            let shebang = Data("#!".utf8)
            let hasShebang = bytes.starts(with: shebang)

            if bytes.count > ScriptFolderScanner.headLength {
                bytes = bytes.prefix(ScriptFolderScanner.headLength)
                // The cut most likely fell inside a line. Half a line could be read as a
                // key with a shorter value, so the head ends with its last whole line.
                let lastLineEnd = bytes.lastIndex { byte in
                    byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
                }
                if let lastLineEnd {
                    bytes = bytes.prefix(through: lastLineEnd)
                } else {
                    bytes = Data()
                }
            }

            // Bytes that are not UTF-8 become replacement characters, in a value or in a
            // line the parser skips anyway.
            let text = String(decoding: bytes, as: UTF8.self)
            return ScriptHead(
                metadata: ScriptMetadataParser.parse(text), hasShebang: hasShebang)
        }

        /// False for a symbolic link to a folder: asked about itself, a link is no folder.
        private static func isRealFolder(_ path: String) -> Bool {
            let ownStatus = ScriptFileStatus(ofItemAt: path, followingLinks: false)
            return ownStatus?.kind == .folder
        }

        private mutating func report(_ problem: ScriptDiagnostic.Problem, at path: String) {
            diagnostics.append(ScriptDiagnostic(path: path, problem: problem))
        }
    }
}
