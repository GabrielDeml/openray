import Foundation
import Observation
import Synchronization
import Testing

import OpenRayCore

// Shared by the Quick AI tests. None of them sends a request: the provider talks to a transport
// that answers from fixtures, and the session talks to a provider that plays a script.

// MARK: - Transport

/// Stands in for the network. Each call to `open` is answered by the next exchange of the
/// script, and every request is kept to be looked at.
final class FakeByteStreamTransport: ByteStreamTransport {
    /// What one call to `open` does.
    struct Exchange: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [[UInt8]] = []
        /// Thrown by `open` itself, as when no connection could be made.
        var openError: (any Error)?
        /// Thrown after the chunks, as when a connection is lost half-way.
        var streamError: (any Error)?
        /// The stream does not end after its chunks, as on a connection where the server has
        /// more to say and takes its time.
        var staysOpen = false
    }

    private struct State {
        var script: [Exchange]
        var requests: [URLRequest] = []
    }

    private let state: Mutex<State>

    /// One element for every body stream that was ended by its reader before the script was.
    let streamCancellations: AsyncStream<Void>
    private let streamCancellationContinuation: AsyncStream<Void>.Continuation

    init(_ script: [Exchange]) {
        state = Mutex(State(script: script))
        (streamCancellations, streamCancellationContinuation) = AsyncStream.makeStream(
            of: Void.self)
    }

    /// The requests so far, in the order they were opened.
    var requests: [URLRequest] {
        state.withLock { $0.requests }
    }

    func open(_ request: URLRequest) async throws -> (
        HTTPURLResponse, AsyncThrowingStream<[UInt8], any Error>
    ) {
        let exchange: Exchange? = state.withLock { state in
            state.requests.append(request)
            return state.script.isEmpty ? nil : state.script.removeFirst()
        }
        // A request the test did not expect fails in a way no test expects either.
        guard let exchange else { throw UnscriptedRequest() }
        if let openError = exchange.openError { throw openError }

        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: exchange.status, httpVersion: "HTTP/1.1",
                headerFields: exchange.headers)
        else { throw UnscriptedRequest() }

        let (chunks, continuation) = AsyncThrowingStream.makeStream(
            of: [UInt8].self, throwing: (any Error).self)
        let cancellations = streamCancellationContinuation
        continuation.onTermination = { termination in
            if case .cancelled = termination {
                cancellations.yield()
            }
        }
        for chunk in exchange.chunks {
            continuation.yield(chunk)
        }
        if let streamError = exchange.streamError {
            continuation.finish(throwing: streamError)
        } else if !exchange.staysOpen {
            continuation.finish()
        }
        return (response, chunks)
    }

    struct UnscriptedRequest: Error {}
}

extension FakeByteStreamTransport.Exchange {
    /// A streamed reply with status 200.
    static func reply(_ chunks: [[UInt8]], requestID: String = "req_fixture") -> Self {
        Self(headers: ["request-id": requestID], chunks: chunks)
    }

    /// A response the API refuses a request with.
    static func failure(
        status: Int, body: [UInt8], headers: [String: String] = [:]
    ) -> Self {
        Self(status: status, headers: headers, chunks: [body])
    }
}

// MARK: - Provider

/// The key the tests' provider sends. No such key exists.
let testKeyText = "sk-ant-api03-not-a-real-key-0123456789"

/// A provider that reads from `transport`, has a key, and does not wait before a retry.
func makeProvider(
    transport: FakeByteStreamTransport,
    retryPolicy: RetryPolicy = RetryPolicy(jitter: { 1 }),
    sleeps: SleepRecorder = SleepRecorder()
) -> ClaudeProvider {
    ClaudeProvider(
        transport: transport,
        apiKey: { APIKey(testKeyText) },
        retryPolicy: retryPolicy,
        sleep: { duration in sleeps.record(duration) })
}

/// A policy that reports every failure at once.
var noRetries: RetryPolicy {
    var policy = RetryPolicy(jitter: { 1 })
    policy.maxRetries = 0
    return policy
}

/// Takes the place of waiting before a retry, and remembers how long the wait would have been.
final class SleepRecorder: Sendable {
    private let recorded = Mutex<[Duration]>([])

    var durations: [Duration] {
        recorded.withLock { $0 }
    }

    func record(_ duration: Duration) {
        recorded.withLock { $0.append(duration) }
    }
}

/// A short question to the default model, as Quick AI would ask it.
func makeRequest(_ messages: [AIMessage] = [userMessage("What is the capital of Switzerland?")])
    -> AIRequest
{
    AIRequest(
        model: ClaudeProvider.haiku,
        system: "You answer questions typed into OpenRay.",
        messages: messages,
        maxOutputTokens: 8192,
        effort: .low)
}

func userMessage(_ text: String) -> AIMessage {
    AIMessage(role: .user, content: [.text(text)])
}

/// Everything a stream delivered: its events, and the error it ended with if it did not end
/// well.
struct StreamOutcome {
    var events: [AIEvent] = []
    var error: (any Error)?

