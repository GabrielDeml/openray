/// Turns bytes that arrive one at a time into the chunks a `ByteStreamTransport` returns.
///
/// `URLSession.AsyncBytes` hands out single bytes and says nothing about how they arrived.
/// The app's transport passes them through here, so that it has no decisions of its own to
/// make and this part can be tested (docs/DESIGN.md §5.4).
public enum ByteStreamChunks {
    /// The size at which a chunk is passed on even though its line has not ended.
    public static let sizeLimit = 4096

    private static let lineFeed: UInt8 = 0x0A

    /// The bytes of `bytes` in chunks that end at a line feed, at `sizeLimit` bytes, or where
    /// the bytes end.
    ///
    /// Ending at a line feed is what keeps a reply moving. Server-sent events are short lines,
    /// and a chunk that waited to fill up would hold back every word until 4 KB had arrived.
    ///
    /// Reading starts at once. It is cancelled when the returned stream is no longer read.
    public static func stream<Bytes: AsyncSequence & Sendable>(
        of bytes: Bytes
    ) -> AsyncThrowingStream<[UInt8], any Error> where Bytes.Element == UInt8 {
        let (chunks, continuation) = AsyncThrowingStream.makeStream(
            of: [UInt8].self, throwing: (any Error).self)

        let reading = Task {
            var chunk: [UInt8] = []
            do {
                for try await byte in bytes {
                    chunk.append(byte)
                    if byte == lineFeed || chunk.count >= sizeLimit {
                        continuation.yield(chunk)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty {
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                // The bytes of a line that was cut off are not passed on: nothing can be read
                // from half a line.
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            reading.cancel()
        }
        return chunks
    }
}
