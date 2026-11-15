import Foundation
import Synchronization
import Testing

import OpenRayCore

private typealias Exchange = FakeByteStreamTransport.Exchange

/// The start of a reply up to its first words, for the tests in which something goes wrong
/// after that.
private let replyUpToFirstText = serverSentEvents([
    (
        name: "message_start",
        data:
            #"{"message":{"model":"claude-haiku-5-5","usage":{"input_tokens":3,"output_tokens":1}}}"#
    ),
    (name: "content_block_start", data: #"{"index":0,"content_block":{"type":"text","text":""}}"#),
    (
        name: "content_block_delta",
        data: #"{"index":0,"delta":{"type":"text_delta","text":"The capital"}}"#
    ),
])

private let overloadedEvent = serverSentEvents([
    (
        name: "error",
        data: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
    )
])

// MARK: - HTTP errors

/// Each failed response of `Fixtures/claude/errors` and the error Quick AI makes of it.
@Suite(.timeLimit(.minutes(1))) struct ClaudeProviderHTTPErrorTests {
    /// Asks one question, has it answered with a failed response, and returns the error the
    /// stream ended with.
    private func failure(
        status: Int, fixture: String?, headers: [String: String] = [:]
    ) async throws -> AIError? {
        var body: [UInt8] = []
        if let fixture {
            body = try ClaudeFixture.errorBody(fixture)
        }
        let transport = FakeByteStreamTransport([
            .failure(status: status, body: body, headers: headers)
        ])
        let provider = makeProvider(transport: transport, retryPolicy: noRetries)

        let outcome = await readToEnd(provider.stream(makeRequest()))

        #expect(outcome.events.isEmpty)
        return outcome.error as? AIError
    }

    @Test func rejectedKey() async throws {
        #expect(try await failure(status: 401, fixture: "401.json") == .invalidCredentials)
    }

    @Test func modelTheKeyCannotUse() async throws {
        let error = try await failure(status: 404, fixture: "404.json")

        #expect(error == .modelUnavailable(ClaudeProvider.haiku))
    }

    @Test func rateLimitWithTheTimeToWait() async throws {
        let error = try await failure(
            status: 429, fixture: "429-rate-limit.json", headers: ["retry-after": "12"])

        #expect(error == .rateLimited(retryAfter: .seconds(12)))
    }

    @Test func rateLimitWithoutTheTimeToWait() async throws {
        let error = try await failure(status: 429, fixture: "429-rate-limit.json")

        #expect(error == .rateLimited(retryAfter: nil))
    }

    // A header can say anything. "1e30" is a number, and one that `Duration` traps on; a
    // date is allowed by HTTP and never sent by the API.
    @Test(arguments: [
        "1e30", "1e300", "86401", "inf", "nan", "-1", "", "Sun, 15 Nov 2026 12:00:00 GMT",
    ])
    func timeToWaitThatMakesNoSenseIsPassedOver(_ retryAfter: String) async throws {
        let error = try await failure(
            status: 429, fixture: "429-rate-limit.json", headers: ["retry-after": retryAfter])

        #expect(error == .rateLimited(retryAfter: nil))
    }

    @Test func timeToWaitMayBeAFractionAndHaveSpaceAroundIt() async throws {
        let error = try await failure(
            status: 429, fixture: "429-rate-limit.json", headers: ["retry-after": " 1.5 "])

        #expect(error == .rateLimited(retryAfter: .milliseconds(1500)))
    }

    @Test func usageTiersMonthlyCap() async throws {
        let error = try await failure(status: 429, fixture: "429-tier-cap.json")

        guard case .spendLimitReached(let message) = error else {
            Issue.record("Expected a spend limit, found \(String(describing: error))")
            return
        }
        #expect(message.hasPrefix("You have reached your API usage limits"))
    }

    @Test func spendLimitTheUserSet() async throws {
        let organisation = try await failure(status: 400, fixture: "400-spend-limit.json")
        let workspace = try await failure(status: 400, fixture: "400-workspace-spend-limit.json")

        let organisationMessage =
            "You have reached your specified API usage limits. You will regain access on 2026-12-01 at 00:00 UTC."
        let workspaceMessage =
            "You have reached your specified workspace API usage limits. You will regain access on 2026-12-01 at 00:00 UTC."
        #expect(organisation == .spendLimitReached(organisationMessage))
        #expect(workspace == .spendLimitReached(workspaceMessage))
    }

    @Test func invalidRequest() async throws {
        let error = try await failure(status: 400, fixture: "400-invalid-request.json")

        let message =
            "max_tokens: 200000 > 128000, which is the maximum allowed number of output tokens for claude-haiku-5-5"
        #expect(error == .badRequest(message))
    }

    @Test func billingProblem() async throws {
        let error = try await failure(status: 402, fixture: "402.json")

        #expect(error == .billing("Your credit balance is too low to access the Anthropic API."))
    }

    @Test func missingPermission() async throws {
        let error = try await failure(status: 403, fixture: "403.json")

        let message = "Your API key does not have permission to use the specified resource."
        #expect(error == .permissionDenied(message))
    }

    @Test func requestThatIsTooLarge() async throws {
        let error = try await failure(status: 413, fixture: "413.json")

        #expect(error == .badRequest("Request exceeds the maximum allowed number of bytes."))
    }

    @Test func requestTheServerWaitedTooLongFor() async throws {
        #expect(try await failure(status: 408, fixture: nil) == .network(.timedOut))
    }

    @Test func faultOfTheServers() async throws {
        let error = try await failure(status: 500, fixture: "500.json")

        #expect(error == .server(status: 500, message: "Internal server error"))
    }

    @Test func overloadedServer() async throws {
        #expect(try await failure(status: 529, fixture: "529.json") == .overloaded)
    }

    // The app's transport follows no redirect, so one arrives as the response it is. Nothing
    // of it is shown.
    @Test func redirectIsAFaultOfTheServers() async throws {
        let error = try await failure(
            status: 307, fixture: "not-json.html",
            headers: ["location": "https://example.com/v1/messages"])

        guard case .server(status: 307, let message) = error else {
            Issue.record("Expected a server error, found \(String(describing: error))")
            return
        }
        #expect(message.contains("307"))
        #expect(!message.contains("example.com"))
    }

    @Test func bodyThatIsNotTheAPIsIsNeverShown() async throws {
        let error = try await failure(status: 502, fixture: "not-json.html")

        guard case .server(status: 502, let message) = error else {
            Issue.record("Expected a server error, found \(String(describing: error))")
            return
        }
        #expect(message.contains("502"))
        #expect(!message.contains("Bad Gateway"))
        #expect(!message.contains("<"))
    }

    @Test func statusWithoutABodyIsEnough() async throws {
        #expect(try await failure(status: 401, fixture: nil) == .invalidCredentials)
        #expect(try await failure(status: 529, fixture: nil) == .overloaded)
    }

    @Test func onlyTheStartOfAnEndlessErrorPageIsRead() async throws {
        // A megabyte in chunks of 4 KB, on a connection that then stays open. Reading stops
        // at the limit, or this test would wait for an end that does not come.
        let chunk = [UInt8](repeating: UInt8(ascii: "x"), count: 4096)
        let page = Exchange(
            status: 503, chunks: Array(repeating: chunk, count: 256), staysOpen: true)
        let provider = makeProvider(
            transport: FakeByteStreamTransport([page]), retryPolicy: noRetries)

        let outcome = await readToEnd(provider.stream(makeRequest()))

        guard case .server(status: 503, _) = outcome.error as? AIError else {
            Issue.record("Expected a server error, found \(String(describing: outcome.error))")
            return
        }
    }
}

// MARK: - Retries

@Suite(.timeLimit(.minutes(1))) struct ClaudeProviderRetryTests {
    private let sleeps = SleepRecorder()

    private func overloaded() throws -> Exchange {
        .failure(status: 529, body: try ClaudeFixture.errorBody("529.json"))
    }

    private func plainTextReply() throws -> Exchange {
        .reply([try ClaudeFixture.bytes("plain-text.sse")], requestID: "req_second")
    }

    @Test func failureThatMayPassIsRetriedTwiceAndThenReported() async throws {
        let transport = FakeByteStreamTransport([
            try overloaded(), try overloaded(), try overloaded(),
        ])
        let provider = makeProvider(transport: transport, sleeps: sleeps)

        let outcome = await readToEnd(provider.stream(makeRequest()))

        #expect(outcome.error as? AIError == .overloaded)
        #expect(outcome.events.isEmpty)
        #expect(transport.requests.count == 3)
        // With the jitter at its upper end: half a second, then twice that.
        #expect(sleeps.durations == [.milliseconds(500), .seconds(1)])
    }

    @Test func retrySendsTheSameBytes() async throws {
        let transport = FakeByteStreamTransport([
            try overloaded(), try overloaded(), try plainTextReply(),
        ])
        let provider = makeProvider(transport: transport, sleeps: sleeps)

        let outcome = await readToEnd(provider.stream(makeRequest()))

        #expect(outcome.finished?.reason == .endTurn)
        let requests = transport.requests
        #expect(requests.count == 3)
        let firstBody = try #require(requests.first?.httpBody)
        for request in requests {
            #expect(request.httpBody == firstBody)
            #expect(request.allHTTPHeaderFields == requests.first?.allHTTPHeaderFields)
            #expect(request.url == requests.first?.url)
        }
    }

    @Test func shortRetryAfterIsWaitedFor() async throws {
        let rateLimited = Exchange.failure(
            status: 429, body: try ClaudeFixture.errorBody("429-rate-limit.json"),
            headers: ["retry-after": "3"])
        let transport = FakeByteStreamTransport([rateLimited, try plainTextReply()])
        let provider = makeProvider(transport: transport, sleeps: sleeps)

        let outcome = await readToEnd(provider.stream(makeRequest()))

        #expect(outcome.error == nil)
        #expect(outcome.finished?.reason == .endTurn)
        #expect(sleeps.durations == [.seconds(3)])
    }

    @Test func longRetryAfterIsReportedAtOnce() async throws {
        let rateLimited = Exchange.failure(
            status: 429, body: try ClaudeFixture.errorBody("429-rate-limit.json"),
            headers: ["retry-after": "30"])
        let transport = FakeByteStreamTransport([rateLimited, try plainTextReply()])
        let provider = makeProvider(transport: transport, sleeps: sleeps)

        let outcome = await readToEnd(provider.stream(makeRequest()))

        #expect(outcome.error as? AIError == .rateLimited(retryAfter: .seconds(30)))
        #expect(transport.requests.count == 1)
        #expect(sleeps.durations.isEmpty)
    }

    @Test func replyStartsOverAfterARetry() async throws {
        let givenUpWhileThinking = Exchange.reply(
            [try ClaudeFixture.bytes("overloaded-mid-stream.sse")], requestID: "req_first")
        let transport = FakeByteStreamTransport([givenUpWhileThinking, try plainTextReply()])
        let provider = makeProvider(transport: transport, sleeps: sleeps)

        let outcome = await readToEnd(provider.stream(makeRequest()))

        #expect(outcome.error == nil)
        let firstUsage = AIUsage(inputTokens: 25, outputTokens: 1)
        #expect(
            outcome.events.prefix(5) == [
                .started(model: ClaudeProvider.haiku, requestID: "req_first"),
                .usage(firstUsage),
                .reasoning(active: true),
                .started(model: ClaudeProvider.haiku, requestID: "req_second"),
                .usage(firstUsage),
            ])
        #expect(outcome.finished?.reason == .endTurn)
        #expect(sleeps.durations == [.milliseconds(500)])
    }

    @Test func nothingIsRetriedOnceTextHasArrived() async throws {
        let givenUpAfterText = Exchange.reply([replyUpToFirstText, overloadedEvent])
        let transport = FakeByteStreamTransport([givenUpAfterText, try plainTextReply()])
        let provider = makeProvider(transport: transport, sleeps: sleeps)

        let outcome = await readToEnd(provider.stream(makeRequest()))

        // The words that had arrived were delivered, and the error after them.
        #expect(outcome.text == "The capital")
        #expect(outcome.error as? AIError == .overloaded)
        #expect(transport.requests.count == 1)
        #expect(sleeps.durations.isEmpty)
    }

    @Test func connectionLostAfterTextIsNotRetried() async throws {
        var lostAfterText = Exchange.reply([replyUpToFirstText])
        lostAfterText.streamError = URLError(.networkConnectionLost)
        let transport = FakeByteStreamTransport([lostAfterText, try plainTextReply()])
        let provider = makeProvider(transport: transport, sleeps: sleeps)

        let outcome = await readToEnd(provider.stream(makeRequest()))

        #expect(outcome.text == "The capital")
        #expect(outcome.error as? AIError == .network(.networkConnectionLost))
        #expect(transport.requests.count == 1)
    }

    @Test func beingOfflineFailsAtOnce() async throws {
        let offline = Exchange(openError: URLError(.notConnectedToInternet))
        let transport = FakeByteStreamTransport([offline, try plainTextReply()])
        let provider = makeProvider(transport: transport, sleeps: sleeps)

        let outcome = await readToEnd(provider.stream(makeRequest()))

        #expect(outcome.error as? AIError == .network(.notConnectedToInternet))
        #expect(transport.requests.count == 1)
        #expect(sleeps.durations.isEmpty)
    }

    @Test func rejectedKeyIsNotRetried() async throws {
        let rejected = Exchange.failure(status: 401, body: try ClaudeFixture.errorBody("401.json"))
        let transport = FakeByteStreamTransport([rejected, try plainTextReply()])
        let provider = makeProvider(transport: transport, sleeps: sleeps)

        let outcome = await readToEnd(provider.stream(makeRequest()))

        #expect(outcome.error as? AIError == .invalidCredentials)
        #expect(transport.requests.count == 1)
    }
}

