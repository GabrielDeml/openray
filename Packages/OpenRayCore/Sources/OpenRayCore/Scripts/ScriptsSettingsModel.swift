import Foundation
import Observation

/// What Settings › Scripts shows and changes: the folders scripts are read from, and where
/// their environment comes from (docs/DESIGN.md §4.10).
@MainActor @Observable public final class ScriptsSettingsModel {
    /// One folder of the list.
    public struct Folder: Identifiable, Equatable, Sendable {
        /// Without a slash at the end.
        public var path: String
        /// The folder OpenRay made itself. It is always read and cannot be removed.
        public var isDefault: Bool
        /// Set for a folder that is, lies in, or is directly above a place macOS asks the
        /// user about before an app may read it. The pane warns about the question.
        public var protectedLocation: ScriptFolders.ProtectedLocation?
        /// Why no script of this folder is offered, as a sentence. nil for a folder that is
        /// in order, and for one that has not been looked at yet.
        public var problem: String?

        public var id: String { path }
    }

    /// Whether the pane is asking for a folder to add, or is to ask as soon as it is on
    /// screen. The pane shows its panel for as long as this is set and clears it when the
    /// panel closes, which is how "Add Script Folder…" in the launcher opens the panel.
    public var isChoosingFolder = false
    /// Where the environment of scripts comes from, as a sentence.
    public private(set) var environmentStatus: String
    /// The shell is being asked right now.
    public private(set) var isReloadingEnvironment = false

    /// What is wrong with each folder that has a problem, by path, as `refresh` found it.
    private var folderProblems: [String: String] = [:]

    @ObservationIgnored private let defaultFolderPath: String
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let environment: ShellEnvironment
    @ObservationIgnored private let homePath: String

    /// - Parameters:
    ///   - defaultFolder: `AppPaths.scriptsDirectory`.
    ///   - homeFolder: The user's home folder, which the protected places are looked for in.
    public init(
        defaultFolder: URL, preferences: Preferences, environment: ShellEnvironment,
        homeFolder: URL = .homeDirectory
    ) {
        defaultFolderPath = ScriptFolders.withoutTrailingSlash(
            defaultFolder.path(percentEncoded: false))
        self.preferences = preferences
        self.environment = environment
        homePath = ScriptFolders.withoutTrailingSlash(homeFolder.path(percentEncoded: false))
        environmentStatus = Self.notReadYet
    }

    private static var notReadYet: String {
        String(
            localized: "Not read yet. OpenRay asks your shell before it runs the first script.",
            bundle: .module,
            comment:
                "Settings › Scripts: says that the environment variables scripts run with have not been read from the user's shell yet."
        )
    }

    // MARK: Folders

    /// The folders in the order they are read: the default one, then the added ones.
    public var folders: [Folder] {
        var folders: [Folder] = []
        for path in allFolderPaths {
            let folder = Folder(
                path: path, isDefault: path == defaultFolderPath,
                protectedLocation: ScriptFolders.protectedLocation(of: path, home: homePath),
                problem: folderProblems[path])
            folders.append(folder)
        }
        return folders
    }

    private var allFolderPaths: [String] {
        ScriptFolders.all(
            defaultFolder: URL(filePath: defaultFolderPath, directoryHint: .isDirectory),
            added: preferences.scriptFolders)
    }

    /// Has the pane ask for a folder to add.
    public func requestFolderPicker() {
        isChoosingFolder = true
    }

    /// Adds the folder to the ones scripts are read from. A folder that is in the list
    /// already, the default one included, is not added again.
    public func add(folder: URL) {
        let path = ScriptFolders.withoutTrailingSlash(folder.path(percentEncoded: false))
        if allFolderPaths.contains(path) { return }
        preferences.scriptFolders.append(path)
    }

    /// Takes an added folder out of the list. The folder and its files stay where they are.
    public func remove(_ folder: Folder) {
        if folder.isDefault { return }
        preferences.scriptFolders.removeAll { stored in
            ScriptFolders.withoutTrailingSlash(stored) == folder.path
        }
    }

    // MARK: Keeping the pane current

    /// Looks at the folders and at the environment as they are now. The pane calls this when
    /// it appears and after the list of folders has changed. It never starts the shell.
    public func refresh() async {
        let problems = await Self.problems(ofFolders: allFolderPaths)
        // The pane has started a newer look, or is gone: this answer is for an older list.
        if Task.isCancelled { return }
        folderProblems = problems

        // A reload that is under way writes the status when it is done.
        if isReloadingEnvironment { return }
        if let captured = await environment.cached {
            environmentStatus = captured.summary
        } else {
            environmentStatus = Self.notReadYet
        }
    }

    /// Asks the shell for its environment again, as "Reload Shell Environment" does.
    public func reloadEnvironment() async {
        isReloadingEnvironment = true
        let captured = await environment.reload()
        environmentStatus = captured.summary
        isReloadingEnvironment = false
    }

    /// A folder that is missing or refused, in the scan's words. A folder that cannot be
    /// listed is only found by the scan itself, and is in Script Diagnostics.
    /// Off the main thread: a folder may be on a volume that is slow to answer.
    @concurrent
    private static func problems(ofFolders paths: [String]) async -> [String: String] {
        let currentUser = getuid()
        var problems: [String: String] = [:]

        for path in paths {
            let problem = ScriptFolderScanner.problem(withFolderAt: path, currentUser: currentUser)
            if let problem {
                problems[path] = ScriptDiagnostic(path: path, problem: problem).message
            }
        }
        return problems
    }
}