    /// The text of all `textDelta` events, joined.
    var text: String {
        var text = ""
        for event in events {
            if case .textDelta(let delta) = event {
                text += delta
            }
        }
        return text
    }

    var finished: (reason: AIStopReason, assistant: AIMessage)? {
        guard case .finished(let reason, let assistant) = events.last else { return nil }
        return (reason, assistant)
    }
}

/// Reads a stream to its end.
func readToEnd(_ stream: AsyncThrowingStream<AIEvent, any Error>) async -> StreamOutcome {
    var outcome = StreamOutcome()
    do {
        for try await event in stream {
            outcome.events.append(event)
        }
    } catch {
        outcome.error = error
    }
    return outcome
}

// MARK: - Session

/// Stands in for a provider. Each call to `stream` plays the next reply of the script, and
/// every request is kept to be looked at.
final class FakeAIProvider: AIProvider {
    /// What one call to `stream` delivers.
    struct Reply: Sendable {
        var events: [AIEvent] = []
        /// Thrown after the events.
        var error: (any Error)?
        /// The stream does not end after its events. The test goes on with `send`, `finish`
        /// and `fail`, or leaves the reply hanging.
        var staysOpen = false
    }

    static let providerID = AIProviderID(rawValue: "fake")

    private struct State {
        var script: [Reply]
        var requests: [AIRequest] = []
        var latestStream: AsyncThrowingStream<AIEvent, any Error>.Continuation?
        var modelsRequestCount = 0
    }

    let id = FakeAIProvider.providerID

    private let state: Mutex<State>

    /// One element for every stream that its reader ended before the provider did.
    let cancellations: AsyncStream<Void>
    private let cancellationContinuation: AsyncStream<Void>.Continuation

    private let modelsAnswers: AsyncStream<Result<[AIModelID], any Error>>
    private let modelsAnswerContinuation: AsyncStream<Result<[AIModelID], any Error>>.Continuation

    init(_ script: [Reply] = []) {
        state = Mutex(State(script: script))
        (cancellations, cancellationContinuation) = AsyncStream.makeStream(of: Void.self)
        (modelsAnswers, modelsAnswerContinuation) = AsyncStream.makeStream(
            of: Result<[AIModelID], any Error>.self)
    }

    /// The requests so far, in the order they were made.
    var requests: [AIRequest] {
        state.withLock { $0.requests }
    }

    /// How often the models were asked for, which is how often a key was checked.
    var modelsRequestCount: Int {
        state.withLock { $0.modelsRequestCount }
    }

    /// What the next call to `availableModels` returns or throws. A call that finds no answer
    /// waits for one, which is how a test holds a verification open.
    func answerModels(with answer: Result<[AIModelID], any Error>) {
        modelsAnswerContinuation.yield(answer)
    }

    func availableModels() async throws -> [AIModelID] {
        state.withLock { $0.modelsRequestCount += 1 }
        for await answer in modelsAnswers {
            return try answer.get()
        }
        return []
    }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        let (events, continuation) = AsyncThrowingStream.makeStream(
            of: AIEvent.self, throwing: (any Error).self)
        let cancellations = cancellationContinuation
        continuation.onTermination = { termination in
            if case .cancelled = termination {
                cancellations.yield()
            }
        }

        let reply: Reply? = state.withLock { state in
            state.requests.append(request)
            state.latestStream = continuation
            return state.script.isEmpty ? nil : state.script.removeFirst()
        }
        // A question the test did not expect fails in a way no test expects either.
        guard let reply else {
            continuation.finish(throwing: UnscriptedQuestion())
            return events
        }

        for event in reply.events {
            continuation.yield(event)
        }
        if let error = reply.error {
            continuation.finish(throwing: error)
        } else if !reply.staysOpen {
            continuation.finish()
        }
        return events
    }

    /// Adds an event to the reply that was asked for last.
    func send(_ event: AIEvent) {
        latestStream?.yield(event)
    }

    /// Ends the reply that was asked for last.
    func finish() {
        latestStream?.finish()
    }

    /// Ends the reply that was asked for last with an error.
    func fail(_ error: any Error) {
        latestStream?.finish(throwing: error)
    }

    private var latestStream: AsyncThrowingStream<AIEvent, any Error>.Continuation? {
        state.withLock { $0.latestStream }
    }

    struct UnscriptedQuestion: Error {}
}

extension FakeAIProvider.Reply {
    /// A reply that the test delivers by hand.
    static var open: Self {
        Self(staysOpen: true)
    }

    /// A whole reply of this text, as a provider delivers one that thought first.
    static func answer(_ text: String, requestID: String = "req_fake") -> Self {
        Self(events: [
            .started(model: ClaudeProvider.haiku, requestID: requestID),
            .reasoning(active: true),
            .reasoning(active: false),
            .textDelta(text),
            .usage(AIUsage(inputTokens: 12, outputTokens: 5)),
            .finished(.endTurn, assistant: assistantMessage(text, thinking: "sig-\(text)")),
        ])
    }
}

