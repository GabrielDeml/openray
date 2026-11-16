import Foundation

/// Reads the `@openray.<key> <value>` lines at the top of a script (docs/DESIGN.md §4.10).
///
/// A line counts when it is a comment that holds nothing else: optional whitespace, one of
/// `#`, `//`, `--` or `;`, optional whitespace, then `@openray.`. The key runs to the first
/// whitespace and the value is the rest of the line. So `#!/bin/zsh` is no such line, and
/// neither is code with a comment behind it.
///
/// The text comes from files anybody may have written, so nothing in here may trap.
public enum ScriptMetadataParser {
    /// The only version there is. A script written for a later one may use the keys in
    /// another way, so it is refused and not half understood.
    static let schemaVersion = "1"
    static let maximumArguments = 3
    /// A day. A larger number is more likely a slip than a wish.
    static let longestTimeoutInSeconds = 86_400

    /// - Parameter head: The beginning of the file. The scanner hands over what it read of
    ///   the first 8 KiB, without a last line that was cut off.
    public static func parse(_ head: String) -> Result<ScriptMetadata, ScriptParseError> {
        do {
            return .success(try readMetadata(in: head))
        } catch {
            return .failure(error)
        }
    }

    private static func readMetadata(in head: String) throws(ScriptParseError) -> ScriptMetadata {
        let values = try valuesByKey(in: head)

        guard let version = values["schemaVersion"] else {
            throw .missingKey("schemaVersion")
        }
        if version != schemaVersion {
            throw .unsupportedSchemaVersion(version)
        }

        guard let title = values["title"], !title.isEmpty else {
            throw .missingKey("title")
        }
        guard let modeName = values["mode"] else {
            throw .missingKey("mode")
        }
        guard let mode = ScriptMode(rawValue: modeName) else {
            throw .invalidValue(key: "mode")
        }

        var metadata = ScriptMetadata(title: title, mode: mode)
        if let text = values["icon"], !text.isEmpty {
            metadata.icon = icon(from: text)
        }
        if let text = values["description"], !text.isEmpty {
            metadata.description = text
        }
        if let text = values["keywords"] {
            for keyword in text.split(whereSeparator: \.isWhitespace) {
                metadata.keywords.append(String(keyword))
            }
        }
        metadata.arguments = try readArguments(in: values)
        if let text = values["timeout"] {
            metadata.timeout = try timeout(from: text)
        }
        if let text = values["needsConfirmation"] {
            switch text {
            case "true": metadata.needsConfirmation = true
            case "false": metadata.needsConfirmation = false
            default: throw .invalidValue(key: "needsConfirmation")
            }
        }
        return metadata
    }

    // MARK: Lines

    private static let commentPrefixes = ["#", "//", "--", ";"]
    private static let marker = "@openray."
    private static let knownKeys: Set<String> = [
        "schemaVersion", "title", "mode", "icon", "description", "keywords", "argument1",
        "argument2", "argument3", "timeout", "needsConfirmation",
    ]

    /// The value of every known key in the text.
    ///
    /// A key this version does not know is skipped, also when it is there twice: a later
    /// version may add keys without making its scripts unreadable here.
    private static func valuesByKey(
        in head: String
    ) throws(ScriptParseError) -> [String: String] {
        // Some editors, on Windows above all, begin a UTF-8 file with a byte order mark. It
        // is no whitespace to Swift, and would hide a metadata line that is the file's first.
        var text = Substring(head)
        if text.hasPrefix("\u{FEFF}") {
            text = text.dropFirst()
        }

        // Unix, Windows and old Mac line endings. Swift reads a CR LF as one character.
        let lines = text.split { character in
            character == "\n" || character == "\r\n" || character == "\r"
        }

        var values: [String: String] = [:]
        var hasMetadataLine = false
        for line in lines {
            guard let (key, value) = keyAndValue(in: line) else { continue }
            hasMetadataLine = true

            if !knownKeys.contains(key) { continue }
            if values[key] != nil {
                throw .duplicateKey(key)
            }
            values[key] = value
        }

        if !hasMetadataLine {
            throw .noMetadata
        }
        return values
    }

    /// The key and the value of a metadata line, and nil for every other line.
    private static func keyAndValue(in line: Substring) -> (key: String, value: String)? {
        var rest = line.drop(while: \.isWhitespace)

        guard let commentPrefix = commentPrefixes.first(where: { rest.hasPrefix($0) }) else {
            return nil
        }
        rest = rest.dropFirst(commentPrefix.count).drop(while: \.isWhitespace)

        guard rest.hasPrefix(marker) else { return nil }
        rest = rest.dropFirst(marker.count)

        let keyEnd = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
        let key = String(rest[..<keyEnd])
        let value = rest[keyEnd...].trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    // MARK: Values

    /// `sf:` and a symbol name, a path to an image, or an emoji. A path is told from an emoji
    /// by its slash or the dot of its extension.
    static func icon(from text: String) -> ScriptIcon {
        let symbolPrefix = "sf:"
        if text.hasPrefix(symbolPrefix) {
            return .symbol(String(text.dropFirst(symbolPrefix.count)))
        }
        if text.contains("/") || text.contains(".") {
            return .image(relativePath: text)
        }
        return .emoji(text)
    }

    /// The JSON of an `argument<number>` line. Other fields are allowed and not read.
    private struct ArgumentDescription: Decodable {
        var placeholder: String?
        var optional: Bool?
        var type: String?
    }

    private static func readArguments(
        in values: [String: String]
    ) throws(ScriptParseError) -> [ScriptArgument] {
        var arguments: [ScriptArgument] = []
        for number in 1...maximumArguments {
            let key = "argument\(number)"
            guard let json = values[key] else { continue }

            // The script is handed its arguments by position, so there is no second
            // argument without a first.
            let isNext = arguments.count == number - 1
            if !isNext {
                throw .argumentGap(number)
            }

            let description: ArgumentDescription
            do {
                description = try JSONDecoder().decode(
                    ArgumentDescription.self, from: Data(json.utf8))
            } catch {
                throw .malformedArgument(number)
            }
            // Text is the only kind so far. A script that asks for a dropdown or a password
            // must not get a plain text field in its place.
            if let type = description.type, type != "text" {
                throw .invalidValue(key: key)
            }

            arguments.append(
                ScriptArgument(
                    placeholder: description.placeholder ?? "",
                    isOptional: description.optional ?? false))
        }
        return arguments
    }

    private static func timeout(from text: String) throws(ScriptParseError) -> Duration {
        guard let seconds = Int(text), (1...longestTimeoutInSeconds).contains(seconds) else {
            throw .invalidValue(key: "timeout")
        }
        return .seconds(seconds)
    }
}
