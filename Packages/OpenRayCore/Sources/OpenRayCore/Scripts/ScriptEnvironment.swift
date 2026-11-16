/// The environment a script runs in (docs/DESIGN.md §4.10).
public enum ScriptEnvironment {
    /// What launchd gives an app that was opened from Finder.
    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// Where Homebrew puts its tools, on Apple silicon and on Intel.
    static let homebrewDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The environment for a script when the user's shell could not be asked for its own:
    /// what OpenRay itself was started with, and Homebrew's folders in front of `PATH`, since
    /// most scripts that fail without a login shell fail to find a tool from there.
    public static func fallback(inherited: [String: String]) -> [String: String] {
        var path = inherited["PATH"] ?? ""
        if path.isEmpty {
            path = systemPath
        }

        var directories: [String] = []
        for directory in path.split(separator: ":") {
            directories.append(String(directory))
        }
        var missingDirectories: [String] = []
        for directory in homebrewDirectories {
            if !directories.contains(directory) {
                missingDirectories.append(directory)
            }
        }

        var variables = inherited
        variables["PATH"] = (missingDirectories + [path]).joined(separator: ":")
        return variables
    }

    /// - Parameters:
    ///   - base: The user's environment: the one captured from the login shell, or the
    ///     fallback.
    ///   - appVersion: OpenRay's version, such as "0.3.0".
    public static func variables(
        for scriptPath: String, base: [String: String], appVersion: String
    ) -> [String: String] {
        var variables = base

        // These are OpenRay's to set, whatever the shell said.
        variables["OPENRAY"] = "1"
        variables["OPENRAY_VERSION"] = appVersion
        variables["OPENRAY_SCRIPT_PATH"] = scriptPath
        // The output goes to a text view and not to a terminal.
        variables["NO_COLOR"] = "1"
        variables["TERM"] = "dumb"

        // Without a locale, tools take their output for ASCII and many will not print an
        // umlaut. A locale the user chose is left alone.
        let language = variables["LANG"] ?? ""
        if language.isEmpty {
            variables["LANG"] = "en_US.UTF-8"
        }
        return variables
    }
}