// MARK: - Timeouts and cancellation

@Suite(.timeLimit(.minutes(1))) struct ClaudeProviderTimeoutAndCancellationTests {
    private func plainTextReply() throws -> Exchange {
        .reply([try ClaudeFixture.bytes("plain-text.sse")])
    }

    @Test func timeoutBeforeTheResponseIsRetried() async throws {
        let timedOut = Exchange(openError: URLError(.timedOut))
        let transport = FakeByteStreamTransport([timedOut, try plainTextReply()])
        let provider = makeProvider(transport: transport)

        let outcome = await readToEnd(provider.stream(makeRequest()))

        #expect(outcome.error == nil)
        #expect(outcome.finished?.reason == .endTurn)
        #expect(transport.requests.count == 2)
    }

    @Test func timeoutBeforeTheResponseIsReportedWhenItPersists() async throws {
        let timedOut = Exchange(openError: URLError(.timedOut))
        let transport = FakeByteStreamTransport([timedOut, timedOut, timedOut])
        let provider = makeProvider(transport: transport)

        let outcome = await readToEnd(provider.stream(makeRequest()))

        #expect(outcome.error as? AIError == .network(.timedOut))
        #expect(transport.requests.count == 3)
    }

    @Test func timeoutBetweenChunksBeforeAnyTextIsRetried() async throws {
        // The server goes quiet while the model is thinking: the fixture up to its error event,
        // and then nothing.
        let fixture = String(
            decoding: try ClaudeFixture.bytes("overloaded-mid-stream.sse"), as: UTF8.self)
        let errorEvent = try #require(fixture.range(of: "event: error"))
        var stalled = Exchange.reply([Array(fixture[..<errorEvent.lowerBound].utf8)])
        stalled.streamError = URLError(.timedOut)
        let transport = FakeByteStreamTransport([stalled, try plainTextReply()])
        let provider = makeProvider(transport: transport)

        let outcome = await readToEnd(provider.stream(makeRequest()))

        #expect(outcome.error == nil)
        #expect(outcome.finished?.reason == .endTurn)
        #expect(transport.requests.count == 2)
    }

    @Test func timeoutBetweenChunksAfterTextIsReported() async throws {
        var stalled = Exchange.reply([replyUpToFirstText])
        stalled.streamError = URLError(.timedOut)
        let transport = FakeByteStreamTransport([stalled, try plainTextReply()])
        let provider = makeProvider(transport: transport)

        let outcome = await readToEnd(provider.stream(makeRequest()))

        #expect(outcome.text == "The capital")
        #expect(outcome.error as? AIError == .network(.timedOut))
        #expect(transport.requests.count == 1)
    }

    @Test func consumerThatStopsReadingEndsTheRequest() async throws {
        var unfinished = Exchange.reply([replyUpToFirstText])
        unfinished.staysOpen = true
        let transport = FakeByteStreamTransport([unfinished])
        let provider = makeProvider(transport: transport)

        for try await event in provider.stream(makeRequest()) {
            if case .textDelta = event { break }
        }

        // The transport's stream is ended from the reading side. Were it not, nothing would
        // arrive here and the test would run into its time limit.
        var cancellations = transport.streamCancellations.makeAsyncIterator()
        await cancellations.next()
        #expect(transport.requests.count == 1)
    }

    @Test func cancellingTheConsumerEndsTheRequestWithoutAnAIError() async throws {
        var unfinished = Exchange.reply([replyUpToFirstText])
        unfinished.staysOpen = true
        let transport = FakeByteStreamTransport([unfinished])
        let provider = makeProvider(transport: transport)
        let (firstText, firstTextContinuation) = AsyncStream.makeStream(of: Void.self)

        let consumer = Task {
            var outcome = StreamOutcome()
            do {
                for try await event in provider.stream(makeRequest()) {
                    outcome.events.append(event)
                    if case .textDelta = event {
                        firstTextContinuation.yield()
                    }
                }
            } catch {
                outcome.error = error
            }
            return outcome
        }
        for await _ in firstText { break }
        consumer.cancel()
        let outcome = await consumer.value

        // A cancelled consumer sees its stream end, or `CancellationError`, and never a
        // failure that would be shown as one.
        #expect(!(outcome.error is AIError))
        #expect(outcome.text == "The capital")

        var cancellations = transport.streamCancellations.makeAsyncIterator()
        await cancellations.next()
        #expect(transport.requests.count == 1)
    }

    @Test func cancelledRequestIsNotANetworkError() async throws {
        let cancelledAtOpen = Exchange(openError: URLError(.cancelled))
        var cancelledWhileStreaming = Exchange.reply([replyUpToFirstText])
        cancelledWhileStreaming.streamError = URLError(.cancelled)
        var cancelledTask = Exchange.reply([replyUpToFirstText])
        cancelledTask.streamError = CancellationError()

        for exchange in [cancelledAtOpen, cancelledWhileStreaming, cancelledTask] {
            let transport = FakeByteStreamTransport([exchange, try plainTextReply()])
            let provider = makeProvider(transport: transport)

            let outcome = await readToEnd(provider.stream(makeRequest()))

            #expect(outcome.error is CancellationError)
            #expect(transport.requests.count == 1)
        }
    }
}

