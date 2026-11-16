import Foundation

/// What `stat` says about a file or a folder, as far as script commands look at it.
public struct ScriptFileStatus: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case file
        case folder
        /// A device, a pipe, a socket, or a symbolic link that was asked about itself.
        case other
    }

    /// Since 1970. Two numbers as `stat` gives them, because a file can be given any date
    /// and no sum of the two is safe from overflowing.
    public struct Timestamp: Sendable, Equatable {
        public var seconds: Int
        public var nanoseconds: Int

        public init(seconds: Int, nanoseconds: Int) {
            self.seconds = seconds
            self.nanoseconds = nanoseconds
        }
    }

    public var owner: uid_t
    /// The permission bits of the mode, such as `0o755`, without the bits for the kind.
    public var permissions: mode_t
    public var kind: Kind
    /// In bytes.
    public var size: Int64
    public var modificationTime: Timestamp
    /// Whether what the file holds is not on this Mac. iCloud Drive leaves such a file in
    /// the place of one it has moved away, and reading it makes macOS fetch all of it.
    public var isDataless: Bool

    public init(
        owner: uid_t, permissions: mode_t, kind: Kind, size: Int64, modificationTime: Timestamp,
        isDataless: Bool = false
    ) {
        self.owner = owner
        self.permissions = permissions
        self.kind = kind
        self.size = size
        self.modificationTime = modificationTime
        self.isDataless = isDataless
    }

    /// Asks the file system. nil when there is nothing at the path that can be asked about: no
    /// file, a link that points nowhere, or a folder on the way that may not be passed.
    ///
    /// - Parameter followingLinks: Whether a symbolic link is answered for with the file it
    ///   leads to, which is the file that would run. Without it the link is `.other`.
    public init?(ofItemAt path: String, followingLinks: Bool = true) {
        var info = stat()
        let result = followingLinks ? stat(path, &info) : lstat(path, &info)
        guard result == 0 else { return nil }

        owner = info.st_uid
        permissions = info.st_mode & 0o7777
        switch info.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .folder
        default: kind = .other
        }
        size = info.st_size
        modificationTime = Timestamp(
            seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
        isDataless = info.st_flags & UInt32(SF_DATALESS) != 0
    }
}

/// Why OpenRay refuses to run a script, or anything in a folder (docs/DESIGN.md §4.10).
public enum ScriptSecurityProblem: LocalizedError, Equatable, Sendable {
    case worldWritable(path: String, isFolder: Bool)
    /// The owner is not the user OpenRay runs as. That includes root.
    case ownedByAnotherUser(path: String, isFolder: Bool)

    /// Names the file or folder by the last part of its path, the way the user sees it in
    /// Finder, and says what to do about it.
    public var errorDescription: String? {
        switch self {
        case .worldWritable(let path, isFolder: false):
            return String(
                localized:
                    "Every user of this Mac can change “\(fileName(of: path))”, so OpenRay does not run it. To fix that, run chmod o-w on the file.",
                bundle: .module,
                comment:
                    "Why a script is refused. The placeholder is the file's name. “chmod o-w” is a command and is typed as it stands."
            )
        case .worldWritable(let path, isFolder: true):
            return String(
                localized:
                    "Every user of this Mac can change the folder “\(fileName(of: path))”, so OpenRay runs no script in it. To fix that, run chmod o-w on the folder.",
                bundle: .module,
                comment:
                    "Why every script in a folder is refused. The placeholder is the folder's name. “chmod o-w” is a command and is typed as it stands."
            )
        case .ownedByAnotherUser(let path, isFolder: false):
            return String(
                localized:
                    "“\(fileName(of: path))” belongs to another user, so OpenRay does not run it. To use it, make your own copy of the file.",
                bundle: .module,
                comment: "Why a script is refused. The placeholder is the file's name."
            )
        case .ownedByAnotherUser(let path, isFolder: true):
            return String(
                localized:
                    "The folder “\(fileName(of: path))” belongs to another user, so OpenRay runs no script in it.",
                bundle: .module,
                comment:
                    "Why every script in a folder is refused. The placeholder is the folder's name."
            )
        }
    }
}

/// A change to a script file that the system refused.
public enum ScriptFileError: LocalizedError, Equatable, Sendable {
    /// - Parameter reason: The system's own words for the error, such as "Permission denied".
    case cannotMakeExecutable(fileName: String, reason: String)
    case cannotRemoveQuarantine(fileName: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .cannotMakeExecutable(let fileName, let reason):
            return String(
                localized: "“\(fileName)” could not be made executable: \(reason)",
                bundle: .module,
                comment:
                    "Shown when the Make Executable action fails. The first placeholder is the file's name, the second the system's description of the error."
            )
        case .cannotRemoveQuarantine(let fileName, let reason):
            return String(
                localized: "“\(fileName)” is still in quarantine and was not run: \(reason)",
                bundle: .module,
                comment:
                    "Shown when a downloaded script cannot be cleared for running. The first placeholder is the file's name, the second the system's description of the error."
            )
        }
    }
}

