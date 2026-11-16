import AppKit
import OpenRayCore
import SwiftUI

/// The window a new user sees first: what OpenRay is, its hotkey, whether it opens at login,
/// whether it looks for updates, and how it deals with permissions (docs/DESIGN.md §4.3.7). It
/// comes to the front the way Settings does.
final class OnboardingWindowController: ActivatingWindowController {
    private let model: OnboardingModel

    init(
        model: OnboardingModel, hotKey: LauncherHotKey, loginItem: LoginItemModel,
        updates: UpdatesModel, focusRestorer: FocusRestorer
    ) {
        self.model = model
        let window = NSWindow(
            contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = String(localized: "Welcome to \(AppInfo.name)")
        super.init(window: window, focusRestorer: focusRestorer)

        let content = OnboardingView(
            model: model, hotKey: hotKey, loginItem: loginItem, updates: updates
        ) { [unowned self] in
            close()
        }
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(NSSize(width: 520, height: 380))
        window.center()
    }

    override func windowWillClose(_ notification: Notification) {
        // Closing the window before the last step ends onboarding too.
        model.dismiss()
        super.windowWillClose(notification)
    }
}

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    let hotKey: LauncherHotKey
    let loginItem: LoginItemModel
    let updates: UpdatesModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.currentStep {
                case .welcome: welcomeStep
                case .hotKey: hotKeyStep
                case .launchAtLogin: launchAtLoginStep
                case .updates: updatesStep
                case .permissions: permissionsStep
                case nil: EmptyView()
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            buttons.padding(16)
        }
        .onChange(of: hotKey.hotKey) { _, _ in
            // Another chord has to be tried in its turn.
            model.hotKeyChanged()
        }
        .onChange(of: model.isFinished) { _, isFinished in
            if isFinished {
                close()
            }
        }
    }

    // MARK: Steps

    private var welcomeStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Welcome to \(AppInfo.name)")
                .font(.title2.weight(.semibold))
            Text(
                "Press a hotkey, type, and act: open apps, run system commands and follow your quicklinks without leaving the keyboard."
            )
            .multilineTextAlignment(.center)
            Text(
                "OpenRay sends no telemetry. Nothing you type leaves this Mac unless a command you run sends it somewhere, such as a web search or a question to Quick AI."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
    }

    private var hotKeyStep: some View {
        VStack(spacing: 14) {
            Text("Choose your hotkey")
                .font(.title2.weight(.semibold))
            Text("The hotkey opens the launcher from anywhere. Click it to record another one.")
                .multilineTextAlignment(.center)
            HotKeyRecorder(launcherHotKey: hotKey).fixedSize()

            if let failure = hotKey.failure {
                let chord = HotKeyFormatter.string(for: failure.hotKey)
                Text("\(chord) could not be registered. Another app may be using it.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if hotKey.usesFallback {
                // The recorder shows the stand-in, and nobody would guess why.
                let fallback = HotKeyFormatter.string(for: LauncherHotKey.fallback)
                Text("\(fallback) opens the launcher for now, until OpenRay quits.")
                    .font(.callout)
            }

            Button("Use ⌘Space") {
                hotKey.record(Self.commandSpace)
            }
            Text(
                "⌘Space belongs to Spotlight. Turn it off first in System Settings › Keyboard › Keyboard Shortcuts › Spotlight."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Divider().padding(.vertical, 2)

            let chord = HotKeyFormatter.string(for: hotKey.hotKey)
            if model.hotKeyWasPressed {
                Label("\(chord) works.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Now press \(chord) to try it.")
                    .fontWeight(.medium)
            }
        }
    }

    private var launchAtLoginStep: some View {
        VStack(spacing: 14) {
            Text("Open at login")
                .font(.title2.weight(.semibold))
            Text("OpenRay is only useful while it is running.")
                .multilineTextAlignment(.center)
            Toggle("Launch \(AppInfo.name) at login", isOn: $model.wantsLaunchAtLogin)
                .toggleStyle(.checkbox)
                .disabled(!loginItem.canChange)
            if !loginItem.canChange {
                Text("Not available in a development build.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("You can change this at any time in Settings › General.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var updatesStep: some View {
        VStack(spacing: 14) {
            Text("Stay up to date")
                .font(.title2.weight(.semibold))
            Text("OpenRay can look for new versions on its own and tell you when there is one.")
                .multilineTextAlignment(.center)
            Toggle("Check for updates automatically", isOn: $model.wantsAutomaticUpdateChecks)
                .toggleStyle(.checkbox)
                .disabled(!updates.isAvailable)
            if let unavailableNote = updates.unavailableNote {
                Text(unavailableNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Text(updates.whatACheckSends)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("You can change this at any time in Settings › Updates.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionsStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Permissions, when they are needed")
                .font(.title2.weight(.semibold))
            Text(
                "OpenRay works without any permission. It asks for one the first time you use a command that needs it, and never before."
            )
            .multilineTextAlignment(.center)
            Text(
                "To paste straight into the app you came from, OpenRay needs the Accessibility permission. Without it, it copies and you press ⌘V. You can grant it at any time in Settings › General."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Text(
                "The window commands, such as Left Half, and Lock Screen need the same permission. OpenRay shows you where to grant it the first time you use one of them."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
    }

    private static let commandSpace = HotKey(
        keyCode: UInt32(VirtualKey.space), modifiers: [.command])

    // MARK: Buttons

    private var buttons: some View {
        HStack {
            if model.stepIndex > 0 {
                Button("Back") {
                    model.goBack()
                }
            }
            Spacer()
            if model.currentStep == .hotKey && !model.canContinue {
                // The hotkey may be one that cannot be pressed right now. It can be changed in
                // Settings later.
                Button("Skip") {
                    model.advance()
                }
            }
            Button(model.isOnLastStep ? "Done" : "Continue") {
                model.advance()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canContinue)
        }
    }
}
