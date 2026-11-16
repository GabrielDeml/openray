/// Reads the environment out of what a login shell printed (docs/DESIGN.md §4.10).
///
/// The shell is asked to print a sentinel, then `env -0`, then another sentinel. Its rc files
/// may print whatever they like before and after, so only the text between the two counts.
/// Values are secrets as far as OpenRay is concerned: nothing here logs or reports one.
public enum ShellEnvironmentParser {
    /// Variables that describe the shell that did the printing and not the user's
    /// environment: its last command, how deeply it is nested, and where it happened to be.
    static let namesOfTheCapturingShell: Set<String> = ["_", "SHLVL", "PWD", "OLDPWD"]

    /// - Parameters:
    ///   - start: The sentinel printed before the environment.
    ///   - end: The sentinel printed after it.
    /// - Returns: nil unless both sentinels are there in that order, which means the shell
    ///   did not get as far as printing its environment whole.
    public static func variables(
        in output: String, start: String, end: String
    ) -> [String: String]? {
        guard let startRange = output.firstRange(of: start) else { return nil }
        let afterStart = output[startRange.upperBound...]
        guard let endRange = afterStart.firstRange(of: end) else { return nil }
        let environment = afterStart[..<endRange.lowerBound]

        var variables: [String: String] = [:]
        // `env -0` ends every entry with a NUL, because a value may hold line ends.
        for entry in environment.split(separator: "\0") {
            // The name ends at the first "="; the value may have more of them. The bytes
            // are searched, since Swift takes "=" and an accent after it for one character.
            let bytes = entry.utf8
            guard let equalsSign = bytes.firstIndex(of: UInt8(ascii: "=")) else { continue }

            let name = String(entry[..<equalsSign])
            if name.isEmpty || namesOfTheCapturingShell.contains(name) { continue }

            let valueStart = bytes.index(after: equalsSign)
            variables[name] = String(entry[valueStart...])
        }
        return variables
    }
}
