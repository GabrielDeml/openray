import Foundation
import Testing

import OpenRayCore

// The rule is tested over made-up statuses. The calls into the system are tested on files the
// test writes into its own folder under the temporary directory; no other file is changed, and
// none is run.
@Suite final class ScriptSecurityTests: Sendable {
    private let rootPath: String

    init() throws {
        rootPath = NSTemporaryDirectory() + "OpenRayTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: rootPath, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: rootPath)
    }

    private func path(_ relativePath: String) -> String {
        "\(rootPath)/\(relativePath)"
    }

    private func makeFile(_ relativePath: String, permissions: mode_t) throws {
        let folder = (path(relativePath) as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: URL(filePath: path(relativePath)))
        try #require(chmod(path(relativePath), permissions) == 0)
    }

    // MARK: The rule

    private static let me: uid_t = 501

    private func madeUpStatus(owner: uid_t, permissions: mode_t) -> ScriptFileStatus {
        ScriptFileStatus(
            owner: owner, permissions: permissions, kind: .file, size: 100,
            modificationTime: ScriptFileStatus.Timestamp(seconds: 1_800_000_000, nanoseconds: 0))
    }

    private func problem(
        owner: uid_t, permissions: mode_t, isFolder: Bool = false
    ) -> ScriptSecurityProblem? {
        ScriptSecurity.problem(
            with: madeUpStatus(owner: owner, permissions: permissions), path: "/Scripts/wifi.sh",
            isFolder: isFolder, currentUser: Self.me)
    }

    @Test func ownFileThatOnlyTheOwnerCanChangeIsFine() {
        #expect(problem(owner: Self.me, permissions: 0o755) == nil)
        #expect(problem(owner: Self.me, permissions: 0o700) == nil)
        #expect(problem(owner: Self.me, permissions: 0o644) == nil)
    }

    @Test func fileTheGroupCanChangeIsFine() {
        #expect(problem(owner: Self.me, permissions: 0o775) == nil)
    }

    @Test func fileEverybodyCanChangeIsRefused() {
        let expected = ScriptSecurityProblem.worldWritable(
            path: "/Scripts/wifi.sh", isFolder: false)

        #expect(problem(owner: Self.me, permissions: 0o757) == expected)
        #expect(problem(owner: Self.me, permissions: 0o777) == expected)
        #expect(problem(owner: Self.me, permissions: 0o002) == expected)
    }

    @Test func fileOfAnotherUserIsRefusedAndSoIsOneOfRoot() {
        let expected = ScriptSecurityProblem.ownedByAnotherUser(
            path: "/Scripts/wifi.sh", isFolder: false)

        #expect(problem(owner: 502, permissions: 0o755) == expected)
        #expect(problem(owner: 0, permissions: 0o755) == expected)
        // The owner is named first: whoever does not own the file cannot fix its mode.
        #expect(problem(owner: 502, permissions: 0o777) == expected)
    }

