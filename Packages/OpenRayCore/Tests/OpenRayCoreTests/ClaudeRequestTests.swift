import Foundation
import Testing

import OpenRayCore

/// What goes over the wire when a question is asked, taken from the transport.
@Suite(.timeLimit(.minutes(1))) struct ClaudeRequestTests {
    private let signature = "EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds/Hk+9Qm7xT2vLw=="

    /// The thread of `Fixtures/claude/request.json`: a question, its answer with the thinking
    /// that came before it, and a follow-up.
    private func thread() throws -> [AIMessage] {
        let thinking: [String: Any] = ["type": "thinking", "thinking": "", "signature": signature]
        let thinkingJSON = try JSONSerialization.data(
            withJSONObject: thinking, options: [.sortedKeys])
        let thinkingBlock = ProviderOpaqueBlock(
            provider: ClaudeProvider.providerID, json: thinkingJSON)
        return [
            userMessage("What is the capital of Switzerland?"),
            AIMessage(role: .assistant, content: [.opaque(thinkingBlock), .text("Bern.")]),
            userMessage("And of Austria?"),
        ]
    }

    /// Sends the request and returns it as the transport received it.
    private func sentRequest(for request: AIRequest) async throws -> URLRequest {
        let reply = FakeByteStreamTransport.Exchange.reply([
            try ClaudeFixture.bytes("plain-text.sse")
        ])
        let transport = FakeByteStreamTransport([reply])
        let provider = makeProvider(transport: transport)

        let outcome = await readToEnd(provider.stream(request))

        #expect(outcome.error == nil)
        #expect(transport.requests.count == 1)
        return try #require(transport.requests.first)
    }

    private func body(of request: URLRequest) throws -> NSDictionary {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    @Test func bodyIsTheGoldenRequest() async throws {
        let sent = try await sentRequest(for: makeRequest(try thread()))

        let golden = try JSONSerialization.jsonObject(
            with: Data(try ClaudeFixture.bytes("request.json")))
        #expect(try body(of: sent) == golden as? NSDictionary)
    }

    @Test func bodyHasWhatTheAPIVersionAsksForAndNothingItRejects() async throws {
        let sent = try await sentRequest(for: makeRequest())
        let body = try body(of: sent)

        #expect(body["stream"] as? Bool == true)
        #expect(body["output_config"] as? NSDictionary == ["effort": "low"])
        #expect(body["cache_control"] as? NSDictionary == ["type": "ephemeral"])
        #expect(body["max_tokens"] as? Int == 8192)

        let rejectedOrUnused = [
            "temperature", "top_p", "top_k", "thinking", "fallbacks", "tools", "tool_choice",
            "metadata", "stop_sequences", "speed",
        ]
        for key in rejectedOrUnused {
            #expect(body[key] == nil, "\(key) must not be sent")
        }

        // `true`, not 1: the two are equal once they have been read back as numbers.
        let text = String(decoding: try #require(sent.httpBody), as: UTF8.self)
        #expect(text.contains(#""stream":true"#))
    }

    @Test func withoutAnEffortTheProvidersDefaultApplies() async throws {
        var request = makeRequest()
        request.effort = nil

        let body = try body(of: try await sentRequest(for: request))

        #expect(body["output_config"] == nil)
    }

    @Test func emptySystemPromptIsLeftOut() async throws {
        var request = makeRequest()
        request.system = ""

        let body = try body(of: try await sentRequest(for: request))

        #expect(body["system"] == nil)
    }

    @Test func requestGoesToTheMessagesEndpointWithThreeHeaders() async throws {
        let sent = try await sentRequest(for: makeRequest())

        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.url?.query() == nil)

        var headers: [String: String] = [:]
        for (name, value) in sent.allHTTPHeaderFields ?? [:] {
            headers[name.lowercased()] = value
        }
        #expect(
            headers == [
                "x-api-key": testKeyText,
                "anthropic-version": "2026-10-21",
                "content-type": "application/json",
            ])
    }

    @Test func keyIsInItsHeaderAndNowhereElse() async throws {
        let sent = try await sentRequest(for: makeRequest())

        let url = try #require(sent.url?.absoluteString)
        let body = String(decoding: try #require(sent.httpBody), as: UTF8.self)
        #expect(!url.contains(testKeyText))
        #expect(!body.contains(testKeyText))
        for (name, value) in sent.allHTTPHeaderFields ?? [:] where name.lowercased() != "x-api-key"
        {
            #expect(!value.contains(testKeyText))
        }
    }

    @Test func sameRequestIsTheSameBytes() async throws {
        let first = try await sentRequest(for: makeRequest(try thread()))
        let second = try await sentRequest(for: makeRequest(try thread()))

        #expect(first.httpBody == second.httpBody)
    }

    @Test func thinkingBlockGoesBackAsItCame() async throws {
        // The first reply thinks before it answers.
        let thinkingReply = FakeByteStreamTransport.Exchange.reply(
            [try ClaudeFixture.bytes("thinking-then-text.sse")])
        let secondReply = FakeByteStreamTransport.Exchange.reply(
            [try ClaudeFixture.bytes("plain-text.sse")])
        let transport = FakeByteStreamTransport([thinkingReply, secondReply])
        let provider = makeProvider(transport: transport)

        let question = userMessage("What is the greatest common divisor of 1071 and 462?")
        let firstOutcome = await readToEnd(provider.stream(makeRequest([question])))
        let assistant = try #require(firstOutcome.finished?.assistant)
        guard case .opaque(let thinking) = assistant.content.first else {
            Issue.record("The reply has no thinking block")
            return
        }

        let followUp = userMessage("And of 21 and 14?")
        _ = await readToEnd(provider.stream(makeRequest([question, assistant, followUp])))

        // The block's bytes are in the second request exactly as the first reply left them.
        let secondBody = try #require(transport.requests.last?.httpBody)
        #expect(secondBody.range(of: thinking.json) != nil)

        // And the first request's messages are the start of the second's.
        let firstMessages = try #require(
            try body(of: transport.requests[0])["messages"] as? [NSDictionary])
        let secondMessages = try #require(
            try body(of: transport.requests[1])["messages"] as? [NSDictionary])
        #expect(secondMessages.count == 3)
        #expect(Array(secondMessages.prefix(firstMessages.count)) == firstMessages)
    }

    @Test func blocksOfAnotherProviderAreLeftOut() async throws {
        let foreign = ProviderOpaqueBlock(
            provider: AIProviderID(rawValue: "ollama"), json: Data(#"{"type":"context"}"#.utf8))
        let assistant = AIMessage(role: .assistant, content: [.opaque(foreign), .text("Bern.")])
        let messages = [userMessage("Capital?"), assistant, userMessage("Sure?")]

        let body = try body(of: try await sentRequest(for: makeRequest(messages)))

        let sentMessages = try #require(body["messages"] as? [NSDictionary])
        let assistantContent = try #require(sentMessages[1]["content"] as? [NSDictionary])
        #expect(assistantContent == [["type": "text", "text": "Bern."]])
    }
}
