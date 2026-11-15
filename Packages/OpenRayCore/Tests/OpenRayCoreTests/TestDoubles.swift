import Foundation

import OpenRayCore

// Stand-ins for the launcher shell, shared by the tests of everything that runs actions or
// drives a screen. They record what they were asked to do and do nothing else.

@MainActor final class FakeActionContext: ActionContext {
    var previousApp: AppRef?
    var query: String
    /// What `confirm` answers.
    var confirmationAnswer = true

    /// What `paste` answers.
    var pasteResult = PasteResult.pasted

    private(set) var closeLauncherCount = 0
    private(set) var hudMessages: [String] = []
    private(set) var confirmations: [Confirmation] = []
    private(set) var copied: [PasteContent] = []
    private(set) var pasted: [PasteContent] = []

    init(query: String = "") {
        self.query = query
    }

    func closeLauncher() {
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
        copied.append(content)
    }

    func paste(_ content: PasteContent) async -> PasteResult {
        pasted.append(content)
        return pasteResult
    }
}

@MainActor final class FakeScreenContext: ScreenContext {
    let request: ScreenRequest
    var searchText = ""
    var isOnScreen = true
    let fakeActionContext = FakeActionContext()

    private(set) var screenActions: [ActionDescriptor] = []

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

    func setSearchText(_ text: String) {
        searchText = text
    }

    // The screens under test are custom screens: they set actions, and neither rows nor the
    // search bar.
    func setSearchBarMode(_ mode: SearchBarMode) {}

    func setSections(_ sections: [ResultSection], answering query: String) {}

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
