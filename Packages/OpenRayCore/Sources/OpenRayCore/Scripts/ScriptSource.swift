import Foundation
import Synchronization

/// What the output screen is asked to run. It travels in the screen's request as JSON, as
/// the question for Quick AI travels in the chat's.
public struct ScriptRunRequest: Codable, Equatable, Sendable {
    public var path: String
    /// One for each argument the script declares.
    public var arguments: [String]

    public init(path: String, arguments: [String]) {
        self.path = path
        self.arguments = arguments
    }
}

/// Script commands in root search (docs/DESIGN.md §4.10): every script in the script folders
/// as an item found by its title and keywords, and five commands that are always there.
///
/// It reads the folders once, and again whenever one of them changes. Reading is all it does
/// by itself: a script only ever runs from an action the user ran.
public final class ScriptSource: SearchSource {
    public static let feature = FeatureID(rawValue: "scripts")
    /// The screen that asks for a script's arguments. Its argument is the script's path.
    public static let argumentsScreen = "arguments"
    /// The screen that shows what a script prints. Its argument is a `ScriptRunRequest` to
    /// start, or nil to show the last run.
    public static let outputScreen = "output"
    /// The list of files and folders that give no script, with the reasons.
    public static let diagnosticsScreen = "diagnostics"

    public let id = SourceID(rawValue: "scripts")
    public let latency = SourceLatency.inline

    /// What makes the source read the folders again.
    private enum RescanRequest: Sendable {
        /// The watcher reported a change in a folder.
        case foldersChanged
        /// `rescan()` was called.
        case everythingAgain
        /// The user's list of added folders is now this.
        case addedFoldersChanged([String])
    }

    private let defaultFolder: URL
    private let preferences: any PreferencesStore
    private let watcher: any ScriptFolderWatching
    private let runs: ScriptRuns
    private let environment: ShellEnvironment
    private let host: any ScriptActionHost
    private let showFolderSettings: @MainActor @Sendable () -> Void
    /// Where rescan requests go: to the items stream that was started last. nil before the
    /// first.
    private let rescanRequestContinuation = Mutex<AsyncStream<RescanRequest>.Continuation?>(nil)
    /// What the last scan found. The screens look their script up in it, and the Script
    /// Diagnostics list shows its diagnostics.
    private let latestScan = Mutex(ScriptScan())

    /// - Parameters:
    ///   - defaultFolder: `AppPaths.scriptsDirectory`. It is read first, and created when it
    ///     is not there.
    ///   - preferences: Where the folders the user added are kept (`scripts.folders`). The
    ///     source follows changes to the list.
    ///   - host: What the actions need from AppKit.
    ///   - showFolderSettings: Opens Settings › Scripts and has it ask for a folder to add.
    public init(
        defaultFolder: URL,
        preferences: any PreferencesStore,
        watcher: any ScriptFolderWatching,
        runs: ScriptRuns,
        environment: ShellEnvironment,
        host: any ScriptActionHost,
        showFolderSettings: @escaping @MainActor @Sendable () -> Void
    ) {
        self.defaultFolder = defaultFolder
        self.preferences = preferences
        self.watcher = watcher
        self.runs = runs
        self.environment = environment
        self.host = host
        self.showFolderSettings = showFolderSettings
    }

    // MARK: What the screens ask

    /// The script at this path, if the last scan found one there.
    public func script(atPath path: String) -> ScriptCommand? {
        let scripts = latestScan.withLock { latest in latest.scripts }
        return scripts.first { $0.path == path }
    }

    /// The files and folders the last scan could not make scripts of.
    public var diagnostics: [ScriptDiagnostic] {
        latestScan.withLock { latest in latest.diagnostics }
    }

    public static func argumentsScreenRequest(for script: ScriptCommand) -> ScreenRequest {
        ScreenRequest(feature: feature, screen: argumentsScreen, argument: script.path)
    }

