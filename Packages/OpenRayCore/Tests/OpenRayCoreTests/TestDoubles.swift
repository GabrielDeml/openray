import Foundation

import OpenRayCore

// Stand-ins for the launcher shell, shared by the tests of everything that runs actions or
// drives a screen. They record what they were asked to do and do nothing else.

@MainActor final class FakeActionContext: ActionContext {
    /// What an action did that touches the launcher or the clipboard, for a test of the order
    /// it did it in.
    enum Call: Equatable {
        case closeLauncher
        case readClipboard
        case copy
        case paste
    }

    var previousApp: AppRef?
    var query: String
    /// What `confirm` answers.
    var confirmationAnswer = true

    /// What `paste` answers.
    var pasteResult = PasteResult.pasted
    /// What `clipboardText` answers: the text on a clipboard that exists only here.
    var clipboard: String?

    private(set) var calls: [Call] = []
    private(set) var closeLauncherCount = 0
    private(set) var hudMessages: [String] = []
    private(set) var confirmations: [Confirmation] = []
    private(set) var copied: [PasteContent] = []
    private(set) var pasted: [PasteContent] = []
    private(set) var clipboardReadCount = 0

    init(query: String = "") {
        self.query = query
    }

    func closeLauncher() {
        calls.append(.closeLauncher)
        closeLauncherCount += 1
    }

    func showHUD(_ text: String) {
        hudMessages.append(text)
    }

    func confirm(_ confirmation: Confirmation) async -> Bool {
        confirmations.append(confirmation)
        return confirmationAnswer
    }

    func copy(_ content: PasteContent) {
        calls.append(.copy)
        copied.append(content)
    }

    func paste(_ content: PasteContent) async -> PasteResult {
        calls.append(.paste)
        pasted.append(content)
        return pasteResult
    }

    func clipboardText() async -> String? {
        calls.append(.readClipboard)
        clipboardReadCount += 1
        return clipboard
    }
}

@MainActor final class FakeScreenContext: ScreenContext {
    /// One call of `setSections`.
    struct Answer {
        var query: String
        var sections: [ResultSection]
        var emptyMessage: String?

        /// The items of every section, in the order the list shows them.
        var itemIDs: [ItemID] {
            var ids: [ItemID] = []
            for section in sections {
                for row in section.rows {
                    ids.append(row.item.id)
                }
            }
            return ids
        }
    }

    let request: ScreenRequest
    var searchText = ""
    var isOnScreen = true
    /// Whether the screen may change the search field. The shell takes a text only from the
    /// screen on top, so a screen that is still being built, or lies under another, is ignored.
    var takesSearchText = true
    let fakeActionContext = FakeActionContext()
    /// The screen's model, kept until the screen is popped, as `ScreenSpec` keeps it in the
    /// app. A model's own tasks hold it weakly, so without this a test that only watches the
    /// answers would have to keep the model alive itself.
    var model: AnyObject?

    private(set) var screenActions: [ActionDescriptor] = []
    /// Every answer of a list screen, in the order it gave them.
    private(set) var answers: [Answer] = []

    private var searchTextContinuations: [AsyncStream<String>.Continuation] = []

    init(request: ScreenRequest) {
        self.request = request
    }

    var actionContext: any ActionContext { fakeActionContext }

    func searchTextChanges() -> AsyncStream<String> {
        let (changes, continuation) = AsyncStream.makeStream(of: String.self)
        searchTextContinuations.append(continuation)
        return changes
    }

    /// What the shell does when the user types on the screen.
    func type(_ text: String) {
        searchText = text
        for continuation in searchTextContinuations {
            continuation.yield(text)
        }
    }

    /// Types the text and waits for an answer to it that came after the typing. A list
    /// screen answers from a task of its own, a moment later.
    func typeAndWaitForAnswer(_ text: String) async {
        let answersBefore = answers.count
        type(text)
        while answers.count == answersBefore || answers.last?.query != text {
            await Task.yield()
        }
    }

    /// The screen was popped: the streams of the search text end, and the model is let go.
    func close() {
        for continuation in searchTextContinuations {
            continuation.finish()
        }
        searchTextContinuations = []
        model = nil
    }

    func setSearchText(_ text: String) {
        if !takesSearchText { return }
        // The text a screen sets comes back to it like typed text.
        type(text)
    }

    // No screen under test changes the search bar.
    func setSearchBarMode(_ mode: SearchBarMode) {}

    func setSections(_ sections: [ResultSection], answering query: String, emptyMessage: String?) {
        answers.append(Answer(query: query, sections: sections, emptyMessage: emptyMessage))
    }

    func setScreenActions(_ actions: [ActionDescriptor]) {
        screenActions = actions
    }
}

@MainActor final class FakePermissionChecker: PermissionChecking {
    /// What `state` answers for each permission; `.unknown` for one that is not listed.
    var states: [Permission: PermissionState] = [:]
    /// What a request changes the state to.
    var stateAfterRequest = PermissionState.granted
    /// Runs each time a state is read, for a test that needs something to happen meanwhile.
    var whileReadingState: (() -> Void)?

    private(set) var requested: [Permission] = []
    private(set) var openedSettingsFor: [Permission] = []

    func state(_ permission: Permission) async -> PermissionState {
        whileReadingState?()
        return states[permission] ?? .unknown
    }

    func request(_ permission: Permission) async -> PermissionState {
        requested.append(permission)
        states[permission] = stateAfterRequest
        return stateAfterRequest
    }

    func openSystemSettings(for permission: Permission) {
        openedSettingsFor.append(permission)
    }
}

/// An updater that lives in the test: it keeps the two settings in memory, counts the checks
/// it is asked for and never looks for an update.
@MainActor final class FakeUpdater: UpdateControlling {
    var automaticallyChecksForUpdates = false {
        didSet { automaticChecksWrites.append(automaticallyChecksForUpdates) }
    }
    var canCheckForUpdates = true
    var lastUpdateCheckDate: Date?

    /// Every value automatic checks were set to, in order. Empty means the setting still has
    /// no value, which is when Sparkle would ask the user with its own prompt.
    private(set) var automaticChecksWrites: [Bool] = []
    private(set) var checkCount = 0

    private var wantsAutomaticDownloads = false

    /// As Sparkle has it: updates are installed on their own only while they are also looked
    /// for on their own, and the choice cannot be changed while they are not.
    var automaticallyDownloadsUpdates: Bool {
        get { automaticallyChecksForUpdates && wantsAutomaticDownloads }
        set {
            if automaticallyChecksForUpdates {
                wantsAutomaticDownloads = newValue
            }
        }
    }

    func checkForUpdates() {
        checkCount += 1
    }
}
