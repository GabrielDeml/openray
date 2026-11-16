import Foundation

// What Quick AI needs from a model provider (docs/DESIGN.md §4.6.1). Claude is the only one
// built; the types name nothing of its API, so that a second provider is a second type.

public struct AIProviderID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct AIModelID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// How much work the model puts into a reply.
public enum AIEffort: String, Sendable, Codable, CaseIterable {
    case low, medium, high
}

/// A part of a reply that only its provider can read, kept to be sent back as it came. Claude's
/// thinking blocks with their signature are such parts. A provider leaves out the blocks of
/// another.
public struct ProviderOpaqueBlock: Sendable, Hashable {
    public let provider: AIProviderID
    /// The block as the provider wants it back, as JSON.
    public let json: Data

    public init(provider: AIProviderID, json: Data) {
        self.provider = provider
        self.json = json
    }
}

public enum AIContentBlock: Sendable, Hashable {
    case text(String)
    case opaque(ProviderOpaqueBlock)
}

public struct AIMessage: Sendable, Hashable {
    public enum Role: String, Sendable {
        case user, assistant
    }

    public let role: Role
    public let content: [AIContentBlock]

    public init(role: Role, content: [AIContentBlock]) {
        self.role = role
        self.content = content
    }
}

public struct AIRequest: Sendable {
    public var model: AIModelID
    public var system: String
    public var messages: [AIMessage]
    public var maxOutputTokens: Int
    /// nil leaves the choice to the provider.
    public var effort: AIEffort?

    public init(
        model: AIModelID, system: String, messages: [AIMessage], maxOutputTokens: Int,
        effort: AIEffort? = nil
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.maxOutputTokens = maxOutputTokens
        self.effort = effort
    }
}

/// The tokens of one request. The three input counts do not overlap: what was read from the
/// cache and what was written to it are not part of `inputTokens`.
public struct AIUsage: Sendable, Hashable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadInputTokens = 0
    public var cacheCreationInputTokens = 0

    public init(
        inputTokens: Int = 0, outputTokens: Int = 0, cacheReadInputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
    }
}

public enum AIStopReason: Sendable, Hashable {
    case endTurn
    case maxTokens
    /// The provider declined. The category is its own name for the reason and may be missing.
    case refusal(category: String?)
    case contextWindowExceeded
    /// A reason this version does not know, by the provider's name for it.
    case other(String)
}

public enum AIEvent: Sendable, Equatable {
    /// The provider has begun to answer.
    ///
    /// This can arrive a second time, when the provider gave up on an attempt and tried again.
    /// The reply then starts over: whatever `reasoning` said before no longer holds. A provider
    /// only tries again while no text has arrived, so no `textDelta` is ever taken back.
    case started(model: AIModelID, requestID: String?)
    /// Whether the model is thinking before it writes.
    case reasoning(active: Bool)
    case textDelta(String)
    /// The tokens counted so far, not those since the last event.
    case usage(AIUsage)
    /// The last event of a reply, with the message to keep as the assistant's turn.
    case finished(AIStopReason, assistant: AIMessage)
}

public enum AIError: Error, Sendable, Equatable {
    /// No key is stored.
    case missingCredentials
    /// A key may be stored, but it could not be read.
    case credentialsUnreadable
    /// The provider rejected the key.
    case invalidCredentials
    case permissionDenied(String)
    case rateLimited(retryAfter: Duration?)
    case spendLimitReached(String)
    case billing(String)
    case overloaded
    case server(status: Int, message: String)
    case badRequest(String)
    case modelUnavailable(AIModelID)
    case network(URLError.Code)
    /// The reply was not what the provider documents. The text says what was wrong and never
    /// quotes the reply.
    case malformedStream(String)
}

public protocol AIProvider: Sendable {
    var id: AIProviderID { get }

    /// The models the stored key can use. Asking is also how a key is checked.
    func availableModels() async throws -> [AIModelID]

    /// Sends the request and returns the reply as it arrives.
    ///
    /// The request is cancelled when the consumer stops reading or is cancelled itself. A
    /// cancelled stream ends with `CancellationError`; every other failure is an `AIError`.
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error>
}

/// One HTTP exchange whose response body is read as it arrives: `URLSession` in the app,
/// fixtures in the tests.
public protocol ByteStreamTransport: Sendable {
    /// Returns once the response's headers are in. Ending the stream early cancels the request.
    func open(_ request: URLRequest) async throws -> (
        HTTPURLResponse, AsyncThrowingStream<[UInt8], any Error>
    )
}
