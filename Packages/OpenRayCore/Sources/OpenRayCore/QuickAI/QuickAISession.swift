import Foundation
import Observation

/// One Quick AI thread: what was asked and answered, and the reply that is arriving now
/// (docs/DESIGN.md §4.6.4).
///
/// The Quick AI feature makes one session and keeps it while the app runs, so a reply goes on
/// arriving when the launcher is hidden. Nothing is saved. The thread ends with New Chat, when
/// the app quits, or once it has rested for fifteen minutes.
///
/// The thread only grows at its end, and only by a question together with its answer. Models
/// that keep their thinking reject a request in which anything before a thinking block differs
/// from what they were sent before, so nothing that was sent once is edited afterwards.
/// A question whose reply failed, was refused or was stopped before its first word is not
/// part of the thread: it stays in `pendingQuestion`, and asking again replaces it.
@MainActor @Observable public final class QuickAISession {
    public enum Phase: Equatable, Sendable {
        /// Nothing has been asked in this thread.
        case idle
        /// The question is sent, and the model has not begun to write.
        case waiting
        /// The model is thinking before it writes.
        case thinking
        /// Text is arriving.
        case streaming
        /// The reply came to its end. It was kept as an exchange unless `pendingQuestion` is
        /// still set, which it is after a refusal, when the thread has grown too long for the
        /// model, and when the reply ended before its first word.
        case complete(AIStopReason)
        /// The reply failed. What had arrived of it is still in `partialAnswer`.
        case failed(AIError)
        /// The reply was stopped. What had arrived of it was kept as an exchange; if nothing
        /// had, the question is still in `pendingQuestion`.
        case cancelled
    }

    /// A question with its answer.
    public struct Exchange: Identifiable, Sendable {
        /// Its place in the thread, counted from 0.
        public let id: Int
        public let question: String
        /// The text of the reply.
        public let answer: String
        /// The reply as it is sent back with the next question. Besides the text it holds what
        /// only the provider can read.
        let assistant: AIMessage
    }

    /// What every request of a thread has in common. A change in Settings applies from the
    /// next thread: the prompt cache serves only requests that begin alike, and a reply's
    /// thinking can only be sent back to the model it came from.
    private struct ThreadSettings {
        var systemPrompt: String
        var model: AIModelID
        var effort: AIEffort
    }

    /// Gathers the events of a reply into the batches that the reply's task reads.
    typealias EventBatching =
        @MainActor (AsyncThrowingStream<AIEvent, any Error>)
        -> AsyncThrowingStream<[AIEvent], any Error>

    /// The most tokens a reply may have. The model's thinking counts towards them, so a small
    /// limit could end a reply before its first word (§4.6.2).
    private static let maxOutputTokens = 8192
    /// How long a thread may rest before it ends.
    private static let idleLimit: TimeInterval = 15 * 60

    public private(set) var phase = Phase.idle
    /// The thread: every question that has an answer, oldest first.
    public private(set) var exchanges: [Exchange] = []
    /// The question that has no answer in the thread. While a reply is arriving it is the one
    /// being answered. Afterwards it is one whose reply was not kept, for the chat to put back
    /// into its field.
    public private(set) var pendingQuestion: String?
    /// The text that has arrived in reply to `pendingQuestion`.
    public private(set) var partialAnswer = ""
    /// The tokens of the latest request, as far as the provider has counted them.
    public private(set) var usage: AIUsage?

    /// The task that reads the reply, or the last one once it has ended. Readable so that tests
    /// can wait for a reply to end.
    @ObservationIgnored private(set) var replyTask: Task<Void, Never>?

    @ObservationIgnored private let provider: any AIProvider
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let batchEvents: EventBatching
    /// nil until the first question of a thread.
    @ObservationIgnored private var threadSettings: ThreadSettings?
    /// When the latest reply ended, however it ended. nil in a thread without one.
    @ObservationIgnored private var lastReplyEnded: Date?
    /// The provider's name for the request that is being answered, for the log.
    @ObservationIgnored private var requestID: String?

    /// - Parameter now: The time, for the date in the system prompt and for how long the
    ///   thread has rested. Tests pass their own.
    public convenience init(
        provider: any AIProvider, preferences: Preferences, now: @escaping @Sendable () -> Date
    ) {
        self.init(provider: provider, preferences: preferences, now: now) { events in
            AIEventCoalescer.batches(of: events)
        }
    }