/// The rules a script has to pass before OpenRay runs it, and the three things OpenRay does to
/// a script file other than run it (docs/DESIGN.md §4.10).
///
/// Scripts run as the user, without a sandbox. A file or folder that somebody else can write
/// to is a way for them to run code as this user, so such a script is not offered at all.
public enum ScriptSecurity {
    /// The rule itself, for one file or folder.
    ///
    /// Writable by the group is allowed: on a Mac the group of a user's files is `staff`,
    /// and files shared with it are common and deliberate.
    public static func problem(
        with status: ScriptFileStatus, path: String, isFolder: Bool, currentUser: uid_t
    ) -> ScriptSecurityProblem? {
        if status.owner != currentUser {
            return .ownedByAnotherUser(path: path, isFolder: isFolder)
        }
        if status.permissions & S_IWOTH != 0 {
            return .worldWritable(path: path, isFolder: isFolder)
        }
        return nil
    }

    /// Checks the script, the folder it is in and, for a script in a subfolder, the script
    /// folder above that. Asked again before every run, because the scan may be old.
    ///
    /// A script that is a symbolic link is judged by the file it leads to, and the folder
    /// that file is in is checked as well: whoever can write to that folder can put another
    /// file in the place of the one that runs.
    ///
    /// Something that is no longer there has no problem of this kind; running it fails by
    /// itself.
    ///
    /// - Parameters:
    ///   - path: The script, as the scan found it.
    ///   - root: The script folder it was found in or one level below.
    public static func problem(
        withScriptAt path: String, inFolder root: String
    ) -> ScriptSecurityProblem? {
        let currentUser = getuid()

        if let status = ScriptFileStatus(ofItemAt: path) {
            let fileProblem = problem(
                with: status, path: path, isFolder: false, currentUser: currentUser)
            if let fileProblem { return fileProblem }
        }

        let parent = (path as NSString).deletingLastPathComponent
        var folders = [parent]
        if parent != root {
            folders.append(root)
        }
        // A link is run as the file it leads to, so that file's folder has to pass too. The
        // two paths also differ when a folder on the way is a link. The folder is then one
        // of those above under another name, and looking at it twice does no harm.
        if let target = pathWithLinksFollowed(path), target != path {
            folders.append((target as NSString).deletingLastPathComponent)
        }
        for folder in folders {
            guard let status = ScriptFileStatus(ofItemAt: folder) else { continue }
            let folderProblem = problem(
                with: status, path: folder, isFolder: true, currentUser: currentUser)
            if let folderProblem { return folderProblem }
        }
        return nil
    }

    /// Where the path leads once every symbolic link in it has been followed. nil when
    /// nothing is there.
    private static func pathWithLinksFollowed(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: Quarantine

    private static let quarantineAttribute = "com.apple.quarantine"

    /// Whether macOS marked the file as downloaded. Such a file is confirmed by the user
    /// before its first run.
    public static func isQuarantined(_ path: String) -> Bool {
        // Without a buffer the call only says how long the value is, or that there is none.
        let length = getxattr(path, quarantineAttribute, nil, 0, 0, 0)
        return length >= 0
    }

    /// Takes the mark off, after the user confirmed the script. The script must not run
    /// when this throws.
    public static func removeQuarantine(from path: String) throws {
        let result = removexattr(path, quarantineAttribute, 0)
        if result == 0 { return }

        let code = errno
        // Somebody else took it off in the meantime, which is all that was wanted.
        if code == ENOATTR { return }
        throw ScriptFileError.cannotRemoveQuarantine(
            fileName: fileName(of: path), reason: String(cString: strerror(code)))
    }

    // MARK: Make Executable

    /// `chmod u+x`: lets the owner run the file and leaves every other permission as it is.
    public static func makeExecutable(_ path: String) throws {
        var info = stat()
        if stat(path, &info) != 0 {
            throw cannotMakeExecutable(path, errorCode: errno)
        }

        let permissions = info.st_mode & 0o7777
        if chmod(path, permissions | S_IXUSR) != 0 {
            throw cannotMakeExecutable(path, errorCode: errno)
        }
    }

    private static func cannotMakeExecutable(_ path: String, errorCode: Int32) -> ScriptFileError {
        .cannotMakeExecutable(
            fileName: fileName(of: path), reason: String(cString: strerror(errorCode)))
    }
}

/// The last part of the path, which is how the user knows the file or folder from Finder.
private func fileName(of path: String) -> String {
    (path as NSString).lastPathComponent
}
