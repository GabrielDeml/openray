import Foundation
import Testing

@testable import OpenRayCore

/// Stands in for the app's way of making a provider around a key that is to be verified. It
/// hands out the same fake every time and remembers the keys it was asked with.
@MainActor private final class VerifierFactory {
    let verifier = FakeAIProvider()
    private(set) var keys: [APIKey] = []

    func makeProvider(for key: APIKey) -> any AIProvider {
        keys.append(key)
        return verifier
    }
}

@Suite struct SecretAccountTests {
    @Test func apiKeyIsFiledUnderTheAppsOwnService() {
        let account = SecretAccount.anthropicAPIKey

        #expect(account.service == AppInfo.bundleIdentifier + ".anthropic")
        #expect(account.account == "api-key")
    }
}

// Nothing here reads a Keychain or sends a request: the secrets are in memory, and "Anthropic"
// is a fake that answers what the test tells it to.
@MainActor @Suite(.timeLimit(.minutes(1))) struct QuickAISettingsModelTests {
    private let secrets = InMemorySecretStore()
    private let preferencesStore = InMemoryPreferencesStore()
    private let preferences: Preferences
    private let chatProvider = FakeAIProvider([.answer("Bern.")])
    private let session: QuickAISession
    private let factory = VerifierFactory()
    private let model: QuickAISettingsModel

    private let allModels = ClaudeProvider.allowedModels

    init() {
        let preferences = Preferences(store: preferencesStore)
        let session = QuickAISession(
            provider: chatProvider, preferences: preferences, now: { Date() })
        let factory = factory
        self.preferences = preferences
        self.session = session
        model = QuickAISettingsModel(
            secrets: secrets, preferences: preferences, session: session
        ) { key in
            factory.makeProvider(for: key)
        }
    }

    private var storedKeyText: String? {
        get async throws {
            try await secrets.read(.anthropicAPIKey)
        }
    }

    /// Types `text` into the field and presses Save & Verify, with Anthropic answering
    /// `answer`.
    private func save(_ text: String, answer: Result<[AIModelID], any Error>) async {
        factory.verifier.answerModels(with: answer)
        model.draft = text
        await model.saveAndVerify()
    }

    /// Leaves the session with one question answered.
    private func askSomething() async {
        session.ask("What is the capital of Switzerland?")
        await waitForEnd(of: session.replyTask)
    }

    // MARK: Whether a key is saved

    @Test func nothingIsKnownAboutTheKeyBeforeThePaneAppears() {
        #expect(model.storedKey == .unknown)
        #expect(model.storedKeyLine == nil)
        #expect(model.verificationLine == nil)
        #expect(!model.canRemoveKey)
    }

    @Test func loadFindsNoKey() async {
        await model.load()

        #expect(model.storedKey == .none)
        #expect(model.storedKeyLine == "No key saved")
        #expect(!model.canRemoveKey)
    }

    @Test func loadFindsAKeyAndKeepsOnlyThatFact() async throws {
        try await secrets.write(testKeyText, for: .anthropicAPIKey)

        await model.load()

        #expect(model.storedKey == .stored)
        #expect(model.storedKeyLine == "A key is saved in your Keychain")
        #expect(model.canRemoveKey)
        #expect(model.draft.isEmpty)
    }

    @Test func keyThatCannotBeReadIsSaidSoAndStaysWhereItIs() async throws {
        try await secrets.write(testKeyText, for: .anthropicAPIKey)
        secrets.refuse([.read])

        await model.load()

        #expect(model.storedKey == .unreadable)
        #expect(model.storedKeyLine == "Couldn't read key")

        // Trying again once the Keychain answers finds the key still there.
        secrets.refuse([])
        await model.load()

        #expect(model.storedKey == .stored)
        #expect(try await storedKeyText == testKeyText)
    }

    // MARK: Save & Verify

    @Test func verifiedKeyIsSavedAndTheFieldEmptied() async throws {
        await model.load()

        await save(testKeyText, answer: .success(allModels))

        #expect(try await storedKeyText == testKeyText)
        #expect(model.storedKey == .stored)
        #expect(model.verification == .verified)
        #expect(model.verificationLine == "Key verified")
        #expect(model.draft.isEmpty)
        #expect(factory.keys.map(\.headerValue) == [testKeyText])
    }

    @Test func savingAKeyStartsANewChat() async {
        await askSomething()
        #expect(session.exchanges.count == 1)

        await save(testKeyText, answer: .success(allModels))

        #expect(session.exchanges.isEmpty)
        #expect(session.phase == .idle)
    }

    @Test func rejectedKeyIsNotSavedAndStaysInTheField() async throws {
        await askSomething()

        await save(testKeyText, answer: .failure(AIError.invalidCredentials))

        #expect(model.verification == .rejected)
        #expect(model.verificationLine == "Key rejected")
        #expect(try await storedKeyText == nil)
        #expect(model.draft == testKeyText)
        // The key that is in use is the same as before, so the thread goes on.
        #expect(session.exchanges.count == 1)
    }

    @Test func keyWithoutPermissionShowsWhatTheAPISaid() async throws {
        let refusal = AIError.permissionDenied("Your API key does not have permission.")

        await save(testKeyText, answer: .failure(refusal))

        #expect(model.verification == .failed("Your API key does not have permission."))
        #expect(model.verificationLine == "Your API key does not have permission.")
        #expect(try await storedKeyText == nil)
    }

    @Test func keyIsNotSavedWhenAnthropicCannotBeReached() async throws {
        await save(testKeyText, answer: .failure(AIError.network(.notConnectedToInternet)))

        #expect(model.verificationLine == "You're offline")
        #expect(try await storedKeyText == nil)
        #expect(model.draft == testKeyText)
    }

    @Test func keyThatCannotBeWrittenIsReportedInTheSystemsWords() async {
        await model.load()
        secrets.refuse([.write])

        await save(testKeyText, answer: .success(allModels))

        #expect(
            model.verification
                == .failed("The user name or passphrase you entered is not correct."))
        #expect(model.storedKey == .none)
        #expect(model.draft == testKeyText)
    }

    @Test func earlierKeyStaysWhenANewOneIsRejected() async throws {
        await save(testKeyText, answer: .success(allModels))
        let otherKey = "sk-ant-api03-another-key-that-does-not-exist"

        await save(otherKey, answer: .failure(AIError.invalidCredentials))

        #expect(try await storedKeyText == testKeyText)
        #expect(model.storedKey == .stored)
    }

    @Test func secondPressDuringAVerificationDoesNothing() async {
        model.draft = testKeyText
        let firstPress = Task { await model.saveAndVerify() }
        await waitUntil { model.verification == .verifying }

        #expect(model.verificationLine == "Verifying…")
        #expect(!model.canSave)
        await model.saveAndVerify()

        factory.verifier.answerModels(with: .success(allModels))
        await firstPress.value

        #expect(factory.verifier.modelsRequestCount == 1)
        #expect(model.verification == .verified)
    }

    @Test func whiteSpaceAroundThePastedKeyIsLeftOut() async throws {
        await save("  \(testKeyText)\n", answer: .success(allModels))

        #expect(factory.keys.map(\.headerValue) == [testKeyText])
        #expect(try await storedKeyText == testKeyText)
    }

    @Test(arguments: ["", "   ", "\n"])
    func emptyFieldVerifiesNothing(draft: String) async throws {
        model.draft = draft

        #expect(!model.canSave)
        await model.saveAndVerify()

        #expect(factory.verifier.modelsRequestCount == 0)
        #expect(model.verification == .idle)
        #expect(try await storedKeyText == nil)
    }

    @Test func cancelledVerificationIsNotAFailure() async throws {
        await save(testKeyText, answer: .failure(CancellationError()))

        #expect(model.verification == .idle)
        #expect(try await storedKeyText == nil)
    }

    @Test func keyTextIsInNothingThePaneShowsAfterASave() async {
        await model.load()

        await save(testKeyText, answer: .success([ClaudeProvider.sonnet]))

        var shown: [String] = [model.draft]
        shown.append(model.storedKeyLine ?? "")
        shown.append(model.verificationLine ?? "")
        shown.append(model.modelNotice ?? "")
        shown.append(String(describing: model.verification))
        shown.append(String(describing: model.storedKey))
        for option in model.modelOptions {
            shown.append(option.name)
            shown.append(option.detail)
        }
        for text in shown {
            #expect(!text.contains(testKeyText))
            #expect(!text.contains("sk-ant"))
        }
    }

    @Test func draftIsForgottenWhenThePaneGoesAway() {
        model.draft = testKeyText

        model.discardDraft()

        #expect(model.draft.isEmpty)
    }

    // MARK: The admin key warning

    @Test func warningFollowsWhatIsTyped() {
        #expect(!model.draftIsAdminKey)

        model.draft = " sk-ant-admin01-not-a-real-key"
        #expect(model.draftIsAdminKey)

        model.draft = testKeyText
        #expect(!model.draftIsAdminKey)
    }

    // MARK: Remove Key

    @Test func removingDeletesTheKeyAndStartsANewChat() async throws {
        await save(testKeyText, answer: .success([ClaudeProvider.haiku]))
        await askSomething()

        await model.removeKey()

        #expect(try await storedKeyText == nil)
        #expect(model.storedKey == .none)
        #expect(model.verification == .idle)
        #expect(session.exchanges.isEmpty)
        // What the removed key could use says nothing about the next one.
        #expect(model.modelOptions.map(\.isAvailable) == [true, true, true])
    }

    @Test func removingWhenNothingIsSavedDoesNothing() async {
        await model.load()
        await askSomething()

        await model.removeKey()

        #expect(model.storedKey == .none)
        #expect(model.verification == .idle)
        #expect(session.exchanges.count == 1)
    }

    @Test func keyThatCannotBeReadCanStillBeRemoved() async throws {
        try await secrets.write(testKeyText, for: .anthropicAPIKey)
        secrets.refuse([.read])
        await model.load()

        #expect(model.canRemoveKey)
        await model.removeKey()

        secrets.refuse([])
        #expect(try await storedKeyText == nil)
        #expect(model.storedKey == .none)
    }

    @Test func keyThatCannotBeDeletedIsReportedAndCountsAsSaved() async throws {
        await save(testKeyText, answer: .success(allModels))
        secrets.refuse([.delete])

        await model.removeKey()

        #expect(
            model.verification
                == .failed("The user name or passphrase you entered is not correct."))
        #expect(model.storedKey == .stored)
    }

    // MARK: Models

    @Test func everyModelCanBeChosenBeforeAKeyWasVerified() async {
        await model.load()

        #expect(model.modelOptions.map(\.id) == ClaudeProvider.allowedModels)
        #expect(
            model.modelOptions.map(\.name)
                == ["Claude Haiku 5.5", "Claude Sonnet 5.5", "Claude Opus 5.5"])
        #expect(
            model.modelOptions.map(\.detail)
                == ["Fastest", "Fast, with better answers", "Slower, with the best answers"])
        #expect(model.modelOptions.map(\.isAvailable) == [true, true, true])
        #expect(model.chosenModel == ClaudeProvider.haiku)
        #expect(model.modelNotice == nil)
        // Showing the list asked Anthropic nothing.
        #expect(factory.verifier.modelsRequestCount == 0)
    }

    @Test func modelsTheKeyLacksAreMarkedAndCannotBeChosen() async {
        await save(testKeyText, answer: .success([ClaudeProvider.haiku, ClaudeProvider.sonnet]))

        let opus = model.modelOptions[2]
        #expect(model.modelOptions.map(\.isAvailable) == [true, true, false])
        #expect(opus.detail == "Not available to this key")

        model.chosenModel = ClaudeProvider.opus
        #expect(model.chosenModel == ClaudeProvider.haiku)

        model.chosenModel = ClaudeProvider.sonnet
        #expect(model.chosenModel == ClaudeProvider.sonnet)
        #expect(model.modelNotice == nil)
    }

    @Test func chosenModelTheKeyLacksIsReplacedByTheFirstItHas() async {
        model.chosenModel = ClaudeProvider.haiku
        #expect(model.modelNotice == nil)

        await save(testKeyText, answer: .success([ClaudeProvider.sonnet, ClaudeProvider.opus]))

        #expect(preferences.aiModel == ClaudeProvider.sonnet)
        #expect(
            model.modelNotice
                == "Claude Haiku 5.5 is not available. Quick AI now uses Claude Sonnet 5.5.")

        // Choosing for oneself ends the remark.
        model.chosenModel = ClaudeProvider.opus
        #expect(model.modelNotice == nil)
    }

    @Test func keyWithoutAnyOfTheModelsLeavesTheChoiceAlone() async {
        model.chosenModel = ClaudeProvider.sonnet

        await save(testKeyText, answer: .success([]))

        #expect(model.verification == .verified)
        #expect(model.modelOptions.map(\.isAvailable) == [false, false, false])
        #expect(preferences.aiModel == ClaudeProvider.sonnet)
        #expect(model.modelNotice == "This key cannot use any of these models.")
    }

    @Test func storedModelThatIsNotOfferedIsReplacedWhenThePaneAppears() async {
        preferences.aiModel = AIModelID(rawValue: "claude-of-another-year")

        await model.load()

        #expect(preferences.aiModel == ClaudeProvider.haiku)
        #expect(
            model.modelNotice
                == "claude-of-another-year is not available. Quick AI now uses Claude Haiku 5.5.")
    }

    @Test func availabilityIsNotSaved() async {
        await save(testKeyText, answer: .success([ClaudeProvider.haiku]))
        let factory = factory

        // The pane as the next run of OpenRay makes it, over the same stores.
        let nextRun = QuickAISettingsModel(
            secrets: secrets, preferences: Preferences(store: preferencesStore), session: session
        ) { key in
            factory.makeProvider(for: key)
        }
        await nextRun.load()

        #expect(nextRun.storedKey == .stored)
        #expect(nextRun.modelOptions.map(\.isAvailable) == [true, true, true])
    }

    @Test func modelAndEffortAreWrittenThroughThePreferences() {
        model.chosenModel = ClaudeProvider.opus
        model.effort = .high

        #expect(model.chosenModel == ClaudeProvider.opus)
        #expect(model.effort == .high)
        let modelAsText = PreferenceKey(name: "ai.model", defaultValue: "")
        let effortAsText = PreferenceKey(name: "ai.effort", defaultValue: "")
        #expect(preferencesStore.value(for: modelAsText) == "claude-opus-5-5")
        #expect(preferencesStore.value(for: effortAsText) == "high")
    }
}
