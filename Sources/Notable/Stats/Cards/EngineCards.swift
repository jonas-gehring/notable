import AppKit
import SwiftUI

/// Which transcriber the words came from.
///
/// Rows without an engine are shown as "Unbekannt" rather than folded into the
/// current one: every dictation from before this update has no engine recorded,
/// and attributing them to Parakeet would be an invented measurement.
struct EngineUsageCard: View {
    let totals: [(engine: String, totals: UsageTotals)]

    private var peak: Int { totals.map(\.totals.dictationWords).max() ?? 0 }

    var body: some View {
        DetailCard(
            title: "Womit du diktierst",
            emptyMessage: "Noch keine Diktate.",
            isEmpty: totals.isEmpty
        ) {
            VStack(spacing: 6) {
                ForEach(totals, id: \.engine) { entry in
                    ShareRow(
                        label: label(entry.engine),
                        value: "\(UsageMetrics.integer(entry.totals.dictationWords)) W · \(entry.totals.dictationCount)×",
                        fraction: peak > 0 ? Double(entry.totals.dictationWords) / Double(peak) : 0
                    )
                }
            }
        }
    }

    private func label(_ engine: String) -> String {
        ASREngineID(rawValue: engine)?.label ?? UsageMetrics.displayKey(engine)
    }
}

/// How fast each engine actually is, in the field.
///
/// Median and p95, never the mean: one cold start (loading a model) adds seconds
/// and would libel a fast engine for the rest of its life. Under ten measurements
/// the card says so instead of printing a number it cannot support.
struct EnginePerformanceCard: View {
    let stats: [(engine: String, stats: UsageMetrics.LatencyStats?)]
    let wordsPerMinute: Double

    private var hasAny: Bool { stats.contains { $0.stats != nil } }

    var body: some View {
        DetailCard(
            title: "Wie schnell die Engines sind",
            subtitle: "Median und p95 — nie der Mittelwert, den ein einzelner Kaltstart verzerrt.",
            emptyMessage: "Noch zu wenig Messungen (mindestens \(UsageMetrics.minimumLatencySamples) Diktate je Engine).",
            isEmpty: !hasAny
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(stats, id: \.engine) { entry in
                    HStack(spacing: 8) {
                        Text(ASREngineID(rawValue: entry.engine)?.label ?? UsageMetrics.displayKey(entry.engine))
                            .font(.system(size: 11))
                            .frame(width: 200, alignment: .leading)
                            .lineLimit(1)
                        if let value = entry.stats {
                            Text("\(Int(value.p50)) ms · p95 \(Int(value.p95)) ms")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Theme.textDefault)
                            Text("(\(value.count))")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textMuted)
                        } else {
                            Text("zu wenig Daten")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                    }
                }
                if wordsPerMinute > 0 {
                    Divider().overlay(Theme.border)
                    Text("Du sprichst im Schnitt \(Int(wordsPerMinute.rounded())) Wörter pro Minute Aufnahme.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSubtle)
                }
            }
        }
    }
}

/// Where the dictated text goes. The bundle ID never leaves SQLite — it is
/// resolved to a name and an icon here, at display time.
struct TargetAppsCard: View {
    let totals: [(sourceApp: String, totals: UsageTotals)]

    private var peak: Int { totals.map(\.totals.dictationWords).max() ?? 0 }

    var body: some View {
        DetailCard(
            title: "Wohin du diktierst",
            emptyMessage: "Wird ab jetzt erfasst — abschaltbar unter Speicherplatz.",
            isEmpty: totals.isEmpty || totals.allSatisfy { $0.sourceApp == UsageMetrics.unknownKey }
        ) {
            VStack(spacing: 6) {
                ForEach(totals, id: \.sourceApp) { entry in
                    ShareRow(
                        label: Self.displayName(entry.sourceApp),
                        value: "\(UsageMetrics.integer(entry.totals.dictationWords)) W · \(entry.totals.dictationCount)×",
                        fraction: peak > 0 ? Double(entry.totals.dictationWords) / Double(peak) : 0,
                        icon: Self.icon(entry.sourceApp)
                    )
                }
            }
        }
    }

    static func displayName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            // Covers the "Unbekannt" bucket, which is not a bundle ID at all.
            return UsageMetrics.displayKey(bundleID)
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    static func icon(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
