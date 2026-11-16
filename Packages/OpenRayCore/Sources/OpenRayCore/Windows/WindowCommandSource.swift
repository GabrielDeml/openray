import Foundation

/// The window commands as items for root search (docs/DESIGN.md §4.7): Left Half, Maximize
/// Window, Move Window to Next Display and the rest, one for every `WindowAction`.
///
/// They act on the focused window of the app the launcher was opened over. The source only
/// describes them and says what to tell the user afterwards; finding the window and moving it
/// is the `WindowHost`'s.
public struct WindowCommandSource: SearchSource {
    public static let feature = FeatureID(rawValue: "window")

    public let id = SourceID(rawValue: "window")
    public let latency = SourceLatency.inline

    private let host: any WindowHost
    private let preferences: any PreferencesStore

    public init(host: any WindowHost, preferences: any PreferencesStore) {
        self.host = host
        self.preferences = preferences
    }

    public func indexedItems() -> AsyncStream<[SearchItem]> {
        var commands: [SearchItem] = []
        for action in WindowAction.allCases {
            commands.append(Self.command(for: action, host: host, preferences: preferences))
        }
        // The commands never change, so they are yielded once.
        return AsyncStream { continuation in
            continuation.yield(commands)
            continuation.finish()
        }
    }

    // MARK: Items

    private static func command(
        for action: WindowAction, host: any WindowHost, preferences: any PreferencesStore
    ) -> SearchItem {
        let title = title(of: action)
        let kindLabel = String(
            localized: "Window", bundle: .module,
            comment:
                "The kind of a search result that is a window command, shown at the end of its row. Also a word every window command is found by."
        )
        let keywords = [
            kindLabel,
            String(
                localized: "Tile", bundle: .module,
                comment: "Another word the window commands are found by."),
            String(
                localized: "Snap", bundle: .module,
                comment: "Another word the window commands are found by."),
        ]
        var alternateNames: [NameVariant] = []
        for keyword in keywords {
            alternateNames.append(.keyword(keyword))
        }

        let move = ActionDescriptor(
            id: ActionID(rawValue: action.rawValue), title: title,
            requiredPermissions: [.accessibility]
        ) { context in
            await perform(action, host: host, preferences: preferences, context: context)
        }
        return SearchItem(
            id: .command(feature, action.rawValue), title: title, alternateNames: alternateNames,
            icon: .symbol(symbol(of: action)), kindLabel: kindLabel, actions: [move])
    }

    private static func title(of action: WindowAction) -> String {
        switch action {
        case .leftHalf:
            return String(
                localized: "Left Half", bundle: .module,
                comment: "The window command that fills the left half of the screen.")
        case .rightHalf:
            return String(
                localized: "Right Half", bundle: .module,
                comment: "The window command that fills the right half of the screen.")
        case .topHalf:
            return String(
                localized: "Top Half", bundle: .module,
                comment: "The window command that fills the top half of the screen.")
        case .bottomHalf:
            return String(
                localized: "Bottom Half", bundle: .module,
                comment: "The window command that fills the bottom half of the screen.")
        case .topLeft:
            return String(
                localized: "Top Left Quarter", bundle: .module,
                comment: "The window command that fills the top left quarter of the screen.")
        case .topRight:
            return String(
                localized: "Top Right Quarter", bundle: .module,
                comment: "The window command that fills the top right quarter of the screen.")
        case .bottomLeft:
            return String(
                localized: "Bottom Left Quarter", bundle: .module,
                comment: "The window command that fills the bottom left quarter of the screen.")
        case .bottomRight:
            return String(
                localized: "Bottom Right Quarter", bundle: .module,
                comment: "The window command that fills the bottom right quarter of the screen.")
        case .firstThird:
            return String(
                localized: "First Third", bundle: .module,
                comment: "The window command that fills the left third of the screen.")
        case .centerThird:
            return String(
                localized: "Center Third", bundle: .module,
                comment: "The window command that fills the middle third of the screen.")
        case .lastThird:
            return String(
                localized: "Last Third", bundle: .module,
                comment: "The window command that fills the right third of the screen.")
        case .firstTwoThirds:
            return String(
                localized: "First Two Thirds", bundle: .module,
                comment: "The window command that fills the left two thirds of the screen.")
        case .lastTwoThirds:
            return String(
                localized: "Last Two Thirds", bundle: .module,
                comment: "The window command that fills the right two thirds of the screen.")
        case .maximize:
            return String(
                localized: "Maximize Window", bundle: .module,
                comment:
                    "The window command that fills the screen, without making the window full screen."
            )
        case .almostMaximize:
            return String(
                localized: "Almost Maximize Window", bundle: .module,
                comment:
                    "The window command that fills most of the screen and leaves a margin all around."
            )
        case .center:
            return String(
                localized: "Center Window", bundle: .module,
                comment:
                    "The window command that moves a window to the middle of the screen at the size it has."
            )
        case .nextDisplay:
            return String(
                localized: "Move Window to Next Display", bundle: .module,
                comment: "The window command that moves a window to the next screen.")
        case .previousDisplay:
            return String(
                localized: "Move Window to Previous Display", bundle: .module,
                comment: "The window command that moves a window to the previous screen.")
        case .restore:
            return String(
                localized: "Restore Window", bundle: .module,
                comment:
                    "The window command that puts a window back where it was before OpenRay moved it."
            )
        }
    }

