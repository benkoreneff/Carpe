import Foundation

enum ClaudeError: LocalizedError, Equatable {
    case missingAPIKey
    case api(status: Int, type: String, message: String)
    case refused
    case truncated
    case unreadableReply(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add your Anthropic API key in Settings."
        case .api(401, _, _):
            "Anthropic rejected the API key. Check it in Settings."
        case .api(404, _, let message):
            "Anthropic doesn't know that model. Check the model ID in Settings. (\(message))"
        case .api(429, _, _):
            "Anthropic's rate limit was hit. Try again in a moment."
        case .api(let status, _, _) where status >= 500:
            "Anthropic's API is having trouble (HTTP \(status)). Try again in a moment."
        case .api(let status, _, let message):
            "Anthropic returned an error (HTTP \(status)): \(message)"
        case .refused:
            "Claude declined to read this screenshot."
        case .truncated:
            "Claude's answer was cut off. Try a smaller selection."
        case .unreadableReply(let detail):
            "Claude's answer wasn't valid event data. (\(detail))"
        }
    }
}

/// What came back for one screenshot: the decoded events and the JSON text
/// Claude produced, kept for the log and the "Copy Last Result" menu item.
struct ExtractionResult: Sendable {
    var extraction: Extraction
    var rawJSON: String
    var usedStructuredOutputs: Bool
}

/// Calls the Messages API with plain URLSession. Request shape follows
/// https://platform.claude.com/docs/en/build-with-claude/structured-outputs
struct ClaudeClient {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// On this version the API rejects temperature, top_p and top_k outright,
    /// so none of them are ever sent.
    static let apiVersion = "2026-10-21"
    /// Thinking is on by default and counts toward this, and a schedule can be
    /// twenty events long, so the cap is generous.
    static let maxTokens = 8192

    var apiKey: String
    var model: String
    var transport: Transport = { try await URLSession.shared.data(for: $0) }
    var retryDelay: Duration = .seconds(2)

    func extractEvents(from image: PreparedImage, now: Date, timeZone: TimeZone) async throws -> ExtractionResult {
        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }
        let system = ExtractionPrompt.system(now: now, timeZone: timeZone)

        do {
            let text = try await send(Self.requestBody(model: model, system: system, image: image, mode: .structured))
            do {
                return ExtractionResult(
                    extraction: try Extraction.decode(fromModelText: text), rawJSON: text,
                    usedStructuredOutputs: true
                )
            } catch {
                throw ClaudeError.unreadableReply(Self.describe(error))
            }
        } catch let error as ClaudeError where Self.meansStructuredOutputsUnavailable(error) {
            // The model ID is editable, and older models reject output_config.
            return try await extractWithPlainJSON(system: system, image: image)
        }
    }

    // MARK: - Plain-JSON fallback

    /// For models without structured outputs: ask for JSON in the prompt,
    /// validate it by decoding, and give the model one chance to correct it.
    private func extractWithPlainJSON(system: String, image: PreparedImage) async throws -> ExtractionResult {
        let first = try await send(Self.requestBody(model: model, system: system, image: image, mode: .plainJSON(correcting: nil)))
        if let extraction = try? Extraction.decode(fromModelText: first) {
            return ExtractionResult(extraction: extraction, rawJSON: first, usedStructuredOutputs: false)
        }

        let second = try await send(Self.requestBody(model: model, system: system, image: image, mode: .plainJSON(correcting: first)))
        do {
            return ExtractionResult(
                extraction: try Extraction.decode(fromModelText: second), rawJSON: second,
                usedStructuredOutputs: false
            )
        } catch {
            throw ClaudeError.unreadableReply(Self.describe(error))
        }
    }

    // MARK: - Request

    enum Mode {
        case structured
        /// `correcting` is a previous reply that failed validation.
        case plainJSON(correcting: String?)
    }

    static func requestBody(model: String, system: String, image: PreparedImage, mode: Mode) -> [String: Any] {
        var system = system
        var userText = ExtractionPrompt.userText
        var body: [String: Any] = ["model": model, "max_tokens": maxTokens]

        switch mode {
        case .structured:
            body["output_config"] = [
                "effort": "low",
                "format": ["type": "json_schema", "schema": ExtractionPrompt.schema],
            ]
        case .plainJSON(let previous):
            let schema = (try? JSONSerialization.data(withJSONObject: ExtractionPrompt.schema, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            system += """


            # Output format
            Reply with a single JSON object and nothing else: no prose and no code \
            fence. It must match this JSON Schema:
            \(schema)
            """
            if let previous {
                userText += """


                Your previous reply could not be parsed as that JSON object. Reply \
                again with only the corrected JSON. The previous reply was:
                \(previous)
                """
            }
        }

        body["system"] = system
        // Image first, then the instruction, as the vision guide recommends.
        body["messages"] = [[
            "role": "user",
            "content": [
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": image.mediaType,
                        "data": image.data.base64EncodedString(),
                    ],
                ],
                ["type": "text", "text": userText],
            ],
        ]]
        return body
    }

    // MARK: - Transport

    private struct Reply: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
        }
        var content: [Block]
        var stop_reason: String?
    }

    private struct ErrorReply: Decodable {
        struct Detail: Decodable {
            var type: String
            var message: String
        }
        var error: Detail
    }

    /// Sends one request and returns the text of the answer. Retries once when
    /// the API is overloaded or rate limited.
    private func send(_ body: [String: Any]) async throws -> String {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var (data, response) = try await transport(request)
        if let status = (response as? HTTPURLResponse)?.statusCode, [429, 500, 502, 503, 504, 529].contains(status) {
            try await Task.sleep(for: retryDelay)
            (data, response) = try await transport(request)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error
            throw ClaudeError.api(
                status: status,
                type: detail?.type ?? "unknown",
                message: detail?.message ?? String(decoding: data.prefix(300), as: UTF8.self)
            )
        }

        let reply: Reply
        do {
            reply = try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw ClaudeError.unreadableReply(Self.describe(error))
        }

        // A refusal or a cut-off answer does not follow the schema, so check
        // the stop reason before trusting the content.
        switch reply.stop_reason {
        case "refusal": throw ClaudeError.refused
        case "max_tokens": throw ClaudeError.truncated
        default: break
        }

        // With thinking on, the answer is not the first block: pick by type.
        let text = reply.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw ClaudeError.unreadableReply("The answer had no text.") }
        return text
    }

    /// A 400 that complains about output_config (the schema format or the
    /// effort setting) means this model can't take the structured request.
    static func meansStructuredOutputsUnavailable(_ error: ClaudeError) -> Bool {
        guard case .api(400, "invalid_request_error", let message) = error else { return false }
        let lowered = message.lowercased()
        return ["output_config", "structured output", "json_schema", "effort"].contains { lowered.contains($0) }
    }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .keyNotFound(let key, _): return "missing \"\(key.stringValue)\""
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }
}