    @Test func foldersFollowTheSameRule() {
        #expect(problem(owner: Self.me, permissions: 0o755, isFolder: true) == nil)
        #expect(
            problem(owner: Self.me, permissions: 0o777, isFolder: true)
                == .worldWritable(path: "/Scripts/wifi.sh", isFolder: true))
        #expect(
            problem(owner: 0, permissions: 0o755, isFolder: true)
                == .ownedByAnotherUser(path: "/Scripts/wifi.sh", isFolder: true))
    }

    @Test func messagesNameTheFileAndNotItsPath() {
        let file = ScriptSecurityProblem.worldWritable(
            path: "/Users/me/Scripts/wifi.sh", isFolder: false)
        #expect(
            file.localizedDescription
                == "Every user of this Mac can change “wifi.sh”, so OpenRay does not run it. To fix that, run chmod o-w on the file."
        )

        let folder = ScriptSecurityProblem.ownedByAnotherUser(
            path: "/Users/Shared/Scripts", isFolder: true)
        #expect(
            folder.localizedDescription
                == "The folder “Scripts” belongs to another user, so OpenRay runs no script in it."
        )
    }

    // MARK: Asking the system

    @Test func statusOfAFile() throws {
        try makeFile("wifi.sh", permissions: 0o750)

        let status = try #require(ScriptFileStatus(ofItemAt: path("wifi.sh")))

        #expect(status.owner == getuid())
        #expect(status.permissions == 0o750)
        #expect(status.kind == .file)
        #expect(status.size == 10)
        // Written a moment ago, by any clock.
        let age = Date.now.timeIntervalSince1970 - Double(status.modificationTime.seconds)
        #expect(age > -60 && age < 3600)
    }

    @Test func statusOfAFolderAndOfNothing() throws {
        let folder = try #require(ScriptFileStatus(ofItemAt: rootPath))
        #expect(folder.kind == .folder)

        #expect(ScriptFileStatus(ofItemAt: path("not-there.sh")) == nil)
    }

    @Test func statusOfALinkIsThatOfTheFileItLeadsTo() throws {
        try makeFile("real.sh", permissions: 0o700)
        try FileManager.default.createSymbolicLink(
            atPath: path("link.sh"), withDestinationPath: path("real.sh"))
        try FileManager.default.createSymbolicLink(
            atPath: path("dangling.sh"), withDestinationPath: path("not-there.sh"))

        let followed = try #require(ScriptFileStatus(ofItemAt: path("link.sh")))
        #expect(followed.kind == .file)
        #expect(followed.permissions == 0o700)

        let itself = try #require(
            ScriptFileStatus(ofItemAt: path("link.sh"), followingLinks: false))
        #expect(itself.kind == .other)

        #expect(ScriptFileStatus(ofItemAt: path("dangling.sh")) == nil)
    }

    @Test func scriptIsCheckedWithItsFolderAndTheScriptFolder() throws {
        try makeFile("Scripts/Work/deploy.sh", permissions: 0o755)
        let script = path("Scripts/Work/deploy.sh")
        let root = path("Scripts")
        #expect(ScriptSecurity.problem(withScriptAt: script, inFolder: root) == nil)

        try #require(chmod(root, 0o777) == 0)
        #expect(
            ScriptSecurity.problem(withScriptAt: script, inFolder: root)
                == .worldWritable(path: root, isFolder: true))

        try #require(chmod(path("Scripts/Work"), 0o777) == 0)
        #expect(
            ScriptSecurity.problem(withScriptAt: script, inFolder: root)
                == .worldWritable(path: path("Scripts/Work"), isFolder: true))

        try #require(chmod(script, 0o757) == 0)
        #expect(
            ScriptSecurity.problem(withScriptAt: script, inFolder: root)
                == .worldWritable(path: script, isFolder: false))
    }

    /// Where the path leads once the links in it are followed. The temporary directory is
    /// itself reached through one.
    private func withLinksFollowed(_ path: String) throws -> String {
        let resolved = try #require(realpath(path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // A link is run as the file it leads to, and whoever can write to that file's folder
    // can put another file there.
    @Test func linkIsCheckedWithTheFolderOfTheFileItLeadsTo() throws {
        try makeFile("Shared/deploy.sh", permissions: 0o755)
        try FileManager.default.createDirectory(
            atPath: path("Scripts"), withIntermediateDirectories: true)
        let link = path("Scripts/deploy.sh")
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: path("Shared/deploy.sh"))
        #expect(ScriptSecurity.problem(withScriptAt: link, inFolder: path("Scripts")) == nil)

        try #require(chmod(path("Shared"), 0o777) == 0)

        let sharedFolder = try withLinksFollowed(path("Shared"))
        #expect(
            ScriptSecurity.problem(withScriptAt: link, inFolder: path("Scripts"))
                == .worldWritable(path: sharedFolder, isFolder: true))
    }

    @Test func scriptThatIsGoneHasNoSecurityProblem() {
        #expect(
            ScriptSecurity.problem(withScriptAt: path("gone.sh"), inFolder: rootPath) == nil)
    }

    // MARK: Quarantine

    @Test func quarantineIsSeenAndRemoved() throws {
        try makeFile("downloaded.sh", permissions: 0o755)
        let file = path("downloaded.sh")
        #expect(!ScriptSecurity.isQuarantined(file))

        try markAsDownloaded(file)
        #expect(ScriptSecurity.isQuarantined(file))

        try ScriptSecurity.removeQuarantine(from: file)
        #expect(!ScriptSecurity.isQuarantined(file))

        // Already gone is as good as removed.
        try ScriptSecurity.removeQuarantine(from: file)
    }

    @Test func quarantineOfAFileThatIsGoneCannotBeRemoved() {
        #expect(!ScriptSecurity.isQuarantined(path("gone.sh")))

        #expect(
            throws: ScriptFileError.cannotRemoveQuarantine(
                fileName: "gone.sh", reason: "No such file or directory")
        ) {
            try ScriptSecurity.removeQuarantine(from: path("gone.sh"))
        }
    }

    // MARK: Make Executable

    @Test(
        arguments: [
            (0o644, 0o744),
            (0o600, 0o700),
            (0o664, 0o764),
            (0o755, 0o755),
        ] as [(mode_t, mode_t)])
    func makeExecutableAddsTheOwnersPermissionToRunAndKeepsTheRest(
        before: mode_t, after: mode_t
    ) throws {
        try makeFile("new.sh", permissions: before)

        try ScriptSecurity.makeExecutable(path("new.sh"))

        #expect(ScriptFileStatus(ofItemAt: path("new.sh"))?.permissions == after)
    }

    @Test func makeExecutableOfAFileThatIsGoneSaysWhy() {
        let expected = ScriptFileError.cannotMakeExecutable(
            fileName: "gone.sh", reason: "No such file or directory")

        #expect(throws: expected) {
            try ScriptSecurity.makeExecutable(path("gone.sh"))
        }
        #expect(
            expected.localizedDescription
                == "“gone.sh” could not be made executable: No such file or directory")
    }
}
