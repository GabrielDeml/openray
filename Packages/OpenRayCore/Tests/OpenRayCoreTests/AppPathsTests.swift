import Foundation
import Testing

import OpenRayCore

@Suite struct AppPathsTests {
    private let root = URL(
        filePath: "/Users/me/Library/Application Support", directoryHint: .isDirectory)

    @Test func dataDirectoryIsNamedAfterTheBundleIdentifier() {
        let paths = AppPaths(
            bundleIdentifier: "io.github.gabrieldeml.openray.debug", applicationSupportRoot: root)

        #expect(
            paths.applicationSupportDirectory.path(percentEncoded: false)
                == "/Users/me/Library/Application Support/io.github.gabrieldeml.openray.debug/")
    }

    @Test func debugAndReleaseBuildsNeverShareADirectory() {
        let release = AppPaths(
            bundleIdentifier: "io.github.gabrieldeml.openray", applicationSupportRoot: root)
        let debug = AppPaths(
            bundleIdentifier: "io.github.gabrieldeml.openray.debug", applicationSupportRoot: root)

        #expect(release.applicationSupportDirectory != debug.applicationSupportDirectory)
    }

    @Test func scriptsFolderIsInTheDataDirectory() {
        let paths = AppPaths(
            bundleIdentifier: "io.github.gabrieldeml.openray", applicationSupportRoot: root)

        #expect(
            paths.scriptsDirectory.path(percentEncoded: false)
                == "/Users/me/Library/Application Support/io.github.gabrieldeml.openray/Scripts/")
    }

    @Test func defaultsToTheRunningBundleInTheUsersApplicationSupport() {
        let directory = AppPaths().applicationSupportDirectory

        #expect(directory.lastPathComponent == AppInfo.bundleIdentifier)
        #expect(
            directory.deletingLastPathComponent().standardizedFileURL
                == URL.applicationSupportDirectory.standardizedFileURL)
    }
}
