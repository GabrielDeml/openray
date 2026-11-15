import Foundation
import Synchronization

/// The apps installed on this Mac, as items for root search (docs/DESIGN.md §4.2.8). It reads
/// the application folders once, and again whenever one of them changes.
public final class AppIndexSource: SearchSource {
    public let id = SourceID(rawValue: "apps")
    public let latency = SourceLatency.inline

    /// The folders macOS keeps apps in. The order matters: of copies of an app in two roots, the
    /// one in the earlier root keeps the bundle identifier as its ID.
    public static let standardRoots: [URL] = [
        URL(filePath: "/Applications", directoryHint: .isDirectory),
        URL(filePath: "/Applications/Utilities", directoryHint: .isDirectory),
        URL(filePath: "/System/Applications", directoryHint: .isDirectory),
        URL(filePath: "/System/Applications/Utilities", directoryHint: .isDirectory),
        URL.homeDirectory.appending(path: "Applications", directoryHint: .isDirectory),
        URL(filePath: "/System/Library/CoreServices/Applications", directoryHint: .isDirectory),
        URL(filePath: "/System/Library/CoreServices/Finder.app", directoryHint: .isDirectory),
    ]

    /// What makes the source read its roots again.
    private enum RescanRequest: Sendable {
        /// Something changed in the root at this index.
        case root(Int)
        case allRoots
    }

    private let roots: [URL]
    private let preferredLanguages: [String]
    private let openApp: @MainActor @Sendable (URL) async throws -> Void
    /// Where rescan requests go: to the items stream that was started last. nil before the
    /// first.
    private let rescanRequestContinuation = Mutex<AsyncStream<RescanRequest>.Continuation?>(nil)

    /// - Parameters:
    ///   - roots: The folders to search, each either a folder of apps or one app.
    ///   - preferredLanguages: The languages localised app names are read in. Tests pass their
    ///     own.
    ///   - openApp: Opens the app at a URL. Core cannot do that itself, because `NSWorkspace`
    ///     is part of AppKit; the app target passes it in.
    public init(
        roots: [URL] = AppIndexSource.standardRoots,
        preferredLanguages: [String] = Locale.preferredLanguages,
        openApp: @escaping @MainActor @Sendable (URL) async throws -> Void
    ) {
        self.roots = roots
        self.preferredLanguages = preferredLanguages
        self.openApp = openApp
    }

    /// The apps as they are now, and the full list again after every change in a root.
    ///
    /// The source is made for one consumer at a time, the command registry. Rescan requests go
    /// to the stream that was returned last, so an earlier one that is still read stops
    /// following changes.
    public func indexedItems() -> AsyncStream<[SearchItem]> {
        // Every element is the full list, so a consumer that falls behind needs only the newest.
        let (items, continuation) = AsyncStream.makeStream(
            of: [SearchItem].self, bufferingPolicy: .bufferingNewest(1))
        // A queue of requests for this stream alone. A queue is over for good once the task
        // that reads it is cancelled, so the next stream could not carry on with this one's.
        let (rescanRequests, requestContinuation) = AsyncStream.makeStream(of: RescanRequest.self)
        rescanRequestContinuation.withLock { current in
            current = requestContinuation
        }

        let scanning = Task {
            await self.keepItemsCurrent(yieldingTo: continuation, rescanRequests: rescanRequests)
        }
        continuation.onTermination = { _ in
            scanning.cancel()
        }
        return items
    }

    /// Reads every root again. FSEvents reports nothing for the time the Mac was asleep and
    /// nothing for a root that did not exist when the watching began, so the app asks for this
    /// when the Mac wakes.
    public func rescan() {
        requestRescan(.allRoots)
    }

    private func requestRescan(_ request: RescanRequest) {
        rescanRequestContinuation.withLock { continuation in
            // Whether the request was taken does not matter: if the stream has ended, nobody
            // is left to rescan for.
            _ = continuation?.yield(request)
        }
    }

    private func keepItemsCurrent(
        yieldingTo continuation: AsyncStream<[SearchItem]>.Continuation,
        rescanRequests: AsyncStream<RescanRequest>
    ) async {
        // The watching starts before the first scan. A change that falls between the two is
        // then a request waiting in the queue, not a change nobody noticed.
        let watchers = startWatchers()
        defer {
            for watcher in watchers {
                watcher.stop()
            }
        }

        var appsByRoot = await scanAllRoots()
        continuation.yield(items(from: appsByRoot))

        // This loop ends when its task is cancelled, which the end of the items stream does.
        for await request in rescanRequests {
            switch request {
            case .allRoots:
                appsByRoot = await scanAllRoots()
            case .root(let index):
                appsByRoot[index] = await AppBundleScanner.apps(
                    in: roots[index], preferredLanguages: preferredLanguages)
            }
            continuation.yield(items(from: appsByRoot))
        }
    }

    /// One watcher for each root that can change while the app runs.
    private func startWatchers() -> [AppFolderWatcher] {
        var watchers: [AppFolderWatcher] = []
        for (index, root) in roots.enumerated() {
            let path = root.path(percentEncoded: false)
            // The system's own apps are on the sealed volume, which only an OS update changes,
            // and the Mac restarts for that.
            if path.hasPrefix("/System/") { continue }
            // A stream that is started on a missing folder does not report what happens in
            // the folder once it is there.
            if !FileManager.default.fileExists(atPath: path) { continue }

            let watcher = AppFolderWatcher(folder: root) { [self] in
                requestRescan(.root(index))
            }
            guard let watcher else {
                Log.search.error("Cannot watch the folder \(path) for changes")
                continue
            }
            watchers.append(watcher)
        }
        return watchers
    }

