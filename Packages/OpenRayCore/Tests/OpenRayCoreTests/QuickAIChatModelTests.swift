import Foundation
import Testing

import OpenRayCore

private typealias Reply = FakeAIProvider.Reply

/// Counts how often the chat asked for the Quick AI settings.
@MainActor private final class SettingsOpener {
    private(set) var openCount = 0

    func open() {
        openCount += 1
    }
}

/// What the chat says about each failure (docs/DESIGN.md §4.6.8).
private let failureMessages: [(AIError, String)] = [
    (.missingCredentials, "Add your Anthropic API key"),
    (.credentialsUnreadable, "Couldn't read key"),
    (.invalidCredentials, "Key rejected"),
    (.modelUnavailable(ClaudeProvider.opus), "Model unavailable to this key"),
    (.network(.notConnectedToInternet), "You're offline"),
    (.network(.timedOut), "The request timed out"),
    (.network(.networkConnectionLost), "Couldn't reach Anthropic"),
    (.rateLimited(retryAfter: .seconds(12)), "Rate limited, try again in 12 s"),
    (.rateLimited(retryAfter: .milliseconds(1500)), "Rate limited, try again in 2 s"),
    (.rateLimited(retryAfter: nil), "Rate limited, try again later"),
    (.overloaded, "Claude is overloaded, try again in a moment"),
    (.malformedStream("a delta for a block that never started"), "The reply could not be read"),
    // The API's own words.
    (.permissionDenied("Your key has no access."), "Your key has no access."),
    (
        .spendLimitReached("You have reached your specified API usage limits."),
        "You have reached your specified API usage limits."
    ),
    (.billing("Your credit balance is too low."), "Your credit balance is too low."),
    (.server(status: 500, message: "Internal server error"), "Internal server error"),
    (.badRequest("max_tokens: must be at least 1"), "max_tokens: must be at least 1"),
]

/// What is said under a reply that ended with text and became part of the thread.
private let noticesOfKeptReplies: [(AIStopReason, String?)] = [
    (.endTurn, nil),
    (.other("pause_turn"), nil),
    (.maxTokens, "Answer cut off"),
]

/// What is said about a reply that ended without text or was not to be kept.
private let noticesOfRepliesNotKept: [(AIStopReason, String)] = [
    (.refusal(category: "cyber"), "Claude declined (cyber)"),
    (.refusal(category: nil), "Claude declined"),
    (.contextWindowExceeded, "Thread too long, start a new one"),
    // The output limit was used up before the first word.
    (.maxTokens, "Answer cut off"),
    (.endTurn, "Answer cut off"),
]