// MARK: - Credentials

@Suite(.timeLimit(.minutes(1))) struct ClaudeProviderCredentialTests {
    private struct KeychainFailure: Error {}

    /// Counts how often the provider asked for the key.
    private final class KeyReads: Sendable {
        private let counted = Mutex(0)

        var count: Int {
            counted.withLock { $0 }
        }

        func countOne() {
            counted.withLock { $0 += 1 }
        }
    }

    @Test func withoutAKeyNothingIsSent() async throws {
        let transport = FakeByteStreamTransport([
            .reply([try ClaudeFixture.bytes("plain-text.sse")])
        ])
        let provider = ClaudeProvider(transport: transport, apiKey: { nil })

        let outcome = await readToEnd(provider.stream(makeRequest()))

        #expect(outcome.error as? AIError == .missingCredentials)
        #expect(outcome.events.isEmpty)
        #expect(transport.requests.isEmpty)
        await #expect(throws: AIError.missingCredentials) {
            try await provider.availableModels()
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func keyThatCannotBeReadIsReportedAsSuch() async throws {
        let transport = FakeByteStreamTransport([])
        let provider = ClaudeProvider(transport: transport, apiKey: { throw KeychainFailure() })

        let outcome = await readToEnd(provider.stream(makeRequest()))

        #expect(outcome.error as? AIError == .credentialsUnreadable)
        #expect(transport.requests.isEmpty)
        await #expect(throws: AIError.credentialsUnreadable) {
            try await provider.availableModels()
        }
    }

    @Test func keyIsReadOnlyWhenARequestIsSent() async throws {
        let reads = KeyReads()
        let unavailable = Exchange.failure(
            status: 529, body: try ClaudeFixture.errorBody("529.json"))
        let reply = Exchange.reply([try ClaudeFixture.bytes("plain-text.sse")])
        let provider = ClaudeProvider(
            transport: FakeByteStreamTransport([unavailable, reply]),
            apiKey: {
                reads.countOne()
                return APIKey(testKeyText)
            },
            sleep: { _ in })

        #expect(reads.count == 0)
        let outcome = await readToEnd(provider.stream(makeRequest()))

        // Once for the question, and not again for its retry.
        #expect(outcome.finished != nil)
        #expect(reads.count == 1)
    }

    @Test func noWayOfPrintingAKeyShowsIt() {
        let key = APIKey(testKeyText)
        var dumped = ""
        dump(key, to: &dumped)
        var dumpedInside = ""
        dump(["key": key], to: &dumpedInside)

        let printed = [
            "\(key)", String(describing: key), String(reflecting: key), key.description,
            key.debugDescription, dumped, dumpedInside, String(describing: [key]),
            String(reflecting: Optional(key)),
        ]
        for text in printed {
            #expect(!text.contains(testKeyText))
            #expect(!text.contains("not-a-real-key"))
        }
        #expect("\(key)" == "sk-ant-…<redacted>")
        #expect(Mirror(reflecting: key).children.isEmpty)
    }

    @Test func noErrorOfAFailedRequestShowsTheKey() async throws {
        let failures: [Exchange] = [
            .failure(status: 401, body: try ClaudeFixture.errorBody("401.json")),
            .failure(status: 403, body: try ClaudeFixture.errorBody("403.json")),
            .failure(status: 400, body: try ClaudeFixture.errorBody("400-invalid-request.json")),
            .failure(status: 502, body: try ClaudeFixture.errorBody("not-json.html")),
            Exchange(openError: URLError(.notConnectedToInternet)),
            .reply([Array("event: message_start\ndata: {\n\n".utf8)]),
        ]

        for failure in failures {
            let provider = makeProvider(
                transport: FakeByteStreamTransport([failure]), retryPolicy: noRetries)

            let outcome = await readToEnd(provider.stream(makeRequest()))

            let error = try #require(outcome.error)
            let printed = [
                String(describing: error), String(reflecting: error), error.localizedDescription,
            ]
            for text in printed {
                #expect(!text.contains(testKeyText))
            }
        }
    }

    @Test func adminKeysAreRecognised() {
        #expect(APIKey("sk-ant-admin01-abcdef").isAdminKey)
        #expect(!APIKey("sk-ant-api03-abcdef").isAdminKey)
        #expect(!APIKey("").isAdminKey)
    }
}