    /// The request that opens the output screen and starts the script there.
    public static func outputScreenRequest(
        running script: ScriptCommand, arguments: [String]
    ) -> ScreenRequest {
        let runRequest = ScriptRunRequest(path: script.path, arguments: arguments)
        let encoder = JSONEncoder()
        // In one order always, so that two requests for the same run are equal.
        encoder.outputFormatting = [.sortedKeys]
        // A few texts and nothing else: there is nothing in them that cannot be encoded.
        var argument: String?
        if let json = try? encoder.encode(runRequest) {
            argument = String(decoding: json, as: UTF8.self)
        }
        return ScreenRequest(feature: feature, screen: outputScreen, argument: argument)
    }

    /// The request that opens the output screen on the run that was started last.
    public static var lastOutputScreenRequest: ScreenRequest {
        ScreenRequest(feature: feature, screen: outputScreen)
    }

    /// What an output screen's request asks to be run. nil for the request that shows the
    /// last run, and for an argument that cannot be read.
    public static func runRequest(in request: ScreenRequest) -> ScriptRunRequest? {
        guard let argument = request.argument else { return nil }
        return try? JSONDecoder().decode(ScriptRunRequest.self, from: Data(argument.utf8))
    }

    // MARK: Indexed items

    /// The commands at once, and after them the commands and the scripts as they are now,
    /// again after every change in a script folder.
    ///
    /// Like the app index, the source is made for one consumer at a time, the command
    /// registry: rescan requests go to the stream that was returned last.
    public func indexedItems() -> AsyncStream<[SearchItem]> {
        // Every list is kept for its reader, unlike in the app index, which keeps only the
        // newest. The first one here is the commands alone, and whether a reader gets to see
        // it must not depend on how quickly the first scan is done. The lists are short, and
        // there is one for each rescan that found something new.
        let (items, continuation) = AsyncStream.makeStream(of: [SearchItem].self)
        // A queue of requests for this stream alone. A queue is over for good once the task
        // that reads it is cancelled, so the next stream could not carry on with this one's.
        let (rescanRequests, requestContinuation) = AsyncStream.makeStream(of: RescanRequest.self)
        rescanRequestContinuation.withLock { current in
            current = requestContinuation
        }

        let scanning = Task {
            await self.keepItemsCurrent(yieldingTo: continuation, rescanRequests: rescanRequests)
        }
        // The list of added folders reaches the scanning task as one more kind of request.
        let preferences = preferences
        let followingFolders = Task {
            for await folders in preferences.changes(for: .scriptFolders) {
                requestContinuation.yield(.addedFoldersChanged(folders))
            }
        }
        continuation.onTermination = { _ in
            scanning.cancel()
            followingFolders.cancel()
        }
        return items
    }

    /// Reads every folder again and begins to watch them afresh. FSEvents reports nothing
    /// for the time the Mac was asleep, and a folder that was missing when the watching began
    /// is not watched, so the app asks for this when the Mac wakes. The actions here ask for
    /// it after they changed a file themselves.
    public func rescan() {
        requestRescan(.everythingAgain)
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
        // The commands go first, before any folder is touched. The registry shows nothing of
        // any source until every source has yielded once (§4.2.4), and a script folder in
        // Documents can wait behind a question of macOS for as long as the user leaves it
        // unanswered.
        let commands = fixedCommands()
        continuation.yield(commands)

        await createDefaultFolderIfMissing()

        var addedFolders = preferences.value(for: .scriptFolders)
        var folders = ScriptFolders.all(defaultFolder: defaultFolder, added: addedFolders)

        // The watching starts before the first scan. A change that falls between the two is
        // then a request waiting in the queue, not a change nobody noticed.
        var stopWatching = startWatching(folders)
        defer { stopWatching() }

        var latest = await scan(folders, after: nil, yielding: commands, to: continuation)

        // This loop ends when its task is cancelled, which the end of the items stream does.
        for await request in rescanRequests {
            switch request {
            case .foldersChanged:
                break

            case .everythingAgain:
                stopWatching()
                stopWatching = startWatching(folders)

            case .addedFoldersChanged(let newAddedFolders):
                // The preference reports its current value first, which is the list this
                // loop started with.
                if newAddedFolders == addedFolders { continue }
                addedFolders = newAddedFolders
                folders = ScriptFolders.all(defaultFolder: defaultFolder, added: addedFolders)
                stopWatching()
                stopWatching = startWatching(folders)
            }
            latest = await scan(folders, after: latest, yielding: commands, to: continuation)
        }
    }