// The model reads the session a moment after each change, so a test waits for the model to
// show what it expects before it looks at anything else. The time limit only stops a test
// that would otherwise wait for ever.
@MainActor @Suite(.timeLimit(.minutes(1))) struct QuickAIChatModelTests {
    private let clock = TestClock(Date(timeIntervalSinceReferenceDate: 800_000_000))
    private let preferences = Preferences(store: InMemoryPreferencesStore())
    private let settings = SettingsOpener()

    private let capital = "What is the capital of Switzerland?"
    private let population = "How many people live there?"
    private let offline = AIError.network(.notConnectedToInternet)

    private func makeSession(_ script: [Reply]) -> (
        session: QuickAISession, provider: FakeAIProvider
    ) {
        let provider = FakeAIProvider(script)
        let clock = clock
        let session = QuickAISession(
            provider: provider, preferences: preferences, now: { clock.now })
        return (session, provider)
    }

    /// The chat as the feature makes it when the screen is pushed, asking `question` if there
    /// is one.
    private func openChat(
        on session: QuickAISession, asking question: String? = nil
    ) -> (model: QuickAIChatModel, context: FakeScreenContext) {
        let context = FakeScreenContext(request: QuickAISource.chatScreenRequest(asking: question))
        let settings = settings
        let model = QuickAIChatModel(session: session, context: context) {
            settings.open()
        }
        return (model, context)
    }

    private func failing(with error: AIError) -> Reply {
        Reply(error: error)
    }

    private func titles(of context: FakeScreenContext) -> [String] {
        context.screenActions.map(\.title)
    }

    /// Runs the screen's action of that title, as Return, a shortcut or ⌘K would.
    private func perform(_ title: String, on context: FakeScreenContext) async throws
        -> ActionOutcome
    {
        let action = try #require(context.screenActions.first { $0.title == title })
        return try await action.perform(context.fakeActionContext)
    }

    // MARK: Opening the chat

    @Test func questionInTheRequestIsAskedOnce() async {
        let (session, provider) = makeSession([.answer("Bern.")])

        let (model, _) = openChat(on: session, asking: capital)
        await waitUntil { model.tokenLine != nil }

        #expect(provider.requests.count == 1)
        #expect(provider.requests.first?.messages == [userMessage(capital)])
        #expect(model.turns.map(\.question) == [capital])
        #expect(model.turns.map(\.answer) == ["Bern."])
    }

    @Test func chatWithoutAQuestionAsksNothing() {
        let (session, provider) = makeSession([])

        let (model, context) = openChat(on: session)

        #expect(provider.requests.isEmpty)
        #expect(model.turns.isEmpty)
        #expect(!model.isThinking)
        #expect(model.notice == nil)
        #expect(model.tokenLine == nil)
        #expect(titles(of: context) == ["Ask"])
    }

    @Test func chatOpensOnTheThreadAsItIs() async {
        let (session, provider) = makeSession([.answer("Bern.")])
        session.ask(capital)
        await waitUntil { !session.isReplying }

        let (model, _) = openChat(on: session)

        #expect(provider.requests.count == 1)
        #expect(model.turns.map(\.question) == [capital])
        #expect(
            model.turns.first?.blocks == [MarkdownBlock(id: 0, kind: .paragraph, text: "Bern.")])
    }

    @Test func chatDoesNotOpenOnAThreadThatHasRestedTooLong() async {
        let (session, _) = makeSession([.answer("Bern.")])
        session.ask(capital)
        await waitUntil { !session.isReplying }

        clock.advance(minutes: 16)
        let (model, context) = openChat(on: session)

        #expect(model.turns.isEmpty)
        #expect(session.exchanges.isEmpty)
        #expect(titles(of: context) == ["Ask"])
    }

    // MARK: What is shown of a reply

    @Test func replyIsShownAsItArrives() async {
        let (session, provider) = makeSession([.open])
        let (model, _) = openChat(on: session, asking: capital)

        // Sent, and nothing has come back.
        #expect(model.isThinking)
        #expect(model.turns.map(\.question) == [capital])
        #expect(model.turns.first?.blocks == [])

        provider.send(.started(model: ClaudeProvider.haiku, requestID: "req_1"))
        provider.send(.textDelta("The capital:\n\n- Be"))
        await waitUntil { !model.isThinking }
        #expect(
            model.turns.first?.blocks == [
                MarkdownBlock(id: 0, kind: .paragraph, text: "The capital:"),
                MarkdownBlock(id: 1, kind: .listItem(number: nil), text: "Be"),
            ])
        #expect(model.notice == nil)
        #expect(model.tokenLine == nil)

        let answer = "The capital:\n\n- Bern"
        provider.send(.textDelta("rn"))
        provider.send(.usage(AIUsage(inputTokens: 812, outputTokens: 240)))
        provider.send(.finished(.endTurn, assistant: assistantMessage(answer)))
        provider.finish()
        await waitUntil { model.tokenLine != nil }

        // The answer is in the thread now, in the same place and with the same blocks.
        #expect(model.turns.map(\.id) == [0])
        #expect(model.turns.first?.answer == answer)
        #expect(model.turns.first?.blocks == MarkdownBlockParser.blocks(of: answer))
        #expect(model.notice == nil)
        #expect(model.tokenLine == "812 in · 240 out")
    }

    @Test func thinkingIsShownUntilTheFirstWord() async {
        let (session, provider) = makeSession([.open])
        let (model, _) = openChat(on: session, asking: capital)

        provider.send(.started(model: ClaudeProvider.haiku, requestID: "req_1"))
        provider.send(.reasoning(active: true))
        await waitUntil { session.phase == .thinking }
        #expect(model.isThinking)

        provider.send(.reasoning(active: false))
        provider.send(.textDelta("Bern"))
        await waitUntil { !model.isThinking }
        #expect(model.turns.first?.answer == "Bern")
    }

    @Test func followUpIsShownBelowTheThread() async {
        let (session, _) = makeSession([.answer("Bern."), .open])
        let (model, _) = openChat(on: session, asking: capital)
        await waitUntil { model.tokenLine != nil }

        session.ask(population)
        await waitUntil { model.turns.count == 2 }

        #expect(model.turns.map(\.id) == [0, 1])
        #expect(model.turns.map(\.question) == [capital, population])
        #expect(model.isThinking)
        // The tokens were those of the first request.
        #expect(model.tokenLine == nil)
    }

    @Test func tokenLineCountsCachedTokensAsSentAndNamesThem() async {
        let usage = AIUsage(
            inputTokens: 12, outputTokens: 240, cacheReadInputTokens: 600,
            cacheCreationInputTokens: 200)
        let reply = Reply(events: [
            .textDelta("Bern."),
            .usage(usage),
            .finished(.endTurn, assistant: assistantMessage("Bern.")),
        ])
        let (session, _) = makeSession([reply])

        let (model, _) = openChat(on: session, asking: capital)
        await waitUntil { model.tokenLine != nil }

        #expect(model.tokenLine == "812 in · 240 out · 600 cached")
    }

    // The counts are the server's to send. Whatever they are, adding them up must not trap.
    @Test func tokenCountsTooLargeToAddUpAreStillShown() async {
        let usage = AIUsage(
            inputTokens: Int.max, outputTokens: 240, cacheReadInputTokens: Int.max,
            cacheCreationInputTokens: Int.max)
        let reply = Reply(events: [
            .textDelta("Bern."),
            .usage(usage),
            .finished(.endTurn, assistant: assistantMessage("Bern.")),
        ])
        let (session, _) = makeSession([reply])

        let (model, _) = openChat(on: session, asking: capital)
        await waitUntil { model.tokenLine != nil }

        let largest = Int.max.formatted()
        #expect(model.tokenLine == "\(largest) in · 240 out · \(largest) cached")
    }

    // MARK: Actions

    @Test func actionsFollowTheSession() async {
        let (session, provider) = makeSession([.open, .open, failing(with: offline)])
        let (model, context) = openChat(on: session)
        #expect(titles(of: context) == ["Ask"])

        // The first reply is arriving: there is no answer to paste or to replace yet.
        session.ask(capital)
        await waitUntil { model.isThinking }
        #expect(titles(of: context) == ["Ask", "New Chat", "Stop"])

        provider.send(.textDelta("Bern."))
        provider.send(.usage(AIUsage(inputTokens: 12, outputTokens: 5)))
        provider.send(.finished(.endTurn, assistant: assistantMessage("Bern.")))
        provider.finish()
        await waitUntil { model.tokenLine != nil }
        #expect(
            titles(of: context) == ["Ask", "Paste Answer", "Copy Answer", "Regenerate", "New Chat"])

        // While the next reply arrives, "the answer" would be the one before it.
        session.ask(population)
        await waitUntil { model.isThinking }
        #expect(titles(of: context) == ["Ask", "New Chat", "Stop"])

        // Stopped before its first word: the last thing in the chat is a question.
        session.stop()
        await waitUntil { model.notice == "Stopped" }
        #expect(titles(of: context) == ["Ask", "Paste Answer", "Copy Answer", "New Chat"])

        session.newChat()
        await waitUntil { model.turns.isEmpty }
        #expect(titles(of: context) == ["Ask"])

        // A failed first question leaves a thread without an answer.
        session.ask(capital)
        await waitUntil { model.notice == "You're offline" }
        #expect(titles(of: context) == ["Ask", "New Chat"])
    }

    @Test func actionsHaveTheShortcutsTheDesignNames() async throws {
        let (session, _) = makeSession([.answer("Bern."), .open])
        let (model, context) = openChat(on: session, asking: capital)
        await waitUntil { model.tokenLine != nil }

        var shortcutsByTitle: [String: KeyChord] = [:]
        for (index, action) in context.screenActions.enumerated() {
            shortcutsByTitle[action.title] = ActionShortcuts.shortcut(
                ofActionAt: index, in: context.screenActions)
        }
        let command = HotKey.Modifiers.command
        #expect(
            shortcutsByTitle == [
                "Paste Answer": KeyChord(keyCode: VirtualKey.returnKey, modifiers: [command]),
                "Copy Answer": KeyChord(
                    keyCode: VirtualKey.ansiC, modifiers: [command, .shift], characters: "c"),
                "Regenerate": KeyChord(
                    keyCode: VirtualKey.ansiR, modifiers: [command], characters: "r"),
                "New Chat": KeyChord(
                    keyCode: VirtualKey.ansiN, modifiers: [command], characters: "n"),
            ])

        // Stop has no shortcut, and being second in the list does not give it ⌘↩ either.
        session.ask(population)
        await waitUntil { model.isThinking }
        let stopIndex = try #require(context.screenActions.firstIndex { $0.title == "Stop" })
        #expect(ActionShortcuts.shortcut(ofActionAt: stopIndex, in: context.screenActions) == nil)
        #expect(ActionShortcuts.shortcuts(of: context.screenActions).count == 1)
    }

    @Test func askSendsTheFieldsTextAndClearsTheField() async throws {
        let (session, provider) = makeSession([.answer("Bern."), .answer("About 146,000.")])
        let (model, context) = openChat(on: session, asking: capital)
        await waitUntil { model.tokenLine != nil }

        context.type("  \(population)\n")
        let outcome = try await perform("Ask", on: context)

        #expect(outcome == .keepOpen)
        #expect(context.searchText == "")
        #expect(provider.requests.count == 2)
        #expect(provider.requests.last?.messages.last == userMessage(population))

        await waitUntil { model.turns.last?.answer == "About 146,000." }
        #expect(model.turns.map(\.question) == [capital, population])
    }

    @Test func askWithABlankFieldSendsNothing() async throws {
        let (session, provider) = makeSession([])
        let (_, context) = openChat(on: session)

        context.type("  \n ")
        let outcome = try await perform("Ask", on: context)

        #expect(outcome == .keepOpen)
        #expect(provider.requests.isEmpty)
        #expect(context.searchText == "  \n ")
    }

    @Test func askWhileAReplyArrivesSendsNothingAndKeepsTheField() async throws {
        let (session, provider) = makeSession([.open])
        let (_, context) = openChat(on: session, asking: capital)

        context.type(population)
        let outcome = try await perform("Ask", on: context)

        #expect(outcome == .keepOpen)
        #expect(provider.requests.count == 1)
        #expect(session.isReplying)
        #expect(context.searchText == population)
    }

    @Test func pasteAnswerPastesTheLastAnswerAndCloses() async throws {
        let (session, _) = makeSession([.answer("Bern."), .answer("About 146,000.")])
        let (model, context) = openChat(on: session, asking: capital)
        await waitUntil { model.tokenLine != nil }
        session.ask(population)
        await waitUntil { model.turns.count == 2 && model.tokenLine != nil }

        let outcome = try await perform("Paste Answer", on: context)

        #expect(outcome == .closeLauncher)
        #expect(
            context.fakeActionContext.pasted == [.text("About 146,000.", cursorOffsetFromEnd: nil)])
        #expect(context.fakeActionContext.copied.isEmpty)
    }

    @Test func copyAnswerCopiesTheLastAnswerAndSaysSo() async throws {
        let (session, _) = makeSession([.answer("Bern.")])
        let (model, context) = openChat(on: session, asking: capital)
        await waitUntil { model.tokenLine != nil }

        let outcome = try await perform("Copy Answer", on: context)

        #expect(outcome == .copiedToClipboard)
        #expect(context.fakeActionContext.copied == [.text("Bern.", cursorOffsetFromEnd: nil)])
        #expect(context.fakeActionContext.pasted.isEmpty)
    }

    @Test func regenerateAsksTheLastQuestionAgain() async throws {
        let (session, provider) = makeSession([.answer("Bern."), .answer("It is Bern.")])
        let (model, context) = openChat(on: session, asking: capital)
        await waitUntil { model.tokenLine != nil }

        let outcome = try await perform("Regenerate", on: context)

        #expect(outcome == .keepOpen)
        await waitUntil { model.turns.first?.answer == "It is Bern." }
        #expect(provider.requests.count == 2)
        #expect(provider.requests.last?.messages == [userMessage(capital)])
        // Another answer in the same place gets its own blocks.
        #expect(model.turns.map(\.id) == [0])
        #expect(
            model.turns.first?.blocks == [
                MarkdownBlock(id: 0, kind: .paragraph, text: "It is Bern.")
            ]
        )
    }

    @Test func newChatEmptiesTheChatAndKeepsTheLauncherOpen() async throws {
        let (session, _) = makeSession([.answer("Bern.")])
        let (model, context) = openChat(on: session, asking: capital)
        await waitUntil { model.tokenLine != nil }

        let outcome = try await perform("New Chat", on: context)

        #expect(outcome == .keepOpen)
        #expect(session.phase == .idle)
        await waitUntil { model.turns.isEmpty }
        #expect(model.tokenLine == nil)
        #expect(titles(of: context) == ["Ask"])
    }

    @Test func stopActionStopsTheReply() async throws {
        let (session, provider) = makeSession([.open])
        let (model, context) = openChat(on: session, asking: capital)
        provider.send(.textDelta("Be"))
        await waitUntil { model.turns.first?.answer == "Be" }

        let outcome = try await perform("Stop", on: context)

        #expect(outcome == .keepOpen)
        #expect(session.phase == .cancelled)
        await waitUntil { model.notice == "Stopped" }
        // What had arrived is the answer now.
        #expect(model.turns.map(\.answer) == ["Be"])
        #expect(context.searchText == "")
    }

    // MARK: Keys

    @Test func escStopsAReplyAndIsTheLaunchersOtherwise() async {
        let (session, provider) = makeSession([.open])
        let (model, _) = openChat(on: session)
        #expect(!model.handleIntent(.escape))

        session.ask(capital)
        provider.send(.textDelta("Be"))
        await waitUntil { model.turns.first?.answer == "Be" }

        #expect(model.handleIntent(.escape))
        #expect(session.phase == .cancelled)
        // The next Esc leaves the screen.
        #expect(!model.handleIntent(.escape))
    }

    @Test func arrowsScrollTheTranscript() {
        let (session, _) = makeSession([])
        let (model, _) = openChat(on: session)
        #expect(model.scrollRequest == nil)

        #expect(model.handleIntent(.moveSelection(1)))
        let down = model.scrollRequest
        #expect(down?.steps == 1)

        // The same key again is another request.
        #expect(model.handleIntent(.moveSelection(1)))
        let downAgain = model.scrollRequest
        #expect(downAgain?.steps == 1)
        #expect(downAgain != down)

        #expect(model.handleIntent(.moveSelection(-1)))
        #expect(model.scrollRequest?.steps == -1)
    }

    @Test func everyOtherKeyIsLeftToTheLauncher() {
        let (session, provider) = makeSession([.open])
        let (model, _) = openChat(on: session, asking: capital)

        // Return included: the launcher runs the first action for it.
        #expect(!model.handleIntent(.performPrimary))
        #expect(!model.handleIntent(.tabComplete))
        #expect(!model.handleIntent(.back))
        #expect(!model.handleIntent(.activateIndex(1)))
        #expect(session.isReplying)
        #expect(provider.requests.count == 1)
    }

    // MARK: A question that got no answer

    @Test func failedQuestionGoesBackIntoTheField() async {
        let (session, _) = makeSession([failing(with: offline)])

        let (model, context) = openChat(on: session, asking: capital)
        await waitUntil { model.notice != nil }

        #expect(model.notice == "You're offline")
        #expect(context.searchText == capital)
        // It stays on screen, with nothing under it.
        #expect(model.turns.map(\.question) == [capital])
        #expect(model.turns.map(\.answer) == [""])
        #expect(!model.isThinking)
    }

    @Test func failedQuestionDoesNotReplaceWhatWasTypedSince() async {
        let (session, provider) = makeSession([.open])
        let (model, context) = openChat(on: session, asking: capital)

        context.type("and Austria?")
        provider.fail(offline)
        await waitUntil { model.notice != nil }

        #expect(context.searchText == "and Austria?")
    }

    @Test func textOfAFailedReplyStaysOnScreenAndTheQuestionGoesBack() async {
        let (session, provider) = makeSession([.open])
        let (model, context) = openChat(on: session, asking: capital)

        provider.send(.textDelta("The capital is"))
        provider.fail(AIError.overloaded)
        await waitUntil { model.notice != nil }

        #expect(model.turns.map(\.answer) == ["The capital is"])
        #expect(model.notice == "Claude is overloaded, try again in a moment")
        #expect(context.searchText == capital)
    }

    @Test func questionStoppedBeforeItsFirstWordGoesBackIntoTheField() async {
        let (session, _) = makeSession([.open])
        let (model, context) = openChat(on: session, asking: capital)

        #expect(model.handleIntent(.escape))
        await waitUntil { model.notice == "Stopped" }

        #expect(context.searchText == capital)
        #expect(model.turns.map(\.answer) == [""])
    }

    @Test func refusedQuestionGoesBackIntoTheField() async {
        let refusal = Reply(events: [
            .textDelta("I can"),
            .finished(.refusal(category: "cyber"), assistant: assistantMessage("I can")),
        ])
        let (session, _) = makeSession([refusal])

        let (model, context) = openChat(on: session, asking: capital)
        await waitUntil { model.notice != nil }

        #expect(model.notice == "Claude declined (cyber)")
        #expect(context.searchText == capital)
        // What a refused reply had written is not shown.
        #expect(model.turns.map(\.answer) == [""])
    }

    @Test func askingAgainReplacesTheFailedAttempt() async throws {
        let (session, provider) = makeSession([failing(with: offline), .answer("Bern.")])
        let (model, context) = openChat(on: session, asking: capital)
        await waitUntil { model.notice != nil }

        // The question is back in the field, so Return asks it again.
        let outcome = try await perform("Ask", on: context)

        #expect(outcome == .keepOpen)
        await waitUntil { model.tokenLine != nil }
        #expect(provider.requests.count == 2)
        #expect(model.turns.map(\.question) == [capital])
        #expect(model.turns.map(\.answer) == ["Bern."])
        #expect(model.notice == nil)
        #expect(context.searchText == "")
    }

    // A screen cannot write the field while it is being built, so a chat that opens on a
    // question without an answer puts it back a moment later.
    @Test func chatOpenedOnAnUnansweredQuestionPutsItBackOnceItIsBuilt() async {
        let (session, _) = makeSession([failing(with: offline)])
        session.ask(capital)
        await waitUntil { !session.isReplying }

        let (model, context) = openChat(on: session)
        #expect(context.searchText == "")
        #expect(model.notice == "You're offline")

        while context.searchText.isEmpty {
            await Task.yield()
        }
        #expect(context.searchText == capital)
    }

    // MARK: The key and the model

    @Test func missingKeyLeadsToSettings() async throws {
        let (session, _) = makeSession([failing(with: .missingCredentials)])

        let (model, context) = openChat(on: session, asking: capital)
        await waitUntil { model.notice != nil }

        #expect(model.notice == "Add your Anthropic API key")
        #expect(model.noticeLeadsToSettings)
        // First, so that Return opens Settings.
        #expect(titles(of: context) == ["Open Quick AI Settings", "Ask", "New Chat"])
        #expect(QuickAIChatModel.openSettingsTitle == "Open Quick AI Settings")

        let outcome = try await perform("Open Quick AI Settings", on: context)

        #expect(outcome == .closeLauncher)
        #expect(settings.openCount == 1)
        // Settings is a window outside the panel, so the launcher is closed first.
        #expect(context.fakeActionContext.closeLauncherCount == 1)
    }

    @Test(arguments: [AIError.invalidCredentials, .modelUnavailable(ClaudeProvider.opus)])
    func rejectedKeyAndUnavailableModelLeadToSettingsToo(_ error: AIError) async {
        let (session, _) = makeSession([failing(with: error)])

        let (model, context) = openChat(on: session, asking: capital)
        await waitUntil { model.notice != nil }

        #expect(model.noticeLeadsToSettings)
        #expect(titles(of: context).first == "Open Quick AI Settings")
    }

    @Test func otherFailuresKeepAskFirst() async {
        let (session, _) = makeSession([failing(with: .credentialsUnreadable)])

        let (model, context) = openChat(on: session, asking: capital)
        await waitUntil { model.notice != nil }

        // The key is there and could not be read. Asking again reads it again.
        #expect(model.notice == "Couldn't read key")
        #expect(!model.noticeLeadsToSettings)
        #expect(titles(of: context) == ["Ask", "New Chat"])
    }

    @Test func settingsButtonClosesTheLauncherAndOpensSettings() {
        let (session, _) = makeSession([])
        let (model, context) = openChat(on: session)

        model.showSettings()

        #expect(settings.openCount == 1)
        #expect(context.fakeActionContext.closeLauncherCount == 1)
    }

    // MARK: Wording

    @Test(arguments: failureMessages)
    func everyFailureHasItsMessage(_ error: AIError, _ message: String) async {
        let (session, _) = makeSession([failing(with: error)])

        let (model, _) = openChat(on: session, asking: capital)
        await waitUntil { model.notice != nil }

        #expect(model.notice == message)
        #expect(model.tokenLine == nil)
    }

    @Test(arguments: noticesOfKeptReplies)
    func keptReplyIsRemarkedOnOnlyWhenItWasCutOff(
        _ stopReason: AIStopReason, _ notice: String?
    ) async {
        let reply = Reply(events: [
            .textDelta("Bern."),
            .usage(AIUsage(inputTokens: 12, outputTokens: 5)),
            .finished(stopReason, assistant: assistantMessage("Bern.")),
        ])
        let (session, _) = makeSession([reply])

        let (model, context) = openChat(on: session, asking: capital)
        await waitUntil { model.tokenLine != nil }

        #expect(model.notice == notice)
        #expect(model.turns.map(\.answer) == ["Bern."])
        #expect(context.searchText == "")
    }

    @Test(arguments: noticesOfRepliesNotKept)
    func replyThatWasNotKeptSaysWhy(_ stopReason: AIStopReason, _ notice: String) async {
        let onlyThinking = AIMessage(role: .assistant, content: [thinkingBlock("sig-1")])
        let reply = Reply(events: [.finished(stopReason, assistant: onlyThinking)])
        let (session, _) = makeSession([reply])

        let (model, context) = openChat(on: session, asking: capital)
        await waitUntil { model.notice != nil }

        #expect(model.notice == notice)
        #expect(context.searchText == capital)
    }

    // MARK: Code blocks

    @Test func copyingACodeBlockGoesThroughTheLaunchersCopy() async throws {
        let answer = "Run this:\n```sh\nbrew install ripgrep\n```"
        let (session, _) = makeSession([.answer(answer)])
        let (model, context) = openChat(on: session, asking: "How do I install ripgrep?")
        await waitUntil { model.tokenLine != nil }
        let code = try #require(model.turns.first?.blocks.last)
        #expect(code.kind == .code(language: "sh"))

        model.copyCode(of: code)

        #expect(
            context.fakeActionContext.copied == [
                .text("brew install ripgrep", cursorOffsetFromEnd: nil)
            ])
        #expect(context.fakeActionContext.hudMessages == ["Copied to Clipboard"])
        // The chat stays open: the user is still reading.
        #expect(context.fakeActionContext.closeLauncherCount == 0)
    }

    @Test(arguments: ["https://example.com/a?b=c", "http://example.com", "HTTPS://EXAMPLE.COM"])
    func linkToAWebAddressIsOpened(_ address: String) throws {
        let url = try #require(URL(string: address))

        #expect(QuickAIChatModel.opensLink(to: url))
    }

    // An answer can be steered by text the user pasted into the question, and a link shows
    // its title, not where it leads.
    @Test(arguments: [
        "file:///System/Applications/Calculator.app", "smb://host/share",
        "shortcuts://run-shortcut?name=Foo", "x-apple.systempreferences:com.apple.preference",
        "mailto:someone@example.com", "javascript:alert(1)", "relative/path", "//example.com",
    ])
    func linkToAnythingElseIsNotOpened(_ address: String) throws {
        let url = try #require(URL(string: address))

        #expect(!QuickAIChatModel.opensLink(to: url))
    }
}
