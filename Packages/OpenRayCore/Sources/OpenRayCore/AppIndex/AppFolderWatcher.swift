import CoreServices
import Foundation

/// Tells when something changed in a folder or anywhere below it, through an `FSEventStream`
/// (docs/DESIGN.md §4.2.8). It watches from `init` until `stop()`.
final class AppFolderWatcher {
    /// What the stream passes to its callback. The callback is a C function and cannot capture
    /// anything, so the closure reaches it through the stream's context pointer.
    private final class Handler {
        let onChange: @Sendable () -> Void

        init(onChange: @escaping @Sendable () -> Void) {
            self.onChange = onChange
        }
    }

    /// How long changes are collected before they are reported. Installing one app changes
    /// thousands of files, and reading the folder once for all of them is enough.
    private static let latency: CFTimeInterval = 1

    private let handler: Handler
    private let queue = DispatchQueue(label: "\(AppInfo.bundleIdentifier).app-folder-watcher")
    private var stream: FSEventStreamRef?

    /// - Parameter onChange: Called on a queue of the watcher's own, at most about once per
    ///   second.
    /// - Returns: nil when FSEvents does not take the folder.
    init?(folder: URL, onChange: @escaping @Sendable () -> Void) {
        handler = Handler(onChange: onChange)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        // The events themselves are not looked at. The folder is read again as a whole whatever
        // changed in it, and that is also all the flags for dropped events ask for.
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            handler.onChange()
        }
        let paths = [folder.path(percentEncoded: false)] as CFArray
        // Without further flags the stream reports folders, not single files. `WatchRoot` adds
        // an event for the watched folder itself going away, as it does when its volume is
        // unmounted.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)

        let stream = FSEventStreamCreate(
            nil, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags)
        guard let stream else { return nil }

        FSEventStreamSetDispatchQueue(stream, queue)
        let hasStarted = FSEventStreamStart(stream)
        if !hasStarted {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        stop()
    }

    /// Ends the watching. `onChange` is not called again once this has returned.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil

        // A callback that had already begun still uses the handler. Callbacks run on the queue,
        // so this waits for it to end.
        queue.sync {}
    }
}
