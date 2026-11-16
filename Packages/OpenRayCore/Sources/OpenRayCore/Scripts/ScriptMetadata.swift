import Foundation

/// What OpenRay does with what a script prints (docs/DESIGN.md §4.10).
public enum ScriptMode: String, Sendable {
    /// The launcher closes, and the last line the script printed is shown in the HUD.
    case silent
    /// The output is shown on a screen of its own while the script runs.
    case fullOutput
}

/// One of the up to three texts a script asks for before it runs.
public struct ScriptArgument: Sendable, Equatable {
    /// What the empty field shows. Empty when the script names none.
    public var placeholder: String
    /// Whether the script also runs when nothing was typed for this argument.
    public var isOptional: Bool

    public init(placeholder: String, isOptional: Bool) {
        self.placeholder = placeholder
        self.isOptional = isOptional
    }
}

/// The icon a script names for itself.
public enum ScriptIcon: Sendable, Equatable {
    case emoji(String)
    /// An SF Symbol name, written `sf:wifi` in the script.
    case symbol(String)
    /// An image file, as a path from the folder the script is in.
    case image(relativePath: String)
}

/// What the `@openray.` lines at the top of a script say about it.
public struct ScriptMetadata: Sendable, Equatable {
    public var title: String
    public var mode: ScriptMode
    public var icon: ScriptIcon?
    public var description: String?
    /// Other words the script is found by.
    public var keywords: [String]
    /// At most three, in the order they are asked for and handed to the script.
    public var arguments: [ScriptArgument]
    /// How long the script may run. nil leaves it to the mode's default.
    public var timeout: Duration?
    /// Whether the user is asked before every run.
    public var needsConfirmation: Bool

    public init(
        title: String, mode: ScriptMode, icon: ScriptIcon? = nil, description: String? = nil,
        keywords: [String] = [], arguments: [ScriptArgument] = [], timeout: Duration? = nil,
        needsConfirmation: Bool = false
    ) {
        self.title = title
        self.mode = mode
        self.icon = icon
        self.description = description
        self.keywords = keywords
        self.arguments = arguments
        self.timeout = timeout
        self.needsConfirmation = needsConfirmation
    }
}

/// Why the `@openray.` lines of a file do not describe a script. Keys are named without the
/// `@openray.` in front.
public enum ScriptParseError: Error, Equatable, Sendable {
    /// The text has no `@openray.` line at all, so the file is not meant to be a script.
    case noMetadata
    /// A key that every script needs is not there, or has no value.
    case missingKey(String)
    case unsupportedSchemaVersion(String)
    case invalidValue(key: String)
    /// `argument<number>` is not a JSON object with a text `placeholder` and a true or false
    /// `optional`.
    case malformedArgument(Int)
    /// `argument<number>` is there and the one before it is not.
    case argumentGap(Int)
    case duplicateKey(String)

    /// The sentence the Script Diagnostics list shows under the file's name.
    public var message: String {
        switch self {
        case .noMetadata:
            // Not shown anywhere today: the scan passes such a file over without a
            // diagnostic. The sentence is here so that the error has one if that changes.
            return String(
                localized: "The file has no @openray lines.", bundle: .module,
                comment:
                    "Not shown at present. Why a file in a script folder is not a script command. @openray is typed as it stands."
            )
        case .missingKey(let key):
            return String(
                localized: "@openray.\(key) is missing.", bundle: .module,
                comment:
                    "Script Diagnostics: a line every script needs is not in the file. The placeholder is the line's key, such as “title”; with @openray. in front it is what the user has to type."
            )
        case .unsupportedSchemaVersion(let version):
            return String(
                localized:
                    "@openray.schemaVersion is “\(version)”. This version of OpenRay reads version 1 only.",
                bundle: .module,
                comment:
                    "Script Diagnostics: the script is written for a format this OpenRay does not know. The placeholder is what the script gives as its version."
            )
        case .invalidValue(let key):
            return String(
                localized: "@openray.\(key) has a value that OpenRay cannot use.",
                bundle: .module,
                comment:
                    "Script Diagnostics: the value of a line in the script is not one of those allowed. The placeholder is the line's key, such as “mode” or “timeout”."
            )
        case .malformedArgument(let number):
            return String(
                localized: "@openray.argument\(number) is not valid JSON for an argument.",
                bundle: .module,
                comment:
                    "Script Diagnostics: the description of one of a script's arguments cannot be read. The placeholder is the argument's number, 1 to 3, and is part of the key."
            )
        case .argumentGap(let number):
            return String(
                localized:
                    "@openray.argument\(number) is there, but @openray.argument\(number - 1) is not.",
                bundle: .module,
                comment:
                    "Script Diagnostics: a script describes its second or third argument and not the one before it. The placeholders are the two arguments' numbers and are part of the keys."
            )
        case .duplicateKey(let key):
            return String(
                localized: "@openray.\(key) is there more than once.", bundle: .module,
                comment:
                    "Script Diagnostics: the same line is in the script twice. The placeholder is the line's key, such as “title”."
            )
        }
    }
}