    private func startWatching(_ folders: [String]) -> () -> Void {
        watcher.startWatching(folders) { [self] in
            requestRescan(.foldersChanged)
        }
    }

    /// Reads the folders, keeps what was found for the screens, and yields the commands with
    /// the scripts after them.
    ///
    /// - Parameter previous: What the scan before this one returned. nil for the first.
    /// - Returns: What was found, and the parse cache for the next scan.
    private func scan(
        _ folders: [String], after previous: (scan: ScriptScan, cache: ScriptParseCache)?,
        yielding commands: [SearchItem], to continuation: AsyncStream<[SearchItem]>.Continuation
    ) async -> (scan: ScriptScan, cache: ScriptParseCache) {
        let cache = previous?.cache ?? ScriptParseCache()
        let result = await ScriptFolderScanner().scan(folders: folders, cache: cache)

        // FSEvents reports whatever changes below a script folder, at any depth: an editor's
        // swap file, a `.git` folder, a log a script writes beside itself. Most reports
        // change nothing that is read here, and the registry and the search must not go over
        // every item again for those.
        if let previous, result.scan == previous.scan {
            return result
        }

        latestScan.withLock { latest in
            latest = result.scan
        }

        var items = commands
        for script in result.scan.scripts {
            items.append(item(for: script))
        }
        continuation.yield(items)

        let scriptCount = result.scan.scripts.count
        let diagnosticCount = result.scan.diagnostics.count
        Log.scripts.info(
            "The script folders hold \(scriptCount, privacy: .public) scripts and \(diagnosticCount, privacy: .public) files or folders with a problem"
        )
        return result
    }

    /// Makes the default folder, for the user alone: what is in it runs as them. Off the
    /// main thread, like every look at the script folders.
    ///
    /// - Returns: Whether the folder was missing and is there now.
    @concurrent @discardableResult
    private func createDefaultFolderIfMissing() async -> Bool {
        let path = defaultFolder.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: path) { return false }

        do {
            try FileManager.default.createDirectory(
                at: defaultFolder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            // The scan reports the missing folder in the Script Diagnostics list.
            Log.scripts.error("Cannot create the Scripts folder: \(error)")
            return false
        }
    }

    // MARK: Scripts

    /// The script as a row of root search.
    public func item(for script: ScriptCommand) -> SearchItem {
        let kindLabel = String(
            localized: "Script", bundle: .module,
            comment: "The kind of a search result that is a script, shown at the end of its row.")

        var alternateNames: [NameVariant] = []
        for keyword in script.metadata.keywords {
            alternateNames.append(.keyword(keyword))
        }
        var accessories: [String] = []
        if let group = script.group {
            accessories.append(group)
        }

        var item = SearchItem(
            id: script.itemID, title: script.metadata.title,
            subtitle: script.metadata.description, alternateNames: alternateNames,
            icon: Self.icon(of: script), kindLabel: kindLabel, accessories: accessories,
            actions: actions(for: script))
        if script.isExecutable && !script.metadata.arguments.isEmpty {
            item.tabTarget = Self.argumentsScreenRequest(for: script)
        }
        return item
    }

    /// The icon the script names, or a terminal for a script that names none.
    public static func icon(of script: ScriptCommand) -> IconSource {
        let terminal = IconSource.symbol("terminal")

        switch script.metadata.icon {
        case nil:
            return terminal
        case .emoji(let emoji):
            return .emoji(emoji)
        case .symbol(let name):
            return .symbol(name)
        case .image(let relativePath):
            guard let path = imagePath(relativePath, besideScriptAt: script.path) else {
                return terminal
            }
            return .image(path: path)
        }
    }

    /// Where the image a script names as its icon is: a path from the folder the script is
    /// in. nil for a path that is absolute or has `..` in it. A script is text that may have
    /// come from anywhere, and it must not make OpenRay open a file outside its own folder.
    static func imagePath(_ relativePath: String, besideScriptAt scriptPath: String) -> String? {
        if relativePath.hasPrefix("/") { return nil }
        let components = relativePath.split(separator: "/")
        // Also a `..` that would not leave the folder: nobody writes one in an icon's path
        // for a good reason.
        if components.isEmpty || components.contains("..") { return nil }

        let folder = (scriptPath as NSString).deletingLastPathComponent
        return "\(folder)/\(relativePath)"
    }

