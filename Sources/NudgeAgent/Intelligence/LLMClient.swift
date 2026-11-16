import Foundation

// MARK: - Errors

enum LLMError: Error, LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited
    case refusal
    case truncated
    case http(status: Int, message: String)
    case network(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key set. Add your Anthropic API key in Settings."
        case .invalidAPIKey:
            return "The API key was rejected. Check the key in Settings."
        case .rateLimited:
            return "The AI service is busy right now (rate limited). Trying again later."
        case .refusal:
            return "The AI declined to answer this request."
        case .truncated:
            return "The AI answer was cut off before it was complete."
        case let .http(status, message):
            return message.isEmpty ? "The AI service returned an error (HTTP \(status))."
                                   : "The AI service returned an error (HTTP \(status)): \(message)"
        case let .network(message):
            return "Could not reach the AI service: \(message)"
        case let .decoding(message):
            return "Could not read the AI answer: \(message)"
        }
    }
}

// MARK: - Client

/// Minimal client for the Claude Messages API with structured JSON output.
/// Stateless and safe to use from any thread.
final class LLMClient: @unchecked Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 30
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    static var hasAPIKey: Bool { KeychainStore.loadAPIKey() != nil }

    /// Sends one user turn (optional JPEG first, then text) and returns the JSON bytes of the answer.
    func completeJSON(model: String,
                      system: String,
                      user: String,
                      imageJPEG: Data?,
                      schema: [String: Any],
                      maxTokens: Int) async throws -> Data {
        guard let key = KeychainStore.loadAPIKey() else { throw LLMError.missingAPIKey }
        let body = try Self.makeRequestBody(model: model, system: system, user: user,
                                            imageJPEG: imageJPEG, schema: schema, maxTokens: maxTokens)
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body

        var attempt = 0
        while true {
            attempt += 1
            let canRetry = attempt < 2
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw LLMError.network("No HTTP response")
                }
                let status = http.statusCode
                switch status {
                case 200..<300:
                    return try Self.extractJSON(from: data)
                case 401, 403:
                    throw LLMError.invalidAPIKey
                case 429, 500...599:
                    if canRetry {
                        try await Task.sleep(nanoseconds: UInt64(Self.retryDelay(http) * 1_000_000_000))
                        continue
                    }
                    if status == 429 { throw LLMError.rateLimited }
                    throw LLMError.http(status: status, message: Self.apiErrorMessage(data))
                default:
                    throw LLMError.http(status: status, message: Self.apiErrorMessage(data))
                }
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                if canRetry {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                throw LLMError.network(error.localizedDescription)
            }
        }
    }

    /// Typed helper: decodes the structured answer into `T`.
    func complete<T: Decodable>(_ type: T.Type = T.self,
                                model: String,
                                system: String,
                                user: String,
                                imageJPEG: Data? = nil,
                                schema: [String: Any],
                                maxTokens: Int) async throws -> T {
        let data = try await completeJSON(model: model, system: system, user: user,
                                          imageJPEG: imageJPEG, schema: schema, maxTokens: maxTokens)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LLMError.decoding(String(describing: error))
        }
    }

    // MARK: Request and response helpers (internal for testing)

    static func makeRequestBody(model: String,
                                system: String,
                                user: String,
                                imageJPEG: Data?,
                                schema: [String: Any],
                                maxTokens: Int) throws -> Data {
        var content: [[String: Any]] = []
        if let imageJPEG {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": imageJPEG.base64EncodedString(),
                ],
            ])
        }
        content.append(["type": "text", "text": user])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": content]],
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema],
            ],
        ]
        guard JSONSerialization.isValidJSONObject(body) else {
            throw LLMError.decoding("Request body is not valid JSON")
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
    }

    static func extractJSON(from data: Data) throws -> Data {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LLMError.decoding("Response is not a JSON object")
        }
        switch root["stop_reason"] as? String {
        case "refusal": throw LLMError.refusal
        case "max_tokens": throw LLMError.truncated
        default: break
        }
        let blocks = root["content"] as? [[String: Any]] ?? []
        var text = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Defensive: strip a Markdown code fence if one slipped through.
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") { text = String(text[text.index(after: firstNewline)...]) }
            if text.hasSuffix("```") { text = String(text.dropLast(3)) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { throw LLMError.decoding("Response had no text") }
        return Data(text.utf8)
    }

    static func apiErrorMessage(_ data: Data) -> String {
        if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let err = root["error"] as? [String: Any], let message = err["message"] as? String {
            return message
        }
        return String(data: data.prefix(300), encoding: .utf8) ?? ""
    }

    private static func retryDelay(_ response: HTTPURLResponse) -> Double {
        if let raw = response.value(forHTTPHeaderField: "retry-after"),
           let seconds = Double(raw.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return min(max(seconds, 0.5), 10)
        }
        return 2
    }
}
