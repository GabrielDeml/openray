import Foundation

/// What a scan reads about one app bundle.
struct ScannedApp: Sendable {
    /// Where the bundle was found. The path may run through a symbolic link, and it is the one
    /// the user knows the app by.
    var path: String
    /// The same place with every symbolic link followed. A bundle that is reached by two ways
    /// has one resolved path.
    var resolvedPath: String
    /// nil when the bundle has none or its `Info.plist` cannot be read.
    var bundleID: String?
    /// The name Finder shows for the bundle to this user: its localised name, or its file name
    /// without ".app".
    var displayName: String
    /// The other names the app goes by: its file name, the names in its `Info.plist` and its
    /// localised names. They may repeat each other and the display name.
    var otherNames: [String]
}

/// Finds the app bundles in a folder and reads their names (docs/DESIGN.md §4.2.8).
enum AppBundleScanner {
    /// How many levels below a root are searched. An app directly in `/Applications` is at
    /// level 1, one in `/Applications/Setapp/` at level 2. Unity Hub installs its editors at
    /// level 5, in `/Applications/Unity/Hub/Editor/<version>/`. The limit is also what ends the
    /// search when symbolic links form a loop.
    static let maximumDepth = 5

    /// The apps in `root` and its subfolders, or the one app `root` is, ordered by path.
    ///
    /// A root that does not exist has no apps; that is not an error, because many users have no
    /// `~/Applications`.
    ///
    /// - Parameter preferredLanguages: The languages localised names are read in, most wanted
    ///   first, as `Locale.preferredLanguages` gives them. English is always read as well.
    @concurrent
    static func apps(in root: URL, preferredLanguages: [String]) async -> [ScannedApp] {
        let rootPath = filePath(of: root)

        var bundlePaths: [String] = []
        if hasAppExtension(rootPath) {
            if isDirectory(rootPath) {
                bundlePaths.append(rootPath)
            }
        } else {
            collectBundlePaths(inFolder: rootPath, level: 1, into: &bundlePaths)
        }

        var apps: [ScannedApp] = []
        for path in bundlePaths {
            apps.append(readApp(at: path, preferredLanguages: preferredLanguages))
        }
        return apps
    }

    // MARK: Finding bundles

