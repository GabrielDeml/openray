import Foundation
import Observation

/// The Quick AI chat screen (docs/DESIGN.md §4.6.6): what it shows of the session, the actions
/// it lists, and the keys it takes.
///
/// The feature makes one each time the screen is pushed, and it lives as long as the screen.
/// The thread is the session's and outlives it.
@MainActor @Observable public final class QuickAIChatModel {
    /// A question with what there is of its answer.
    public struct Turn: Identifiable, Equatable, Sendable {
        /// The turn's place in the thread. A question that is still being answered has the
        /// place its exchange will get, so the view keeps what it has drawn of it.
        public let id: Int
        public let question: String
        /// The answer so far. Empty while nothing has arrived, and when nothing ever did.
        public let answer: String
        public let blocks: [MarkdownBlock]
    }

    /// Asks the view to scroll the transcript. `serial` makes two requests for the same
    /// distance distinct.
    public struct ScrollRequest: Equatable, Sendable {
        /// How far, in steps of the view's choosing: down when positive, up when negative.
        public let steps: Int
        public let serial: UInt64
    }

    /// The thread, and after it the question that is being answered or was left without an
    /// answer.
    public private(set) var turns: [Turn] = []
    /// The question is sent and the model has not begun to write.
    public private(set) var isThinking = false
    /// What there is to say about the latest reply: that it was stopped or cut off, or why
    /// there is none.
    public private(set) var notice: String?
    /// Whether the notice is about something Settings puts right: the key or the model.
    public private(set) var noticeLeadsToSettings = false
    /// The tokens of the latest request, once its reply is complete.
    public private(set) var tokenLine: String?
    public private(set) var scrollRequest: ScrollRequest?

    @ObservationIgnored private let session: QuickAISession
    @ObservationIgnored private weak var context: (any ScreenContext)?
    @ObservationIgnored private let openSettings: @MainActor () -> Void
    /// The answer that is arriving, in blocks.
    @ObservationIgnored private var arrivingAnswer = StreamingMarkdown()
    /// The actions the screen has now, to tell when they have to be set again.
    @ObservationIgnored private var listedActions: [ActionID] = []
    /// Whether a reply was arriving when the session was last looked at.
    @ObservationIgnored private var wasReplying = false

    /// - Parameters:
    ///   - context: The screen's context. A question in its request's argument is asked at
    ///     once; without one the chat opens on the thread as it is.
    ///   - openSettings: Opens the Quick AI pane of the settings window.
    public init(
        session: QuickAISession, context: any ScreenContext,
        openSettings: @escaping @MainActor () -> Void
    ) {
        self.session = session
        self.context = context
        self.openSettings = openSettings

        // Not a thread the next question would discard.
        session.endThreadIfIdle()
        if let question = context.request.argument {
            session.ask(question)
        }
        wasReplying = session.isReplying
        followSession()

        if session.pendingQuestion != nil && !session.isReplying {
            // The thread was left with a question that got no answer. A screen is not on the
            // launcher's stack before it is built, and until then the field is not its to
            // write, so the question goes back a moment later.
            Task { [weak self] in
                self?.putUnansweredQuestionBack()
            }
        }
    }

    // MARK: - Following the session

    /// Shows the session as it is now, and again after its next change.
    private func followSession() {
        withObservationTracking {
            sessionDidChange()
        } onChange: { [weak self] in
            // This runs just before the change. What it leads to is read a moment later,
            // and several changes made in one go are then read once.
            Task { @MainActor [weak self] in
                self?.followSession()
            }
        }
    }

    private func sessionDidChange() {
        let replyHasEnded = wasReplying && !session.isReplying
        wasReplying = session.isReplying

        showTurns()
        showStateOfLatestReply()
        listActions()

        if replyHasEnded {
            putUnansweredQuestionBack()
        }
    }