    /// The SF Symbol of each command. There is none for a centre third or for two thirds, so
    /// those have the nearest one.
    private static func symbol(of action: WindowAction) -> String {
        switch action {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .topLeft: return "rectangle.inset.topleft.filled"
        case .topRight: return "rectangle.inset.topright.filled"
        case .bottomLeft: return "rectangle.inset.bottomleft.filled"
        case .bottomRight: return "rectangle.inset.bottomright.filled"
        case .firstThird: return "rectangle.leftthird.inset.filled"
        case .centerThird: return "rectangle.split.3x1"
        case .lastThird: return "rectangle.rightthird.inset.filled"
        case .firstTwoThirds: return "rectangle.lefthalf.inset.filled"
        case .lastTwoThirds: return "rectangle.righthalf.inset.filled"
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        case .almostMaximize: return "rectangle.inset.filled"
        case .center: return "rectangle.center.inset.filled"
        case .nextDisplay: return "rectangle.righthalf.inset.filled.arrow.right"
        case .previousDisplay: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .restore: return "arrow.uturn.backward"
        }
    }

    // MARK: Running a command

    @MainActor
    private static func perform(
        _ action: WindowAction, host: any WindowHost, preferences: any PreferencesStore,
        context: any ActionContext
    ) async -> ActionOutcome {
        // The launcher was opened over no app at all, so there is no window to mean.
        guard let app = context.previousApp else {
            return .showHUD(noWindowMessage)
        }
        // First, so that the user sees the window move.
        context.closeLauncher()

        let gap = preferences.value(for: .windowGap)
        // The strip is only there while Stage Manager is on.
        var stageStripInset = 0.0
        if host.isStageManagerOn {
            stageStripInset = preferences.value(for: .windowStageStripInset)
        }

        do {
            try await host.perform(
                action, pid: app.pid, displays: host.displays, gap: gap,
                stageStripInset: stageStripInset, isDockOnTheLeft: host.isDockOnTheLeft)
            return .closeLauncher
        } catch {
            if error != .unchanged {
                // The error only, never the window's title or the app's name.
                Log.windows.info(
                    "\(action.rawValue, privacy: .public) moved no window: \(String(describing: error), privacy: .public)"
                )
            }
            return outcome(of: error)
        }
    }

    private static func outcome(of error: WindowError) -> ActionOutcome {
        switch error {
        case .unchanged:
            // A window that is where the command would put it is left alone without a word.
            return .closeLauncher
        case .nothingToRestore:
            let message = String(
                localized: "No earlier position to restore", bundle: .module,
                comment:
                    "Shown when Restore Window is used on a window that OpenRay has not moved.")
            return .showHUD(message)
        case .noOtherDisplay:
            let message = String(
                localized: "No other display", bundle: .module,
                comment:
                    "Shown when a window is to be moved to another display and the Mac has only one."
            )
            return .showHUD(message)
        case .noWindow:
            return .showHUD(noWindowMessage)
        case .appNotResponding:
            let message = String(
                localized: "App not responding", bundle: .module,
                comment:
                    "Shown when the app whose window was to be moved did not answer in time.")
            return .showHUD(message)
        case .fullScreen:
            let message = String(
                localized: "Full-screen windows cannot be moved", bundle: .module,
                comment: "Shown when a window command is used on a full-screen window.")
            return .showHUD(message)
        case .notTrusted:
            // The permission was there when the launcher checked it, or the command would
            // not have run. It was taken away since.
            let message = String(
                localized: "Accessibility is no longer allowed. Grant it in Settings › General.",
                bundle: .module,
                comment:
                    "Shown when a window command fails because OpenRay has lost the Accessibility permission."
            )
            return .showHUD(message)
        }
    }

    private static var noWindowMessage: String {
        String(
            localized: "No window to move", bundle: .module,
            comment: "Shown when a window command finds no window it could move.")
    }
}
