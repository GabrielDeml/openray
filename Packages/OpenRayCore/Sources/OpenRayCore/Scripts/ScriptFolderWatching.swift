import Foundation

/// Tells when something changed in the script folders (docs/DESIGN.md §4.10).
///
/// What changed is not said. `ScriptSource` reads every folder again after each report, and
/// the parse cache keeps that cheap.
public protocol ScriptFolderWatching: Sendable {
    /// Begins to watch the folders and everything below them.
    ///
    /// - Parameters:
    ///   - folders: Absolute paths. One that does not exist is not watched.
    ///   - onChange: Called after something changed, on a queue of the watcher's choosing.
    /// - Returns: What ends the watching. `onChange` is not called again once it has returned.
    func startWatching(
        _ folders: [String], onChange: @escaping @Sendable () -> Void
    ) -> () -> Void
}

/// Watches the script folders through FSEvents, with one `FolderWatcher` for each.
public struct FSEventsScriptFolderWatcher: ScriptFolderWatching {
    /// How long changes are collected before they are reported. Saving a file in an editor
    /// is several changes, and one scan is enough for them. It is short because the user is
    /// waiting to try the script they have just saved.
    private static let latency: CFTimeInterval = 0.3

    public init() {}

    public func startWatching(
        _ folders: [String], onChange: @escaping @Sendable () -> Void
    ) -> () -> Void {
        var watchers: [FolderWatcher] = []
        for folder in folders {
            // A stream that is started on a missing folder does not report what happens in
            // the folder once it is there.
            if !FileManager.default.fileExists(atPath: folder) { continue }

            let watcher = FolderWatcher(
                folder: URL(filePath: folder, directoryHint: .isDirectory),
                latency: Self.latency, onChange: onChange)
            guard let watcher else {
                // The folder is still read at launch, when the Mac wakes and when the list
                // of folders changes.
                Log.scripts.error(
                    "Cannot watch the script folder \(folder, privacy: .private) for changes")
                continue
            }
            watchers.append(watcher)
        }

        return {
            for watcher in watchers {
                watcher.stop()
            }
        }
    }
}
