import Foundation
import Testing

import OpenRayCore

/// The fixtures of `Fixtures/claude`, read through the provider. Every test runs three times,
/// with the fixture's bytes arriving whole, one at a time and in random chunks: what comes out
/// must not depend on how the network cut them up.
@Suite(.timeLimit(.minutes(1))) struct ClaudeStreamTests {
    private let haiku = ClaudeProvider.haiku
    private let firstUsage = AIUsage(inputTokens: 25, outputTokens: 1)

    /// Sends one question and answers it with the fixture. Nothing is retried, so a fixture
    /// that fails needs no second answer.
    private func outcome(ofFixture name: String, _ chunking: Chunking) async throws -> StreamOutcome
    {
        let bytes = try ClaudeFixture.bytes(name)
        let transport = FakeByteStreamTransport([.reply(chunking.chunks(of: bytes))])
        let provider = makeProvider(transport: transport, retryPolicy: noRetries)
        return await readToEnd(provider.stream(makeRequest()))
    }

    /// The fields of a thinking block that was kept to be sent back.
    private func fields(of block: AIContentBlock?) throws -> NSDictionary {
        guard case .opaque(let opaque) = block else {
            Issue.record("Expected an opaque block, found \(String(describing: block))")
            return [:]
        }
        #expect(opaque.provider == ClaudeProvider.providerID)
        return try #require(try JSONSerialization.jsonObject(with: opaque.json) as? NSDictionary)
    }

    private let signature = "EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds/Hk+9Qm7xT2vLw=="

    @Test(arguments: Chunking.allCases)
    func plainText(_ chunking: Chunking) async throws {
        let outcome = try await outcome(ofFixture: "plain-text.sse", chunking)

        let answer = "Zürich is the largest city, but the capital is Bern 🇨🇭."
        #expect(outcome.error == nil)
        #expect(
            outcome.events == [
                .started(model: haiku, requestID: "req_fixture"),
                .usage(firstUsage),
                .textDelta("Zürich is the largest city, "),
                .textDelta("but the capital is Bern 🇨🇭."),
                .usage(AIUsage(inputTokens: 25, outputTokens: 15)),
                .finished(
                    .endTurn, assistant: AIMessage(role: .assistant, content: [.text(answer)])),
            ])
    }

    @Test(arguments: Chunking.allCases)
    func thinkingThenText(_ chunking: Chunking) async throws {
        let outcome = try await outcome(ofFixture: "thinking-then-text.sse", chunking)

        let answer = "The greatest common divisor of 1071 and 462 is **21**."
        #expect(outcome.error == nil)
        #expect(
            outcome.events.dropLast() == [
                .started(model: haiku, requestID: "req_fixture"),
                .usage(AIUsage(inputTokens: 12, outputTokens: 3, cacheReadInputTokens: 600)),
                .reasoning(active: true),
                .reasoning(active: false),
                .textDelta("The greatest common divisor "),
                .textDelta("of 1071 and 462 is **21**."),
                .usage(AIUsage(inputTokens: 12, outputTokens: 148, cacheReadInputTokens: 600)),
            ])

        let finished = try #require(outcome.finished)
        #expect(finished.reason == .endTurn)
        #expect(finished.assistant.role == .assistant)
        #expect(finished.assistant.content.count == 2)
        // The thinking block comes first, as it did in the reply, with the signature that the
        // delta brought.
        let thinking = try fields(of: finished.assistant.content.first)
        #expect(thinking == ["type": "thinking", "thinking": "", "signature": signature])
        #expect(finished.assistant.content.last == .text(answer))
    }

    @Test(arguments: Chunking.allCases)
    func refusalBeforeAnyOutput(_ chunking: Chunking) async throws {
        let outcome = try await outcome(ofFixture: "refusal-before-output.sse", chunking)

        #expect(outcome.error == nil)
        #expect(
            outcome.events == [
                .started(model: haiku, requestID: "req_fixture"),
                .usage(firstUsage),
                .usage(AIUsage(inputTokens: 25, outputTokens: 0)),
                .finished(
                    .refusal(category: "cyber"), assistant: AIMessage(role: .assistant, content: [])
                ),
            ])
    }

    @Test(arguments: Chunking.allCases)
    func refusalDuringOutput(_ chunking: Chunking) async throws {
        let outcome = try await outcome(ofFixture: "refusal-during-output.sse", chunking)

        // The text that had arrived is reported like any other. Whether it is shown is for
        // the session to decide.
        #expect(outcome.error == nil)
        #expect(outcome.text == "The first step is to ")
        let finished = try #require(outcome.finished)
        #expect(finished.reason == .refusal(category: nil))
        #expect(finished.assistant.content == [.text("The first step is to ")])
    }

    @Test(arguments: Chunking.allCases)
    func cutOffAtMaxTokens(_ chunking: Chunking) async throws {
        let outcome = try await outcome(ofFixture: "max-tokens.sse", chunking)

        #expect(outcome.error == nil)
        #expect(outcome.text == "There are three reasons. The first is that")
        let finished = try #require(outcome.finished)
        #expect(finished.reason == .maxTokens)
        #expect(finished.assistant.content.count == 2)
        #expect(
            finished.assistant.content.last == .text("There are three reasons. The first is that"))
        #expect(outcome.events.contains(.usage(AIUsage(inputTokens: 25, outputTokens: 8192))))
    }

    @Test(arguments: Chunking.allCases)
    func overloadedInTheMiddleOfTheStream(_ chunking: Chunking) async throws {
        let outcome = try await outcome(ofFixture: "overloaded-mid-stream.sse", chunking)

        #expect(
            outcome.events == [
                .started(model: haiku, requestID: "req_fixture"),
                .usage(firstUsage),
                .reasoning(active: true),
            ])
        #expect(outcome.error as? AIError == .overloaded)
    }

    @Test(arguments: Chunking.allCases)
    func unknownEventsBlocksDeltasAndFields(_ chunking: Chunking) async throws {
        let outcome = try await outcome(ofFixture: "unknown-event-and-block.sse", chunking)

        #expect(outcome.error == nil)
        #expect(
            outcome.events.dropLast() == [
                .started(model: haiku, requestID: "req_fixture"),
                .usage(firstUsage),
                .reasoning(active: true),
                .reasoning(active: false),
                .textDelta("Still an answer."),
                .usage(AIUsage(inputTokens: 25, outputTokens: 30)),
            ])

        // The block of an unknown kind is gone. The thinking block has kept the field this
        // version does not know, because the API wants the block back as it sent it.
        let finished = try #require(outcome.finished)
        #expect(finished.reason == .endTurn)
        #expect(finished.assistant.content.count == 2)
        let thinking = try fields(of: finished.assistant.content.first)
        #expect(
            thinking == [
                "type": "thinking", "thinking": "", "signature": signature,
                "future_field": ["kept": true],
            ])
        #expect(finished.assistant.content.last == .text("Still an answer."))
    }

    @Test(arguments: Chunking.allCases)
    func pingsAnywhere(_ chunking: Chunking) async throws {
        let outcome = try await outcome(ofFixture: "ping.sse", chunking)

        #expect(outcome.error == nil)
        #expect(
            outcome.events == [
                .started(model: haiku, requestID: "req_fixture"),
                .usage(firstUsage),
                .textDelta("Pong"),
                .textDelta("."),
                .usage(AIUsage(inputTokens: 25, outputTokens: 4)),
                .finished(
                    .endTurn, assistant: AIMessage(role: .assistant, content: [.text("Pong.")])),
            ])
    }

    @Test(arguments: Chunking.allCases)
    func linesEndingInCarriageReturnLineFeed(_ chunking: Chunking) async throws {
        let bytes = try ClaudeFixture.bytes("crlf.sse")
        // The fixture is of no use if a tool has rewritten its line endings.
        #expect(bytes.contains(0x0D))

        let outcome = try await outcome(ofFixture: "crlf.sse", chunking)

        #expect(outcome.error == nil)
        #expect(outcome.text == "Line one.\nLine two.")
        #expect(outcome.finished?.reason == .endTurn)
    }

    // MARK: - Streams that break the rules

    /// Answers one question with a stream written in the test.
    private func outcome(ofEvents events: [(name: String, data: String)]) async -> StreamOutcome {
        let transport = FakeByteStreamTransport([.reply([serverSentEvents(events)])])
        let provider = makeProvider(transport: transport, retryPolicy: noRetries)
        return await readToEnd(provider.stream(makeRequest()))
    }

    private let messageStart = (
        name: "message_start",
        data:
            #"{"type":"message_start","message":{"model":"claude-haiku-5-5","usage":{"input_tokens":3,"output_tokens":1}}}"#
    )
    private let secretText = "the reply's own words"

    private func malformedReason(of outcome: StreamOutcome) -> String? {
        guard case .malformedStream(let reason) = outcome.error as? AIError else { return nil }
        return reason
    }

    @Test func streamThatEndsBeforeTheMessageDoesIsMalformed() async throws {
        let fixture = String(decoding: try ClaudeFixture.bytes("plain-text.sse"), as: UTF8.self)
        // Cut in the middle of the second text delta.
        let secondDelta = try #require(fixture.range(of: "but the capital"))
        let cutOff = Array(fixture[..<secondDelta.upperBound].utf8)
        let transport = FakeByteStreamTransport([.reply([cutOff])])
        let provider = makeProvider(transport: transport, retryPolicy: noRetries)

        let outcome = await readToEnd(provider.stream(makeRequest()))

        #expect(outcome.text == "Zürich is the largest city, ")
        #expect(malformedReason(of: outcome) != nil)
    }

    @Test func dataThatIsNotJSONIsMalformedAndIsNotQuoted() async {
        let outcome = await outcome(ofEvents: [
            messageStart,
            (name: "content_block_delta", data: #"{"index":0,"delta":{"text":"\#(secretText)""#),
        ])

        let reason = malformedReason(of: outcome)
        #expect(reason?.contains("content_block_delta") == true)
        #expect(reason?.contains(secretText) == false)
    }

    @Test func deltaForABlockThatNeverStartedIsMalformed() async {
        let outcome = await outcome(ofEvents: [
            messageStart,
            (
                name: "content_block_delta",
                data: #"{"index":4,"delta":{"type":"text_delta","text":"\#(secretText)"}}"#
            ),
        ])

        let reason = malformedReason(of: outcome)
        #expect(reason?.contains(secretText) == false)
        #expect(outcome.text.isEmpty)
    }

    @Test func messageThatStopsWithoutAStopReasonIsMalformed() async {
        let outcome = await outcome(ofEvents: [
            messageStart,
            (name: "message_stop", data: #"{"type":"message_stop"}"#),
        ])

        #expect(malformedReason(of: outcome) != nil)
        #expect(outcome.finished == nil)
    }

    @Test func textOfABlockThatWasNeverClosedIsKept() async throws {
        let outcome = await outcome(ofEvents: [
            messageStart,
            (
                name: "content_block_start",
                data: #"{"index":0,"content_block":{"type":"text","text":""}}"#
            ),
            (
                name: "content_block_delta",
                data: #"{"index":0,"delta":{"type":"text_delta","text":"Half a"}}"#
            ),
            (
                name: "message_delta",
                data: #"{"delta":{"stop_reason":"pause_turn"},"usage":{"output_tokens":2}}"#
            ),
            (name: "message_stop", data: #"{"type":"message_stop"}"#),
        ])

        let finished = try #require(outcome.finished)
        // A stop reason this version has no case for keeps its name.
        #expect(finished.reason == .other("pause_turn"))
        #expect(finished.assistant.content == [.text("Half a")])
    }

    // OpenRay asks for no readable thinking, so the deltas in the fixtures are empty. Should
    // a reply carry some all the same, it comes in pieces, and the block has to go back to
    // the API whole or its signature no longer fits.
    @Test func thinkingThatArrivesInPiecesIsKeptWhole() async throws {
        let outcome = await outcome(ofEvents: [
            messageStart,
            (
                name: "content_block_start",
                data:
                    #"{"index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#
            ),
            (
                name: "content_block_delta",
                data: #"{"index":0,"delta":{"type":"thinking_delta","thinking":"Euclid: "}}"#
            ),
            (
                name: "content_block_delta",
                data:
                    #"{"index":0,"delta":{"type":"thinking_delta","thinking":"1071 = 2 × 462 + 147."}}"#
            ),
            (
                name: "content_block_delta",
                data: #"{"index":0,"delta":{"type":"signature_delta","signature":"\#(signature)"}}"#
            ),
            (name: "content_block_stop", data: #"{"index":0}"#),
            (
                name: "content_block_start",
                data: #"{"index":1,"content_block":{"type":"text","text":""}}"#
            ),
            (
                name: "content_block_delta",
                data: #"{"index":1,"delta":{"type":"text_delta","text":"21."}}"#
            ),
            (name: "content_block_stop", data: #"{"index":1}"#),
            (
                name: "message_delta",
                data: #"{"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":40}}"#
            ),
            (name: "message_stop", data: #"{"type":"message_stop"}"#),
        ])

        let finished = try #require(outcome.finished)
        let thinking = try fields(of: finished.assistant.content.first)
        #expect(
            thinking == [
                "type": "thinking", "thinking": "Euclid: 1071 = 2 × 462 + 147.",
                "signature": signature,
            ])
        // None of the thinking is shown.
        #expect(outcome.text == "21.")
    }

    @Test func redactedThinkingBlockIsKeptAsItArrived() async throws {
        let outcome = await outcome(ofEvents: [
            messageStart,
            (
                name: "content_block_start",
                data:
                    #"{"index":0,"content_block":{"type":"redacted_thinking","data":"EmwKAhgBEgy3va3pzix"}}"#
            ),
            (name: "content_block_stop", data: #"{"index":0}"#),
            (
                name: "message_delta",
                data:
                    #"{"delta":{"stop_reason":"model_context_window_exceeded"},"usage":{"output_tokens":2}}"#
            ),
            (name: "message_stop", data: #"{"type":"message_stop"}"#),
        ])

        let finished = try #require(outcome.finished)
        #expect(finished.reason == .contextWindowExceeded)
        let block = try fields(of: finished.assistant.content.first)
        #expect(block == ["type": "redacted_thinking", "data": "EmwKAhgBEgy3va3pzix"])
    }

    @Test func usageCountsThatAnEventLeavesOutStayAsTheyWere() async {
        let outcome = await outcome(ofEvents: [
            (
                name: "message_start",
                data:
                    #"{"message":{"model":"claude-haiku-5-5","usage":{"input_tokens":7,"cache_read_input_tokens":600,"cache_creation_input_tokens":40,"output_tokens":1}}}"#
            ),
            (
                name: "message_delta",
                data:
                    #"{"delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":null,"output_tokens":20}}"#
            ),
            (name: "message_stop", data: #"{"type":"message_stop"}"#),
        ])

        let expected = AIUsage(
            inputTokens: 7, outputTokens: 20, cacheReadInputTokens: 600,
            cacheCreationInputTokens: 40)
        #expect(outcome.events.contains(.usage(expected)))
    }
}
