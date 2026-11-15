import Foundation
import Testing

import OpenRayCore

@Suite(.timeLimit(.minutes(1))) struct ByteStreamChunksTests {
    /// Bytes that arrive one at a time and then end, as `URLSession.AsyncBytes` delivers a
    /// response.
    private func upstream(of bytes: [UInt8]) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for byte in bytes {
                continuation.yield(byte)
            }
            continuation.finish()
        }
    }

    private func chunks(of bytes: [UInt8]) async throws -> [[UInt8]] {
        var chunks: [[UInt8]] = []
        for try await chunk in ByteStreamChunks.stream(of: upstream(of: bytes)) {
            chunks.append(chunk)
        }
        return chunks
    }

    @Test func chunkEndsAtEveryLineFeed() async throws {
        let chunks = try await chunks(of: Array("event: ping\ndata: {}\n\n".utf8))

        #expect(
            chunks == [Array("event: ping\n".utf8), Array("data: {}\n".utf8), Array("\n".utf8)])
    }

    @Test func longLineIsPassedOnAtTheSizeLimit() async throws {
        let line = [UInt8](repeating: UInt8(ascii: "a"), count: ByteStreamChunks.sizeLimit * 2 + 10)

        let chunks = try await chunks(of: line + [0x0A])

        #expect(chunks.map(\.count) == [4096, 4096, 11])
        #expect(Array(chunks.joined()) == line + [0x0A])
    }

    @Test func whatIsLeftAtTheEndIsPassedOn() async throws {
        let chunks = try await chunks(of: Array("data: whole\ndata: cut".utf8))

        #expect(chunks == [Array("data: whole\n".utf8), Array("data: cut".utf8)])
    }

    @Test func nothingComesOfNoBytes() async throws {
        #expect(try await chunks(of: []).isEmpty)
    }

    @Test func errorOfTheUpstreamEndsTheChunks() async throws {
        let upstream = AsyncThrowingStream<UInt8, any Error> { continuation in
            for byte in Array("data: one\ndata: tw".utf8) {
                continuation.yield(byte)
            }
            continuation.finish(throwing: URLError(.networkConnectionLost))
        }

        var chunks: [[UInt8]] = []
        let error = await #expect(throws: URLError.self) {
            for try await chunk in ByteStreamChunks.stream(of: upstream) {
                chunks.append(chunk)
            }
        }

        #expect(error?.code == .networkConnectionLost)
        #expect(chunks == [Array("data: one\n".utf8)])
    }

    @Test func whenNobodyReadsTheChunksTheUpstreamIsCancelled() async throws {
        let (upstreamEnded, upstreamEndedContinuation) = AsyncStream.makeStream(of: Void.self)
        // One line, and then a connection on which nothing more arrives.
        let upstream = AsyncStream<UInt8> { continuation in
            for byte in Array("data: one\n".utf8) {
                continuation.yield(byte)
            }
            continuation.onTermination = { _ in
                upstreamEndedContinuation.yield()
            }
        }

        for try await chunk in ByteStreamChunks.stream(of: upstream) {
            #expect(chunk == Array("data: one\n".utf8))
            break
        }

        // Were the upstream still being read, nothing would arrive here and the test would
        // run into its time limit.
        var ended = upstreamEnded.makeAsyncIterator()
        await ended.next()
    }
}
