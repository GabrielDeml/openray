import Foundation
import OpenRayCore

/// Quick AI's way to the network (docs/DESIGN.md §4.6.2): the one `URLSession` its requests
/// go through. What is sent, what is retried and how the reply is read are the provider's;
/// nothing is decided or logged here, and no redirect is followed.
nonisolated struct URLSessionByteTransport: ByteStreamTransport {
    private let session: URLSession
    private let redirectRefusal = RedirectRefusal()

    init() {
        // Nothing of a request or a reply is to be kept. An ephemeral configuration writes
        // nothing to disk but still has a cache and a cookie store in memory.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // The longest silence between two pieces of a reply, and the longest a whole reply
        // may take.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        // `waitsForConnectivity` stays off, so a question asked offline fails at once.
        session = URLSession(configuration: configuration)
    }

    func open(_ request: URLRequest) async throws -> (
        HTTPURLResponse, AsyncThrowingStream<[UInt8], any Error>
    ) {
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectRefusal)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (httpResponse, ByteStreamChunks.stream(of: bytes))
    }
}

/// Refuses every redirect. Followed, one would send the request again, with the key and the
/// thread in it, to whatever host the answer names. Refused, the 3xx is the response, and the
/// provider reports it like any other status it does not expect.
private nonisolated final class RedirectRefusal: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
