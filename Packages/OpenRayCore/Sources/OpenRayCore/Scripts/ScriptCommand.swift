import Foundation

/// A file in a script folder that OpenRay offers as a command (docs/DESIGN.md §4.10).
public struct ScriptCommand: Sendable, Equatable {
    /// The absolute path as the scan came to it: the script folder, the subfolder if there
    /// is one, and the file's name. Symbolic links are not followed in it, so it is the path
    /// the user knows the file by, and it is what the item's ID is made of.
    public var path: String
    /// The script folder the file was found in, or one level below.
    public var folder: String
    /// The name of the subfolder the file is in. nil for a file directly in the script folder.
    public var group: String?
    public var metadata: ScriptMetadata
    /// False for a file that has a `#!` line and no permission to run yet. It is offered so
    /// that the user finds it, with Make Executable in place of running it.
    public var isExecutable: Bool

    public init(
        path: String, folder: String, group: String? = nil, metadata: ScriptMetadata,
        isExecutable: Bool = true
    ) {
        self.path = path
        self.folder = folder
        self.group = group
        self.metadata = metadata
        self.isExecutable = isExecutable
    }

    public var itemID: ItemID {
        .script(path: path)
    }

    /// The file's name as Finder shows it, for the sentences that name the file.
    public var fileName: String {
        (path as NSString).lastPathComponent
    }
}

/// A file or folder that was meant to give script commands and does not, with the reason. The
/// Script Diagnostics list shows these.
public struct ScriptDiagnostic: Sendable, Equatable {
    public enum Problem: Sendable, Equatable {
        /// The file's `@openray.` lines do not describe a script.
        case parse(ScriptParseError)
        case security(ScriptSecurityProblem)
        /// A script folder that is not there, or is no folder.
        case folderMissing
        case folderUnreadable
        case fileUnreadable
        /// The file describes a script, may not be run, and has no `#!` line that would say
        /// what to run it with. Make Executable would not help it.
        case noShebang
        /// The folder has more entries than a scan reads. The ones after the limit, in name
        /// order, were left out.
        case tooManyFiles(limit: Int)
    }

    public var path: String
    public var problem: Problem

    public init(path: String, problem: Problem) {
        self.path = path
        self.problem = problem
    }

    /// The last part of the path, which is what the list calls the file or folder.
    public var name: String {
        (path as NSString).lastPathComponent
    }

    /// Whether `path` is a folder. The problem says it: each kind is found either on files
    /// or on folders, and a security problem carries which it was found on.
    public var isFolder: Bool {
        switch problem {
        case .folderMissing, .folderUnreadable, .tooManyFiles:
            return true
        case .parse, .fileUnreadable, .noShebang:
            return false
        case .security(.worldWritable(_, let isFolder)),
            .security(.ownedByAnotherUser(_, let isFolder)):
            return isFolder
        }
    }

    /// What is wrong, as a sentence for the list.
    public var message: String {
        switch problem {
        case .parse(let error):
            return error.message
        case .security(let securityProblem):
            return securityProblem.localizedDescription
        case .folderMissing:
            return String(
                localized: "This folder does not exist.", bundle: .module,
                comment: "Script Diagnostics: a folder that scripts are read from is gone.")
        case .folderUnreadable:
            return String(
                localized: "OpenRay cannot read this folder.", bundle: .module,
                comment:
                    "Script Diagnostics: a folder that scripts are read from cannot be opened.")
        case .fileUnreadable:
            return String(
                localized: "OpenRay cannot read this file.", bundle: .module,
                comment: "Script Diagnostics: a file in a script folder cannot be opened.")
        case .noShebang:
            return String(
                localized:
                    "This file is not executable and does not begin with a #! line, so OpenRay does not know what to run it with.",
                bundle: .module,
                comment:
                    "Script Diagnostics: a script cannot be run. “#!” is typed as it stands; it begins the line that names a script's interpreter."
            )
        case .tooManyFiles(let limit):
            return String(
                localized:
                    "This folder has more than \(limit) files. OpenRay reads the first \(limit) by name.",
                bundle: .module,
                comment:
                    "Script Diagnostics: a script folder is too large to be read whole. Both placeholders are the same number, the limit."
            )
        }
    }
}

/// What one pass over the script folders found.
public struct ScriptScan: Sendable, Equatable {
    /// In the order of the folders, and by name within each.
    public var scripts: [ScriptCommand]
    public var diagnostics: [ScriptDiagnostic]

    public init(scripts: [ScriptCommand] = [], diagnostics: [ScriptDiagnostic] = []) {
        self.scripts = scripts
        self.diagnostics = diagnostics
    }
}