    /// What each root holds, in the order of `roots`.
    func scanAllRoots() async -> [[ScannedApp]] {
        var appsByRoot: [[ScannedApp]] = []
        for root in roots {
            let apps = await AppBundleScanner.apps(
                in: root, preferredLanguages: preferredLanguages)
            appsByRoot.append(apps)
        }
        return appsByRoot
    }

    /// Turns what the scans found into items: one for each bundle, with the ID that is stored
    /// with its usage.
    func items(from appsByRoot: [[ScannedApp]]) -> [SearchItem] {
        let kindLabel = String(
            localized: "Application", bundle: .module,
            comment: "The kind of a search result that is an app, shown at the end of its row.")
        var items: [SearchItem] = []
        var seenResolvedPaths: Set<String> = []
        var takenBundleIDs: Set<String> = []

        for apps in appsByRoot {
            // One bundle can be found twice: `/Applications/Utilities` is a root and also a
            // folder inside the root `/Applications`, and a symbolic link can point at an app
            // that is in a root itself.
            var newApps: [ScannedApp] = []
            for app in apps {
                let isNewBundle = seenResolvedPaths.insert(app.resolvedPath).inserted
                if isNewBundle {
                    newApps.append(app)
                }
            }

            let ownerPaths = bundleIDOwnerPaths(among: newApps, alreadyTaken: takenBundleIDs)
            takenBundleIDs.formUnion(ownerPaths.keys)

            for app in newApps {
                let id: ItemID
                let subtitle: String?
                if let bundleID = app.bundleID, ownerPaths[bundleID] == app.path {
                    id = .app(bundleID: bundleID)
                    subtitle = nil
                } else {
                    // Nothing but its path tells this bundle from the others, in the usage
                    // table and for the user: it is a further copy of an app, or it has no
                    // bundle identifier.
                    id = .app(path: app.path)
                    subtitle = app.path
                }

                let item = SearchItem(
                    id: id,
                    title: app.displayName,
                    subtitle: subtitle,
                    alternateNames: alternateNames(of: app),
                    // The bundle itself, not a link to it: the icon of a symbolic link is drawn
                    // with an alias arrow, and `/Applications/Safari.app` is one.
                    icon: .file(path: app.resolvedPath),
                    kindLabel: kindLabel,
                    actions: [openAction(forAppAt: app.path)])
                items.append(item)
            }
        }

        Log.search.info("The app index holds \(items.count, privacy: .public) apps")
        return items
    }

    /// The path of the app that keeps each bundle identifier as its ID, for the apps of one
    /// root. Identifiers that an earlier root has taken are left out.
    ///
    /// Of several copies in the root, the one with the shortest path keeps the identifier, and
    /// of equally long paths the first in order. The usage of an app is stored under its ID, so
    /// a copy that turns up later must not take the ID over just because it sorts first. Such a
    /// copy usually has the longer name: "Xcode-beta.app", "Lantern copy.app", "Lantern 2.app".
    private func bundleIDOwnerPaths(
        among apps: [ScannedApp], alreadyTaken takenBundleIDs: Set<String>
    ) -> [String: String] {
        var ownerPaths: [String: String] = [:]
        for app in apps {
            guard let bundleID = app.bundleID else { continue }
            if takenBundleIDs.contains(bundleID) { continue }

            guard let ownerPath = ownerPaths[bundleID] else {
                ownerPaths[bundleID] = app.path
                continue
            }
            let isShorter = app.path.count < ownerPath.count
            let isEquallyLongAndEarlier = app.path.count == ownerPath.count && app.path < ownerPath
            if isShorter || isEquallyLongAndEarlier {
                ownerPaths[bundleID] = app.path
            }
        }
        return ownerPaths
    }

    /// Every name of the app other than its title, each once.
    private func alternateNames(of app: ScannedApp) -> [NameVariant] {
        var variants: [NameVariant] = []
        var seenNames: Set<String> = [app.displayName]
        for name in app.otherNames {
            let isNewName = seenNames.insert(name).inserted
            if !isNewName { continue }
            // These are the app's own names, so a match on one counts in full: "code" has to
            // find Visual Studio Code, whose bundle calls itself "Code", as an exact match.
            variants.append(NameVariant(text: name, weight: 1))
        }
        return variants
    }

    private func openAction(forAppAt path: String) -> ActionDescriptor {
        let url = URL(filePath: path, directoryHint: .isDirectory)
        let title = String(
            localized: "Open", bundle: .module, comment: "The action that opens the selected app.")
        // A copy, so that the action holds on to the closure and not to the whole source.
        let openApp = openApp

        return ActionDescriptor(id: ActionID(rawValue: "open"), title: title) { context in
            // The launcher goes first (§4.1.6): an app that was not running can take seconds to
            // start, and its window must not come up behind the panel.
            context.closeLauncher()
            try await openApp(url)
            return .closeLauncher
        }
    }
}