    private func showTurns() {
        var turns: [Turn] = []
        for exchange in session.exchanges {
            turns.append(turn(for: exchange))
        }

        if let question = session.pendingQuestion {
            let answer = session.partialAnswer
            arrivingAnswer.update(to: answer)
            let turn = Turn(
                id: session.exchanges.count, question: question, answer: answer,
                blocks: arrivingAnswer.blocks)
            turns.append(turn)
        }
        self.turns = turns
    }

    private func turn(for exchange: QuickAISession.Exchange) -> Turn {
        // An answer in the thread does not change, so its blocks are worked out once and not
        // at every word of the answer after it. Only Regenerate puts another answer in the
        // same place. An answer that has just been kept is found here as it arrived.
        if exchange.id < turns.count {
            let shown = turns[exchange.id]
            if shown.question == exchange.question && shown.answer == exchange.answer {
                return shown
            }
        }
        return Turn(
            id: exchange.id, question: exchange.question, answer: exchange.answer,
            blocks: MarkdownBlockParser.blocks(of: exchange.answer))
    }

    private func showStateOfLatestReply() {
        var isThinking = false
        var notice: String?
        var noticeLeadsToSettings = false
        var tokenLine: String?

        switch session.phase {
        case .idle, .streaming:
            break
        case .waiting, .thinking:
            isThinking = true
        case .complete(let stopReason):
            let answerWasKept = session.pendingQuestion == nil
            notice = Self.notice(for: stopReason, answerWasKept: answerWasKept)
            if let usage = session.usage {
                tokenLine = Self.tokenLine(for: usage)
            }
        case .failed(let error):
            notice = error.userMessage
            noticeLeadsToSettings = Self.isPutRightInSettings(error)
        case .cancelled:
            notice = String(
                localized: "Stopped", bundle: .module,
                comment: "Quick AI: shown under an answer that the user stopped.")
        }

        self.isThinking = isThinking
        self.notice = notice
        self.noticeLeadsToSettings = noticeLeadsToSettings
        self.tokenLine = tokenLine
    }

    /// Puts a question that got no answer back into the field, for the user to ask again or
    /// to put differently. What they have typed since is left alone.
    private func putUnansweredQuestionBack() {
        guard let context, let question = session.pendingQuestion, !session.isReplying else {
            return
        }
        if context.searchText.isEmpty {
            context.setSearchText(question)
        }
    }

    // MARK: - Keys

    /// Takes the keys that mean something else here than in a list. Return is not among them:
    /// it runs the screen's first action, as on every screen.
    public func handleIntent(_ intent: LauncherIntent) -> Bool {
        switch intent {
        case .escape:
            // Esc stops a reply. Only the next one leaves the screen.
            guard session.isReplying else { return false }
            session.stop()
            return true

        case .moveSelection(let steps):
            // There are no rows to move through, so the arrows scroll: a long answer has to
            // be readable without a mouse.
            let previousSerial = scrollRequest?.serial ?? 0
            scrollRequest = ScrollRequest(steps: steps, serial: previousSerial + 1)
            return true

        default:
            return false
        }
    }

    // MARK: - What the view's buttons do

    /// Copies a code block of an answer.
    public func copyCode(of block: MarkdownBlock) {
        guard let actionContext = context?.actionContext else { return }
        actionContext.copy(.text(block.text, cursorOffsetFromEnd: nil))
        actionContext.showHUD(ActionOutcome.copiedToClipboardMessage)
    }

