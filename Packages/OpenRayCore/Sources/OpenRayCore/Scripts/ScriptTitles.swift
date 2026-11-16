import Foundation

/// The words that more than one part of script commands uses. Each is written once, as in
/// `ActionTitles`: the string catalog keeps one comment for a text, and that comment has to
/// fit every place the text is shown.
enum ScriptTitles {
    static var run: String {
        String(
            localized: "Run", bundle: .module,
            comment:
                "The action that runs the selected script. Also the button that confirms running one."
        )
    }

    static var openInEditor: String {
        String(
            localized: "Open in Editor", bundle: .module,
            comment:
                "The action that opens a script's file in the app that edits plain text files.")
    }

    /// The title of the question before a script runs, whether the script asks for it itself
    /// or the file was downloaded.
    static func runQuestion(for script: ScriptCommand) -> String {
        String(
            localized: "Run “\(script.metadata.title)”?", bundle: .module,
            comment:
                "The title of the confirmation before a script runs. The placeholder is the script's title."
        )
    }

    /// What a script that sets `needsConfirmation` asks before every run.
    static func runConfirmation(for script: ScriptCommand) -> Confirmation {
        Confirmation(title: runQuestion(for: script), confirmTitle: run)
    }
}
