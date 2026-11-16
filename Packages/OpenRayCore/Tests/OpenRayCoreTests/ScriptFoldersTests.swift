import Foundation
import Testing

import OpenRayCore

@Suite struct ScriptFoldersTests {
    private let defaultFolder = URL(
        filePath: "/Users/me/Library/Application Support/openray/Scripts",
        directoryHint: .isDirectory)
    private let defaultPath = "/Users/me/Library/Application Support/openray/Scripts"

    // MARK: The list

    @Test func defaultFolderComesFirst() {
        let folders = ScriptFolders.all(
            defaultFolder: defaultFolder, added: ["/Users/me/bin", "/Users/me/Work/Scripts"])

        #expect(folders == [defaultPath, "/Users/me/bin", "/Users/me/Work/Scripts"])
    }

    @Test func defaultFolderIsThereWithoutAnyAdded() {
        #expect(ScriptFolders.all(defaultFolder: defaultFolder, added: []) == [defaultPath])
    }

    @Test func slashesAtTheEndAreTakenOff() {
        let folders = ScriptFolders.all(defaultFolder: defaultFolder, added: ["/Users/me/bin/"])

        #expect(folders == [defaultPath, "/Users/me/bin"])
    }

    @Test func folderIsListedOnce() {
        let added = ["/Users/me/bin", "/Users/me/bin/", defaultPath + "/", "/Users/me/bin"]

        let folders = ScriptFolders.all(defaultFolder: defaultFolder, added: added)

        #expect(folders == [defaultPath, "/Users/me/bin"])
    }

    // MARK: Protected locations

    private func location(of folder: String) -> ScriptFolders.ProtectedLocation? {
        ScriptFolders.protectedLocation(of: folder, home: "/Users/me")
    }

    @Test func theFourProtectedLocations() {
        #expect(location(of: "/Users/me/Desktop") == .desktop)
        #expect(location(of: "/Users/me/Documents") == .documents)
        #expect(location(of: "/Users/me/Downloads") == .downloads)
        #expect(location(of: "/Users/me/Library/Mobile Documents") == .iCloudDrive)
    }

    @Test func folderBelowAProtectedLocation() {
        #expect(location(of: "/Users/me/Documents/Scripts") == .documents)
        #expect(location(of: "/Users/me/Documents/Work/Scripts/") == .documents)
        #expect(
            location(of: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Scripts")
                == .iCloudDrive)
    }

    @Test func folderWhoseNameOnlyBeginsLikeAProtectedOne() {
        #expect(location(of: "/Users/me/DocumentsOld") == nil)
        #expect(location(of: "/Users/me/Desktop Pictures/Scripts") == nil)
        #expect(location(of: "/Users/me/Library/Mobile Documents Backup") == nil)
    }

    @Test func foldersThatAreNotProtected() {
        #expect(location(of: "/Users/me") == nil)
        #expect(location(of: "/Users/me/bin") == nil)
        #expect(location(of: "/Users/me/Library/Application Support/openray/Scripts") == nil)
        // Another user's Documents is not this user's to be asked about.
        #expect(location(of: "/Users/you/Documents") == nil)
        #expect(location(of: "/Documents") == nil)
    }

    @Test func homeFolderGivenWithASlashAtItsEnd() {
        let found = ScriptFolders.protectedLocation(
            of: "/Users/me/Downloads/Scripts", home: "/Users/me/")

        #expect(found == .downloads)
    }

    // MARK: The preference

    @Test func preferenceHoldsOnlyAddedFoldersAndStartsEmpty() {
        let key = PreferenceKey<[String]>.scriptFolders

        #expect(key.name == "scripts.folders")
        #expect(key.defaultValue == [])
    }

    @Test @MainActor func preferenceIsReadAndWritten() {
        let preferences = Preferences(store: InMemoryPreferencesStore())
        #expect(preferences.scriptFolders == [])

        preferences.scriptFolders = ["/Users/me/bin"]

        #expect(preferences.scriptFolders == ["/Users/me/bin"])
    }
}