    // MARK: Actions

    /// What can be done with a script. The first action is what Return does.
    private func actions(for script: ScriptCommand) -> [ActionDescriptor] {
        let primary: ActionDescriptor
        if !script.isExecutable {
            primary = makeExecutableAction(for: script)
        } else if script.metadata.arguments.isEmpty {
            primary = runAction(for: script)
        } else {
            primary = enterArgumentsAction(for: script)
        }

        return [
            primary,
            ScriptFileActions.openInEditor(script.path, host: host),
            ScriptFileActions.showInFinder(script.path, host: host),
            ScriptFileActions.copyPath(script.path),
        ]
    }

    private func runAction(for script: ScriptCommand) -> ActionDescriptor {
        var confirmation: Confirmation?
        if script.metadata.needsConfirmation {
            confirmation = ScriptTitles.runConfirmation(for: script)
        }
        let runs = runs

        return ActionDescriptor(
            id: ActionID(rawValue: "run"), title: ScriptTitles.run, confirmation: confirmation
        ) { context in
            try await Self.run(script, arguments: [], runs: runs, context: context)
        }
    }

    /// A script that takes arguments has none yet, so Return and Tab lead to the screen that
    /// asks for them. That screen's last step is the one that asks for a confirmation.
    private func enterArgumentsAction(for script: ScriptCommand) -> ActionDescriptor {
        let argumentsScreen = Self.argumentsScreenRequest(for: script)

        return ActionDescriptor(id: ActionID(rawValue: "run"), title: ScriptTitles.run) { _ in
            .push(argumentsScreen)
        }
    }

    /// Runs a script that has all its arguments, in the way its mode asks for.
    ///
    /// - Returns: `.keepOpen` when the user was asked about a downloaded file and said no.
    /// - Throws: What `ScriptRuns.isCleared` throws, with the launcher still open, and
    ///   `CancellationError` when the action was cancelled before the script could start.
    @MainActor static func run(
        _ script: ScriptCommand, arguments: [String], runs: ScriptRuns,
        context: any ActionContext
    ) async throws -> ActionOutcome {
        // While the launcher is open: a downloaded file is asked about in the panel, and a
        // file that is refused is said to be so there.
        let isCleared = try await runs.isCleared(script, context: context)
        if !isCleared { return .keepOpen }
        // Esc while the files were being looked at, which can take a while on a network
        // volume. The user has called the script off, and it must not run after that.
        try Task.checkCancellation()

        switch script.metadata.mode {
        case .fullOutput:
            // The output screen starts the script, and stops it when the screen goes.
            return .push(outputScreenRequest(running: script, arguments: arguments))

        case .silent:
            context.closeLauncher()
            let run = runs.start(script, arguments: arguments)
            // The launcher has long gone when this returns. The outcome still shows its text
            // in the HUD (§4.1.4).
            await run.waitUntilFinished()
            return .showHUD(run.hudText)
        }
    }

    /// For a file with a `#!` line that may not be run yet. It takes the place of Run.
    private func makeExecutableAction(for script: ScriptCommand) -> ActionDescriptor {
        let title = String(
            localized: "Make Executable", bundle: .module,
            comment:
                "The action that gives a script's file the permission to be run, for a script that does not have it."
        )
        let fileName = script.fileName

        return ActionDescriptor(
            id: ActionID(rawValue: "make-executable"), title: title, icon: .symbol("lock.open")
        ) { [self] context in
            try await Self.makeExecutable(script)
            // The item with Run in place of this action comes with the next scan.
            rescan()

            let message = String(
                localized: "“\(fileName)” can be run now", bundle: .module,
                comment:
                    "Shown after a script's file was made executable. The placeholder is the file's name."
            )
            context.showHUD(message)
            return .keepOpen
        }
    }

    /// Off the main thread, like every look at a script's file: its folder may be on a
    /// network volume.
    @concurrent
    private static func makeExecutable(_ script: ScriptCommand) async throws {
        // A file that others can change is not made runnable either.
        let securityProblem = ScriptSecurity.problem(
            withScriptAt: script.path, inFolder: script.folder)
        if let securityProblem {
            throw securityProblem
        }
        try ScriptSecurity.makeExecutable(script.path)
    }