/// A block that only its provider can read, as a reply's thinking is. The signature tells
/// one block from another.
func thinkingBlock(_ signature: String) -> AIContentBlock {
    let json = Data(#"{"signature":"\#(signature)","thinking":"","type":"thinking"}"#.utf8)
    return .opaque(ProviderOpaqueBlock(provider: FakeAIProvider.providerID, json: json))
}

/// An assistant's turn of this text, behind a thinking block when a signature is given.
func assistantMessage(_ text: String, thinking signature: String? = nil) -> AIMessage {
    var content: [AIContentBlock] = []
    if let signature {
        content.append(thinkingBlock(signature))
    }
    content.append(.text(text))
    return AIMessage(role: .assistant, content: content)
}

/// The time as the test sets it, for a session's `now`.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date) {
        current = Mutex(start)
    }

    var now: Date {
        current.withLock { $0 }
    }

    func set(_ date: Date) {
        current.withLock { $0 = date }
    }

    func advance(minutes: Double) {
        current.withLock { $0 += minutes * 60 }
    }
}

/// Returns once `condition` holds. It is looked at again whenever something it read has
/// changed, so it has to read what it waits for from an `@Observable` object. No test sleeps
/// to let a reply settle.
@MainActor func waitUntil(_ condition: @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = condition()
            } onChange: {
                changed.resume()
            }
        }
    }
}

/// Returns once a reply's task has ended.
///
/// `Task.value` alone goes on waiting when the test that waits is cancelled, which is what a
/// time limit does to it. A reply that never ended would then hang the whole run. Here the
/// reply is cancelled with the test, so the test goes on and fails where it can be read.
func waitForEnd(of replyTask: Task<Void, Never>?) async {
    guard let replyTask else { return }
    await withTaskCancellationHandler {
        await replyTask.value
    } onCancel: {
        replyTask.cancel()
    }
}

/// Keeps secrets for as long as a test runs. Nothing in the app uses it: the app's secrets
/// are in the Keychain, which no test touches.
final class InMemorySecretStore: SecretStore {
    enum Operation: Sendable {
        case read, write, delete
    }

    /// What a refused operation throws, with a message as the Keychain has one for a status.
    struct Refused: Error, LocalizedError {
        var errorDescription: String? { "The user name or passphrase you entered is not correct." }
    }

    private struct State {
        var secrets: [SecretAccount: String] = [:]
        var refused: Set<Operation> = []
    }

    private let state = Mutex(State())

    /// Makes these operations throw from now on, and every other one work.
    func refuse(_ operations: Set<Operation>) {
        state.withLock { $0.refused = operations }
    }

    func read(_ account: SecretAccount) async throws -> String? {
        try state.withLock { state in
            if state.refused.contains(.read) { throw Refused() }
            return state.secrets[account]
        }
    }

    func write(_ value: String, for account: SecretAccount) async throws {
        try state.withLock { state in
            if state.refused.contains(.write) { throw Refused() }
            state.secrets[account] = value
        }
    }

    func delete(_ account: SecretAccount) async throws {
        try state.withLock { state in
            if state.refused.contains(.delete) { throw Refused() }
            state.secrets[account] = nil
        }
    }
}

// MARK: - Fixtures

enum ClaudeFixture {
    /// The bytes of `Fixtures/claude/<name>`.
    static func bytes(_ name: String, in subdirectory: String = "Fixtures/claude") throws
        -> [UInt8]
    {
        let fileName = name as NSString
        let url = try #require(
            Bundle.module.url(
                forResource: fileName.deletingPathExtension,
                withExtension: fileName.pathExtension,
                subdirectory: subdirectory))
        return [UInt8](try Data(contentsOf: url))
    }

    /// The bytes of `Fixtures/claude/errors/<name>`.
    static func errorBody(_ name: String) throws -> [UInt8] {
        try bytes(name, in: "Fixtures/claude/errors")
    }
}

/// A stream written in the test itself: each event with its name and its data, ended by a blank
/// line.
func serverSentEvents(_ events: [(name: String, data: String)]) -> [UInt8] {
    var text = ""
    for event in events {
        text += "event: \(event.name)\ndata: \(event.data)\n\n"
    }
    return [UInt8](text.utf8)
}

// MARK: - Chunking

/// SplitMix64, a small random number generator. The chunking has to be the same on every run,
/// and the system's generator cannot be seeded.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// The ways a network can cut up the same bytes.
enum Chunking: CustomStringConvertible, CaseIterable {
    case whole, byteByByte, random

    var description: String {
        switch self {
        case .whole: "whole"
        case .byteByByte: "byte by byte"
        case .random: "random chunks"
        }
    }

    func chunks(of bytes: [UInt8]) -> [[UInt8]] {
        switch self {
        case .whole:
            return [bytes]

        case .byteByByte:
            return bytes.map { [$0] }

        case .random:
            var generator = SeededGenerator(seed: 2026)
            var chunks: [[UInt8]] = []
            var remaining = bytes[...]
            while !remaining.isEmpty {
                // Mostly short, so that many cuts fall inside a line, a character or a CR LF.
                let length = Int.random(in: 1...40, using: &generator)
                chunks.append(Array(remaining.prefix(length)))
                remaining = remaining.dropFirst(length)
            }
            return chunks
        }
    }
}
