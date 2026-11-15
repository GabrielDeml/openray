import Foundation
import Observation

/// The Quick AI pane of Settings (docs/DESIGN.md §4.6.7): the API key, the model and the
/// effort.
///
/// Of the key that is saved, the model knows only that there is one. The text of a key is
/// here in one place, `draft`, from when the user types it until it is saved or the pane
/// goes away.
@MainActor @Observable public final class QuickAISettingsModel {
    /// Whether a key is in the Keychain.
    public enum StoredKey: Equatable, Sendable {
        /// The Keychain has not been asked yet.
        case unknown
        case none
        case stored
        /// Reading failed, so there may be a key or not. Nothing is deleted on that account.
        case unreadable
    }

    /// How the last Save & Verify went. A Remove Key that did not work is reported here too.
    public enum Verification: Equatable, Sendable {
        case idle
        case verifying
        /// Anthropic accepted the key, and it was saved.
        case verified
        /// Anthropic did not accept the key.
        case rejected
        /// Something else was in the way, with what to tell the user about it: the API's
        /// message, the network's, or the Keychain's when the key could not be saved or
        /// removed.
        case failed(String)
    }

    /// One of the models Quick AI offers, as the picker lists it.
    public struct ModelOption: Identifiable, Equatable, Sendable {
        public let id: AIModelID
        /// The model's name, such as "Claude Haiku 5.5".
        public let name: String
        /// What sets the model apart from the others, or that the key cannot use it.
        public let detail: String
        /// False once a verification has shown that the key cannot use the model.
        public let isAvailable: Bool
    }

    /// What is typed into the key field.
    public var draft = ""
    public private(set) var storedKey = StoredKey.unknown
    public private(set) var verification = Verification.idle
    /// Says that another model was chosen in place of one the key cannot use. Cleared when
    /// the user chooses a model.
    public private(set) var modelNotice: String?

    /// The models the key was found to have when it was last verified, or nil while no key
    /// was verified since OpenRay started. Not saved anywhere: the next verification is what
    /// knows better.
    private var verifiedModels: [AIModelID]?

    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let session: QuickAISession
    @ObservationIgnored private let makeProvider: @MainActor (APIKey) -> any AIProvider

    /// - Parameters:
    ///   - session: The Quick AI thread, which ends when the key changes.
    ///   - makeProvider: A provider that sends this key and no other. A key is verified
    ///     before it is saved, so the provider that reads the saved key cannot do it.
    public init(
        secrets: any SecretStore, preferences: Preferences, session: QuickAISession,
        makeProvider: @escaping @MainActor (APIKey) -> any AIProvider
    ) {
        self.secrets = secrets
        self.preferences = preferences
        self.session = session
        self.makeProvider = makeProvider
    }

    // MARK: - The key

    /// Whether the draft looks like an Admin API key. Those manage an organisation and cannot
    /// ask a model anything, so the pane warns before one is saved.
    public var draftIsAdminKey: Bool {
        APIKey(trimmedDraft).isAdminKey
    }

    public var canSave: Bool {
        !trimmedDraft.isEmpty && verification != .verifying
    }

