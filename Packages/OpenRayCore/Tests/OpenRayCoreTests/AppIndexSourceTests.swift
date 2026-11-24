import Foundation
import Testing

@testable import OpenRayCore

// Every test builds its own folder of fake apps under the temporary directory. The suite is a
// class so that `deinit` can remove the folder whichever way the test ends.
@Suite final class AppIndexSourceTests: Sendable {
    /// Without a slash at the end, like every path the index reports.
    private let directoryPath: String
    /// What a source is given when the test is not about overrides or about user folders.
    private let commands: CommandStore
    private let preferences = InMemoryPreferencesStore()

    init() throws {
        commands = CommandStore(database: try AppDatabase.inMemory())
        directoryPath = NSTemporaryDirectory() + "OpenRayTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directoryPath, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: directoryPath)
    }

    // MARK: Fixtures

    private func path(_ relativePath: String) -> String {
        "\(directoryPath)/\(relativePath)"
    }

    private func makeFolder(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            atPath: path(relativePath), withIntermediateDirectories: true)
    }

    private func write(_ propertyList: [String: Any], to relativePath: String) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList, format: .binary, options: 0)
        try data.write(to: URL(filePath: path(relativePath)))
    }

    /// Writes a fake app: a folder with `Contents/Info.plist` and an empty `Contents/Resources`.
    ///
    /// - Parameter info: Further `Info.plist` entries, such as `CFBundleName`.
    private func makeApp(
        _ relativePath: String, bundleID: String?, packageType: String? = "APPL",
        info furtherInfo: [String: Any] = [:]
    ) throws {
        try makeFolder("\(relativePath)/Contents/Resources")

        var info = furtherInfo
        info["CFBundleIdentifier"] = bundleID
        info["CFBundlePackageType"] = packageType
        try write(info, to: "\(relativePath)/Contents/Info.plist")
    }

    /// Gives a fake app a localisation: the folder that says the app is translated into the
    /// language and, unless `strings` is nil, an `InfoPlist.strings` in it.
    private func addLocalization(
        _ language: String, toApp relativePath: String, strings: [String: String]? = nil
    ) throws {
        let folder = "\(relativePath)/Contents/Resources/\(language).lproj"
        try makeFolder(folder)
        if let strings {
            try write(strings, to: "\(folder)/InfoPlist.strings")
        }
    }

    private func makeLink(_ relativePath: String, to targetRelativePath: String) throws {
        try FileManager.default.createSymbolicLink(
            atPath: path(relativePath), withDestinationPath: path(targetRelativePath))
    }

    private func source(
        roots: [String], preferredLanguages: [String] = ["en"],
        host: any AppActionHost = IdleHost(), preferences: (any PreferencesStore)? = nil
    ) -> AppIndexSource {
        var rootURLs: [URL] = []
        for root in roots {
            rootURLs.append(URL(filePath: path(root), directoryHint: .isDirectory))
        }
        return AppIndexSource(
            roots: rootURLs, preferredLanguages: preferredLanguages, host: host,
            commands: commands, preferences: preferences ?? self.preferences)
    }

    /// One scan of the roots, without the stream and without watching for changes.
    private func items(
        inRoots roots: [String], preferredLanguages: [String] = ["en"]
    ) async -> [SearchItem] {
        let source = source(roots: roots, preferredLanguages: preferredLanguages)
        return await source.items(from: source.scanAllRoots())
    }

    private func titles(of items: [SearchItem]) -> [String] {
        var titles: [String] = []
        for item in items {
            titles.append(item.title)
        }
        return titles
    }

    private func alternateNames(of item: SearchItem) -> [String] {
        var names: [String] = []
        for variant in item.alternateNames {
            names.append(variant.text)
        }
        return names
    }

    // MARK: Items and IDs

    @Test func appBecomesAnItemWithItsBundleIDAndItsActions() async throws {
        try makeApp("Apps/Lantern.app", bundleID: "com.example.lantern")

        let items = await items(inRoots: ["Apps"])

        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.id == ItemID.app(bundleID: "com.example.lantern"))
        #expect(item.id.rawValue == "app:com.example.lantern")
        #expect(item.title == "Lantern")
        #expect(item.subtitle == nil)
        #expect(item.alternateNames == [])
        #expect(item.icon == .file(path: path("Apps/Lantern.app")))
        #expect(item.kindLabel == "Application")
        // Open is first, which makes it what Return runs.
        #expect(
            item.actions.map(\.title) == [
                "Open", "Show in Finder", "Quit", "Copy Path", "Copy Bundle Identifier",
                "Add Alias…", "Hide from Root Search",
            ])
        #expect(item.actions.first?.id == ActionID(rawValue: "open"))
    }

    // Finder's own type is "FNDR" and a Safari web app's is "AAPL". Like Finder, the index goes
    // by the name of the bundle.
    @Test func bundleIsAnAppWhateverTypeItNames() async throws {
        try makeApp("Apps/Finder.app", bundleID: "com.example.finder", packageType: "FNDR")
        try makeApp("Apps/Web App.app", bundleID: "com.example.webapp", packageType: "AAPL")
        try makeApp("Apps/Lantern.app", bundleID: "com.example.lantern", packageType: nil)

        let items = await items(inRoots: ["Apps"])

        #expect(titles(of: items) == ["Finder", "Lantern", "Web App"])
        #expect(items[1].id == ItemID.app(bundleID: "com.example.lantern"))
    }

    @Test func folderThatIsNotCalledAnAppIsNotOne() async throws {
        try makeApp("Apps/Lantern.bundle", bundleID: "com.example.lantern")
        try Data().write(to: URL(filePath: path("Apps/Flat.app")))

        let items = await items(inRoots: ["Apps"])

        #expect(items.isEmpty)
    }

    // An iPhone or iPad app from the App Store has no `Contents`. Its real bundle is behind a
    // link.
    @Test func wrappedPhoneAppIsReadThroughItsWrappedBundle() async throws {
        try makeFolder("Apps/Pocket.app/Wrapper/Pocket.app")
        try write(
            ["CFBundleIdentifier": "com.example.pocket", "CFBundleName": "Pocket"],
            to: "Apps/Pocket.app/Wrapper/Pocket.app/Info.plist")
        try makeLink("Apps/Pocket.app/WrappedBundle", to: "Apps/Pocket.app/Wrapper/Pocket.app")

        let items = await items(inRoots: ["Apps"])

        #expect(items.count == 1)
        #expect(items.first?.id == ItemID.app(bundleID: "com.example.pocket"))
        #expect(items.first?.title == "Pocket")
    }

    @Test func appWithoutABundleIDIsKnownByItsPath() async throws {
        try makeApp("Apps/Lantern.app", bundleID: nil)

        let items = await items(inRoots: ["Apps"])

        let item = try #require(items.first)
        #expect(item.id == ItemID.app(path: path("Apps/Lantern.app")))
        #expect(item.id.rawValue == "app:path:" + path("Apps/Lantern.app"))
        #expect(item.subtitle == path("Apps/Lantern.app"))
        #expect(item.title == "Lantern")
    }

    @Test func appWithAnUnreadableInfoPlistIsKnownByItsPath() async throws {
        try makeFolder("Apps/Garbled.app/Contents")
        try Data("not a property list".utf8).write(
            to: URL(filePath: path("Apps/Garbled.app/Contents/Info.plist")))
        try makeFolder("Apps/Hollow.app")

        let items = await items(inRoots: ["Apps"])

        #expect(titles(of: items) == ["Garbled", "Hollow"])
        #expect(items[0].id == ItemID.app(path: path("Apps/Garbled.app")))
        #expect(items[0].subtitle == path("Apps/Garbled.app"))
        #expect(items[1].id == ItemID.app(path: path("Apps/Hollow.app")))
    }

    @Test func ofTwoCopiesTheOneInTheEarlierRootKeepsTheBundleID() async throws {
        try makeApp("Old/Lantern.app", bundleID: "com.example.lantern")
        try makeApp("New/Lantern.app", bundleID: "com.example.lantern")

        let items = await items(inRoots: ["New", "Old"])

        #expect(items.count == 2)
        #expect(items[0].id == ItemID.app(bundleID: "com.example.lantern"))
        #expect(items[0].icon == .file(path: path("New/Lantern.app")))
        #expect(items[0].subtitle == nil)
        #expect(items[1].id == ItemID.app(path: path("Old/Lantern.app")))
        #expect(items[1].subtitle == path("Old/Lantern.app"))
    }

    // "Xcode-beta.app" sorts before "Xcode.app". If the first copy listed kept the bundle ID,
    // installing the beta would hand it everything stored about how Xcode is used.
    @Test func ofTwoCopiesInOneRootTheOneWithTheShorterPathKeepsTheBundleID() async throws {
        try makeApp("Apps/Xcode.app", bundleID: "com.example.xcode")
        try makeApp("Apps/Xcode-beta.app", bundleID: "com.example.xcode")

        let items = await items(inRoots: ["Apps"])

        #expect(titles(of: items) == ["Xcode-beta", "Xcode"])
        #expect(items[0].id == ItemID.app(path: path("Apps/Xcode-beta.app")))
        #expect(items[0].subtitle == path("Apps/Xcode-beta.app"))
        #expect(items[1].id == ItemID.app(bundleID: "com.example.xcode"))
        #expect(items[1].subtitle == nil)
    }

    // MARK: Where apps are looked for

    @Test func appReachedDirectlyAndThroughALinkIsIndexedOnce() async throws {
        try makeApp("Apps/Lantern.app", bundleID: "com.example.lantern")
        try makeFolder("Links")
        try makeLink("Links/Lantern.app", to: "Apps/Lantern.app")

        let items = await items(inRoots: ["Apps", "Links"])

        #expect(items.count == 1)
        #expect(items.first?.icon == .file(path: path("Apps/Lantern.app")))
    }

    @Test func folderThatIsARootAndInsideAnotherRootIsIndexedOnce() async throws {
        try makeApp("Apps/Utilities/Lantern.app", bundleID: "com.example.lantern")

        let items = await items(inRoots: ["Apps", "Apps/Utilities"])

        #expect(items.count == 1)
        #expect(items.first?.id == ItemID.app(bundleID: "com.example.lantern"))
    }

    // Safari is installed like this: `/Applications/Safari.app` is a link into a cryptex.
    @Test func linkToAnAppOutsideTheRootsIsIndexedUnderTheLinksPath() async throws {
        // Without a bundle ID, so that the item's ID tells which path it was indexed under.
        try makeApp("Elsewhere/Lantern.app", bundleID: nil)
        try makeFolder("Apps")
        try makeLink("Apps/Lantern.app", to: "Elsewhere/Lantern.app")

        let items = await items(inRoots: ["Apps"])

        #expect(items.count == 1)
        #expect(items.first?.id == ItemID.app(path: path("Apps/Lantern.app")))
        #expect(items.first?.subtitle == path("Apps/Lantern.app"))
        // The icon is the bundle's own. That of the link would be drawn with an alias arrow.
        #expect(items.first?.icon == .file(path: path("Elsewhere/Lantern.app")))
    }

    @Test func linkedFolderIsSearched() async throws {
        try makeApp("Elsewhere/Suite/Lantern.app", bundleID: "com.example.lantern")
        try makeFolder("Apps")
        try makeLink("Apps/Suite", to: "Elsewhere/Suite")

        let items = await items(inRoots: ["Apps"])

        #expect(titles(of: items) == ["Lantern"])
    }

    @Test func linkThatPointsNowhereIsIgnored() async throws {
        try makeFolder("Apps")
        try makeLink("Apps/Gone.app", to: "Elsewhere/Gone.app")

        let items = await items(inRoots: ["Apps"])

        #expect(items.isEmpty)
    }

    @Test func foldersAreSearchedFiveLevelsDeep() async throws {
        try makeApp("Apps/One/Two/Three/Four/Deep.app", bundleID: "com.example.deep")
        try makeApp("Apps/One/Two/Three/Four/Five/TooDeep.app", bundleID: "com.example.toodeep")

        let items = await items(inRoots: ["Apps"])

        #expect(titles(of: items) == ["Deep"])
    }

    @Test func appsInsideAnAppAreNotIndexed() async throws {
        try makeApp("Apps/Lantern.app", bundleID: "com.example.lantern")
        try makeApp(
            "Apps/Lantern.app/Contents/Helpers/Lantern Helper.app",
            bundleID: "com.example.lantern.helper")

        let items = await items(inRoots: ["Apps"])

        #expect(titles(of: items) == ["Lantern"])
    }

    // Finder shows a package as one file, and what is in it is not for the user to open.
    @Test func appsInsideAnotherPackageAreNotIndexed() async throws {
        try makeApp(
            "Apps/Driver Installer.bundle/Driver Installer.app",
            bundleID: "com.example.installer")

        let items = await items(inRoots: ["Apps"])

        #expect(items.isEmpty)
    }

    @Test func appsInAHiddenFolderAreNotIndexed() async throws {
        try makeApp("Apps/.Trash/Lantern.app", bundleID: "com.example.lantern")

        let items = await items(inRoots: ["Apps"])

        #expect(items.isEmpty)
    }

    // Finder is listed like this: its bundle is a root of its own.
    @Test func rootCanBeAnApp() async throws {
        try makeApp("Apps/Lantern.app", bundleID: "com.example.lantern")

        let items = await items(inRoots: ["Apps/Lantern.app"])

        #expect(items.count == 1)
        #expect(items.first?.id == ItemID.app(bundleID: "com.example.lantern"))
        #expect(items.first?.icon == .file(path: path("Apps/Lantern.app")))
    }

    @Test func missingRootIsIgnored() async throws {
        try makeApp("Apps/Lantern.app", bundleID: "com.example.lantern")

        let items = await items(inRoots: ["Nowhere", "Nowhere/Gone.app", "Apps"])

        #expect(titles(of: items) == ["Lantern"])
    }

    @Test func appsOfARootAreOrderedByName() async throws {
        try makeApp("Apps/Compass.app", bundleID: "com.example.compass")
        try makeApp("Apps/Anchor.app", bundleID: "com.example.anchor")
        try makeApp("Apps/Beacon.app", bundleID: "com.example.beacon")

        let items = await items(inRoots: ["Apps"])

        #expect(titles(of: items) == ["Anchor", "Beacon", "Compass"])
    }

    // MARK: Names

    @Test func namesFromTheInfoPlistAreAlternateNames() async throws {
        try makeApp(
            "Apps/Visual Studio Code.app", bundleID: "com.example.code",
            info: ["CFBundleName": "Code", "CFBundleDisplayName": "Code"])
        try makeApp(
            "Apps/Lantern.app", bundleID: "com.example.lantern",
            info: ["CFBundleName": "Lantern", "CFBundleDisplayName": "Lantern Pro"])

        let items = await items(inRoots: ["Apps"])

        // "Code" is there once although two keys have it, and the file name is not repeated
        // when it is the title already.
        #expect(items[1].title == "Visual Studio Code")
        #expect(items[1].alternateNames == [NameVariant(text: "Code", weight: 1)])
        #expect(items[0].title == "Lantern")
        #expect(items[0].alternateNames == [NameVariant(text: "Lantern Pro", weight: 1)])
    }

    @Test func alternateNameOfAnAppIsAnExactMatch() async throws {
        try makeApp(
            "Apps/Visual Studio Code.app", bundleID: "com.example.code",
            info: ["CFBundleName": "Code"])

        let snapshot = await IndexSnapshot.build(from: items(inRoots: ["Apps"]))
        let results = try #require(
            await snapshot.rank(query: SearchQuery("code"), usage: UsageSnapshot(), now: Date()))

        #expect(results.rows.first?.scored.quality == 1)
    }

    /// An app as macOS ships them: translated into three languages, with the names for all of
    /// them in one table.
    private func makeAbacus(at relativePath: String) throws {
        try makeApp(
            relativePath, bundleID: "com.example.abacus",
            info: ["CFBundleDisplayName": "Abacus", "CFBundleName": "Abacus"])
        for language in ["de", "en", "fr"] {
            try addLocalization(language, toApp: relativePath)
        }
        let table: [String: Any] = [
            "de": ["CFBundleDisplayName": "Rechenbrett", "CFBundleName": "Rechenbrett"],
            "en": ["CFBundleDisplayName": "Counting Frame", "CFBundleName": "Abacus"],
            "fr": ["CFBundleDisplayName": "Boulier", "CFBundleName": "Boulier"],
        ]
        try write(table, to: "\(relativePath)/Contents/Resources/InfoPlist.loctable")
    }

    @Test func titleIsTheNameInTheUsersLanguage() async throws {
        try makeAbacus(at: "Apps/Abacus.app")

        let items = await items(inRoots: ["Apps"], preferredLanguages: ["de-DE", "en-US"])

        // The English names stay findable. The French ones were never read.
        let item = try #require(items.first)
        #expect(item.title == "Rechenbrett")
        #expect(alternateNames(of: item) == ["Abacus", "Counting Frame"])
    }

    @Test func englishUserGetsTheEnglishName() async throws {
        try makeAbacus(at: "Apps/Abacus.app")

        let items = await items(inRoots: ["Apps"], preferredLanguages: ["en-US"])

        let item = try #require(items.first)
        #expect(item.title == "Counting Frame")
        #expect(alternateNames(of: item) == ["Abacus"])
    }

    @Test func renamedAppKeepsItsFileNameAsTitle() async throws {
        try makeAbacus(at: "Apps/My Abacus.app")

        let items = await items(inRoots: ["Apps"], preferredLanguages: ["de"])

        let item = try #require(items.first)
        #expect(item.title == "My Abacus")
        #expect(alternateNames(of: item) == ["Abacus", "Rechenbrett", "Counting Frame"])
    }

    @Test func localisedNamesAreReadFromAStringsFileInUTF16Text() async throws {
        try makeApp(
            "Apps/Lantern.app", bundleID: "com.example.lantern",
            info: ["CFBundleDisplayName": "Lantern"])
        try addLocalization("de", toApp: "Apps/Lantern.app")
        let strings = """
            /* The name in Finder. */
            "CFBundleDisplayName" = "Laterne";
            "CFBundleName" = "Laterne";

            """
        let stringsPath = path("Apps/Lantern.app/Contents/Resources/de.lproj/InfoPlist.strings")
        try #require(strings.data(using: .utf16)).write(to: URL(filePath: stringsPath))

        let items = await items(inRoots: ["Apps"], preferredLanguages: ["de"])

        let item = try #require(items.first)
        #expect(item.title == "Laterne")
        #expect(alternateNames(of: item) == ["Lantern"])
    }

    @Test func localisedNamesAreReadFromAStringsFileThatIsABinaryPropertyList() async throws {
        try makeApp(
            "Apps/Lantern.app", bundleID: "com.example.lantern",
            info: ["CFBundleDisplayName": "Lantern"])
        try addLocalization(
            "de", toApp: "Apps/Lantern.app", strings: ["CFBundleDisplayName": "Laterne"])
        try addLocalization(
            "en", toApp: "Apps/Lantern.app", strings: ["CFBundleDisplayName": "Lantern Light"])
        try addLocalization(
            "fr", toApp: "Apps/Lantern.app", strings: ["CFBundleDisplayName": "Lanterne"])

        let items = await items(inRoots: ["Apps"], preferredLanguages: ["de"])

        // German because it is preferred, English because it always is, French not at all.
        let item = try #require(items.first)
        #expect(item.title == "Laterne")
        #expect(alternateNames(of: item) == ["Lantern", "Lantern Light"])
    }

    @Test func regionalVariantOfALanguageGoesBeforeTheLanguage() async throws {
        try makeApp(
            "Apps/Color Meter.app", bundleID: "com.example.colormeter",
            info: ["CFBundleDisplayName": "Color Meter"])
        try addLocalization(
            "en", toApp: "Apps/Color Meter.app", strings: ["CFBundleName": "Color Meter"])
        try addLocalization(
            "en_GB", toApp: "Apps/Color Meter.app",
            strings: ["CFBundleDisplayName": "Colour Meter"])

        let british = await items(inRoots: ["Apps"], preferredLanguages: ["en-GB"])
        let american = await items(inRoots: ["Apps"], preferredLanguages: ["en-US"])

        #expect(british.first?.title == "Colour Meter")
        #expect(american.first?.title == "Color Meter")
    }

    // Activity Monitor is one of these: no `CFBundleDisplayName`, a localised `CFBundleName`.
    @Test func olderAppThatSaysSoIsTitledByItsLocalisedShortName() async throws {
        try makeApp(
            "Apps/Lantern.app", bundleID: "com.example.lantern",
            info: ["CFBundleName": "Lantern", "LSHasLocalizedDisplayName": true])
        try addLocalization(
            "de", toApp: "Apps/Lantern.app", strings: ["CFBundleName": "Laterne"])
        try makeApp(
            "Apps/Compass.app", bundleID: "com.example.compass", info: ["CFBundleName": "Compass"])
        try addLocalization(
            "de", toApp: "Apps/Compass.app", strings: ["CFBundleName": "Kompass"])

        let items = await items(inRoots: ["Apps"], preferredLanguages: ["de"])

        // Finder shows "Compass" too. Its German name still finds it.
        #expect(items[0].title == "Compass")
        #expect(alternateNames(of: items[0]) == ["Kompass"])
        #expect(items[1].title == "Laterne")
        #expect(alternateNames(of: items[1]) == ["Lantern"])
    }

    @Test func nameForTheMacGoesBeforeTheNameForEveryPlatform() async throws {
        try makeApp(
            "Apps/Image Playground.app", bundleID: "com.example.playground",
            info: ["CFBundleDisplayName": "Image Playground"])
        try addLocalization(
            "de", toApp: "Apps/Image Playground.app",
            strings: [
                "CFBundleDisplayName": "Spielplatz",
                "CFBundleDisplayName-macos": "Bilderspielplatz",
            ])

        let items = await items(inRoots: ["Apps"], preferredLanguages: ["de"])

        let item = try #require(items.first)
        #expect(item.title == "Bilderspielplatz")
        #expect(alternateNames(of: item) == ["Image Playground", "Spielplatz"])
    }

    // `Bundle.preferredLocalizations` falls back to some localisation of the bundle when none
    // is in the user's languages. A name from there is not the app's name to this user.
    @Test func appWithoutANameInTheUsersLanguagesIsTitledByItsFileName() async throws {
        try makeApp(
            "Apps/Lantern.app", bundleID: "com.example.lantern",
            info: ["CFBundleDisplayName": "Lantern"])
        try addLocalization(
            "ar", toApp: "Apps/Lantern.app", strings: ["CFBundleDisplayName": "فانوس"])
        try addLocalization(
            "ja", toApp: "Apps/Lantern.app", strings: ["CFBundleDisplayName": "ランタン"])
        try makeApp(
            "Apps/Compass.app", bundleID: "com.example.compass",
            info: ["CFBundleDisplayName": "Compass"])
        try addLocalization(
            "en", toApp: "Apps/Compass.app", strings: ["CFBundleDisplayName": "Compass Rose"])
        try addLocalization(
            "fr", toApp: "Apps/Compass.app", strings: ["CFBundleDisplayName": "Boussole"])

        let items = await items(inRoots: ["Apps"], preferredLanguages: ["de-DE"])

        // The English name still finds the app, as it does for every user.
        #expect(items[0].title == "Compass")
        #expect(alternateNames(of: items[0]) == ["Compass Rose"])
        #expect(items[1].title == "Lantern")
        #expect(alternateNames(of: items[1]) == [])
    }

    // Bundles from before language codes name the folder after the language.
    @Test func localisationFolderNamedAfterTheLanguageCountsAsThatLanguage() async throws {
        try makeApp(
            "Apps/Lantern.app", bundleID: "com.example.lantern",
            info: ["CFBundleDisplayName": "Lantern"])
        try addLocalization(
            "German", toApp: "Apps/Lantern.app", strings: ["CFBundleDisplayName": "Laterne"])

        let items = await items(inRoots: ["Apps"], preferredLanguages: ["de-DE"])

        #expect(items.first?.title == "Laterne")
    }

    // MARK: Actions

    /// A host for the tests that are not about actions.
    @MainActor private final class IdleHost: AppActionHost {
        func openApp(at url: URL) async throws {}
        func hideAppIfFrontmost(at url: URL) -> Bool { false }
        func showInFinder(_ url: URL) {}
        func quitApp(at url: URL) -> Bool { false }
        func showAliasSettings(for item: ItemID) {}
    }

    private struct LaunchFailure: Error {}

    /// Records what the actions asked for, in order, together with what they asked of the
    /// launcher through `context`.
    @MainActor private final class RecordingHost: AppActionHost {
        let context = FakeActionContext(query: "lan")
        private(set) var events: [String] = []
        var openFails = false
        var appIsRunning = true
        var appIsFrontmost = false

        /// The launcher has to be closed before a window opens outside the panel.
        private func record(_ event: String) {
            let launcher = context.closeLauncherCount > 0 ? "closed" : "open"
            events.append("\(event), launcher \(launcher)")
        }

        func openApp(at url: URL) async throws {
            if openFails { throw LaunchFailure() }
            record("open \(url.lastPathComponent)")
        }

        func hideAppIfFrontmost(at url: URL) -> Bool {
            guard appIsFrontmost else { return false }
            record("hide \(url.lastPathComponent)")
            return true
        }

        func showInFinder(_ url: URL) {
            record("reveal \(url.lastPathComponent)")
        }

        func quitApp(at url: URL) -> Bool {
            record("quit \(url.lastPathComponent)")
            return appIsRunning
        }

        func showAliasSettings(for item: ItemID) {
            record("alias \(item.rawValue)")
        }
    }

    /// The action with this ID of the one app the tests below index.
    private func lanternAction(
        _ id: String, host: any AppActionHost
    ) async throws -> ActionDescriptor {
        try makeApp("Apps/Lantern.app", bundleID: "com.example.lantern")
        let source = source(roots: ["Apps"], host: host)
        let items = await source.items(from: source.scanAllRoots())
        let item = try #require(items.first)
        return try #require(item.actions.first { $0.id == ActionID(rawValue: id) })
    }

    @MainActor @Test func openActionClosesTheLauncherAndThenOpensTheApp() async throws {
        let host = RecordingHost()
        let open = try await lanternAction("open", host: host)

        let outcome = try await open.perform(host.context)

        #expect(host.events == ["open Lantern.app, launcher closed"])
        #expect(outcome == .closeLauncher)
    }

    @MainActor @Test func hotKeyHidesTheAppWhenItIsInFront() async throws {
        let host = RecordingHost()
        host.appIsFrontmost = true
        host.context.startedByHotKey = true
        let open = try await lanternAction("open", host: host)

        let outcome = try await open.perform(host.context)

        #expect(host.events == ["hide Lantern.app, launcher closed"])
        #expect(outcome == .closeLauncher)
    }

    @MainActor @Test func hotKeyOpensTheAppWhenAnotherAppIsInFront() async throws {
        let host = RecordingHost()
        host.context.startedByHotKey = true
        let open = try await lanternAction("open", host: host)

        _ = try await open.perform(host.context)

        #expect(host.events == ["open Lantern.app, launcher closed"])
    }

    @MainActor @Test func returnInTheLauncherOpensTheAppEvenWhenItIsInFront() async throws {
        let host = RecordingHost()
        host.appIsFrontmost = true
        let open = try await lanternAction("open", host: host)

        _ = try await open.perform(host.context)

        #expect(host.events == ["open Lantern.app, launcher closed"])
    }

    @MainActor @Test func openActionThrowsWhenTheAppCannotBeOpened() async throws {
        let host = RecordingHost()
        host.openFails = true
        let open = try await lanternAction("open", host: host)

        await #expect(throws: LaunchFailure.self) {
            try await open.perform(host.context)
        }
    }

    @MainActor @Test func showInFinderClosesTheLauncherAndRevealsTheApp() async throws {
        let host = RecordingHost()
        let reveal = try await lanternAction("show-in-finder", host: host)

        let outcome = try await reveal.perform(host.context)

        #expect(host.events == ["reveal Lantern.app, launcher closed"])
        #expect(outcome == .closeLauncher)
    }

    @MainActor @Test func quitAsksARunningAppToQuitAndCloses() async throws {
        let host = RecordingHost()
        let quit = try await lanternAction("quit", host: host)

        let outcome = try await quit.perform(host.context)

        #expect(host.events == ["quit Lantern.app, launcher open"])
        #expect(outcome == .closeLauncher)
        #expect(host.context.hudMessages.isEmpty)
    }

    @MainActor @Test func quitOfAnAppThatIsNotRunningSaysSoAndStays() async throws {
        let host = RecordingHost()
        host.appIsRunning = false
        let quit = try await lanternAction("quit", host: host)

        let outcome = try await quit.perform(host.context)

        #expect(outcome == .keepOpen)
        #expect(host.context.hudMessages == ["Lantern is not running"])
    }

    @MainActor @Test func copyPathCopiesThePathTheAppWasFoundUnder() async throws {
        // Found through a link, as Safari is in `/Applications`. The path to copy is the
        // link's, which is the one Finder shows, and not where it leads.
        try makeApp("Elsewhere/Lantern.app", bundleID: "com.example.lantern")
        try makeFolder("Apps")
        try makeLink("Apps/Lantern.app", to: "Elsewhere/Lantern.app")
        let items = await items(inRoots: ["Apps"])
        let copyPath = try #require(
            items.first?.actions.first { $0.id == ActionID(rawValue: "copy-path") })
        let context = FakeActionContext()

        let outcome = try await copyPath.perform(context)

        #expect(context.copied == [.text(path("Apps/Lantern.app"), cursorOffsetFromEnd: nil)])
        #expect(outcome == .copiedToClipboard)
    }

    @MainActor @Test func copyBundleIdentifierCopiesTheIdentifier() async throws {
        let host = RecordingHost()
        let copyIdentifier = try await lanternAction("copy-bundle-identifier", host: host)

        let outcome = try await copyIdentifier.perform(host.context)

        #expect(host.context.copied == [.text("com.example.lantern", cursorOffsetFromEnd: nil)])
        #expect(outcome == .copiedToClipboard)
    }

    @Test func appWithoutABundleIdentifierHasNoActionToCopyOne() async throws {
        try makeApp("Apps/Nameless.app", bundleID: nil)

        let items = await items(inRoots: ["Apps"])

        let actionIDs = try #require(items.first).actions.map(\.id.rawValue)
        #expect(actionIDs.contains("copy-path"))
        #expect(!actionIDs.contains("copy-bundle-identifier"))
    }

    @MainActor @Test func addAliasOpensSettingsOnTheApp() async throws {
        let host = RecordingHost()
        let addAlias = try await lanternAction("add-alias", host: host)

        let outcome = try await addAlias.perform(host.context)

        #expect(host.events == ["alias app:com.example.lantern, launcher closed"])
        #expect(outcome == .closeLauncher)
    }

    @MainActor @Test func hideWritesAnOverrideAndKeepsWhatElseWasStored() async throws {
        let lantern = ItemID.app(bundleID: "com.example.lantern")
        try await commands.updateOverride(for: lantern) { override in override.disabled = true }
        let host = RecordingHost()
        let hide = try await lanternAction("hide", host: host)

        let outcome = try await hide.perform(host.context)

        let stored = try await commands.snapshot().overrides[lantern]
        #expect(stored == ItemOverride(hidden: true, disabled: true))
        #expect(outcome == .keepOpen)
        #expect(
            host.context.hudMessages == ["Lantern is hidden. Settings › Commands brings it back."])
    }

    // MARK: User folders

    @Test func foldersFromThePreferenceAreSearchedAfterTheRoots() async throws {
        try makeApp("Apps/Lantern.app", bundleID: "com.example.lantern")
        try makeApp("Tools/Compass.app", bundleID: "com.example.compass")
        // A copy of an app that a root has: the root's copy keeps the bundle ID.
        try makeApp("Tools/Lantern.app", bundleID: "com.example.lantern")
        let preferences = InMemoryPreferencesStore()
        preferences.set([path("Tools")], for: .appFolders)
        let source = source(roots: ["Apps"], preferences: preferences)

        let items = await source.items(from: source.scanAllRoots())

        #expect(titles(of: items) == ["Lantern", "Compass", "Lantern"])
        #expect(items[0].id == .app(bundleID: "com.example.lantern"))
        #expect(items[2].id == .app(path: path("Tools/Lantern.app")))
    }

    // Two equal roots would be scanned twice, and a change would only ever reach the first.
    @Test func folderThatIsARootAlreadyIsNotSearchedTwice() async throws {
        try makeApp("Apps/Lantern.app", bundleID: "com.example.lantern")
        let preferences = InMemoryPreferencesStore()
        // With a slash at the end, as an open panel reports a folder.
        preferences.set([path("Apps") + "/"], for: .appFolders)
        let source = source(roots: ["Apps"], preferences: preferences)

        let appsByRoot = await source.scanAllRoots()

        #expect(appsByRoot.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func addingAndRemovingAFolderIsFollowedWithoutARestart() async throws {
        try makeApp("Apps/Lantern.app", bundleID: "com.example.lantern")
        try makeApp("Tools/Compass.app", bundleID: "com.example.compass")
        let preferences = InMemoryPreferencesStore()
        let itemSets = source(roots: ["Apps"], preferences: preferences).indexedItems()
        var iterator = itemSets.makeAsyncIterator()
        let firstItems = try #require(await iterator.next())
        #expect(titles(of: firstItems) == ["Lantern"])

        preferences.set([path("Tools")], for: .appFolders)
        let withFolder = try #require(await iterator.next())
        #expect(titles(of: withFolder) == ["Lantern", "Compass"])

        preferences.set([], for: .appFolders)
        let withoutFolder = try #require(await iterator.next())
        #expect(titles(of: withoutFolder) == ["Lantern"])
    }

    // MARK: Staying current

    /// Whether the stream yields a set of items with this title before the time is up.
    ///
    /// Swift Testing counts time limits in minutes, so the wait is raced against a sleep.
    private func hasItem(
        titled title: String, in itemSets: AsyncStream<[SearchItem]>, within timeout: Duration
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await items in itemSets {
                    let hasTitle = items.contains { item in item.title == title }
                    if hasTitle { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }

            let firstAnswer = await group.next() ?? false
            // Ends the task that is still waiting, and with it the stream.
            group.cancelAll()
            return firstAnswer
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func streamStartsWithTheAppsThatAreThere() async throws {
        try makeApp("Apps/Lantern.app", bundleID: "com.example.lantern")
        let itemSets = source(roots: ["Apps", "Nowhere"]).indexedItems()

        var iterator = itemSets.makeAsyncIterator()
        let firstItems = try #require(await iterator.next())

        #expect(titles(of: firstItems) == ["Lantern"])
    }

    // The one test that depends on FSEvents delivering an event, which takes about a second.
    @Test(.timeLimit(.minutes(1)))
    func appAddedToAWatchedRootIsYieldedWithoutARescanRequest() async throws {
        try makeApp("Apps/Lantern.app", bundleID: "com.example.lantern")
        let itemSets = source(roots: ["Apps"]).indexedItems()

        // The first set is taken before anything changes: by then the folder is being watched.
        var iterator = itemSets.makeAsyncIterator()
        let firstItems = try #require(await iterator.next())
        #expect(titles(of: firstItems) == ["Lantern"])

        try makeApp("Apps/Compass.app", bundleID: "com.example.compass")

        let hasNewApp = await hasItem(titled: "Compass", in: itemSets, within: .seconds(5))
        #expect(hasNewApp, "No file-system event led to a rescan within 5 seconds")
    }

    @Test(.timeLimit(.minutes(1)))
    func rescanYieldsTheAppsAsTheyAreNow() async throws {
        try makeApp("Apps/Lantern.app", bundleID: "com.example.lantern")
        let source = source(roots: ["Apps", "Later"])
        let itemSets = source.indexedItems()
        var iterator = itemSets.makeAsyncIterator()
        _ = await iterator.next()

        // This root did not exist when the stream began, so nothing watches it.
        try makeApp("Later/Compass.app", bundleID: "com.example.compass")
        source.rescan()

        let hasLaterApp = await hasItem(titled: "Compass", in: itemSets, within: .seconds(5))
        #expect(hasLaterApp, "The rescan did not yield the app in the root that appeared later")
    }

    // The registry takes the stream once. A source must not depend on that: the queue of rescan
    // requests ends with the stream it belongs to, and the next stream needs one of its own.
    @Test(.timeLimit(.minutes(1)))
    func streamTakenAfterAnEarlierOneHasEndedFollowsRescansToo() async throws {
        try makeApp("Apps/Lantern.app", bundleID: "com.example.lantern")
        let source = source(roots: ["Apps", "Later"])

        // `hasItem` ends the stream it was given as soon as it has its answer.
        let earlierStreamHadTheApp = await hasItem(
            titled: "Lantern", in: source.indexedItems(), within: .seconds(5))
        #expect(earlierStreamHadTheApp)

        let itemSets = source.indexedItems()
        var iterator = itemSets.makeAsyncIterator()
        _ = await iterator.next()
        try makeApp("Later/Compass.app", bundleID: "com.example.compass")
        source.rescan()

        let hasLaterApp = await hasItem(titled: "Compass", in: itemSets, within: .seconds(5))
        #expect(hasLaterApp, "The second stream did not follow the rescan")
    }
}
