import Observation

extension PreferenceKey where Value == Int {
    /// The version of the onboarding the user has been through; 0 for a new user.
    public static var onboardingCompletedVersion: PreferenceKey {
        PreferenceKey(name: "onboarding.completedVersion", defaultValue: 0)
    }
}

extension Preferences {
    public var onboardingCompletedVersion: Int {
        get { self[.onboardingCompletedVersion] }
        set { self[.onboardingCompletedVersion] = newValue }
    }
}

/// One page of the onboarding window (docs/DESIGN.md §4.3.7).
public enum OnboardingStep: Sendable, Equatable, CaseIterable {
    case welcome
    case hotKey
    case launchAtLogin
    /// Text only: which permissions OpenRay can use and that each is asked for at first use.
    case permissions

    /// The onboarding version that added the step. A milestone that adds a step raises
    /// `OnboardingModel.currentVersion` and gives the new step that number, so that people who
    /// have been through the earlier steps see only the new one.
    var introducedInVersion: Int {
        switch self {
        case .welcome, .hotKey, .launchAtLogin: return 1
        case .permissions: return 2
        }
    }
}

/// Walks a user through the onboarding steps they have not seen.
@MainActor @Observable public final class OnboardingModel {
    public static let currentVersion = 2

    /// The steps this user is shown, in order. Never empty while onboarding is needed.
    public let steps: [OnboardingStep]
    public private(set) var stepIndex = 0
    /// Whether the user pressed the hotkey while the hotkey step asked them to.
    public private(set) var hotKeyWasPressed = false
    /// The checkbox of the launch-at-login step. It starts as macOS has it, and nothing is
    /// registered or removed until Continue on that step.
    public var wantsLaunchAtLogin: Bool
    /// True once the user has been through every step or has closed the window.
    public private(set) var isFinished = false

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let loginItem: LoginItemModel

    public init(preferences: Preferences, loginItem: LoginItemModel) {
        self.preferences = preferences
        self.loginItem = loginItem
        wantsLaunchAtLogin = loginItem.isOn
        steps = Self.steps(after: preferences.onboardingCompletedVersion)
    }

    /// Whether the onboarding window opens at launch.
    public static func isNeeded(completedVersion: Int) -> Bool {
        completedVersion < currentVersion
    }

    /// The steps added since the version the user has completed.
    public static func steps(after completedVersion: Int) -> [OnboardingStep] {
        OnboardingStep.allCases.filter { step in step.introducedInVersion > completedVersion }
    }

    public var currentStep: OnboardingStep? {
        steps.indices.contains(stepIndex) ? steps[stepIndex] : nil
    }

    public var isOnLastStep: Bool {
        stepIndex == steps.count - 1
    }

    /// Whether Continue is available. The hotkey step passes when the hotkey has been seen to
    /// work; it can still be skipped.
    public var canContinue: Bool {
        if currentStep == .hotKey { return hotKeyWasPressed }
        return true
    }

    /// The hotkey fired. It counts only while the hotkey step is the one on screen.
    ///
    /// - Returns: Whether onboarding took the press. The launcher stays shut for a press that
    ///   was only the user trying the hotkey out.
    public func hotKeyPressed() -> Bool {
        guard currentStep == .hotKey, !isFinished else { return false }
        hotKeyWasPressed = true
        return true
    }

    /// The user recorded another hotkey, which has to be tried in its turn.
    public func hotKeyChanged() {
        hotKeyWasPressed = false
    }

    /// Continue, and Skip on the hotkey step: the next step, or the end after the last.
    public func advance() {
        // Continue is what confirms the checkbox. Waiting for the last step with it would
        // lose the choice of someone who closes the window on a later page.
        if currentStep == .launchAtLogin && wantsLaunchAtLogin != loginItem.isOn {
            // A failure is kept by the login item model, and the General pane shows it.
            loginItem.setEnabled(wantsLaunchAtLogin)
        }

        if isOnLastStep {
            markCompleted()
        } else {
            stepIndex += 1
        }
    }

    public func goBack() {
        if stepIndex > 0 {
            stepIndex -= 1
        }
    }

    /// The window was closed before the last step. That is an answer too: the steps are not
    /// shown again, and nothing the user had not confirmed with Continue is applied.
    public func dismiss() {
        markCompleted()
    }

    private func markCompleted() {
        preferences.onboardingCompletedVersion = Self.currentVersion
        isFinished = true
    }
}