    /// A key that could not be read can still be removed: that is one way out of a Keychain
    /// item that has gone bad.
    public var canRemoveKey: Bool {
        let mayHaveKey = storedKey == .stored || storedKey == .unreadable
        return mayHaveKey && verification != .verifying
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Finds out whether a key is saved. The pane calls this when it appears.
    ///
    /// The Keychain can only be asked for the key itself, so the key is read, and nothing of
    /// it is kept but that it is there. On a build whose signature changed since the key was
    /// saved, macOS may ask the user first, which opening this pane accounts for.
    public func load() async {
        do {
            let key = try await secrets.read(.anthropicAPIKey)
            storedKey = key == nil ? .none : .stored
        } catch {
            // The pane says only that reading failed. The store's reason is its status in
            // words and has nothing of the key in it.
            Log.ai.error("The API key could not be read: \(error.localizedDescription)")
            storedKey = .unreadable
        }
        // The stored model may be one that is not offered, after `defaults write` or once a
        // later version offers other models.
        replaceChosenModelIfUnavailable()
    }

    /// Asks Anthropic which models the draft's key can use, and saves the key if the answer
    /// is a list. A key is never saved unverified.
    public func saveAndVerify() async {
        guard canSave else { return }
        let keyText = trimmedDraft

        verification = .verifying
        modelNotice = nil

        let usableModels: [AIModelID]
        do {
            let provider = makeProvider(APIKey(keyText))
            usableModels = try await provider.availableModels()
        } catch {
            // The draft stays as it is, to be corrected.
            verification = Self.verification(failedWith: error)
            return
        }

        do {
            try await secrets.write(keyText, for: .anthropicAPIKey)
        } catch {
            verification = .failed(error.localizedDescription)
            return
        }

        draft = ""
        storedKey = .stored
        verification = .verified
        verifiedModels = usableModels
        replaceChosenModelIfUnavailable()
        // A reply's thinking can only be sent back by the account it came from, so a thread
        // does not go on under another key.
        session.newChat()
    }

    /// Deletes the saved key. The thread ends with it, as it does when another key is saved.
    public func removeKey() async {
        guard canRemoveKey else { return }
        do {
            try await secrets.delete(.anthropicAPIKey)
        } catch {
            verification = .failed(error.localizedDescription)
            return
        }

        storedKey = .none
        verification = .idle
        // What was found out about the key that is gone says nothing about the next one.
        verifiedModels = nil
        modelNotice = nil
        session.newChat()
    }

    /// Forgets what was typed. The pane calls this when it goes away, so that a key that was
    /// not saved does not stay in memory behind a closed window.
    public func discardDraft() {
        draft = ""
    }

    private static func verification(failedWith error: any Error) -> Verification {
        switch error {
        case AIError.invalidCredentials:
            return .rejected
        case let error as AIError:
            return .failed(error.userMessage)
        case is CancellationError:
            return .idle
        default:
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - What the pane says about the key

    /// Whether a key is saved, in words. nil until the Keychain has answered.
    public var storedKeyLine: String? {
        switch storedKey {
        case .unknown:
            return nil
        case .none:
            return String(
                localized: "No key saved", bundle: .module,
                comment: "Quick AI settings: the state of the API key when none is stored.")
        case .stored:
            return String(
                localized: "A key is saved in your Keychain", bundle: .module,
                comment: "Quick AI settings: the state of the API key when one is stored.")
        case .unreadable:
            return AIError.credentialsUnreadable.userMessage
        }
    }

    /// What `verification` has to say, in words. nil when that is nothing.
    public var verificationLine: String? {
        switch verification {
        case .idle:
            return nil
        case .verifying:
            return String(
                localized: "Verifying…", bundle: .module,
                comment: "Quick AI settings: shown while Anthropic is asked about the API key.")
        case .verified:
            return String(
                localized: "Key verified", bundle: .module,
                comment: "Quick AI settings: shown when Anthropic accepted the API key.")
        case .rejected:
            return AIError.invalidCredentials.userMessage
        case .failed(let message):
            return message
        }
    }

    // MARK: - Model and effort

    /// The models Quick AI offers, in the order of `ClaudeProvider.allowedModels`, with the
    /// table of §4.6.2 in a few words each.
    ///
    /// Before a key was verified all of them can be chosen: the pane sends nothing to find
    /// out, because data goes to Anthropic only when the user asks a question or verifies a
    /// key (§4.6.7). A wrong choice shows in the chat.
    public var modelOptions: [ModelOption] {
        let fastest = String(
            localized: "Fastest", bundle: .module,
            comment: "Quick AI settings: what sets Claude Haiku apart from the other models.")
        let better = String(
            localized: "Fast, with better answers", bundle: .module,
            comment: "Quick AI settings: what sets Claude Sonnet apart from the other models.")
        let best = String(
            localized: "Slower, with the best answers", bundle: .module,
            comment: "Quick AI settings: what sets Claude Opus apart from the other models.")

        // The names are product names and are not translated.
        return [
            modelOption(ClaudeProvider.haiku, name: "Claude Haiku 5.5", summary: fastest),
            modelOption(ClaudeProvider.sonnet, name: "Claude Sonnet 5.5", summary: better),
            modelOption(ClaudeProvider.opus, name: "Claude Opus 5.5", summary: best),
        ]
    }

    private func modelOption(_ model: AIModelID, name: String, summary: String) -> ModelOption {
        let isAvailable = verifiedModels?.contains(model) ?? true
        if isAvailable {
            return ModelOption(id: model, name: name, detail: summary, isAvailable: true)
        }
        let unavailable = String(
            localized: "Not available to this key", bundle: .module,
            comment: "Quick AI settings: beside a model that the API key cannot use.")
        return ModelOption(id: model, name: name, detail: unavailable, isAvailable: false)
    }

    /// The model Quick AI asks. A change applies from the next thread (§4.6.4).
    public var chosenModel: AIModelID {
        get { preferences.aiModel }
        set {
            // Whatever the picker lets through, a model the key cannot use is not chosen.
            guard canChoose(newValue) else { return }

            preferences.aiModel = newValue
            modelNotice = nil
        }
    }

    /// How much work the model puts into a reply. A change applies from the next thread.
    public var effort: AIEffort {
        get { preferences.aiEffort }
        set { preferences.aiEffort = newValue }
    }

    /// Whether the model is one of those offered and, as far as is known, one the key has.
    private func canChoose(_ model: AIModelID) -> Bool {
        modelOptions.contains { option in
            option.id == model && option.isAvailable
        }
    }

    /// Chooses the first model that can be chosen when the chosen one cannot, and says so.
    private func replaceChosenModelIfUnavailable() {
        let chosen = preferences.aiModel
        if canChoose(chosen) { return }

        let options = modelOptions
        guard let replacement = options.first(where: \.isAvailable) else {
            modelNotice = String(
                localized: "This key cannot use any of these models.", bundle: .module,
                comment:
                    "Quick AI settings: shown when the API key has none of the models Quick AI offers."
            )
            return
        }
        preferences.aiModel = replacement.id

        // A model that is not offered at all has no name here and goes by its ID.
        let chosenName = options.first { $0.id == chosen }?.name ?? chosen.rawValue
        modelNotice = String(
            localized: "\(chosenName) is not available. Quick AI now uses \(replacement.name).",
            bundle: .module,
            comment:
                "Quick AI settings: shown when the chosen model was replaced. Both placeholders are names of models."
        )
    }
}