// MARK: - Models

@Suite(.timeLimit(.minutes(1))) struct ClaudeProviderModelTests {
    /// A page of `GET /v1/models` with the fields the provider reads and a few it does not.
    private func modelsPage(_ ids: [String], hasMore: Bool = false) throws -> Exchange {
        var models: [[String: Any]] = []
        for id in ids {
            models.append(["type": "model", "id": id, "display_name": id, "lifecycle": "active"])
        }
        let page: [String: Any] = [
            "data": models, "has_more": hasMore,
            "first_id": ids.first ?? NSNull(), "last_id": ids.last ?? NSNull(),
        ]
        let body = try JSONSerialization.data(withJSONObject: page)
        return Exchange(headers: ["request-id": "req_models"], chunks: [[UInt8](body)])
    }

    @Test func allowedModelsTheKeyCanUseInTheOrderTheyAreOffered() async throws {
        let listed = [
            "claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5", "claude-haiku-5-5",
            "claude-haiku-4-5",
        ]
        let transport = FakeByteStreamTransport([try modelsPage(listed)])
        let provider = makeProvider(transport: transport)

        let models = try await provider.availableModels()

        #expect(models == [ClaudeProvider.haiku, ClaudeProvider.opus])
        #expect(
            ClaudeProvider.allowedModels.map(\.rawValue) == [
                "claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5",
            ])
    }

    @Test func requestForTheListCarriesTheKeyInItsHeaderOnly() async throws {
        let transport = FakeByteStreamTransport([try modelsPage([])])
        let provider = makeProvider(transport: transport)

        #expect(try await provider.availableModels().isEmpty)

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
        #expect(
            request.allHTTPHeaderFields == [
                "x-api-key": testKeyText, "anthropic-version": "2026-10-21",
            ])
    }

    @Test func listInSeveralPagesIsReadToItsEnd() async throws {
        let transport = FakeByteStreamTransport([
            try modelsPage(["claude-opus-5-5", "claude-sonnet-5"], hasMore: true),
            try modelsPage(["claude-haiku-5-5"]),
        ])
        let provider = makeProvider(transport: transport)

        let models = try await provider.availableModels()

        #expect(models == [ClaudeProvider.haiku, ClaudeProvider.opus])
        #expect(transport.requests.count == 2)
        let secondURL = transport.requests.last?.url?.absoluteString
        #expect(
            secondURL == "https://api.anthropic.com/v1/models?limit=1000&after_id=claude-sonnet-5")
    }

    @Test func listThatNeverEndsIsGivenUpOn() async throws {
        var pages: [Exchange] = []
        for _ in 0..<50 {
            pages.append(try modelsPage(["claude-haiku-5-5"], hasMore: true))
        }
        let transport = FakeByteStreamTransport(pages)
        let provider = makeProvider(transport: transport)

        let models = try await provider.availableModels()

        #expect(models == [ClaudeProvider.haiku])
        #expect(transport.requests.count < 10)
    }

    @Test func rejectedKeyAndAMissingPermissionAreToldApart() async throws {
        let rejected = Exchange.failure(status: 401, body: try ClaudeFixture.errorBody("401.json"))
        let forbidden = Exchange.failure(status: 403, body: try ClaudeFixture.errorBody("403.json"))
        let provider = makeProvider(transport: FakeByteStreamTransport([rejected, forbidden]))

        await #expect(throws: AIError.invalidCredentials) {
            try await provider.availableModels()
        }
        let message = "Your API key does not have permission to use the specified resource."
        await #expect(throws: AIError.permissionDenied(message)) {
            try await provider.availableModels()
        }
    }

    @Test func otherFailuresAreReportedAsTheyAreForAQuestion() async throws {
        let offline = Exchange(openError: URLError(.notConnectedToInternet))
        let overloaded = Exchange.failure(
            status: 529, body: try ClaudeFixture.errorBody("529.json"))
        let notAList = Exchange(chunks: [Array("<html></html>".utf8)])
        let transport = FakeByteStreamTransport([offline, overloaded, notAList])
        let provider = makeProvider(transport: transport)

        await #expect(throws: AIError.network(.notConnectedToInternet)) {
            try await provider.availableModels()
        }
        // The list is asked for once. Whoever pressed the button can press it again.
        await #expect(throws: AIError.overloaded) {
            try await provider.availableModels()
        }
        await #expect(throws: AIError.malformedStream("the list of models could not be read")) {
            try await provider.availableModels()
        }
        #expect(transport.requests.count == 3)
    }
}
