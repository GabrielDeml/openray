import Foundation

/// Quick AI's provider for the Claude API (docs/DESIGN.md §4.6.2). It speaks HTTP through a
/// `ByteStreamTransport` and uses no SDK.
public struct ClaudeProvider: AIProvider {
    public static let providerID = AIProviderID(rawValue: "anthropic")

    public static let haiku = AIModelID(rawValue: "claude-haiku-5-5")
    public static let sonnet = AIModelID(rawValue: "claude-sonnet-5-5")
    public static let opus = AIModelID(rawValue: "claude-opus-5-5")

    /// The models Quick AI offers, from the fastest to the most capable. The API lists many
    /// more; these are the ones the request was written for and checked against.
    public static let allowedModels = [haiku, sonnet, opus]

    /// How much of the list of models is read. A page of the real list is some tens of
    /// kilobytes.
    private static let modelsBodySizeLimit = 4 * 1024 * 1024
    /// How many pages of the list of models are asked for at most. One page holds a thousand
    /// models, so a second is not expected, and a server that kept promising more would
    /// otherwise be asked for ever.
    private static let modelsPageLimit = 5

    public let id = ClaudeProvider.providerID

    private let transport: any ByteStreamTransport
    private let apiKey: @Sendable () async throws -> APIKey?
    private let retryPolicy: RetryPolicy
    private let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameters:
    ///   - apiKey: Reads the key, or returns nil when none is stored. It is called when a
    ///     request is about to be sent and not before, so that a prompt from the Keychain
    ///     follows something the user did. The key is not kept beyond the request.
    ///   - sleep: Waits before a retry. Tests pass one that returns at once.
    public init(
        transport: any ByteStreamTransport,
        apiKey: @escaping @Sendable () async throws -> APIKey?,
        retryPolicy: RetryPolicy = RetryPolicy(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.transport = transport
        self.apiKey = apiKey
        self.retryPolicy = retryPolicy
        self.sleep = sleep
    }

    // MARK: - Asking

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        let (events, continuation) = AsyncThrowingStream.makeStream(
            of: AIEvent.self, throwing: (any Error).self)

        let producing = Task {
            do {
                try await sendUntilAnswered(request, yieldingTo: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        // The consumer has stopped reading or was cancelled. The task's cancellation reaches
        // the transport, which ends the request.
        continuation.onTermination = { _ in
            producing.cancel()
        }
        return events
    }

    /// What one attempt at a request got to before it ended. A retry is decided from this.
    private struct AttemptProgress {
        /// The `request-id` header of the response, for the log.
        var requestID: String?
        /// The wait the server asked for with a failed response.
        var retryAfter: Duration?
        var hasStreamedText = false
    }

    /// Sends the request, and sends it again after a failure that the retry policy lets pass.
    private func sendUntilAnswered(
        _ request: AIRequest,
        yieldingTo continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation
    ) async throws {
        // Written once. Every attempt sends these same bytes, so that an attempt which got as
        // far as filling the prompt cache has filled it for the next one.
        let body = try ClaudeRequest.messagesBody(for: request)
        // Read once as well. Asking the Keychain again before a retry could put a second
        // prompt in front of the user for one question.
        let key = try await readKey()
        let urlRequest = ClaudeRequest.messages(body: body, key: key)

        var retriesSoFar = 0
        while true {
            var progress = AttemptProgress()
            do {
                try await attempt(
                    urlRequest, model: request.model, yieldingTo: continuation, progress: &progress)
                return
            } catch {
                let failure = try ClaudeErrors.aiError(from: error)
                let requestID = progress.requestID ?? "none"
                let delay = retryPolicy.delay(
                    after: failure, retryAfter: progress.retryAfter, retriesSoFar: retriesSoFar,
                    hasStreamedText: progress.hasStreamedText)

                guard let delay else {
                    Log.ai.error(
                        "Request \(requestID, privacy: .public) failed: \(String(describing: failure))"
                    )
                    throw failure
                }
                Log.ai.info(
                    "Request \(requestID, privacy: .public) failed and is sent again: \(String(describing: failure))"
                )
                retriesSoFar += 1
                try await sleep(delay)
            }
        }
    }

    /// Sends the request once and passes on the events of its answer.
    private func attempt(
        _ urlRequest: URLRequest, model: AIModelID,
        yieldingTo continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation,
        progress: inout AttemptProgress
    ) async throws {
        let (response, chunks) = try await transport.open(urlRequest)
        let requestID = response.value(forHTTPHeaderField: "request-id")
        progress.requestID = requestID

        guard Self.isSuccess(response) else {
            progress.retryAfter = ClaudeErrors.retryAfter(in: response)
            let bodyData = try await Self.collect(chunks, upTo: ClaudeErrors.bodySizeLimit)
            throw ClaudeErrors.error(
                status: response.statusCode, body: ClaudeErrorBody(json: bodyData),
                retryAfter: progress.retryAfter, model: model)
        }

        var parser = SSEParser()
        var accumulator = ClaudeMessageAccumulator(requestedModel: model, requestID: requestID)

        for try await chunk in chunks {
            for serverSentEvent in parser.consume(chunk) {
                let streamEvent = try ClaudeStreamEvent(serverSentEvent)
                for event in try accumulator.apply(streamEvent) {
                    if case .textDelta = event {
                        progress.hasStreamedText = true
                    }
                    continuation.yield(event)

                    if case .finished(let stopReason, _) = event {
                        logFinished(
                            requestID: requestID, stopReason: stopReason,
                            skippedBlockTypes: accumulator.skippedBlockTypes)
                        return
                    }
                }
            }
        }
        throw AIError.malformedStream("the stream ended before the message did")
    }

    private func logFinished(
        requestID: String?, stopReason: AIStopReason, skippedBlockTypes: [String]
    ) {
        let requestID = requestID ?? "none"
        Log.ai.info(
            "Request \(requestID, privacy: .public) finished: \(String(describing: stopReason), privacy: .public)"
        )
        if !skippedBlockTypes.isEmpty {
            let types = skippedBlockTypes.joined(separator: ", ")
            Log.ai.notice(
                "Request \(requestID, privacy: .public) had content blocks of unknown kinds, which were left out: \(types, privacy: .public)"
            )
        }
    }

    // MARK: - Models

    public func availableModels() async throws -> [AIModelID] {
        do {
            let key = try await readKey()
            let listed = try await listedModelIDs(key: key)
            return Self.allowedModels.filter { model in
                listed.contains(model.rawValue)
            }
        } catch {
            // Cancellation is thrown on as it is. Everything else becomes an `AIError`.
            let failure = try ClaudeErrors.aiError(from: error)
            throw failure
        }
    }

    /// One page of `GET /v1/models`, as far as it is read.
    private struct ModelsPage: Decodable {
        struct Model: Decodable {
            var id: String
        }

        var data: [Model]
        var hasMore: Bool
        var lastID: String?

        enum CodingKeys: String, CodingKey {
            case data
            case hasMore = "has_more"
            case lastID = "last_id"
        }
    }

    /// The IDs of all models the key can use.
    private func listedModelIDs(key: APIKey) async throws -> Set<String> {
        var modelIDs: Set<String> = []
        var cursor: String?

        for _ in 0..<Self.modelsPageLimit {
            let page = try await modelsPage(after: cursor, key: key)
            for model in page.data {
                modelIDs.insert(model.id)
            }

            guard page.hasMore, let lastID = page.lastID else { break }
            cursor = lastID
        }
        return modelIDs
    }

    private func modelsPage(after cursor: String?, key: APIKey) async throws -> ModelsPage {
        let urlRequest = ClaudeRequest.modelsPage(after: cursor, key: key)
        let (response, chunks) = try await transport.open(urlRequest)

        guard Self.isSuccess(response) else {
            let bodyData = try await Self.collect(chunks, upTo: ClaudeErrors.bodySizeLimit)
            throw ClaudeErrors.error(
                status: response.statusCode, body: ClaudeErrorBody(json: bodyData),
                retryAfter: ClaudeErrors.retryAfter(in: response), model: nil)
        }

        let bodyData = try await Self.collect(chunks, upTo: Self.modelsBodySizeLimit)
        guard let page = try? JSONDecoder().decode(ModelsPage.self, from: bodyData) else {
            throw AIError.malformedStream("the list of models could not be read")
        }
        return page
    }

    // MARK: - Shared

    /// - Throws: `AIError.missingCredentials` when no key is stored, and
    ///   `AIError.credentialsUnreadable` when reading it failed.
    private func readKey() async throws -> APIKey {
        let key: APIKey?
        do {
            key = try await apiKey()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // What the store threw is not passed on. It is the store's to log, and nothing
            // that was near the key belongs in an error that ends up on screen.
            throw AIError.credentialsUnreadable
        }

        guard let key else {
            throw AIError.missingCredentials
        }
        return key
    }

    private static func isSuccess(_ response: HTTPURLResponse) -> Bool {
        (200..<300).contains(response.statusCode)
    }

    /// Reads a response body into memory, and stops reading at `limit` bytes.
    private static func collect(
        _ chunks: AsyncThrowingStream<[UInt8], any Error>, upTo limit: Int
    ) async throws -> Data {
        var body = Data()
        for try await chunk in chunks {
            body.append(contentsOf: chunk.prefix(limit - body.count))
            if body.count >= limit { break }
        }
        return body
    }
}
