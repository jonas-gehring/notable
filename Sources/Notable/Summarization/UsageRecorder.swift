import Foundation

/// Persists what a provider round-trip cost.
///
/// Sits between the Summarization layer, which produces `SummarizationUsage`,
/// and the store, which knows only scalars — so neither has to know the other's
/// type. Every summarization call site funnels through here, which is also the
/// only place that decides what counts as a recordable call.
enum UsageRecorder {
    /// What the tokens were spent on. Stored as a string so a later purpose is
    /// a new case and not a migration. All three of today's cases are real
    /// provider round-trips: a meeting that is summarized, named and then
    /// chatted about spends on all of them.
    enum Purpose: String {
        case summary
        case chat
        case speakerNaming = "speaker_naming"
        /// A dictation the user explicitly asked to have improved. Booked for
        /// one reason above all: it makes the number of times dictated text left
        /// the device countable. `billed` is false (flat rate), so it never
        /// appears in a spend total.
        case dictationEnhance = "dictation-enhance"
    }

    /// Records one round-trip, if the provider reported anything usable.
    ///
    /// Fire-and-forget on purpose: a statistics row must never be the reason a
    /// finished summary is lost, so a store error is swallowed — the cost of
    /// that is one missing row in the usage window. A `nil` usage records
    /// nothing rather than a row of zeros, which would drag averages down with
    /// calls whose spend is simply unknown.
    /// - Parameter countEvenWhenUnknown: writes a zero row when the provider
    ///   reported nothing. Off by default — a row of zeros would drag token
    ///   averages down with calls whose spend is simply unknown. **On for the
    ///   dictation path**, where the row is not an expense but a tally of how
    ///   often dictated text left the device, and where two of the three CLIs
    ///   report no numbers at all. A missing row there would understate that
    ///   count, which is the one thing it exists to state.
    static func record(
        _ usage: SummarizationUsage?,
        provider: String,
        purpose: Purpose,
        recordingID: String?,
        at date: Date = Date(),
        countEvenWhenUnknown: Bool = false,
        store: RecordingStore = .shared
    ) async {
        let usage = usage ?? (countEvenWhenUnknown ? SummarizationUsage() : nil)
        guard let usage else { return }
        try? await store.insertLLMUsage(RecordingStore.LLMUsage(
            recordingID: recordingID,
            provider: provider,
            purpose: purpose.rawValue,
            createdAt: date,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheCreationTokens: usage.cacheCreationTokens,
            cacheReadTokens: usage.cacheReadTokens,
            costUSD: usage.costUSD,
            billed: usage.billed
        ))
    }
}
