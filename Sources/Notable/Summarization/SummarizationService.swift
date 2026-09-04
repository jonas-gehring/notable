import Foundation

/// Resolves the provider chosen in Settings and runs summarization.
/// No silent fallback: if the chosen provider is unavailable, the error
/// names it and points at Settings — the user decides.
struct SummarizationService: Sendable {
    static let providers: [any SummarizationProvider] = [
        AnthropicAPIProvider(),
        ClaudeCodeCLIProvider(),
        AgentCLIProvider(tool: .gemini),
        AgentCLIProvider(tool: .codex),
    ]

    static func provider(withID id: String) -> (any SummarizationProvider)? {
        providers.first { $0.id == id }
    }

    /// - Parameter providerID: value of the `summarizationProvider` setting.
    static func summarize(
        transcript: String,
        context: MeetingContext,
        providerID: String
    ) async throws -> Summary {
        guard let provider = provider(withID: providerID) else {
            throw SummarizationError.notConfigured("Unbekannter Provider: \(providerID)")
        }
        if case .unavailable(let reason) = await provider.availability() {
            throw SummarizationError.notConfigured(String(localized: "\(provider.displayName) nicht verfügbar: \(reason)"))
        }
        return try await provider.summarize(transcript: transcript, context: context)
    }

    /// Raw system+user completion via the chosen provider (used by
    /// `SpeakerNameResolver` and the transcript chat). Same no-silent-fallback
    /// contract as `summarize`. Returns the spend alongside the text so every
    /// provider round-trip can be booked, not just summaries.
    static func complete(
        system: String,
        user: String,
        providerID: String
    ) async throws -> Completion {
        guard let provider = provider(withID: providerID) else {
            throw SummarizationError.notConfigured("Unbekannter Provider: \(providerID)")
        }
        if case .unavailable(let reason) = await provider.availability() {
            throw SummarizationError.notConfigured(String(localized: "\(provider.displayName) nicht verfügbar: \(reason)"))
        }
        return try await provider.complete(system: system, user: user)
    }
}
