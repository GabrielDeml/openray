import Foundation

/// The two requests Quick AI makes to the Claude API (docs/DESIGN.md §4.6.2).
///
/// The addresses are fixed. No environment variable or preference changes where a request and
/// the key in it are sent.
enum ClaudeRequest {
    static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    static let modelsURL = URL(string: "https://api.anthropic.com/v1/models")!

    /// The version of the API these requests and the reading of their answers are written for.
    static let apiVersion = "2026-10-21"

    /// The most models the API returns in one page of its list.
    private static let modelsPageSize = 1000

    /// The body of a streamed Messages request.
    ///
    /// Thinking is not configured, so the model decides how much it thinks, within the effort
    /// asked for. `temperature`, `top_p` and `top_k` are never sent: this API version rejects
    /// them.
    ///
    /// The same request gives the same bytes. A request that is tried again must not differ
    /// from the first, and the prompt cache holds only while the start of the body does not
    /// change from one question to the next.
    static func messagesBody(for request: AIRequest) throws -> Data {
        var messages: [[String: Any]] = []
        for message in request.messages {
            messages.append([
                "role": message.role.rawValue,
                "content": contentBlocks(of: message),
            ])
        }

        var body: [String: Any] = [
            "model": request.model.rawValue,
            "max_tokens": request.maxOutputTokens,
            "stream": true,
            "messages": messages,
            // Caches everything up to the last block, and moves on with the thread.
            "cache_control": ["type": "ephemeral"],
        ]
        // The API does not take a text block without text.
        if !request.system.isEmpty {
            body["system"] = [["type": "text", "text": request.system]]
        }
        if let effort = request.effort {
            body["output_config"] = ["effort": effort.rawValue]
        }

        do {
            return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            let message = String(
                localized: "The conversation could not be prepared for sending.",
                bundle: .module,
                comment: "Quick AI: the error shown when a request could not be written.")
            throw AIError.badRequest(message)
        }
    }

    private static func contentBlocks(of message: AIMessage) -> [Any] {
        var blocks: [Any] = []
        for block in message.content {
            switch block {
            case .text(let text):
                blocks.append(["type": "text", "text": text])

            case .opaque(let opaque):
                // Another provider's blocks mean nothing to this one.
                if opaque.provider != ClaudeProvider.providerID { continue }
                // The block goes back with every field it came with. It was written by
                // `ClaudeMessageAccumulator`, so it is JSON.
                if let fields = try? JSONSerialization.jsonObject(with: opaque.json) {
                    blocks.append(fields)
                }
            }
        }
        return blocks
    }

    /// The request that asks a question and streams the answer.
    static func messages(body: Data, key: APIKey) -> URLRequest {
        var request = authorizedRequest(to: messagesURL, key: key)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body
        return request
    }

    /// The request for one page of the models the key can use.
    ///
    /// - Parameter cursor: The ID of the last model of the page before, or nil for the first
    ///   page.
    static func modelsPage(after cursor: String?, key: APIKey) -> URLRequest {
        var queryItems = [URLQueryItem(name: "limit", value: String(modelsPageSize))]
        if let cursor {
            queryItems.append(URLQueryItem(name: "after_id", value: cursor))
        }
        let pageURL = modelsURL.appending(queryItems: queryItems)

        var request = authorizedRequest(to: pageURL, key: key)
        request.httpMethod = "GET"
        return request
    }

    /// A request with the headers every call to the API needs. This is the one place where the
    /// key leaves its wrapper, and the header is the one place it goes.
    private static func authorizedRequest(to url: URL, key: APIKey) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(key.headerValue, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        return request
    }
}