    // MARK: Commands

    private static var commandKindLabel: String {
        String(
            localized: "Command", bundle: .module,
            comment: "The kind of a search result that is a command, shown at the end of its row."
        )
    }

    /// The commands that are there whether or not there is a script.
    private func fixedCommands() -> [SearchItem] {
        [
            openFolderCommand(), addFolderCommand(), reloadEnvironmentCommand(),
            lastOutputCommand(), diagnosticsCommand(),
        ]
    }

    private func openFolderCommand() -> SearchItem {
        let title = String(
            localized: "Open Scripts Folder", bundle: .module,
            comment: "The command that opens the folder OpenRay reads scripts from in Finder.")

        let open = ActionDescriptor(id: ActionID(rawValue: "open"), title: title) {
            [self] context in
            // The folder was made when OpenRay started, and may have been removed since.
            let wasMissing = await createDefaultFolderIfMissing()
            if wasMissing {
                // Nothing watches a folder that was not there, so the watching begins again.
                rescan()
            }
            context.closeLauncher()
            host.openFolder(defaultFolder)
            return .closeLauncher
        }
        return SearchItem(
            id: .command(Self.feature, "openFolder"), title: title, icon: .symbol("folder"),
            kindLabel: Self.commandKindLabel, actions: [open])
    }

    private func addFolderCommand() -> SearchItem {
        let title = String(
            localized: "Add Script Folder…", bundle: .module,
            comment:
                "The command that opens Settings and asks for a further folder to read scripts from."
        )
        let showFolderSettings = showFolderSettings

        let add = ActionDescriptor(id: ActionID(rawValue: "add"), title: title) { context in
            // Settings is a window outside the panel, and so is the panel that asks for the
            // folder.
            context.closeLauncher()
            showFolderSettings()
            return .closeLauncher
        }
        return SearchItem(
            id: .command(Self.feature, "addFolder"), title: title,
            icon: .symbol("folder.badge.plus"), kindLabel: Self.commandKindLabel, actions: [add])
    }

    private func reloadEnvironmentCommand() -> SearchItem {
        let title = String(
            localized: "Reload Shell Environment", bundle: .module,
            comment:
                "The command that asks the user's shell for its environment variables again, for scripts to run with."
        )
        let environment = environment

        let reload = ActionDescriptor(id: ActionID(rawValue: "reload"), title: title) {
            context in
            // The shell can take some seconds, and there is nothing to watch meanwhile. The
            // HUD says how it went.
            context.closeLauncher()
            let captured = await environment.reload()
            return .showHUD(captured.summary)
        }
        return SearchItem(
            id: .command(Self.feature, "reloadEnvironment"), title: title,
            icon: .symbol("arrow.clockwise"), kindLabel: Self.commandKindLabel, actions: [reload])
    }

    private func lastOutputCommand() -> SearchItem {
        let title = String(
            localized: "Show Last Script Output", bundle: .module,
            comment:
                "The command that shows what the script that ran last has printed, also one that ran without showing its output."
        )
        let screen = Self.lastOutputScreenRequest

        let show = ActionDescriptor(id: ActionID(rawValue: "show"), title: title) { _ in
            .push(screen)
        }
        return SearchItem(
            id: .command(Self.feature, "lastOutput"), title: title, icon: .symbol("terminal"),
            kindLabel: Self.commandKindLabel, tabTarget: screen, actions: [show])
    }

    private func diagnosticsCommand() -> SearchItem {
        let title = String(
            localized: "Script Diagnostics", bundle: .module,
            comment:
                "The command that lists the files in the script folders that could not be made into commands, with the reasons."
        )
        let screen = ScreenRequest(feature: Self.feature, screen: Self.diagnosticsScreen)

        let show = ActionDescriptor(id: ActionID(rawValue: "show"), title: title) { _ in
            .push(screen)
        }
        return SearchItem(
            id: .command(Self.feature, "diagnostics"), title: title,
            icon: .symbol("exclamationmark.triangle"), kindLabel: Self.commandKindLabel,
            tabTarget: screen, actions: [show])
    }
}
