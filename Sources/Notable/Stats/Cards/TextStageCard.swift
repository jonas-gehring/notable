import SwiftUI

/// Which stage shaped the dictated text last, and how long the on-device stage
/// takes (Spec 32 §3.7, §3.8).
///
/// The CLI row names what it means — the text left the device — because that is
/// the one fact this card exists to make countable at a glance. Rows from before
/// the column existed stay "Unbekannt", never folded into the rules.
struct TextStageCard: View {
    let shares: [(polisher: String, count: Int)]
    let latency: UsageMetrics.LatencyStats?

    private var total: Int { shares.map(\.count).reduce(0, +) }

    var body: some View {
        DetailCard(
            title: "Wer den Text geformt hat",
            subtitle: "Die Regeln laufen immer; das lokale Modell und die CLI nur, wenn eingeschaltet.",
            emptyMessage: "Noch keine Diktate mit dieser Messung.",
            isEmpty: total == 0
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(shares, id: \.polisher) { entry in
                    ShareRow(
                        label: label(entry.polisher),
                        value: "\(entry.count)×",
                        fraction: total > 0 ? Double(entry.count) / Double(total) : 0
                    )
                }
                if let latency {
                    Divider().overlay(Theme.border)
                    Text("Auf dem Gerät: \(Int(latency.p50)) ms · p95 \(Int(latency.p95)) ms (\(latency.count))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.textSubtle)
                }
            }
        }
    }

    private func label(_ polisher: String) -> String {
        switch polisher {
        case "rules": String(localized: "Regeln")
        case "local": String(localized: "Lokales Modell")
        case "command": String(localized: "Befehl (lokal)")
        case "cli": String(localized: "CLI — Text verließ das Gerät")
        default: String(localized: "Unbekannt")
        }
    }
}
