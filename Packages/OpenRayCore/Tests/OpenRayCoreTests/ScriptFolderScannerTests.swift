import Foundation
import Testing

@testable import OpenRayCore

// Every test builds its own folder of small text files under the temporary directory and scans
// nothing else. No file in it is ever run: the scanner only reads. The suite is a class so that
// `deinit` can remove the folder whichever way the test ends.
@Suite(.timeLimit(.minutes(1))) final class ScriptFolderScannerTests: Sendable {
    /// Without a slash at the end, like the paths of the scripts.
    private let rootPath: String

    init() throws {
        rootPath = NSTemporaryDirectory() + "OpenRayTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: rootPath, withIntermediateDirectories: true)
    }

    deinit {
        // A test may have taken the permission to list a folder away.
        chmod(rootPath + "/Locked", 0o700)
        try? FileManager.default.removeItem(atPath: rootPath)
    }

    // MARK: Fixtures

    private func path(_ relativePath: String) -> String {
        "\(rootPath)/\(relativePath)"
    }

    private func makeFolder(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            atPath: path(relativePath), withIntermediateDirectories: true)
    }

    private func header(title: String) -> String {
        """
        #!/bin/sh
        # @openray.schemaVersion 1
        # @openray.title \(title)
        # @openray.mode silent

        """
    }

    /// Writes a file, and the folders above it if they are not there yet.
    private func makeFile(
        _ relativePath: String, text: String, permissions: mode_t = 0o755
    ) throws {
        let folder = (relativePath as NSString).deletingLastPathComponent
        try makeFolder(folder)
        try Data(text.utf8).write(to: URL(filePath: path(relativePath)))
        try setPermissions(permissions, of: relativePath)
    }

    /// A file with a valid header, executable unless the test says otherwise.
    private func makeScript(
        _ relativePath: String, title: String, permissions: mode_t = 0o755
    ) throws {
        try makeFile(relativePath, text: header(title: title), permissions: permissions)
    }

    private func setPermissions(_ permissions: mode_t, of relativePath: String) throws {
        try #require(chmod(path(relativePath), permissions) == 0)
    }

    /// Scans the test's folder, or the folders the test names.
    private func scanFolders(
        _ folders: [String]? = nil, cache: ScriptParseCache = ScriptParseCache(),
        with scanner: ScriptFolderScanner = ScriptFolderScanner()
    ) async -> (scan: ScriptScan, cache: ScriptParseCache) {
        await scanner.scan(folders: folders ?? [rootPath], cache: cache)
    }

    /// The titles of the scripts in the order of the scan.
    private func titles(in found: ScriptScan) -> [String] {
        found.scripts.map(\.metadata.title)
    }

    // MARK: What is found

    @Test func scriptsOfTheFolderAndOfItsSubfolders() async throws {
        try makeScript("wifi.sh", title: "Toggle Wi-Fi")
        try makeScript("Work/deploy.sh", title: "Deploy")

        let found = await scanFolders().scan

        let wifi = ScriptCommand(
            path: path("wifi.sh"), folder: rootPath, group: nil,
            metadata: ScriptMetadata(title: "Toggle Wi-Fi", mode: .silent), isExecutable: true)
        let deploy = ScriptCommand(
            path: path("Work/deploy.sh"), folder: rootPath, group: "Work",
            metadata: ScriptMetadata(title: "Deploy", mode: .silent), isExecutable: true)
        #expect(found.scripts == [deploy, wifi])
        #expect(found.diagnostics == [])
        #expect(wifi.itemID == ItemID(rawValue: "script:" + path("wifi.sh")))
    }

    @Test func foldersBelowASubfolderAreNotRead() async throws {
        try makeScript("Work/deploy.sh", title: "Deploy")
        try makeScript("Work/Old/deploy.sh", title: "Old Deploy")

        let found = await scanFolders().scan

        #expect(titles(in: found) == ["Deploy"])
        #expect(found.diagnostics == [])
    }

    @Test func dotFilesAndDotFoldersAreNotRead() async throws {
        try makeScript(".hidden.sh", title: "Hidden")
        try makeScript(".git/hook.sh", title: "Hook")
        try makeScript("Work/.draft.sh", title: "Draft")
        try makeScript("shown.sh", title: "Shown")

        let found = await scanFolders().scan

        #expect(titles(in: found) == ["Shown"])
    }

    @Test func scriptsComeInTheOrderOfTheirNames() async throws {
        try makeScript("c.sh", title: "C")
        try makeScript("a.sh", title: "A")
        try makeScript("b/z.sh", title: "Z in b")
        try makeScript("b/y.sh", title: "Y in b")

        let found = await scanFolders().scan

        #expect(titles(in: found) == ["A", "Y in b", "Z in b", "C"])
    }

    @Test func fileWithoutMetadataIsNoScriptAndNoProblem() async throws {
        try makeFile("lib.sh", text: "#!/bin/sh\necho helper\n")
        try makeFile("README.md", text: "Scripts for OpenRay.\n", permissions: 0o644)
        try makeFile("empty", text: "", permissions: 0o644)
        try makeFile("binary", text: "\u{0}\u{1}\u{2}MZ\u{0}")

        let found = await scanFolders().scan

        #expect(found == ScriptScan())
    }

    @Test func headThatIsNotUTF8IsStillRead() async throws {
        var bytes = Array("#!/bin/sh\n# caf".utf8)
        // Latin-1, as an old editor would have saved an é.
        bytes.append(0xE9)
        bytes += Array("\n# @openray.schemaVersion 1\n# @openray.title Latin\n".utf8)
        bytes += Array("# @openray.mode silent\n".utf8)
        try Data(bytes).write(to: URL(filePath: path("latin.sh")))
        try setPermissions(0o755, of: "latin.sh")

        let found = await scanFolders().scan

        #expect(titles(in: found) == ["Latin"])
    }

    @Test func fileThatFailsToParseIsADiagnostic() async throws {
        try makeFile(
            "broken.sh", text: "#!/bin/sh\n# @openray.schemaVersion 1\n# @openray.mode silent\n")

        let found = await scanFolders().scan

        #expect(found.scripts == [])
        #expect(
            found.diagnostics == [
                ScriptDiagnostic(path: path("broken.sh"), problem: .parse(.missingKey("title")))
            ])
        #expect(found.diagnostics.first?.message == "@openray.title is missing.")
    }

    // MARK: Files that may not be run

    @Test func fileWithAShebangAndNoPermissionToRunIsAScriptThatIsNotExecutable() async throws {
        try makeScript("new.sh", title: "New", permissions: 0o644)

        let found = await scanFolders().scan

        #expect(found.scripts.map(\.isExecutable) == [false])
        #expect(found.diagnostics == [])
    }

    @Test func fileWithoutAShebangAndNoPermissionToRunIsADiagnostic() async throws {
        let text = "# @openray.schemaVersion 1\n# @openray.title Notes\n# @openray.mode silent\n"
        try makeFile("notes.txt", text: text, permissions: 0o644)

        let found = await scanFolders().scan

        #expect(found.scripts == [])
        #expect(
            found.diagnostics == [
                ScriptDiagnostic(path: path("notes.txt"), problem: .noShebang)
            ])
    }

    @Test func executableFileNeedsNoShebang() async throws {
        // A compiled program would be one, if it had the lines in its first 8 KiB.
        let text = "# @openray.schemaVersion 1\n# @openray.title Tool\n# @openray.mode silent\n"
        try makeFile("tool", text: text, permissions: 0o700)

        let found = await scanFolders().scan

        #expect(found.scripts.map(\.isExecutable) == [true])
    }

    @Test func worldWritableFileIsADiagnostic() async throws {
        try makeScript("open.sh", title: "Open", permissions: 0o757)
        try makeScript("shared.sh", title: "Shared With The Group", permissions: 0o775)

        let found = await scanFolders().scan

        #expect(titles(in: found) == ["Shared With The Group"])
        let problem = ScriptSecurityProblem.worldWritable(path: path("open.sh"), isFolder: false)
        #expect(
            found.diagnostics == [
                ScriptDiagnostic(path: path("open.sh"), problem: .security(problem))
            ])
    }

    @Test func worldWritableSubfolderGivesOneDiagnosticAndNoScripts() async throws {
        try makeScript("Shared/one.sh", title: "One")
        try makeScript("Shared/two.sh", title: "Two")
        try makeScript("mine.sh", title: "Mine")
        try setPermissions(0o777, of: "Shared")

        let found = await scanFolders().scan

        #expect(titles(in: found) == ["Mine"])
        let problem = ScriptSecurityProblem.worldWritable(path: path("Shared"), isFolder: true)
        #expect(
            found.diagnostics == [
                ScriptDiagnostic(path: path("Shared"), problem: .security(problem))
            ])
    }

    @Test func worldWritableScriptFolderGivesNoScripts() async throws {
        try makeScript("Scripts/one.sh", title: "One")
        try makeScript("Scripts/Sub/two.sh", title: "Two")
        try setPermissions(0o777, of: "Scripts")

        let found = await scanFolders([path("Scripts")]).scan

        #expect(found.scripts == [])
        #expect(found.diagnostics.map(\.path) == [path("Scripts")])
    }

    // MARK: Folders

    @Test func missingFolderIsADiagnosticAndTheOthersAreStillRead() async throws {
        try makeScript("Here/one.sh", title: "One")

        let found = await scanFolders([path("Gone"), path("Here")]).scan

        #expect(titles(in: found) == ["One"])
        #expect(
            found.diagnostics == [
                ScriptDiagnostic(path: path("Gone"), problem: .folderMissing)
            ])
    }

    @Test func fileGivenAsAFolderCountsAsMissing() async throws {
        try makeScript("one.sh", title: "One")

        let found = await scanFolders([path("one.sh")]).scan

        #expect(found.scripts == [])
        #expect(found.diagnostics.map(\.problem) == [.folderMissing])
    }

    @Test func folderThatMayNotBeListedIsADiagnostic() async throws {
        try makeScript("Locked/one.sh", title: "One")
        try setPermissions(0o300, of: "Locked")

        let found = await scanFolders([path("Locked")]).scan

        #expect(found.scripts == [])
        #expect(
            found.diagnostics == [
                ScriptDiagnostic(path: path("Locked"), problem: .folderUnreadable)
            ])
    }

    @Test func fileThatMayNotBeReadIsADiagnostic() async throws {
        try makeScript("secret.sh", title: "Secret", permissions: 0o300)

        let found = await scanFolders().scan

        #expect(found.scripts == [])
        #expect(
            found.diagnostics == [
                ScriptDiagnostic(path: path("secret.sh"), problem: .fileUnreadable)
            ])
    }

    @Test func folderListedTwiceIsReadOnce() async throws {
        try makeScript("one.sh", title: "One")

        let found = await scanFolders([rootPath, rootPath + "/", path("Gone"), path("Gone")]).scan

        #expect(found.scripts.map(\.path) == [path("one.sh")])
        #expect(found.diagnostics.count == 1)
    }

    @Test func subfolderThatIsAlsoAScriptFolderGivesItsScriptsOnce() async throws {
        try makeScript("Work/deploy.sh", title: "Deploy")

        let found = await scanFolders([rootPath, path("Work")]).scan

        #expect(found.scripts.map(\.path) == [path("Work/deploy.sh")])
    }

    @Test func foldersAreReadInTheOrderGiven() async throws {
        try makeScript("B/one.sh", title: "From B")
        try makeScript("A/one.sh", title: "From A")

        let found = await scanFolders([path("B"), path("A")]).scan

        #expect(titles(in: found) == ["From B", "From A"])
        #expect(found.scripts.map(\.folder) == [path("B"), path("A")])
    }

    // MARK: Links

    @Test func linkToAScriptIsAScriptAtThePathOfTheLink() async throws {
        try makeScript("Elsewhere/real.sh", title: "Linked")
        try makeFolder("Scripts")
        try FileManager.default.createSymbolicLink(
            atPath: path("Scripts/link.sh"), withDestinationPath: path("Elsewhere/real.sh"))

        let found = await scanFolders([path("Scripts")]).scan

        #expect(found.scripts.map(\.path) == [path("Scripts/link.sh")])
        #expect(found.diagnostics == [])
    }

    @Test func linkThatPointsNowhereIsPassedOver() async throws {
        try makeScript("one.sh", title: "One")
        try FileManager.default.createSymbolicLink(
            atPath: path("dangling.sh"), withDestinationPath: path("nothing-here.sh"))

        let found = await scanFolders().scan

        #expect(titles(in: found) == ["One"])
        #expect(found.diagnostics == [])
    }

    @Test func linkToAFolderIsNotFollowed() async throws {
        try makeScript("Elsewhere/real.sh", title: "Behind A Link")
        try makeFolder("Scripts")
        try FileManager.default.createSymbolicLink(
            atPath: path("Scripts/Linked"), withDestinationPath: path("Elsewhere"))

        let found = await scanFolders([path("Scripts")]).scan

        #expect(found == ScriptScan())
    }

    // MARK: Limits

    @Test func folderWithMoreEntriesThanTheLimitIsReadUpToIt() async throws {
        for number in 1...6 {
            try makeScript("script\(number).sh", title: "Script \(number)")
        }
        // Dot files are not counted: Finder puts one into many folders.
        try makeFile(".DS_Store", text: "")
        var scanner = ScriptFolderScanner()
        scanner.maximumEntriesPerFolder = 4

        let found = await scanFolders(with: scanner).scan

        #expect(titles(in: found) == ["Script 1", "Script 2", "Script 3", "Script 4"])
        #expect(
            found.diagnostics == [
                ScriptDiagnostic(path: rootPath, problem: .tooManyFiles(limit: 4))
            ])
        #expect(
            found.diagnostics.first?.message
                == "This folder has more than 4 files. OpenRay reads the first 4 by name.")
    }

    @Test func limitCountsEachFolderOnItsOwn() async throws {
        try makeScript("a.sh", title: "A")
        try makeScript("Sub/b.sh", title: "B")
        try makeScript("Sub/c.sh", title: "C")
        var scanner = ScriptFolderScanner()
        scanner.maximumEntriesPerFolder = 2

        let found = await scanFolders(with: scanner).scan

        #expect(titles(in: found) == ["B", "C", "A"])
        #expect(found.diagnostics == [])
    }

    @Test func metadataAfterTheFirstEightKibibytesIsNotSeen() async throws {
        let padding = String(repeating: "# padding\n", count: 820)
        try #require(padding.utf8.count > 8192)
        try makeFile("late.sh", text: "#!/bin/sh\n" + padding + header(title: "Late"))

        let found = await scanFolders().scan

        #expect(found == ScriptScan())
    }

    @Test func lineCutByTheEndOfTheHeadIsNotHalfRead() async throws {
        // The title's line begins before byte 8192 and ends after it. Read to the cut, the
        // script would have a title that is only the beginning of its own.
        let start = "#!/bin/sh\n# @openray.schemaVersion 1\n# @openray.mode silent\n"
        let titleLine = "# @openray.title A Title That Is Cut\n"
        let paddingLength = 8192 - start.utf8.count - "# @openray.title A Tit".utf8.count
        let padding = "#" + String(repeating: "x", count: paddingLength - 2) + "\n"
        try makeFile("cut.sh", text: start + padding + titleLine)

        let found = await scanFolders().scan

        #expect(found.scripts == [])
        #expect(found.diagnostics.map(\.problem) == [.parse(.missingKey("title"))])
    }

    @Test func headOfExactlyEightKibibytesIsReadWhole() async throws {
        let start = header(title: "Exact")
        let padding = String(repeating: "x", count: 8192 - start.utf8.count - 1)
        // No line end after the last line, which ends with the file. The file does not begin
        // with `#!`, and is a script by its permission to run.
        try makeFile("exact.sh", text: "#" + padding + "\n" + String(start.dropLast()))

        let found = await scanFolders().scan

        #expect(titles(in: found) == ["Exact"])
    }

    // MARK: The cache

    @Test func unchangedFilesAreNotReadAgain() async throws {
        try makeScript("one.sh", title: "One")
        try makeScript("Sub/two.sh", title: "Two")
        try makeFile("helper.sh", text: "echo helper\n")
        try makeFile("broken.sh", text: "# @openray.title Broken\n")

        let first = await scanFolders()
        #expect(first.cache.filesRead == 4)

        let second = await scanFolders(cache: first.cache)
        #expect(second.cache.filesRead == 0)
        #expect(second.scan == first.scan)

        // The cache of the second scan is as good as that of the first.
        let third = await scanFolders(cache: second.cache)
        #expect(third.cache.filesRead == 0)
        #expect(third.scan == first.scan)
    }

    @Test func fileOfAnotherSizeIsReadAgain() async throws {
        try makeScript("one.sh", title: "One")
        let first = await scanFolders()
        let modified = try #require(ScriptFileStatus(ofItemAt: path("one.sh"))).modificationTime

        try makeScript("one.sh", title: "One, Renamed")
        // The same date as before, so that only the size tells the two apart.
        try setModificationTime(modified, of: "one.sh")

        let second = await scanFolders(cache: first.cache)
        #expect(second.cache.filesRead == 1)
        #expect(titles(in: second.scan) == ["One, Renamed"])
    }

    @Test func fileOfAnotherDateIsReadAgain() async throws {
        try makeScript("one.sh", title: "One")
        let first = await scanFolders()
        var modified = try #require(ScriptFileStatus(ofItemAt: path("one.sh"))).modificationTime

        // The same number of bytes as before.
        try makeScript("one.sh", title: "Two")
        modified.seconds += 1
        try setModificationTime(modified, of: "one.sh")

        let second = await scanFolders(cache: first.cache)
        #expect(second.cache.filesRead == 1)
        #expect(titles(in: second.scan) == ["Two"])
    }

    @Test func permissionsAreNeverTakenFromTheCache() async throws {
        try makeScript("one.sh", title: "One", permissions: 0o644)
        let first = await scanFolders()
        #expect(first.scan.scripts.map(\.isExecutable) == [false])

        // Make Executable does this, and it does not change the file's date.
        try setPermissions(0o755, of: "one.sh")
        let second = await scanFolders(cache: first.cache)
        #expect(second.cache.filesRead == 0)
        #expect(second.scan.scripts.map(\.isExecutable) == [true])

        try setPermissions(0o757, of: "one.sh")
        let third = await scanFolders(cache: second.cache)
        #expect(third.cache.filesRead == 0)
        #expect(third.scan.scripts == [])
        #expect(third.scan.diagnostics.count == 1)
    }

    @Test func fileThatIsGoneLeavesTheCache() async throws {
        try makeScript("one.sh", title: "One")
        try makeScript("two.sh", title: "Two")
        let first = await scanFolders()
        #expect(first.cache.entries.count == 2)

        try FileManager.default.removeItem(atPath: path("two.sh"))
        let second = await scanFolders(cache: first.cache)

        #expect(Array(second.cache.entries.keys) == [path("one.sh")])
        #expect(titles(in: second.scan) == ["One"])
    }

    private func setModificationTime(
        _ time: ScriptFileStatus.Timestamp, of relativePath: String
    ) throws {
        let moment = timespec(tv_sec: time.seconds, tv_nsec: time.nanoseconds)
        // Access time first, then modification time.
        let times = [moment, moment]
        try #require(utimensat(AT_FDCWD, path(relativePath), times, 0) == 0)
    }
}
