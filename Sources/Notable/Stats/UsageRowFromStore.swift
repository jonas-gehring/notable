import Foundation

/// The one place `RecordingStore.UsageRecord` becomes a `UsageRow`.
///
/// It was written out twice — in `StatsView` and in `UsageSummary` — and the two
/// copies had already drifted: the menu-line version dropped `engine`,
/// `latencyMs` and `sourceApp`, which is harmless only because the menu line
/// does not read them. The direction matters too: this extension lives in the
/// Stats layer, not in `UsageMetrics`, so the pure metrics core keeps knowing
/// nothing about SQLite.
extension UsageRow {
    init(_ record: RecordingStore.UsageRecord) {
        self.init(
            kind: record.kind == .dictation ? .dictation : .meeting,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            wordCount: record.wordCount,
            engine: record.engine,
            latencyMs: record.latencyMs,
            sourceApp: record.sourceApp
        )
    }
}
