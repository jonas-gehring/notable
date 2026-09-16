import SwiftUI

/// Personal bests, and how far the next milestone is (Spec 37 §3.3, §3.5).
///
/// The reason to open the window. It stands **above** "Details", not inside it:
/// the details answer questions, this one answers none — it is the only place
/// where the numbers are about the person rather than about the app.
///
/// Every value comes out of `recordings`. A record whose measurement never
/// existed — `latency_ms` is null on six weeks of rows — is left out rather
/// than computed from what happens to be there.
struct RecordsCard: View {
    let records: [UsageMetrics.Record]
    let progress: Milestones.Progress?
    let reached: [Milestone]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Flipped once the card is on screen, so a broken record can bounce
    /// exactly once instead of on every re-render.
    @State private var arrived = false

    var body: some View {
        DetailCard(
            title: "Rekorde",
            subtitle: "Aus deinen Aufnahmen gezählt, nie geschätzt.",
            emptyMessage: "Noch keine Rekorde — die stellen sich beim Diktieren ein.",
            isEmpty: records.isEmpty
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach(records) { record in
                    row(record)
                }
                if let progress {
                    Divider().overlay(Theme.border)
                    milestoneBar(progress)
                }
            }
            .onAppear {
                withAnimation(reduceMotion ? nil : Theme.Motion.appear) { arrived = true }
            }
        }
    }

    private func row(_ record: UsageMetrics.Record) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: Self.symbol(record.kind))
                .font(.subheadline)
                .foregroundStyle(record.isNew ? Theme.accent : Theme.textMuted)
                .symbolEffect(.bounce, options: .nonRepeating, value: record.isNew && arrived)
                .frame(width: 18)
            Text(Self.label(record.kind))
                .font(.subheadline)
                .foregroundStyle(Theme.textEmphasis)
                .frame(width: 180, alignment: .leading)
                .lineLimit(1)
            Text(Self.value(record))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.textEmphasis)
            if record.isNew {
                // A band, not a colour: "Neu" is readable, and a coloured row
                // would have to mean something the rest of the time too.
                Text("Neu")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.accent.opacity(0.15)))
                    .foregroundStyle(Theme.accent)
                    .transition(.opacity)
            }
            Spacer(minLength: Theme.Spacing.s)
            if let at = record.at {
                Text(at.formatted(.dateTime.day().month(.abbreviated).year()))
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    /// "noch 2.023 bis 10.000" — the next threshold, and nothing about the ones
    /// long past except how many there were.
    private func milestoneBar(_ progress: Milestones.Progress) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "flag.checkered")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                Text("Noch \(UsageMetrics.integer(progress.remaining)) bis \(progress.milestone.title)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSubtle)
                Spacer(minLength: Theme.Spacing.s)
                if !reached.isEmpty {
                    Text("\(reached.count) erreicht")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceSubtle)
                    Capsule()
                        .fill(Theme.chartPrimary)
                        .frame(width: max(2, proxy.size.width * (arrived ? progress.fraction : 0)))
                }
            }
            .frame(height: 8)
            .animation(reduceMotion ? nil : Theme.Motion.gentle, value: progress.fraction)
        }
    }

    // MARK: - Presentation

    private static func label(_ kind: UsageMetrics.Record.Kind) -> String {
        switch kind {
        case .longestDictation: String(localized: "Längstes Diktat")
        case .bestDay: String(localized: "Meiste Wörter an einem Tag")
        case .bestWeek: String(localized: "Beste Woche")
        case .longestStreak: String(localized: "Längste Serie")
        case .fastestDictation: String(localized: "Schnellstes Diktat")
        }
    }

    private static func symbol(_ kind: UsageMetrics.Record.Kind) -> String {
        switch kind {
        case .longestDictation: "text.alignleft"
        case .bestDay: "sun.max"
        case .bestWeek: "calendar"
        case .longestStreak: "flame"
        case .fastestDictation: "bolt"
        }
    }

    private static func value(_ record: UsageMetrics.Record) -> String {
        switch record.kind {
        case .longestDictation, .bestDay:
            String(localized: "\(UsageMetrics.integer(record.value)) Wörter")
        case .bestWeek:
            String(localized: "\(UsageMetrics.duration(TimeInterval(record.value))) gespart")
        case .longestStreak:
            String(localized: "\(record.value) Tage")
        case .fastestDictation:
            String(localized: "\(record.value) ms")
        }
    }
}
