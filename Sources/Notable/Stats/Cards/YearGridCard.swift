import SwiftUI

/// A year of dictating on one surface (Spec 37 §3.3).
///
/// At the "Jahr" granularity a bar chart of five years says almost nothing —
/// five bars, one of them this year, three of them empty. The same cells as the
/// heatmap, one per day, say what a year of using this actually looked like.
///
/// The existing data reaches back to July, so ten of the columns are full and
/// the rest are empty. That is honest, and it fills up by itself.
struct YearGridCard: View {
    /// 7 rows (row 0 = the calendar's first weekday) × 53 columns.
    let grid: [[UsageMetrics.DayCell]]
    let calendar: Calendar

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private var peak: Int {
        grid.flatMap { $0 }.map(\.words).max() ?? 0
    }

    var body: some View {
        DetailCard(
            title: "Dein Jahr",
            subtitle: peak > 0 ? "Ein Feld je Tag, heller = mehr Wörter." : nil,
            emptyMessage: "Noch keine Diktate.",
            isEmpty: peak == 0
        ) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(grid.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 3) {
                        Text(weekdaySymbol(index))
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 24, alignment: .leading)
                        ForEach(row) { cell in
                            RoundedRectangle(cornerRadius: Theme.radiusMark)
                                .fill(fill(cell))
                                .frame(height: 9)
                                .help(label(cell))
                                // 371 unlabelled shapes otherwise — the same
                                // lesson as the heatmap.
                                .accessibilityLabel(label(cell))
                        }
                    }
                }
                Text(range)
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(reduceMotion ? nil : Theme.Motion.appear) { shown = true } }
        }
    }

    /// A day that has not happened yet is drawn as nothing at all — not as a
    /// quiet day, which is what a floor colour would claim.
    private func fill(_ cell: UsageMetrics.DayCell) -> Color {
        guard !cell.inFuture else { return Color.clear }
        guard peak > 0, cell.words > 0 else { return Theme.chartPrimary.opacity(0.06) }
        return Theme.chartPrimary.opacity(0.15 + 0.85 * (Double(cell.words) / Double(peak)))
    }

    private func label(_ cell: UsageMetrics.DayCell) -> String {
        let day = cell.date.formatted(.dateTime.day().month(.abbreviated).year())
        return String(localized: "\(day) — \(UsageMetrics.integer(cell.words)) Wörter")
    }

    private func weekdaySymbol(_ index: Int) -> String {
        let symbols = calendar.shortWeekdaySymbols
        return symbols[(index + calendar.firstWeekday - 1) % 7]
    }

    private var range: String {
        guard let first = grid.first?.first?.date, let last = grid.first?.last?.date else { return "" }
        let from = first.formatted(.dateTime.month(.abbreviated).year())
        let to = last.formatted(.dateTime.month(.abbreviated).year())
        return "\(from) – \(to)"
    }
}