    /// Whether a link in an answer is opened when it is clicked.
    ///
    /// Only web addresses are. The model writes the links, and what it writes can be steered
    /// by text the user pasted into a question. A link is shown by its title and not by where
    /// it leads, and one click on a `file:` or `smb:` link would start an app or mount a
    /// share.
    public nonisolated static func opensLink(to url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    /// Opens the Quick AI pane of Settings.
    public func showSettings() {
        // Settings is a window outside the panel.
        context?.actionContext.closeLauncher()
        openSettings()
    }

    // MARK: - Actions

    public static var openSettingsTitle: String {
        String(
            localized: "Open Quick AI Settings", bundle: .module,
            comment:
                "Quick AI: the action and button that open the settings where the API key and the model are set."
        )
    }

    /// Brings the screen's actions in line with the session.
    private func listActions() {
        let actions = makeActions()
        // The actions read the session when they run, so a list of the same actions is the
        // same list. Setting it again at every word of a reply would redraw the footer for
        // nothing.
        let ids = actions.map(\.id)
        if ids == listedActions { return }
        listedActions = ids
        context?.setScreenActions(actions)
    }

    private func makeActions() -> [ActionDescriptor] {
        var actions: [ActionDescriptor] = []

        // Return runs the first action. That is Ask, except when asking cannot work before
        // something is changed in Settings.
        if noticeLeadsToSettings {
            actions.append(openSettingsAction())
        }
        actions.append(askAction())

        // The answer these two mean is the last one in the thread. While another is
        // arriving, that would not be the one the user is looking at.
        let hasAnswer = !session.exchanges.isEmpty && !session.isReplying
        if hasAnswer {
            actions.append(pasteAnswerAction())
            actions.append(copyAnswerAction())
        }
        if session.canRegenerate {
            actions.append(regenerateAction())
        }
        if session.phase != .idle {
            actions.append(newChatAction())
        }
        if session.isReplying {
            actions.append(stopAction())
        }
        return actions
    }

    private func askAction() -> ActionDescriptor {
        let title = String(
            localized: "Ask", bundle: .module,
            comment: "Quick AI: the action that sends what is in the search field as a question.")
        let session = session

        return ActionDescriptor(id: ActionID(rawValue: "ask"), title: title) { [weak context] _ in
            let typed = context?.searchText ?? ""
            let question = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            // Asking while a reply arrives would stop it, and Return is too easily pressed
            // for that. Esc stops a reply.
            if question.isEmpty || session.isReplying { return .keepOpen }

            session.ask(question)
            context?.setSearchText("")
            return .keepOpen
        }
    }

    private func pasteAnswerAction() -> ActionDescriptor {
        let title = String(
            localized: "Paste Answer", bundle: .module,
            comment:
                "Quick AI: the action that pastes the last answer into the app the user was in.")
        let session = session

        return ActionDescriptor(
            id: ActionID(rawValue: "paste-answer"), title: title,
            shortcut: ActionShortcuts.secondAction
        ) { actionContext in
            guard let answer = session.exchanges.last?.answer else { return .keepOpen }
            // The result is not looked at: the paste service itself tells the user when it
            // could only copy.
            _ = await actionContext.paste(.text(answer, cursorOffsetFromEnd: nil))
            return .closeLauncher
        }
    }

    private func copyAnswerAction() -> ActionDescriptor {
        let title = String(
            localized: "Copy Answer", bundle: .module,
            comment: "Quick AI: the action that copies the last answer to the clipboard.")
        let shortcut = KeyChord(
            keyCode: VirtualKey.ansiC, modifiers: [.command, .shift], characters: "c")
        let session = session

        return ActionDescriptor(
            id: ActionID(rawValue: "copy-answer"), title: title, shortcut: shortcut
        ) { actionContext in
            guard let answer = session.exchanges.last?.answer else { return .keepOpen }
            actionContext.copy(.text(answer, cursorOffsetFromEnd: nil))
            return .copiedToClipboard
        }
    }

    private func regenerateAction() -> ActionDescriptor {
        let title = String(
            localized: "Regenerate", bundle: .module,
            comment: "Quick AI: the action that asks the last question again for another answer.")
        let shortcut = KeyChord(keyCode: VirtualKey.ansiR, modifiers: [.command], characters: "r")
        let session = session

        return ActionDescriptor(
            id: ActionID(rawValue: "regenerate"), title: title, shortcut: shortcut
        ) { _ in
            session.regenerate()
            return .keepOpen
        }
    }

    private func newChatAction() -> ActionDescriptor {
        let title = String(
            localized: "New Chat", bundle: .module,
            comment: "Quick AI: the action that ends the conversation and starts an empty one.")
        let shortcut = KeyChord(keyCode: VirtualKey.ansiN, modifiers: [.command], characters: "n")
        let session = session

        return ActionDescriptor(
            id: ActionID(rawValue: "new-chat"), title: title, shortcut: shortcut
        ) { _ in
            session.newChat()
            return .keepOpen
        }
    }

    /// Without a shortcut: Esc stops a reply, and Esc is a key the launcher keeps for itself,
    /// so no action can have it (§4.1.3). `handleIntent` takes it instead.
    private func stopAction() -> ActionDescriptor {
        let title = String(
            localized: "Stop", bundle: .module,
            comment: "Quick AI: the action that stops the answer that is arriving.")
        let session = session

        return ActionDescriptor(id: ActionID(rawValue: "stop"), title: title) { _ in
            session.stop()
            return .keepOpen
        }
    }

    private func openSettingsAction() -> ActionDescriptor {
        let openSettings = openSettings

        return ActionDescriptor(
            id: ActionID(rawValue: "open-settings"), title: Self.openSettingsTitle
        ) { actionContext in
            // Settings is a window outside the panel.
            actionContext.closeLauncher()
            openSettings()
            return .closeLauncher
        }
    }

    // MARK: - Wording

    /// What is said under a reply that came to its end, or nil when it needs no remark.
    ///
    /// - Parameter answerWasKept: Whether the reply became part of the thread. One that
    ///   ended in the ordinary way and was still not kept had no text: the output limit was
    ///   used up before the model wrote its first word.
    private static func notice(for stopReason: AIStopReason, answerWasKept: Bool) -> String? {
        let cutOff = String(
            localized: "Answer cut off", bundle: .module,
            comment: "Quick AI: shown under an answer that ended at the length limit.")

        switch stopReason {
        case .endTurn, .other:
            return answerWasKept ? nil : cutOff
        case .maxTokens:
            return cutOff
        case .refusal(let category):
            guard let category else {
                return String(
                    localized: "Claude declined", bundle: .module,
                    comment: "Quick AI: shown when the model refused to answer.")
            }
            return String(
                localized: "Claude declined (\(category))", bundle: .module,
                comment:
                    "Quick AI: shown when the model refused to answer. The placeholder is the API's name for the reason, such as cyber."
            )
        case .contextWindowExceeded:
            return String(
                localized: "Thread too long, start a new one", bundle: .module,
                comment: "Quick AI: shown when the conversation no longer fits the model.")
        }
    }

    private static func isPutRightInSettings(_ error: AIError) -> Bool {
        switch error {
        case .missingCredentials, .invalidCredentials, .modelUnavailable:
            return true
        case .credentialsUnreadable, .permissionDenied, .rateLimited, .spendLimitReached,
            .billing, .overloaded, .server, .badRequest, .network, .malformedStream:
            return false
        }
    }

    /// "812 in · 240 out · 600 cached". "in" is everything the request sent, whether it was
    /// read from the prompt cache or not; "cached" is the part that was.
    private static func tokenLine(for usage: AIUsage) -> String {
        // The counts are whatever the server sent. Absurd ones would overflow `+`, which
        // traps, so a sum that does not fit stops at the largest number.
        var sent = usage.inputTokens
        for count in [usage.cacheReadInputTokens, usage.cacheCreationInputTokens] {
            let (sum, didOverflow) = sent.addingReportingOverflow(count)
            sent = didOverflow ? Int.max : sum
        }
        let input = sent.formatted()
        let output = usage.outputTokens.formatted()

        if usage.cacheReadInputTokens == 0 {
            return String(
                localized: "\(input) in · \(output) out", bundle: .module,
                comment:
                    "Quick AI: the tokens of a request, under its answer. The placeholders are the numbers of tokens sent and received."
            )
        }
        let cached = usage.cacheReadInputTokens.formatted()
        return String(
            localized: "\(input) in · \(output) out · \(cached) cached", bundle: .module,
            comment:
                "Quick AI: the tokens of a request, under its answer. The placeholders are the numbers of tokens sent, received, and read from the prompt cache."
        )
    }
}
