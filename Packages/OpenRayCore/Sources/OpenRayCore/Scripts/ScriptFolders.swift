import Foundation

extension PreferenceKey where Value == [String] {
    /// Folders the user has added to the one scripts are read from, as absolute paths. The
    /// default Scripts folder is not in this list: it comes from `AppPaths` and is always
    /// read first.
    public static var scriptFolders: PreferenceKey {
        PreferenceKey(name: "scripts.folders", defaultValue: [])
    }
}

extension Preferences {
    public var scriptFolders: [String] {
        get { self[.scriptFolders] }
        set { self[.scriptFolders] = newValue }
    }
}

/// Which folders scripts are read from (docs/DESIGN.md §4.10).
public enum ScriptFolders {
    /// The folders in the order they are read: the default one, then the added ones.
    ///
    /// - Parameters:
    ///   - defaultFolder: `AppPaths.scriptsDirectory`.
    ///   - added: The `scripts.folders` preference.
    /// - Returns: Paths without a slash at the end, each once.
    public static func all(defaultFolder: URL, added: [String]) -> [String] {
        var folders = [withoutTrailingSlash(defaultFolder.path(percentEncoded: false))]
        for folder in added {
            let path = withoutTrailingSlash(folder)
            if !folders.contains(path) {
                folders.append(path)
            }
        }
        return folders
    }

    /// The path as the scan builds the paths below it. The path of a folder's URL ends with
    /// a slash, and so may a path somebody wrote into the preference by hand.
    static func withoutTrailingSlash(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    // MARK: Folders macOS asks about

    /// A place in the home folder that macOS lets an app read only after it asked the user.
    public enum ProtectedLocation: Sendable, Equatable, CaseIterable {
        case desktop, documents, downloads, iCloudDrive

        /// Where it is, from the home folder.
        var pathFromHome: String {
            switch self {
            case .desktop: "Desktop"
            case .documents: "Documents"
            case .downloads: "Downloads"
            case .iCloudDrive: "Library/Mobile Documents"
            }
        }
    }

    /// The protected place a script folder is, lies in, or is directly above. Reading such a
    /// folder makes macOS show a Files & Folders prompt, which the settings pane warns about.
    /// For the home folder, which is above three of them, this is the first.
    ///
    /// - Parameter home: The user's home folder, as a path.
    public static func protectedLocation(of folder: String, home: String) -> ProtectedLocation? {
        // Whole components are compared, so that "DocumentsOld" is not taken for a folder in
        // "Documents".
        let folderComponents = folder.split(separator: "/")

        for location in ProtectedLocation.allCases {
            let locationPath = "\(home)/\(location.pathFromHome)"
            let locationComponents = locationPath.split(separator: "/")
            if folderComponents.starts(with: locationComponents) {
                return location
            }
            // The scan reads one folder below a script folder, so the folder directly above
            // a protected place is read into it as well.
            if locationComponents.dropLast().elementsEqual(folderComponents) {
                return location
            }
        }
        return nil
    }
}
