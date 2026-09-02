import SwiftUI

/// When the user dictates — 7 × 24, one hue, intensity = words.
///
/// Only the busiest cell and the axis ends are labelled. A grid of 168 numbers is
/// not a chart, and the question here is "when do I work", which one bright square
/// answers on its own.
struct HeatmapCard: View {
    /// 7 × 24, row 0 = the calendar's first weekday.
    let matrix: [[UsageTotals]]
    let calendar: Calendar

    private var peak: Int {
        matrix.flatMap { $0 }.map(\.dictationWords).max() ?? 0
    }

    var body: some View {
        DetailCard(
            title: "Wann du diktierst",
            subtitle: peak > 0 ? "Spitze: \(peakLabel)" : nil,
            emptyMessage: "Noch keine Diktate.",
            isEmpty: peak == 0
        ) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(matrix.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 3) {
                        Text(weekdaySymbol(index))
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 24, alignment: .leading)
                        ForEach(Array(row.enumerated()), id: \.offset) { hour, totals in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.chartPrimary.opacity(intensity(totals.dictationWords)))
                                .frame(height: 11)
                                .help("\(weekdaySymbol(index)) \(hour):00 — \(UsageMetrics.integer(totals.dictationWords)) Wörter")
                        }
                    }
                }
                HStack(spacing: 3) {
                    Color.clear.frame(width: 24, height: 1)
                    Text("0")
                    Spacer()
                    Text("12")
                    Spacer()
                    Text("23")
                }
                .font(.system(size: 9))
                .foregroundStyle(Theme.textMuted)
            }
        }
    }

    /// A hard floor so a quiet hour is still visibly *an* hour, not background.
    private func intensity(_ words: Int) -> Double {
        guard peak > 0, words > 0 else { return 0.06 }
        return 0.15 + 0.85 * (Double(words) / Double(peak))
    }

    private func weekdaySymbol(_ index: Int) -> String {
        let symbols = calendar.shortWeekdaySymbols
        return symbols[(index + calendar.firstWeekday - 1) % 7]
    }

    private var peakLabel: String {
        var best = (row: 0, hour: 0, words: 0)
        for (row, hours) in matrix.enumerated() {
            for (hour, totals) in hours.enumerated() where totals.dictationWords > best.words {
                best = (row, hour, totals.dictationWords)
            }
        }
        return "\(weekdaySymbol(best.row)) \(best.hour):00 · \(UsageMetrics.integer(best.words)) Wörter"
    }
}
