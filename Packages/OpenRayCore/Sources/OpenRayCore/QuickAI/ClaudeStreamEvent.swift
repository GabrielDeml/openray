import Foundation

/// The token counts in one event of a stream. The API leaves out the counts an event has
/// nothing new to say about, and the ones it sends are totals.
struct ClaudeUsageUpdate: Decodable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadInputTokens: Int?
    var cacheCreationInputTokens: Int?

    /// Replaces the counts this update has and leaves the others as they are.
    func apply(to usage: inout AIUsage) {
        if let inputTokens {
            usage.inputTokens = inputTokens
        }
        if let outputTokens {
            usage.outputTokens = outputTokens
        }
        if let cacheReadInputTokens {
            usage.cacheReadInputTokens = cacheReadInputTokens
        }
        if let cacheCreationInputTokens {
            usage.cacheCreationInputTokens = cacheCreationInputTokens
        }
    }
}

/// One event of a Messages API stream, with what Quick AI reads from it
/// (docs/DESIGN.md §4.6.2).
enum ClaudeStreamEvent {
    /// A content block as the event that starts it describes it.
    enum Block {
        /// A text block and the text it starts with, which has always been empty.
        case text(String)
        /// A `thinking` or `redacted_thinking` block with every field it came with, known to
        /// this version or not. The block has to go back to the API as it was.
        case thinking(fields: [String: Any])
        /// A kind of block this version does not know.
        case unknown(type: String)
    }

    enum Delta {
        case text(String)
        case thinking(String)
        case signature(String)
        /// A kind of delta this version does not know.
        case unknown
    }

    case messageStart(model: String, usage: ClaudeUsageUpdate)
    case contentBlockStart(index: Int, block: Block)
    case contentBlockDelta(index: Int, delta: Delta)
    case contentBlockStop(index: Int)
    case messageDelta(stopReason: String?, refusalCategory: String?, usage: ClaudeUsageUpdate)
    case messageStop
    case error(ClaudeErrorBody)
    /// A `ping`, or a kind of event that was added to the API after this was written. The
    /// documentation asks clients to pass over those.
    case ignored

    /// Reads a server-sent event of the stream.
    ///
    /// The API names every event twice, in the `event` field and in the `type` of its data.
    /// The field decides here, as it does in Anthropic's own SDKs, so the data of an event
    /// that is passed over is never looked at.
    ///
    /// - Throws: `AIError.malformedStream` when the data of a known event cannot be read.
    init(_ serverSentEvent: ServerSentEvent) throws {
        guard let name = serverSentEvent.event else {
            self = .ignored
            return
        }
        let data = Data(serverSentEvent.data.utf8)

        switch name {
        case "message_start":
            let payload = try Self.decode(MessageStartPayload.self, from: data, of: name)
            let usage = payload.message.usage ?? ClaudeUsageUpdate()
            self = .messageStart(model: payload.message.model, usage: usage)

        case "content_block_start":
            let payload = try Self.decode(ContentBlockStartPayload.self, from: data, of: name)
            let block: Block
            switch payload.contentBlock.type {
            case "text":
                block = .text(payload.contentBlock.text ?? "")
            case "thinking", "redacted_thinking":
                block = .thinking(fields: try Self.contentBlockFields(in: data, of: name))
            default:
                block = .unknown(type: payload.contentBlock.type)
            }
            self = .contentBlockStart(index: payload.index, block: block)

        case "content_block_delta":
            let payload = try Self.decode(ContentBlockDeltaPayload.self, from: data, of: name)
            let delta: Delta
            switch payload.delta.type {
            case "text_delta":
                delta = .text(payload.delta.text ?? "")
            case "thinking_delta":
                delta = .thinking(payload.delta.thinking ?? "")
            case "signature_delta":
                delta = .signature(payload.delta.signature ?? "")
            default:
                delta = .unknown
            }
            self = .contentBlockDelta(index: payload.index, delta: delta)

        case "content_block_stop":
            let payload = try Self.decode(ContentBlockStopPayload.self, from: data, of: name)
            self = .contentBlockStop(index: payload.index)

        case "message_delta":
            let payload = try Self.decode(MessageDeltaPayload.self, from: data, of: name)
            self = .messageDelta(
                stopReason: payload.delta.stopReason,
                refusalCategory: payload.delta.stopDetails?.category,
                usage: payload.usage ?? ClaudeUsageUpdate())

        case "message_stop":
            self = .messageStop

        case "error":
            guard let body = ClaudeErrorBody(json: data) else {
                throw Self.unreadableData(of: name)
            }
            self = .error(body)

        default:
            self = .ignored
        }
    }

    // The data of each event, as far as it is read. The names follow the API's, in camel case.

    private struct MessageStartPayload: Decodable {
        struct Message: Decodable {
            var model: String
            var usage: ClaudeUsageUpdate?
        }

        var message: Message
    }

    private struct ContentBlockStartPayload: Decodable {
        struct ContentBlock: Decodable {
            var type: String
            var text: String?
        }

        var index: Int
        var contentBlock: ContentBlock
    }

    private struct ContentBlockDeltaPayload: Decodable {
        struct Delta: Decodable {
            var type: String
            var text: String?
            var thinking: String?
            var signature: String?
        }

        var index: Int
        var delta: Delta
    }

    private struct ContentBlockStopPayload: Decodable {
        var index: Int
    }

    private struct MessageDeltaPayload: Decodable {
        struct Delta: Decodable {
            struct StopDetails: Decodable {
                var category: String?
            }

            var stopReason: String?
            var stopDetails: StopDetails?
        }

        var delta: Delta
        var usage: ClaudeUsageUpdate?
    }

    private static func decode<Payload: Decodable>(
        _ type: Payload.Type, from data: Data, of eventName: String
    ) throws -> Payload {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw unreadableData(of: eventName)
        }
    }

    /// The `content_block` object of a `content_block_start` event with all of its fields.
    /// `Decodable` keeps only the fields a type declares, and a thinking block has to be sent
    /// back with every one it had.
    private static func contentBlockFields(
        in data: Data, of eventName: String
    ) throws -> [String: Any] {
        let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let fields = event?["content_block"] as? [String: Any] else {
            throw unreadableData(of: eventName)
        }
        return fields
    }

    /// The error for an event whose data is not what the API documents. It names the kind of
    /// event and nothing of the data: a decoder's own error quotes what it read, which can be
    /// part of a reply.
    private static func unreadableData(of eventName: String) -> AIError {
        .malformedStream("the data of a \(eventName) event could not be read")
    }
}