    /// - Parameter batchEvents: The coalescer, everywhere but in a test that has to hand the
    ///   session a batch at a moment of its own choosing.
    init(
        provider: any AIProvider, preferences: Preferences, now: @escaping @Sendable () -> Date,
        batchEvents: @escaping EventBatching
    ) {
        self.provider = provider
        self.preferences = preferences
        self.now = now
        self.batchEvents = batchEvents
    }

    deinit {
        replyTask?.cancel()
    }

    // MARK: - State

    public var isReplying: Bool {
        switch phase {
        case .waiting, .thinking, .streaming: return true
        case .idle, .complete, .failed, .cancelled: return false
        }
    }

    /// Whether there is a thread to come back to: one with an answer that has not rested for
    /// too long, or one whose reply is arriving.
    public var isLive: Bool {
        if isReplying { return true }
        return !exchanges.isEmpty && !hasRestedTooLong
    }

    /// Whether `regenerate()` has an answer to replace: the last thing in the chat is an
    /// answer, and not a question that is waiting for one or was left without.
    public var canRegenerate: Bool {
        !isReplying && pendingQuestion == nil && !exchanges.isEmpty
    }

    /// The thread as the provider is sent it, ahead of the next question.
    var threadMessages: [AIMessage] {
        var messages: [AIMessage] = []
        for exchange in exchanges {
            messages.append(Self.userMessage(exchange.question))
            messages.append(exchange.assistant)
        }
        return messages
    }

    private var hasRestedTooLong: Bool {
        guard let lastReplyEnded else { return false }
        return now().timeIntervalSince(lastReplyEnded) > Self.idleLimit
    }

    /// The request's ID as the log shows it. A reply that was given up before the provider
    /// had begun to answer has none.
    private var requestIDForLog: String {
        requestID ?? "none"
    }

    // MARK: - What the user does

    /// Asks the question in this thread.
    ///
    /// A reply that is still arriving is stopped first, by the rules of `stop()`. The chat
    /// never asks that way from its own field; it happens when a new question comes from root
    /// search while the launcher was showing something else.
    public func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        // The API takes no empty text.
        if question.isEmpty { return }

