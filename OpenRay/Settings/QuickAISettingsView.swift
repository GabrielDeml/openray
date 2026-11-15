import OpenRayCore
import SwiftUI

extension SettingsPane {
    static let quickAIID = "quick-ai"
}

/// Where the pane's links lead. Not yet checked against the live pages (docs/DESIGN.md §8,
/// item 14).
private enum QuickAILinks {
    /// The terms Anthropic handles API data under, which the privacy statement names.
    static let commercialTerms = URL(string: "https://www.anthropic.com/legal/commercial-terms")!
    /// The Anthropic Console, where an account's keys, usage and spend are.
    static let console = URL(string: "https://platform.claude.com/")!
}

/// Settings › Quick AI: the API key, the model, and what Quick AI sends to Anthropic
/// (docs/DESIGN.md §4.6.7). What it shows and does is `QuickAISettingsModel`'s.
struct QuickAISettingsView: View {
    @Bindable var settings: QuickAISettingsModel

    var body: some View {
        Form {
            keySection
            modelSection
            privacySection
        }
        .formStyle(.grouped)
        .onAppear {
            Task { await settings.load() }
        }
        .onDisappear {
            settings.discardDraft()
        }
    }

    // MARK: API key

    private var keySection: some View {
        Section {
            // ⌘V works here through the Edit menu of the hidden main menu (§4.1.1).
            SecureField("Anthropic API key", text: $settings.draft)
                .onSubmit(saveAndVerify)
            HStack {
                Button("Save & Verify", action: saveAndVerify)
                    .disabled(!settings.canSave)
                Button("Remove Key") {
                    Task { await settings.removeKey() }
                }
                .disabled(!settings.canRemoveKey)
                Spacer()
                if settings.verification == .verifying {
                    ProgressView().controlSize(.small)
                }
            }
        } header: {
            Text("API Key")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if settings.draftIsAdminKey {
                    Label {
                        Text(
                            "This looks like an Admin API key. Those manage an organization and cannot ask a model anything. Quick AI needs an ordinary API key."
                        )
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                }
                if let verificationLine = settings.verificationLine {
                    Text(verificationLine).foregroundStyle(verificationColor)
                }
                if let storedKeyLine = settings.storedKeyLine {
                    HStack {
                        Text(storedKeyLine)
                        if settings.storedKey == .unreadable {
                            Button("Try Again") {
                                Task { await settings.load() }
                            }
                        }
                    }
                }
                Text(
                    "The key is kept in the Keychain of this Mac and nowhere else. Quick AI shows how many tokens an answer used, not what it cost."
                )
                Link(
                    "See your usage and spend in the Anthropic Console",
                    destination: QuickAILinks.console)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var verificationColor: Color {
        switch settings.verification {
        case .idle, .verifying: return .secondary
        case .verified: return .green
        case .rejected, .failed: return .red
        }
    }

    private func saveAndVerify() {
        Task { await settings.saveAndVerify() }
    }

    // MARK: Model

    private var modelSection: some View {
        Section {
            Picker("Model", selection: $settings.chosenModel) {
                ForEach(settings.modelOptions) { option in
                    Text("\(option.name) · \(option.detail)")
                        .tag(option.id)
                        .disabled(!option.isAvailable)
                }
            }
            .pickerStyle(.radioGroup)

            DisclosureGroup("Advanced") {
                Picker("Effort", selection: $settings.effort) {
                    Text("Low").tag(AIEffort.low)
                    Text("Medium").tag(AIEffort.medium)
                    Text("High").tag(AIEffort.high)
                }
            }
        } header: {
            Text("Model")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let modelNotice = settings.modelNotice {
                    // In the primary colour: this is news, unlike the hint below it.
                    Text(modelNotice).foregroundStyle(.primary)
                }
                Text(
                    "A change of model or effort applies from the next chat. With more effort an answer is more thorough, takes longer and uses more tokens."
                )
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                // The statement of docs/DESIGN.md §4.6.7, word for word. Change both together.
                Text(
                    "Quick AI sends data to Anthropic (api.anthropic.com, HTTPS) only when you press Tab or Return to ask, ask a follow-up, regenerate, or verify a key. It sends your question, earlier messages in the current thread, a short instruction text including today's date, the model name and your API key. It never sends keystrokes before you ask, your clipboard, selection, files or screen contents. Threads stay in memory and are discarded on quit. Anthropic handles API data under its commercial terms."
                )
                Link("Anthropic's commercial terms", destination: QuickAILinks.commercialTerms)
            }
            .font(.callout)
        } header: {
            Text("Privacy")
        }
    }
}
