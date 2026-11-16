import Foundation

/// Follows the events of one Messages API stream and says what each of them means for Quick AI
/// (docs/DESIGN.md §4.6.2). Along the way it builds the assistant's message, which the last
/// event hands over.
///
/// It reads no bytes and waits for nothing, so every stream the API can send is a test case.
struct ClaudeMessageAccumulator {
    /// A content block that has started and not ended.
    private enum OpenBlock {
        case text(String)
        /// The block's fields as they stand: those it started with, the thinking text and the
        /// signature replaced by what the deltas have brought.
        case thinking(fields: [String: Any])
        /// A block of a kind this version does not know. Its deltas are passed over.
        case unknown
    }

    /// The model the request asked for, named in the error when the API says it is unknown.
    private let requestedModel: AIModelID
    /// The `request-id` header of the response the stream belongs to.
    private let requestID: String?

    private var openBlocks: [Int: OpenBlock] = [:]
    /// The finished blocks of the assistant's message, in the order they ended.
    private var content: [AIContentBlock] = []
    private var usage = AIUsage()
    private var stopReason: AIStopReason?

    /// The kinds of the blocks that were left out of the message because this version does not
    /// know them. They are here to be logged.
    private(set) var skippedBlockTypes: [String] = []

    init(requestedModel: AIModelID, requestID: String?) {
        self.requestedModel = requestedModel
        self.requestID = requestID
    }

    /// Takes the next event of the stream and returns what it means, which is often nothing.
    ///
    /// - Throws: The `AIError` for an `error` event, and `AIError.malformedStream` for a
    ///   stream that does not follow the documented order.
    mutating func apply(_ event: ClaudeStreamEvent) throws -> [AIEvent] {
        switch event {
        case .messageStart(let model, let usageUpdate):
            usageUpdate.apply(to: &usage)
            return [
                .started(model: AIModelID(rawValue: model), requestID: requestID),
                .usage(usage),
            ]

        case .contentBlockStart(let index, let block):
            return start(block, at: index)

        case .contentBlockDelta(let index, let delta):
            return try add(delta, toBlockAt: index)

        case .contentBlockStop(let index):
            return try endBlock(at: index)

        case .messageDelta(let stopReasonName, let refusalCategory, let usageUpdate):
            usageUpdate.apply(to: &usage)
            if let stopReasonName {
                stopReason = Self.stopReason(
                    named: stopReasonName, refusalCategory: refusalCategory)
            }
            return [.usage(usage)]

        case .messageStop:
            guard let stopReason else {
                throw AIError.malformedStream("the message ended without a stop reason")
            }
            keepTextOfOpenBlocks()
            let assistant = AIMessage(role: .assistant, content: content)
            return [.finished(stopReason, assistant: assistant)]

        case .error(let body):
            throw ClaudeErrors.error(forStreamError: body, model: requestedModel)

        case .ignored:
            return []
        }
    }

    private mutating func start(_ block: ClaudeStreamEvent.Block, at index: Int) -> [AIEvent] {
        switch block {
        case .text(let text):
            openBlocks[index] = .text(text)
            return text.isEmpty ? [] : [.textDelta(text)]

        case .thinking(let fields):
            openBlocks[index] = .thinking(fields: fields)
            return [.reasoning(active: true)]

        case .unknown(let type):
            openBlocks[index] = .unknown
            skippedBlockTypes.append(type)
            return []
        }
    }

    private mutating func add(
        _ delta: ClaudeStreamEvent.Delta, toBlockAt index: Int
    ) throws -> [AIEvent] {
        guard let block = openBlocks[index] else {
            throw AIError.malformedStream(
                "a delta arrived for a content block that had not started")
        }

        switch (block, delta) {
        case (.text(let text), .text(let addition)):
            openBlocks[index] = .text(text + addition)
            return addition.isEmpty ? [] : [.textDelta(addition)]

        case (.thinking(var fields), .thinking(let addition)):
            let thinkingSoFar = fields["thinking"] as? String ?? ""
            fields["thinking"] = thinkingSoFar + addition
            openBlocks[index] = .thinking(fields: fields)
            return []

        case (.thinking(var fields), .signature(let signature)):
            // The signature arrives in one piece, just before the block ends.
            fields["signature"] = signature
            openBlocks[index] = .thinking(fields: fields)
            return []

        default:
            // A delta of an unknown kind, or one for a block of an unknown kind.
            return []
        }
    }

    private mutating func endBlock(at index: Int) throws -> [AIEvent] {
        guard let block = openBlocks.removeValue(forKey: index) else {
            throw AIError.malformedStream("a content block ended that had not started")
        }

        switch block {
        case .text(let text):
            // A block without text is left out: the API rejects a message that sends one back.
            if !text.isEmpty {
                content.append(.text(text))
            }
            return []

        case .thinking(let fields):
            // Sorted keys, so that the same block is the same bytes whenever it is written.
            // The prompt cache only holds for a history that does not change.
            guard
                let json = try? JSONSerialization.data(
                    withJSONObject: fields, options: [.sortedKeys])
            else {
                throw AIError.malformedStream("a thinking block could not be kept")
            }
            let opaque = ProviderOpaqueBlock(provider: ClaudeProvider.providerID, json: json)
            content.append(.opaque(opaque))
            return [.reasoning(active: false)]

        case .unknown:
            // Not kept. Its deltas were not understood, so what could be sent back would be
            // half a block, and the API would reject every later request of the thread.
            return []
        }
    }

    /// A text block that the message ended on without closing is kept all the same: the user
    /// has read it. A thinking block in that state has no signature yet and cannot be sent
    /// back, so it is dropped.
    private mutating func keepTextOfOpenBlocks() {
        for index in openBlocks.keys.sorted() {
            if case .text(let text) = openBlocks[index], !text.isEmpty {
                content.append(.text(text))
            }
        }
        openBlocks.removeAll()
    }

    private static func stopReason(named name: String, refusalCategory: String?) -> AIStopReason {
        switch name {
        case "end_turn":
            return .endTurn
        case "max_tokens":
            return .maxTokens
        case "refusal":
            return .refusal(category: refusalCategory)
        case "model_context_window_exceeded":
            return .contextWindowExceeded
        default:
            return .other(name)
        }
    }
}
