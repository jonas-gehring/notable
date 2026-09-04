import Foundation

/// Option 1: Anthropic API with `claude-sonnet-5`, key from the Keychain.
/// Raw URLSession — there is no official Swift SDK. Sonnet 5 rejects
/// sampling parameters (`temperature` etc.), so none are sent.
struct AnthropicAPIProvider: SummarizationProvider {
    let id = "anthropic-api"
    let displayName = "Anthropic API (claude-sonnet-5)"

    static let model = "claude-sonnet-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func availability() async -> ProviderAvailability {
        // "Not there" and "not allowed to look" are different problems and used
        // to read the same — which sent the user off to create a key they
        // already had.
        switch KeychainStore.readResult(account: KeychainStore.anthropicAPIKeyAccount) {
        case .value:
            return .available
        case .absent:
            return .unavailable(reason: String(localized: "Kein API-Key im Schlüsselbund (Einstellungen → Zusammenfassung)."))
        case .denied(let status):
            return .unavailable(reason: String(localized: "Schlüsselbund verweigert den Zugriff auf den API-Key (OSStatus \(Int(status))) — Eintrag „de.jonasgehring.notable“ prüfen."))
        }
    }

    func summarize(transcript: String, context: MeetingContext) async throws -> Summary {
        let prompt = SummarizationPrompt.messages(transcript: transcript, context: context)
        let response = try await requestText(
            system: prompt.system,
            user: prompt.user,
            maxTokens: 16000 // Sonnet 5 counts adaptive thinking against max_tokens
        )
        return Summary(rawModelOutput: response.text, providerID: id, usage: response.usage)
    }

    /// `maxTokens` defaults to a chat-sized ceiling, not a naming-sized one.
    ///
    /// It used to be hard-wired to 1024 with a comment about the strict-JSON
    /// speaker mapping — but `MeetingChat` calls the same method for answers
    /// about transcripts of up to 120 000 characters, and adaptive thinking
    /// counts against `max_tokens` too. A longer answer hit
    /// `stop_reason == "max_tokens"`, which the chat turns into an *error*: the
    /// question was paid for and the user got nothing. Callers that really do
    /// want a tight ceiling pass one.
    func complete(system: String, user: String) async throws -> Completion {
        try await complete(system: system, user: user, maxTokens: Self.defaultCompletionTokens)
    }

    /// A chat-sized ceiling by default, not a naming-sized one.
    static let defaultCompletionTokens = 8192

    func complete(system: String, user: String, maxTokens: Int) async throws -> Completion {
        let response = try await requestText(system: system, user: user, maxTokens: maxTokens)
        return Completion(text: response.text, usage: response.usage)
    }

    /// One system+user round-trip, returning the concatenated text blocks.
    /// Shared by `summarize` and `complete` so the request wiring, retry
    /// policy, and `stop_reason` checks live in exactly one place.
    private func requestText(system: String, user: String, maxTokens: Int) async throws -> (text: String, usage: SummarizationUsage?) {
        guard let apiKey = KeychainStore.read(account: KeychainStore.anthropicAPIKeyAccount) else {
            throw SummarizationError.notConfigured(String(localized: "Kein API-Key im Schlüsselbund."))
        }

        let body = MessagesRequest(
            model: Self.model,
            maxTokens: maxTokens,
            system: system,
            messages: [.init(role: "user", content: user)],
            outputConfig: .init(effort: "low")
        )

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)

        let data = try await Self.send(request)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let message = try decoder.decode(MessagesResponse.self, from: data)

        switch message.stopReason {
        case "refusal":
            throw SummarizationError.requestFailed(String(localized: "Das Modell hat die Anfrage abgelehnt (refusal)."))
        case "max_tokens":
            throw SummarizationError.requestFailed("Antwort abgeschnitten (max_tokens erreicht).")
        default:
            break
        }

        let text = message.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw SummarizationError.unexpectedResponse("Leere Antwort.")
        }
        return (text, Self.usage(from: message.usage))
    }

    /// Per-million-token list prices for `Self.model`. Hard-coded on purpose:
    /// the API does not return a price, so the only alternatives are this or no
    /// cost figure at all. **Update alongside `model`.**
    private static let inputPricePerMTok = 2.00   // claude-sonnet-5
    private static let outputPricePerMTok = 10.00 // claude-sonnet-5

    /// Real money, unlike the CLI provider's figure — this account is metered.
    ///
    /// Cache tokens are reported but not priced: the summarization requests
    /// carry no `cache_control`, so both counters are zero. Introducing caching
    /// means adding its rates here, or the total silently under-reports.
    private static func usage(from usage: MessagesResponse.Usage?) -> SummarizationUsage? {
        guard let usage else { return nil }
        let input = usage.inputTokens ?? 0
        let output = usage.outputTokens ?? 0
        let cost = Double(input) / 1_000_000 * inputPricePerMTok
            + Double(output) / 1_000_000 * outputPricePerMTok
        return SummarizationUsage(
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: usage.cacheCreationInputTokens ?? 0,
            cacheReadTokens: usage.cacheReadInputTokens ?? 0,
            costUSD: cost,
            billed: true
        )
    }

    /// Rate limits (429) and capacity (529) are transient by definition — and
    /// they arrive right when a meeting has just ended, i.e. at the worst
    /// possible moment. Failing on the first one hands the user a note without
    /// a summary and a manual retry from the menu; a short backoff usually
    /// makes the problem disappear. `Retry-After` wins over our own delay when
    /// the server sends one.
    private static let retriableStatus: Set<Int> = [429, 500, 502, 503, 529]
    private static let maximumAttempts = 3

    /// Transport failures that mean "try again", as opposed to "this will never
    /// work". A connection reset right after a meeting ends is the same
    /// transient the status-code retry was written for — but it arrives as a
    /// thrown `URLError`, so the loop never saw it and attempt 1 was the last.
    private static let retriableURLErrors: Set<URLError.Code> = [
        .networkConnectionLost, .timedOut, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
        .secureConnectionFailed, .resourceUnavailable,
    ]

    private static func send(_ request: URLRequest) async throws -> Data {
        var lastDetail = ""
        for attempt in 1...maximumAttempts {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let error as URLError where retriableURLErrors.contains(error.code)
                && attempt < maximumAttempts {
                lastDetail = error.localizedDescription
                try await Task.sleep(for: .seconds(Double(1 << (attempt - 1)) * 2))
                continue
            }
            guard let http = response as? HTTPURLResponse else {
                throw SummarizationError.requestFailed(String(localized: "Keine HTTP-Antwort."))
            }
            if http.statusCode == 200 { return data }

            lastDetail = errorDetail(from: data)
            guard retriableStatus.contains(http.statusCode), attempt < maximumAttempts else {
                throw SummarizationError.requestFailed("HTTP \(http.statusCode): \(lastDetail)")
            }

            let advised = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
            let backoff = advised ?? Double(1 << (attempt - 1)) * 2 // 2 s, 4 s
            try await Task.sleep(for: .seconds(min(backoff, 60)))
        }
        throw SummarizationError.requestFailed(lastDetail)
    }

    /// Cheap connectivity/key check against GET /v1/models (no token cost).
    static func validateKey() async -> String {
        guard let apiKey = KeychainStore.read(account: KeychainStore.anthropicAPIKeyAccount) else {
            return "Kein Key hinterlegt."
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "Keine HTTP-Antwort." }
            switch http.statusCode {
            case 200: return String(localized: "Verbindung ok — Key gültig.")
            case 401: return String(localized: "Key ungültig (401).")
            default: return "Unerwartete Antwort: HTTP \(http.statusCode)."
            }
        } catch {
            return "Netzwerkfehler: \(error.localizedDescription)"
        }
    }

    private static func errorDetail(from data: Data) -> String {
        struct APIError: Decodable {
            struct Detail: Decodable {
                let type: String?
                let message: String?
            }
            let error: Detail?
        }
        if let parsed = try? JSONDecoder().decode(APIError.self, from: data),
           let message = parsed.error?.message {
            return message
        }
        return String(data: data.prefix(300), encoding: .utf8) ?? "unlesbar"
    }

    // MARK: - Wire types

    private struct MessagesRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct OutputConfig: Encodable {
            let effort: String
        }
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]
        let outputConfig: OutputConfig
    }

    private struct MessagesResponse: Decodable {
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
        /// Every field optional: a usage block that gains or loses a counter
        /// must never fail the decode and cost the user their summary.
        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?
        }
        let content: [ContentBlock]
        let stopReason: String?
        let usage: Usage?
    }
}
