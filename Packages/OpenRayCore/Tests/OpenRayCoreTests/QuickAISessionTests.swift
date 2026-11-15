import Foundation
import Testing

@testable import OpenRayCore

private typealias Reply = FakeAIProvider.Reply

/// Replies whose batches a test hands to the session itself, with no coalescer in between.
@MainActor private final class HandDeliveredReplies {
    /// One for each request, in the order they were sent.
    private(set) var continuations: [AsyncThrowingStream<[AIEvent], any Error>.Continuation] = []

    func makeStream() -> AsyncThrowingStream<[AIEvent], any Error> {
        let (batches, continuation) = AsyncThrowingStream.makeStream(
            of: [AIEvent].self, throwing: (any Error).self)
        continuations.append(continuation)
        return batches
    }
}

// No test sleeps to let a reply settle. A test either waits for the reply's task to end, after
// which nothing more can change, or delivers the reply by hand and waits for the session to
// show each step. The time limit only stops a test that would otherwise wait for ever.
@MainActor @Suite(.timeLimit(.minutes(1))) struct QuickAISessionTests {
    private let clock = TestClock(Date(timeIntervalSinceReferenceDate: 800_000_000))
    private let preferences = Preferences(store: InMemoryPreferencesStore())

    private let capital = "What is the capital of Switzerland?"
    private let population = "How many people live there?"

    /// A session whose provider answers with `script`, one reply for each request.
    private func makeSession(_ script: [Reply]) -> (
        session: QuickAISession, provider: FakeAIProvider
    ) {
        let provider = FakeAIProvider(script)
        let clock = clock
        let session = QuickAISession(
            provider: provider, preferences: preferences, now: { clock.now })
        return (session, provider)
    }

    /// Returns once the reply that is being read has ended, however it ended.
    private func replyToEnd(in session: QuickAISession) async {
        await waitForEnd(of: session.replyTask)
    }

    /// Returns once the provider's stream has been ended by its reader.
    private func streamToBeCancelled(of provider: FakeAIProvider) async {
        for await _ in provider.cancellations { break }
    }

    private func started(_ requestID: String = "req_fake") -> AIEvent {
        .started(model: ClaudeProvider.haiku, requestID: requestID)
    }

    // MARK: A reply from beginning to end

    @Test func newSessionIsIdleAndNotLive() {
        let (session, provider) = makeSession([])

        #expect(session.phase == .idle)
        #expect(session.exchanges.isEmpty)
        #expect(session.pendingQuestion == nil)
        #expect(!session.isLive)
        #expect(!session.canRegenerate)
        #expect(provider.requests.isEmpty)
    }

    @Test func replyGoesThroughItsPhasesAndBecomesAnExchange() async throws {
        let (session, provider) = makeSession([.open])
        let usage = AIUsage(inputTokens: 300, outputTokens: 9, cacheReadInputTokens: 200)
        let reply = assistantMessage("Bern.", thinking: "sig-1")

        session.ask(capital)
        // Before the provider has said anything.
        #expect(session.phase == .waiting)
        #expect(session.pendingQuestion == capital)
        #expect(session.isReplying)
        #expect(session.isLive)

        provider.send(started())
        provider.send(.reasoning(active: true))
        await waitUntil { session.phase == .thinking }

        provider.send(.reasoning(active: false))
        await waitUntil { session.phase == .waiting }

        provider.send(.textDelta("Bern"))
        await waitUntil { session.phase == .streaming }
        #expect(session.partialAnswer == "Bern")
        #expect(session.exchanges.isEmpty)

        provider.send(.textDelta("."))
        provider.send(.usage(usage))
        provider.send(.finished(.endTurn, assistant: reply))
        provider.finish()
        await replyToEnd(in: session)

        #expect(session.phase == .complete(.endTurn))
        #expect(!session.isReplying)
        #expect(session.isLive)
        #expect(session.usage == usage)
        #expect(session.pendingQuestion == nil)
        #expect(session.partialAnswer == "")

        let exchange = try #require(session.exchanges.first)
        #expect(session.exchanges.count == 1)
        #expect(exchange.id == 0)
        #expect(exchange.question == capital)
        #expect(exchange.answer == "Bern.")
        // The provider's message is kept as it came, thinking block included.
        #expect(session.threadMessages == [userMessage(capital), reply])
    }

    @Test func requestCarriesTheQuestionAndTheSettings() throws {
        let (session, provider) = makeSession([.open])

        session.ask(capital)

        let request = try #require(provider.requests.first)
        #expect(provider.requests.count == 1)
        #expect(request.messages == [userMessage(capital)])
        #expect(request.model == ClaudeProvider.haiku)
        #expect(request.effort == .low)
        #expect(request.maxOutputTokens == 8192)
        #expect(request.system == QuickAISystemPrompt.text(on: clock.now))
    }

    @Test func questionIsSentWithoutTheSpaceAroundIt() throws {
        let (session, provider) = makeSession([.open])

        session.ask("  \(capital)\n")

        #expect(session.pendingQuestion == capital)
        #expect(provider.requests.first?.messages == [userMessage(capital)])
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func blankQuestionIsNotAsked(_ question: String) {
        let (session, provider) = makeSession([.open])

        session.ask(question)

        #expect(session.phase == .idle)
        #expect(session.pendingQuestion == nil)
        #expect(provider.requests.isEmpty)
    }

    @Test func usageOfTheLastReplyIsForgottenWhenTheNextQuestionIsAsked() async {
        let (session, _) = makeSession([.answer("Bern."), .open])

        session.ask(capital)
        await replyToEnd(in: session)
        #expect(session.usage == AIUsage(inputTokens: 12, outputTokens: 5))

        session.ask(population)
        #expect(session.usage == nil)
    }

    // MARK: Follow-ups

    @Test func followUpSendsTheThreadSoFarAndThenTheNewQuestion() async throws {
        let (session, provider) = makeSession([.answer("Bern."), .answer("About 140,000.")])

        session.ask(capital)
        await replyToEnd(in: session)
        session.ask(population)
        await replyToEnd(in: session)

        let first = try #require(provider.requests.first)
        let second = try #require(provider.requests.last)
        #expect(provider.requests.count == 2)
        // The second request begins with all of the first, which is what the prompt cache
        // and the thinking blocks need.
        #expect(Array(second.messages.prefix(first.messages.count)) == first.messages)
        #expect(
            second.messages == [
                userMessage(capital), assistantMessage("Bern.", thinking: "sig-Bern."),
                userMessage(population),
            ])

        #expect(session.exchanges.map(\.id) == [0, 1])
        #expect(session.exchanges.map(\.question) == [capital, population])
        #expect(session.exchanges.map(\.answer) == ["Bern.", "About 140,000."])
    }

    @Test func threadKeepsItsPromptModelAndEffortWhateverChangesMeanwhile() async throws {
        // Five minutes before midnight where the tests run, so that the date in a new prompt
        // would differ ten minutes later.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let midnight = calendar.startOfDay(for: clock.now)
        let before = midnight.addingTimeInterval(-5 * 60)
        let after = midnight.addingTimeInterval(5 * 60)
        let promptBefore = QuickAISystemPrompt.text(on: before)
        let promptAfter = QuickAISystemPrompt.text(on: after)
        try #require(promptBefore != promptAfter)

        let (session, provider) = makeSession([.answer("Bern."), .answer("About 140,000."), .open])
        clock.set(before)
        session.ask(capital)
        await replyToEnd(in: session)

        clock.set(after)
        preferences.aiModel = ClaudeProvider.opus
        preferences.aiEffort = .high
        session.ask(population)
        await replyToEnd(in: session)

        let first = try #require(provider.requests.first)
        let second = try #require(provider.requests.last)
        #expect(first.system == promptBefore)
        #expect(second.system == promptBefore)
        #expect(second.model == ClaudeProvider.haiku)
        #expect(second.effort == .low)

        // The next thread takes what is set now.
        session.newChat()
        session.ask(capital)

        let third = try #require(provider.requests.last)
        #expect(provider.requests.count == 3)
        #expect(third.system == promptAfter)
        #expect(third.model == ClaudeProvider.opus)
        #expect(third.effort == .high)
        #expect(third.messages == [userMessage(capital)])
    }

    // A first question that failed leaves nothing a later request has to agree with. This is
    // the way out of "Model unavailable to this key": choose another model, ask again.
    @Test func threadWithoutAnAnswerTakesTheSettingsAsTheyAreNow() async throws {
        let unavailable = Reply(error: AIError.modelUnavailable(ClaudeProvider.opus))
        let (session, provider) = makeSession([unavailable, .open])
        preferences.aiModel = ClaudeProvider.opus

        session.ask(capital)
        await replyToEnd(in: session)
        #expect(session.phase == .failed(.modelUnavailable(ClaudeProvider.opus)))

        preferences.aiModel = ClaudeProvider.sonnet
        session.ask(capital)

        #expect(provider.requests.map(\.model) == [ClaudeProvider.opus, ClaudeProvider.sonnet])
    }

    // MARK: Regenerate

    @Test func regenerateAsksTheSameAgainAndReplacesTheAnswer() async throws {
        let (session, provider) = makeSession([
            .answer("Bern."), .answer("Zurich."), .answer("Bern, not Zurich."), .open,
        ])
        session.ask(capital)
        await replyToEnd(in: session)
        session.ask(population)
        await replyToEnd(in: session)
        #expect(session.canRegenerate)

        session.regenerate()
        #expect(session.isReplying)
        #expect(!session.canRegenerate)
        #expect(session.pendingQuestion == population)
        // The first exchange stays while the second is asked again.
        #expect(session.exchanges.map(\.answer) == ["Bern."])
        await replyToEnd(in: session)

        let asked = try #require(provider.requests.dropLast().last)
        let askedAgain = try #require(provider.requests.last)
        #expect(provider.requests.count == 3)
        #expect(askedAgain.messages == asked.messages)
        #expect(askedAgain.system == asked.system)
        #expect(session.exchanges.map(\.id) == [0, 1])
        #expect(session.exchanges.map(\.answer) == ["Bern.", "Bern, not Zurich."])

        // The answer that was replaced is not sent again.
        session.ask("Are you sure?")
        #expect(
            provider.requests.last?.messages == [
                userMessage(capital), assistantMessage("Bern.", thinking: "sig-Bern."),
                userMessage(population),
                assistantMessage("Bern, not Zurich.", thinking: "sig-Bern, not Zurich."),
                userMessage("Are you sure?"),
            ])
    }

    @Test func regenerateNeedsAnAnswerToReplace() async {
        let overloaded = Reply(events: [started()], error: AIError.overloaded)
        let (session, provider) = makeSession([.answer("Bern."), overloaded, .open])

        // Nothing was asked.
        session.regenerate()
        #expect(provider.requests.isEmpty)

        session.ask(capital)
        await replyToEnd(in: session)
        session.ask(population)
        await replyToEnd(in: session)

        // The last thing in the chat is a question without an answer, and asking that again
        // is what Return does.
        #expect(!session.canRegenerate)
        session.regenerate()
        #expect(provider.requests.count == 2)
        #expect(session.exchanges.count == 1)

        // Not while a reply is arriving either.
        session.ask(population)
        session.regenerate()
        #expect(provider.requests.count == 3)
    }

    // MARK: Stop

    @Test func stopBeforeAnyTextLeavesTheThreadAsItWas() async {
        let (session, provider) = makeSession([.open, .open])
        session.ask(capital)
        provider.send(started())
        provider.send(.reasoning(active: true))
        await waitUntil { session.phase == .thinking }

        session.stop()

        #expect(session.phase == .cancelled)
        #expect(session.exchanges.isEmpty)
        #expect(session.threadMessages.isEmpty)
        // The question is still there, to be put back into the field.
        #expect(session.pendingQuestion == capital)
        #expect(!session.isLive)
        await streamToBeCancelled(of: provider)

        session.ask(population)
        #expect(provider.requests.last?.messages == [userMessage(population)])
    }

    @Test func stopAfterTextKeepsTheTextAsTheAnswer() async {
        let (session, provider) = makeSession([.open, .open])
        session.ask(capital)
        provider.send(started())
        provider.send(.reasoning(active: true))
        provider.send(.reasoning(active: false))
        provider.send(.textDelta("Bern is"))
        await waitUntil { session.phase == .streaming }

        session.stop()

        #expect(session.phase == .cancelled)
        #expect(session.exchanges.map(\.answer) == ["Bern is"])
        #expect(session.pendingQuestion == nil)
        #expect(session.partialAnswer == "")
        #expect(session.isLive)
        await streamToBeCancelled(of: provider)

        // The turn is sent back as text alone. The thinking that came before it was never
        // handed over, and half a thinking block could not be sent.
        session.ask(population)
        #expect(
            provider.requests.last?.messages == [
                userMessage(capital), assistantMessage("Bern is"), userMessage(population),
            ])
    }

    @Test func textThatIsOnlySpaceIsNotAnAnswerToKeep() async {
        let (session, provider) = makeSession([.open])
        session.ask(capital)
        provider.send(started())
        provider.send(.textDelta("\n\n"))
        await waitUntil { session.phase == .streaming }

        session.stop()

        #expect(session.phase == .cancelled)
        #expect(session.exchanges.isEmpty)
        #expect(session.pendingQuestion == capital)
    }

    @Test func stopWithoutAReplyDoesNothing() async {
        let (session, _) = makeSession([.answer("Bern.")])

        session.stop()
        #expect(session.phase == .idle)

        session.ask(capital)
        await replyToEnd(in: session)
        session.stop()
        #expect(session.phase == .complete(.endTurn))
    }

    // MARK: Replies that are not kept

    @Test func errorBeforeAnyTextKeepsTheQuestionAndNothingElse() async {
        let overloaded = Reply(events: [started()], error: AIError.overloaded)
        let (session, provider) = makeSession([overloaded, .open])

        session.ask(capital)
        await replyToEnd(in: session)

        #expect(session.phase == .failed(.overloaded))
        #expect(session.exchanges.isEmpty)
        #expect(session.pendingQuestion == capital)
        #expect(session.partialAnswer == "")
        #expect(!session.isLive)

        session.ask(capital)
        #expect(provider.requests.last?.messages == [userMessage(capital)])
    }

    @Test func errorAfterTextLeavesTheTextOnScreenAndOutOfTheThread() async {
        let connectionLost = Reply(
            events: [started(), .textDelta("Bern"), .textDelta(" is")],
            error: AIError.network(.networkConnectionLost))
        let (session, provider) = makeSession([connectionLost, .open])

        session.ask(capital)
        await replyToEnd(in: session)

        #expect(session.phase == .failed(.network(.networkConnectionLost)))
        #expect(session.partialAnswer == "Bern is")
        #expect(session.pendingQuestion == capital)
        #expect(session.exchanges.isEmpty)

        // Asking again replaces the failed attempt.
        session.ask("What is the capital of Austria?")
        #expect(session.partialAnswer == "")
        #expect(
            provider.requests.last?.messages == [userMessage("What is the capital of Austria?")])
    }

    @Test func refusalTakesBackWhatWasWrittenAndKeepsTheQuestion() async {
        let refused = Reply(events: [
            started(), .textDelta("I"),
            .finished(.refusal(category: "cyber"), assistant: assistantMessage("I")),
        ])
        let (session, provider) = makeSession([.answer("Bern."), refused, .open])
        session.ask(capital)
        await replyToEnd(in: session)

        session.ask(population)
        await replyToEnd(in: session)

        #expect(session.phase == .complete(.refusal(category: "cyber")))
        #expect(session.partialAnswer == "")
        #expect(session.pendingQuestion == population)
        #expect(session.exchanges.map(\.question) == [capital])

        // The refused exchange is not part of what is sent next.
        session.ask("And in the whole canton?")
        #expect(
            provider.requests.last?.messages == [
                userMessage(capital), assistantMessage("Bern.", thinking: "sig-Bern."),
                userMessage("And in the whole canton?"),
            ])
    }

    @Test func threadThatGrewTooLongKeepsTheQuestionOutOfIt() async {
        let tooLong = Reply(events: [
            started(), .finished(.contextWindowExceeded, assistant: assistantMessage("Be")),
        ])
        let (session, _) = makeSession([tooLong])

        session.ask(capital)
        await replyToEnd(in: session)

        #expect(session.phase == .complete(.contextWindowExceeded))
        #expect(session.exchanges.isEmpty)
        #expect(session.pendingQuestion == capital)
    }

    @Test func answerThatWasCutOffIsKept() async {
        let cutOff = Reply(events: [
            started(), .textDelta("Bern is the"),
            .finished(.maxTokens, assistant: assistantMessage("Bern is the", thinking: "sig-1")),
        ])
        let (session, _) = makeSession([cutOff])

        session.ask(capital)
        await replyToEnd(in: session)

        #expect(session.phase == .complete(.maxTokens))
        #expect(session.exchanges.map(\.answer) == ["Bern is the"])
        #expect(session.pendingQuestion == nil)
        #expect(session.threadMessages.last == assistantMessage("Bern is the", thinking: "sig-1"))
    }

    // The output limit was used up by the thinking. A turn that is a thinking block and
    // nothing else is not one to send back.
    @Test func replyThatWasCutOffBeforeItsFirstWordIsNotKept() async {
        let onlyThinking = AIMessage(role: .assistant, content: [thinkingBlock("sig-1")])
        let cutOff = Reply(events: [
            started(), .reasoning(active: true), .reasoning(active: false),
            .finished(.maxTokens, assistant: onlyThinking),
        ])
        let (session, provider) = makeSession([cutOff, .open])

        session.ask(capital)
        await replyToEnd(in: session)

        #expect(session.phase == .complete(.maxTokens))
        #expect(session.exchanges.isEmpty)
        #expect(session.pendingQuestion == capital)

        session.ask(capital)
        #expect(provider.requests.last?.messages == [userMessage(capital)])
    }

    @Test func stopReasonThisVersionDoesNotKnowCountsAsComplete() async {
        let paused = Reply(events: [
            started(), .textDelta("Bern."),
            .finished(.other("pause_turn"), assistant: assistantMessage("Bern.")),
        ])
        let (session, _) = makeSession([paused])

        session.ask(capital)
        await replyToEnd(in: session)

        #expect(session.phase == .complete(.other("pause_turn")))
        #expect(session.exchanges.map(\.answer) == ["Bern."])
    }

    // MARK: What a provider can do besides

    // A provider that tried again announces the new attempt with a second `.started`.
    @Test func secondStartTakesTheThinkingIndicatorBack() async {
        let (session, provider) = makeSession([.open])
        session.ask(capital)
        provider.send(started("req_1"))
        provider.send(.reasoning(active: true))
        await waitUntil { session.phase == .thinking }

        provider.send(started("req_2"))
        await waitUntil { session.phase == .waiting }

        provider.send(.textDelta("Bern."))
        provider.send(.finished(.endTurn, assistant: assistantMessage("Bern.")))
        provider.finish()
        await replyToEnd(in: session)
        #expect(session.phase == .complete(.endTurn))
        #expect(session.exchanges.map(\.answer) == ["Bern."])
    }

    @Test func streamThatEndsWithoutAStopReasonIsAFailure() async throws {
        let cutShort = Reply(events: [started(), .textDelta("Bern")])
        let (session, _) = makeSession([cutShort])

        session.ask(capital)
        await replyToEnd(in: session)

        guard case .failed(.malformedStream) = session.phase else {
            Issue.record("The phase is \(session.phase)")
            return
        }
        #expect(session.partialAnswer == "Bern")
        #expect(session.exchanges.isEmpty)
    }

    @Test func errorThatIsNoAIErrorIsStillAFailure() async {
        struct Unexpected: Error {}
        let (session, _) = makeSession([Reply(error: Unexpected())])

        session.ask(capital)
        await replyToEnd(in: session)

        guard case .failed(.malformedStream) = session.phase else {
            Issue.record("The phase is \(session.phase)")
            return
        }
        #expect(session.pendingQuestion == capital)
    }

    // The request was cancelled where the session did not ask for it, as when its connection
    // is torn down. That is a stop and not an error.
    @Test func cancellationFromUnderneathIsAStopAndNotAFailure() async {
        let cancelled = Reply(
            events: [started(), .textDelta("Bern is")], error: CancellationError())
        let (session, _) = makeSession([cancelled])

        session.ask(capital)
        await replyToEnd(in: session)

        #expect(session.phase == .cancelled)
        #expect(session.exchanges.map(\.answer) == ["Bern is"])
    }

    // MARK: A new question or a new chat while a reply arrives

    @Test func askingDuringAReplyStopsItAndAsksInTheSameThread() async throws {
        let (session, provider) = makeSession([.open, .answer("About 140,000.")])
        session.ask(capital)
        provider.send(started())
        provider.send(.textDelta("Bern"))
        await waitUntil { session.phase == .streaming }

        session.ask(population)
        await streamToBeCancelled(of: provider)
        await replyToEnd(in: session)

        #expect(
            provider.requests.last?.messages == [
                userMessage(capital), assistantMessage("Bern"), userMessage(population),
            ])
        #expect(session.phase == .complete(.endTurn))
        #expect(session.exchanges.map(\.answer) == ["Bern", "About 140,000."])
    }

    @Test func askingDuringAReplyWithoutTextDropsItsQuestion() async {
        let (session, provider) = makeSession([.open, .answer("About 140,000.")])
        session.ask(capital)
        provider.send(started())
        provider.send(.reasoning(active: true))
        await waitUntil { session.phase == .thinking }

        session.ask(population)
        await streamToBeCancelled(of: provider)
        await replyToEnd(in: session)

        #expect(provider.requests.last?.messages == [userMessage(population)])
        #expect(session.exchanges.map(\.question) == [population])
    }

    // The reply before has ended, but its stream has not: a provider may take its time to
    // close it. The end of the old stream must not be taken for the end of the new reply.
    @Test func endOfAFinishedReplysStreamDoesNotTouchTheNextReply() async {
        let finishedButOpen = Reply(
            events: [
                started(), .textDelta("Bern."),
                .finished(.endTurn, assistant: assistantMessage("Bern.")),
            ], staysOpen: true)
        let (session, _) = makeSession([finishedButOpen, .open])
        session.ask(capital)
        await waitUntil { session.phase == .complete(.endTurn) }
        let finishedReply = session.replyTask

        session.ask(population)
        await waitForEnd(of: finishedReply)

        #expect(session.phase == .waiting)
        #expect(session.pendingQuestion == population)
    }

    @Test func newChatDuringAReplyEndsItAndClearsTheThread() async {
        let (session, provider) = makeSession([.answer("Bern."), .open, .open])
        session.ask(capital)
        await replyToEnd(in: session)
        session.ask(population)
        provider.send(started())
        provider.send(.textDelta("About"))
        await waitUntil { session.phase == .streaming }
        let abandonedReply = session.replyTask

        provider.send(.textDelta(" 140,000."))
        session.newChat()
        await streamToBeCancelled(of: provider)
        await waitForEnd(of: abandonedReply)

        #expect(session.phase == .idle)
        #expect(session.exchanges.isEmpty)
        #expect(session.pendingQuestion == nil)
        #expect(session.partialAnswer == "")
        #expect(session.usage == nil)
        #expect(!session.isLive)

        session.ask(capital)
        #expect(provider.requests.last?.messages == [userMessage(capital)])
    }

    // MARK: A batch that is on its way when the reply is given up

    // Only what the session had applied when a reply was given up counts. More of the reply
    // may be on its way at that moment: handed to the reply's task, which is waiting for the
    // main actor to apply it.
    //
    // The tests below bring that moment about every time. They hand the session its batches
    // themselves and give the reply up in the same stretch on the main actor, so the reply's
    // task cannot run in between and finds the batch and the cancellation together.

    /// A session that reads its replies from `replies`. The provider is still asked, and what
    /// it answers is not read.
    private func makeSession(readingFrom replies: HandDeliveredReplies) -> QuickAISession {
        let clock = clock
        return QuickAISession(
            provider: FakeAIProvider([.open, .open]), preferences: preferences,
            now: { clock.now },
            batchEvents: { _ in replies.makeStream() })
    }

    /// Asks `capital` and waits until "Bern" is on screen and the reply's task waits for more.
    private func askAndReceiveFirstWord(
        in session: QuickAISession, from replies: HandDeliveredReplies
    ) async {
        session.ask(capital)
        replies.continuations[0].yield([started(), .textDelta("Bern")])
        await waitUntil { session.phase == .streaming }
    }

    @Test func batchOfAStoppedReplyChangesNothingAfterwards() async {
        let replies = HandDeliveredReplies()
        let session = makeSession(readingFrom: replies)
        await askAndReceiveFirstWord(in: session, from: replies)
        let stoppedReply = session.replyTask

        replies.continuations[0].yield([.reasoning(active: true)])
        replies.continuations[0].yield([
            .textDelta(" is the capital."),
            .finished(.endTurn, assistant: assistantMessage("Bern is the capital.")),
        ])
        session.stop()
        await waitForEnd(of: stoppedReply)

        #expect(session.phase == .cancelled)
        #expect(session.exchanges.map(\.answer) == ["Bern"])
        #expect(session.partialAnswer == "")
    }

    @Test func failureOfAStoppedReplyIsNotReported() async {
        let replies = HandDeliveredReplies()
        let session = makeSession(readingFrom: replies)
        await askAndReceiveFirstWord(in: session, from: replies)
        let stoppedReply = session.replyTask

        replies.continuations[0].finish(throwing: AIError.overloaded)
        session.stop()
        await waitForEnd(of: stoppedReply)

        #expect(session.phase == .cancelled)
        #expect(session.exchanges.map(\.answer) == ["Bern"])
    }

    @Test func batchOfTheReplyBeforeIsNotTakenForTheNextReply() async {
        let replies = HandDeliveredReplies()
        let session = makeSession(readingFrom: replies)
        await askAndReceiveFirstWord(in: session, from: replies)
        let replyBefore = session.replyTask

        replies.continuations[0].yield([
            .textDelta(" is the capital."),
            .finished(.endTurn, assistant: assistantMessage("Bern is the capital.")),
        ])
        session.ask(population)
        await waitForEnd(of: replyBefore)

        // The first reply was stopped with what it had, and the second has not begun.
        #expect(session.exchanges.map(\.answer) == ["Bern"])
        #expect(session.phase == .waiting)
        #expect(session.pendingQuestion == population)
        #expect(session.partialAnswer == "")
    }

    @Test func batchOfAnEndedChatDoesNotBringItBack() async {
        let replies = HandDeliveredReplies()
        let session = makeSession(readingFrom: replies)
        await askAndReceiveFirstWord(in: session, from: replies)
        let abandonedReply = session.replyTask

        replies.continuations[0].yield([.textDelta(" is the capital.")])
        session.newChat()
        await waitForEnd(of: abandonedReply)

        #expect(session.phase == .idle)
        #expect(session.partialAnswer == "")
        #expect(!session.isLive)
    }

    // MARK: A thread that rests

    @Test func threadIsStillLiveAfterFourteenMinutes() async {
        let (session, provider) = makeSession([.answer("Bern."), .open])
        session.ask(capital)
        await replyToEnd(in: session)

        clock.advance(minutes: 14)

        #expect(session.isLive)
        session.ask(population)
        #expect(provider.requests.last?.messages.count == 3)
    }

    @Test func threadHasEndedAfterSixteenMinutes() async {
        let (session, provider) = makeSession([.answer("Bern."), .open])
        session.ask(capital)
        await replyToEnd(in: session)

        clock.advance(minutes: 16)

        #expect(!session.isLive)
        // Nothing is cleared until somebody asks.
        #expect(session.exchanges.count == 1)

        session.ask(population)
        #expect(provider.requests.last?.messages == [userMessage(population)])
        #expect(session.exchanges.isEmpty)
        #expect(session.pendingQuestion == population)
    }

    @Test func chatThatOpensOnAThreadThatHasEndedFindsItCleared() async {
        let (session, _) = makeSession([.answer("Bern.")])
        session.ask(capital)
        await replyToEnd(in: session)

        clock.advance(minutes: 14)
        session.endThreadIfIdle()
        #expect(session.exchanges.count == 1)

        clock.advance(minutes: 2)
        session.endThreadIfIdle()
        #expect(session.exchanges.isEmpty)
        #expect(session.phase == .idle)
    }

    @Test func replyThatIsArrivingKeepsItsThreadHoweverLongItTakes() async {
        let (session, provider) = makeSession([.open, .open])
        session.ask(capital)
        provider.send(started())

        clock.advance(minutes: 16)
        session.endThreadIfIdle()
        #expect(session.isLive)
        #expect(session.pendingQuestion == capital)

        // The rest begins when the reply ends, not when it was asked for.
        provider.send(.textDelta("Bern."))
        provider.send(.finished(.endTurn, assistant: assistantMessage("Bern.")))
        provider.finish()
        await replyToEnd(in: session)
        clock.advance(minutes: 14)

        #expect(session.isLive)
        session.ask(population)
        #expect(provider.requests.last?.messages.count == 3)
    }
}
