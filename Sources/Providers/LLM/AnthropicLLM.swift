import Foundation

/// Anthropic Claude Messages API provider.
struct AnthropicLLM: LLMProvider {
    static let providerID: LLMProviderID = .anthropic

    private let apiKey: String
    private let httpClient: ProviderHTTPClient
    private let model: String
    private let timeoutSeconds: TimeInterval

    init(
        apiKey: String,
        httpClient: ProviderHTTPClient,
        // Haiku 4.5 is plenty for transcript cleanup — fast, cheap, and
        // the prompt-caching path below makes the per-request cost
        // negligible. Sonnet would be overkill for this task and 5–10×
        // the price. Users can override per-provider if they want.
        model: String = "claude-haiku-4-5-20251001",
        timeoutSeconds: TimeInterval = 20
    ) {
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    private static let endpointURL = URL(string: "https://api.anthropic.com/v1/messages")

    var endpointOrigin: URL? { URL(string: "https://api.anthropic.com") }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        guard let url = Self.endpointURL else {
            throw LLMError.apiError(provider: .anthropic, message: "Invalid endpoint URL.", statusCode: nil)
        }

        // Wrap the system prompt in a single content block with
        // `cache_control: { type: "ephemeral" }`. Anthropic's prompt
        // caching gives a 5-minute server-side cache and a 90% discount
        // on cached tokens. Comet's cleanup prompt is ~1,400 tokens of
        // mostly-static rules + examples, sent on every dictation —
        // ideal for caching. First request in a 5-min window pays full
        // price + a small write surcharge; everything after is cheap and
        // ~30–50% faster (cache hit avoids re-tokenising the system
        // block).
        //
        // The minimum cacheable size for the cheaper `claude-haiku`
        // family is 1,024 tokens; cleanup prompt clears that. For
        // shorter prompts the cache_control hint is silently ignored.
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": request.maxTokens,
            "system": [
                [
                    "type": "text",
                    "text": request.systemPrompt,
                    "cache_control": ["type": "ephemeral"],
                ],
            ],
            "messages": [
                ["role": "user", "content": request.userMessage],
            ],
        ]

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        httpRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.timeoutInterval = timeoutSeconds
        httpRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        do {
            let response = try await httpClient.send(
                httpRequest,
                providerID: Self.providerID.rawValue,
                kind: .llm,
                requestBodySummary: """
                JSON payload
                model: \(model)
                max_tokens: \(request.maxTokens)
                system_prompt_chars: \(request.systemPrompt.count)
                user_message_chars: \(request.userMessage.count)
                """
            )

            if response.response.statusCode == 429 {
                let retryAfter = response.response.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
                throw LLMError.rateLimited(provider: .anthropic, retryAfter: retryAfter)
            }

            guard (200 ... 299).contains(response.response.statusCode) else {
                throw LLMError.apiError(
                    provider: .anthropic,
                    message: response.errorMessage ?? "The provider rejected the completion request.",
                    statusCode: response.response.statusCode
                )
            }

            let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            let content = json?["content"] as? [[String: Any]]
            let text = content?.first?["text"] as? String ?? ""
            let usage = json?["usage"] as? [String: Any]

            guard !text.isEmpty else {
                throw LLMError.emptyResponse(provider: .anthropic)
            }

            return LLMResponse(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                model: model,
                promptTokens: usage?["input_tokens"] as? Int,
                completionTokens: usage?["output_tokens"] as? Int
            )
        } catch let error as LLMError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw LLMError.timeout(provider: .anthropic)
        } catch {
            throw LLMError.apiError(
                provider: .anthropic,
                message: ProviderHTTPClient.transportErrorMessage(for: error),
                statusCode: nil
            )
        }
    }
}