    private static func collectBundlePaths(
        inFolder folderPath: String, level: Int, into bundlePaths: inout [String]
    ) {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folderPath)
        } catch {
            if FileManager.default.fileExists(atPath: folderPath) {
                Log.search.error("Cannot list the folder \(folderPath): \(error)")
            }
            return
        }

        // Sorted, so that two scans of an unchanged folder give the same list.
        for name in names.sorted() {
            // Finder and Spotlight do not show what is in a hidden folder either.
            if name.hasPrefix(".") { continue }

            let path = (folderPath as NSString).appendingPathComponent(name)
            // This follows symbolic links, as the listing of a folder above does. It has to:
            // `/Applications/Safari.app` is a link into a cryptex.
            guard isDirectory(path) else { continue }

            if hasAppExtension(name) {
                // The name alone makes it an app, as it does for Finder. The type a bundle
                // gives itself says little: Finder's is "FNDR", a Safari web app's "AAPL".
                // The app's own folders are not searched; the helper apps in there are not for
                // the user to open.
                bundlePaths.append(path)
            } else if level < maximumDepth && !isPackage(path) {
                // Other packages are not searched either. An installer's `.bundle` can hold an
                // app, and Finder and Spotlight do not show that one.
                collectBundlePaths(inFolder: path, level: level + 1, into: &bundlePaths)
            }
        }
    }

    private static func hasAppExtension(_ name: String) -> Bool {
        name.hasSuffix(".app")
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Whether Finder shows the folder as one file, as it does a `.bundle` or a `.framework`.
    private static func isPackage(_ path: String) -> Bool {
        let url = URL(filePath: path, directoryHint: .isDirectory)
        let values = try? url.resourceValues(forKeys: [.isPackageKey])
        return values?.isPackage == true
    }

    /// The URL's path without the slash that the path of a folder's URL ends in. Paths are
    /// compared, stored in item IDs and shown to the user without it.
    private static func filePath(of url: URL) -> String {
        let path = url.path(percentEncoded: false)
        if path.count > 1 && path.hasSuffix("/") {
            return String(path.dropLast())
        }
        return path
    }

    // MARK: Reading one bundle

    /// The `InfoPlist` strings of a bundle in the languages that matter for one user.
    private struct LocalizedInfo {
        /// One table for each of the user's languages the bundle is translated into, best
        /// first. For a British user that is British English and then English.
        var stringsInUserLanguages: [[String: Any]] = []
        /// The English table, unless English is among the user's languages already.
        var englishStrings: [String: Any]?
    }

    /// Reads the bundle's own files. Neither `Bundle` nor LaunchServices is asked: `Bundle`
    /// caches what it read for as long as the process lives, and
    /// `FileManager.displayName(atPath:)` answers in the languages this app is translated into,
    /// not in the user's, and blocks on a call into another process for a bundle LaunchServices
    /// has not seen before.
    private static func readApp(at path: String, preferredLanguages: [String]) -> ScannedApp {
        let info = readInfo(ofBundleAt: path)
        let localizedInfo = readLocalizedInfo(
            ofBundleAt: path, preferredLanguages: preferredLanguages)

        let lastPathComponent = (path as NSString).lastPathComponent
        let fileName = String(lastPathComponent.dropLast(".app".count))

        var otherNames = [fileName]
        otherNames += names(in: info)
        for strings in localizedInfo.stringsInUserLanguages {
            otherNames += names(in: strings)
        }
        // People also type an app's English name on a Mac that is set to another language.
        otherNames += names(in: localizedInfo.englishStrings)

        var bundleID = info?["CFBundleIdentifier"] as? String
        if bundleID == "" {
            bundleID = nil
        }

        let resolvedURL = URL(filePath: path, directoryHint: .isDirectory).resolvingSymlinksInPath()
        return ScannedApp(
            path: path,
            resolvedPath: filePath(of: resolvedURL),
            bundleID: bundleID,
            displayName: displayName(
                fileName: fileName, info: info,
                localizedStrings: localizedInfo.stringsInUserLanguages),
            otherNames: otherNames)
    }

    /// - Returns: nil when the bundle has no `Info.plist` that can be read.
    private static func readInfo(ofBundleAt path: String) -> [String: Any]? {
        if let info = propertyList(atPath: path + "/Contents/Info.plist") {
            return info
        }
        // An iPhone or iPad app from the App Store is a wrapper around the real bundle, which
        // is laid out as on iOS and reached through the link `WrappedBundle`.
        return propertyList(atPath: path + "/WrappedBundle/Info.plist")
    }

    private static func readLocalizedInfo(
        ofBundleAt path: String, preferredLanguages: [String]
    ) -> LocalizedInfo {
        let resourcesPath = path + "/Contents/Resources"
        // System apps keep the strings for every language in one file, {language: {key: text}}.
        // Other apps have an `InfoPlist.strings` in the folder of each language.
        let table = propertyList(atPath: resourcesPath + "/InfoPlist.loctable")
        let bestLocalizations = Bundle.preferredLocalizations(
            from: localizations(inResourcesAt: resourcesPath), forPreferences: preferredLanguages)

        // `Bundle` never answers with nothing. For a bundle that has none of the user's
        // languages it names English, or else whichever localisation comes first. A name in
        // such a language is not the app's name to this user, so those answers are left out.
        var userLanguages: [String] = []
        for localization in bestLocalizations {
            if isLocalization(localization, inOneOf: preferredLanguages) {
                userLanguages.append(localization)
            }
        }

        var localizedInfo = LocalizedInfo()
        for language in userLanguages {
            let strings = localizedStrings(
                for: language, resourcesPath: resourcesPath, table: table)
            if let strings {
                localizedInfo.stringsInUserLanguages.append(strings)
            }
        }
        if !userLanguages.contains("en") {
            localizedInfo.englishStrings = localizedStrings(
                for: "en", resourcesPath: resourcesPath, table: table)
        }
        return localizedInfo
    }

    /// Whether a localisation of a bundle ("en_GB", "de", "German") is in one of the languages
    /// ("en-GB", "de-DE"), whatever the region.
    private static func isLocalization(
        _ localization: String, inOneOf languages: [String]
    ) -> Bool {
        guard let code = languageCode(of: localization) else { return false }
        for language in languages {
            if languageCode(of: language) == code { return true }
        }
        return false
    }

    private static func languageCode(of identifier: String) -> String? {
        // Made canonical first: old bundles call the folder "German.lproj", and that only
        // becomes "de" this way.
        let canonical = Locale.canonicalLanguageIdentifier(from: identifier)
        return Locale.Language(identifier: canonical).languageCode?.identifier
    }

    /// The languages the bundle is translated into: it has a folder for each.
    private static func localizations(inResourcesAt resourcesPath: String) -> [String] {
        let resourceNames = try? FileManager.default.contentsOfDirectory(atPath: resourcesPath)

        var localizations: [String] = []
        for name in resourceNames ?? [] where name.hasSuffix(".lproj") {
            localizations.append(String(name.dropLast(".lproj".count)))
        }
        // Sorted, because a folder is not always listed in the same order, and two scans of an
        // unchanged bundle should ask `Bundle` the same question.
        return localizations.sorted()
    }

    private static func localizedStrings(
        for language: String, resourcesPath: String, table: [String: Any]?
    ) -> [String: Any]? {
        if let table {
            return table[language] as? [String: Any]
        }
        return propertyList(atPath: "\(resourcesPath)/\(language).lproj/InfoPlist.strings")
    }

    /// The name Finder shows for the app to this user, by the rules LaunchServices goes by.
    /// They were checked against `FileManager.displayName(atPath:)` for the apps of one Mac in
    /// thirteen languages (docs/DESIGN.md §4.2.8).
    ///
    /// - Parameter localizedStrings: The bundle's strings in the user's languages, best first.
    private static func displayName(
        fileName: String, info: [String: Any]?, localizedStrings: [[String: Any]]
    ) -> String {
        // A bundle has a localised name only while it is still called what its `Info.plist`
        // says. Once the user has renamed the app, the file name is its name. Most apps name
        // themselves with `CFBundleDisplayName`; older ones localise `CFBundleName` and say so
        // with `LSHasLocalizedDisplayName`.
        let nameKey: String
        if info?["CFBundleDisplayName"] as? String == fileName {
            nameKey = "CFBundleDisplayName"
        } else if info?["CFBundleName"] as? String == fileName,
            info?["LSHasLocalizedDisplayName"] as? Bool == true
        {
            nameKey = "CFBundleName"
        } else {
            return fileName
        }

        for strings in localizedStrings {
            // A name for the Mac alone goes before the name for every platform: Image
            // Playground is called "Playground" on the iPhone.
            if let name = strings[nameKey + "-macos"] as? String, !name.isEmpty { return name }
            if let name = strings[nameKey] as? String, !name.isEmpty { return name }
        }
        return fileName
    }

    /// The names in an `Info.plist` or in one of its localisations: the display name first,
    /// then the short name, each only when it is there.
    private static func names(in strings: [String: Any]?) -> [String] {
        var names: [String] = []
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            guard let name = strings?[key] as? String, !name.isEmpty else { continue }
            names.append(name)
        }
        return names
    }

    /// Reads a property list whose root is a dictionary. That covers `Info.plist`, a `.loctable`
    /// and both forms a `.strings` file comes in: text (usually UTF-16) and a binary property
    /// list.
    ///
    /// - Returns: nil when the file is missing or is not such a property list.
    private static func propertyList(atPath path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil)
        return propertyList as? [String: Any]
    }
}
