import Foundation

/// The titles of the actions that more than one feature has. Each is written once: the string
/// catalog keeps one comment for a title, and that comment has to fit every item the action
/// is offered for.
enum ActionTitles {
    static var open: String {
        String(
            localized: "Open", bundle: .module,
            comment: "The action that opens the selected app, quicklink or file.")
    }

    static var showInFinder: String {
        String(
            localized: "Show in Finder", bundle: .module,
            comment: "The action that reveals the selected app or file in a Finder window.")
    }

    static var copyPath: String {
        String(
            localized: "Copy Path", bundle: .module,
            comment: "The action that copies the path of the selected app or file.")
    }

    static var stop: String {
        String(
            localized: "Stop", bundle: .module,
            comment:
                "The action that stops what is under way: an answer of Quick AI that is arriving, or a running script."
        )
    }
}
