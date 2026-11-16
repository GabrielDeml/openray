/// Writes what the user typed as a query in Spotlight's own syntax (docs/DESIGN.md §4.8), the
/// one `mdfind` takes.
public enum SpotlightQueryBuilder {
    /// "Search Files" asks Spotlight twice for one text. `MDQuerySetMaxCount` hands back a
    /// subset of the matches that Spotlight chooses itself, so the names that start with the
    /// text are asked for on their own and cannot be crowded out by the looser matches.
    public enum Pass: Sendable {
        /// The file's name starts with the first word; every further word is anywhere in it.
        case namePrefix
        /// Every word is somewhere in the file's name.
        case nameSubstring
    }

    /// Applications are left out of every search: root search finds those.
    private static let applicationType = "com.apple.application-bundle"

    /// Finds the applications, and is only ever asked of `/System/Applications`. A Mac whose
    /// index is on has an answer to it; none means that Spotlight is off.
    public static let canary = "kMDItemContentTypeTree == \"\(applicationType)\""

    /// The words of a search: the text split at whitespace.
    public static func tokens(of text: String) -> [String] {
        var tokens: [String] = []
        for word in text.split(whereSeparator: \.isWhitespace) {
            tokens.append(String(word))
        }
        return tokens
    }

    /// - Returns: nil for a text without a word in it, which has nothing to search for.
    public static func build(_ text: String, pass: Pass) -> String? {
        let tokens = tokens(of: text)
        if tokens.isEmpty { return nil }

        var clauses: [String] = []
        for (index, token) in tokens.enumerated() {
            let escaped = escape(token)
            let isNamePrefix = pass == .namePrefix && index == 0
            let pattern = isNamePrefix ? "\(escaped)*" : "*\(escaped)*"
            // "c" ignores case and "d" ignores diacritics.
            clauses.append("kMDItemFSName == \"\(pattern)\"cd")
        }
        clauses.append("kMDItemContentTypeTree != \"\(applicationType)\"")
        return clauses.joined(separator: " && ")
    }

    /// A quote would end the value and an asterisk is the wildcard, so both are written with
    /// a backslash, and so is the backslash itself. It goes first, or it would escape the
    /// backslashes the other two have just been given.
    private static func escape(_ token: String) -> String {
        var escaped = token.replacing("\\", with: "\\\\")
        escaped = escaped.replacing("\"", with: "\\\"")
        escaped = escaped.replacing("*", with: "\\*")
        return escaped
    }
}