        if isReplying {
            stop()
        } else {
            endThreadIfIdle()
        }
        send(question, with: settingsForNextQuestion())
    }

    /// Stops the reply that is arriving.
    ///
    /// The text that has arrived stays in the thread as the answer. Without any, the thread
    /// is as it was before the question, and the question stays in `pendingQuestion`.
    public func stop() {
        guard isReplying else { return }
        replyTask?.cancel()

        Log.ai.info("Request \(self.requestIDForLog, privacy: .public) was stopped")
        endStoppedReply()
    }

    /// Asks the last question again and replaces its answer. Does nothing unless
    /// `canRegenerate`.
    ///
    /// The old answer is gone once this is called, also if the new one fails.
    public func regenerate() {
        guard canRegenerate, let threadSettings else { return }
        let replaced = exchanges.removeLast()
        send(replaced.question, with: threadSettings)
    }

    /// Ends the thread, and the reply that is arriving with it.
    public func newChat() {
        replyTask?.cancel()

        exchanges = []
        pendingQuestion = nil
        partialAnswer = ""
        usage = nil
        phase = .idle
        threadSettings = nil
        lastReplyEnded = nil
        requestID = nil
    }

    /// Ends a thread that has rested for too long, as `ask(_:)` does before it sends. The chat
    /// calls this when it opens, so that it does not show a thread the next question would
    /// discard.
    ///
    /// There is no timer behind the limit: nothing is lost while an old thread stays in
    /// memory until somebody looks.
    public func endThreadIfIdle() {
        if isReplying || !hasRestedTooLong { return }
        Log.ai.info("The thread has rested for too long and ends")
        newChat()
    }

    // MARK: - Sending

    /// The settings of the thread, read from the preferences while it has no answer yet.
    ///
    /// Until then nothing ties the thread to what an earlier attempt was sent with. So a first
    /// question that failed because the key cannot use the model is asked again with the model
    /// the user has chosen since.
    private func settingsForNextQuestion() -> ThreadSettings {
        if let threadSettings, !exchanges.isEmpty {
            return threadSettings
        }
        let settings = ThreadSettings(
            systemPrompt: QuickAISystemPrompt.text(on: now()),
            model: preferences.aiModel,
            effort: preferences.aiEffort)
        threadSettings = settings
        return settings
    }

    private func send(_ question: String, with settings: ThreadSettings) {
        var messages = threadMessages
        messages.append(Self.userMessage(question))
        let request = AIRequest(
            model: settings.model, system: settings.systemPrompt, messages: messages,
            maxOutputTokens: Self.maxOutputTokens, effort: settings.effort)

        // The reply before this one has ended, but its task may not have noticed yet.
        // Cancelled, it leaves the new reply alone when it does.
        replyTask?.cancel()

        pendingQuestion = question
        partialAnswer = ""
        usage = nil
        requestID = nil
        phase = .waiting

        let batches = batchEvents(provider.stream(request))
        // The task holds the session only while it handles a batch, so a session that nobody
        // keeps is released and its `deinit` ends the reply.
        replyTask = Task { [weak self] in
            do {
                for try await batch in batches {
                    self?.receive(batch)
                }
                self?.replyStreamEnded()
            } catch {
                self?.replyFailed(error)
            }
        }
    }

    private static func userMessage(_ question: String) -> AIMessage {
        AIMessage(role: .user, content: [.text(question)])
    }

    // MARK: - Receiving

    // The three functions below are called from the reply's task and start by asking whether
    // it was cancelled. Whoever gives a reply up cancels its task on the main actor, where
    // these run too, and none of them suspends. So a reply that was given up changes nothing
    // afterwards, even when a batch of it was already on its way.

    private func receive(_ batch: [AIEvent]) {
        if Task.isCancelled { return }
        for event in batch {
            apply(event)
        }
    }

    private func replyStreamEnded() {
        // After `.finished`, the end of the stream is all there is left to come.
        if Task.isCancelled || !isReplying { return }
        // A provider ends a reply with `.finished` or with an error. One that does neither
        // must not leave the chat waiting for ever.
        endReply(in: .failed(.malformedStream("the reply ended without a stop reason")))
    }

    private func replyFailed(_ error: any Error) {
        if Task.isCancelled { return }

        if error is CancellationError {
            // Nobody here stopped the reply: the request was cancelled underneath it, as when
            // its connection is closed. It is no failure, so it is treated as a stop.
            endStoppedReply()
            return
        }
        // Everything else a provider throws is an `AIError`.
        let failure =
            (error as? AIError) ?? .malformedStream("the provider failed in a way it does not name")
        endReply(in: .failed(failure))
    }

    private func apply(_ event: AIEvent) {
        switch event {
        case .started(let model, let requestID):
            self.requestID = requestID
            // This comes a second time when the provider tried again, and the reply then
            // starts over.
            partialAnswer = ""
            phase = .waiting
            Log.ai.info(
                "Request \(self.requestIDForLog, privacy: .public) is answered by \(model.rawValue, privacy: .public)"
            )

        case .reasoning(let isActive):
            phase = isActive ? .thinking : .waiting

        case .textDelta(let text):
            partialAnswer += text
            phase = .streaming

        case .usage(let usage):
            self.usage = usage

        case .finished(let stopReason, let assistant):
            switch stopReason {
            case .refusal:
                // What a refused reply had written is taken back, as Anthropic's documentation
                // advises. The question stays, for the user to put differently.
                partialAnswer = ""
            case .contextWindowExceeded:
                // Sent back, this exchange would make the next request longer still.
                break
            case .endTurn, .maxTokens, .other:
                keepExchange(answeredBy: assistant)
            }
            endReply(in: .complete(stopReason))
        }
    }

    /// The reply was stopped, by the user or from underneath.
    private func endStoppedReply() {
        // `.finished` never came, and the message it would have brought with it. The text is
        // all there is to keep. Thinking that was cut off has no signature, and the API would
        // refuse it.
        keepExchange(answeredBy: AIMessage(role: .assistant, content: [.text(partialAnswer)]))
        endReply(in: .cancelled)
    }

    private func endReply(in phase: Phase) {
        self.phase = phase
        lastReplyEnded = now()
    }

    /// Adds the pending question and its reply to the thread, if the reply says anything.
    private func keepExchange(answeredBy assistant: AIMessage) {
        guard let question = pendingQuestion else { return }

        var answer = ""
        for block in assistant.content {
            if case .text(let text) = block {
                answer += text
            }
        }

        // A reply without text is one that ran into the output limit while the model was
        // still thinking, or was stopped that early. It is not kept: the API takes no turn
        // that is blank, and one that is only a thinking block is not safe to send back.
        let isBlank = answer.allSatisfy(\.isWhitespace)
        if isBlank {
            Log.ai.notice(
                "The reply to request \(self.requestIDForLog, privacy: .public) had no text and was not kept"
            )
            return
        }

        let exchange = Exchange(
            id: exchanges.count, question: question, answer: answer, assistant: assistant)
        exchanges.append(exchange)
        pendingQuestion = nil
        partialAnswer = ""
    }
}
