import SwiftUI

/// The streak, as a surface rather than a line (Spec 37 §3.3).
///
/// This deliberately reverses a comment that stood in `StatsView`: "a streak is
/// one number and deserves no more room than that." That was right while the
/// streak was a footnote. If it is meant to carry any of the feeling, it needs
/// the room — so it gets a ring, the current number, and the best there has been.
///
/// **No punishment.** A broken streak does not turn red and does not say what
/// was lost; it says "Neue Serie: 1 Tag". Streaks as pressure are somebody
/// else's product decision.
struct StreakCard: View {
    let current: Int
    let longest: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    /// The ring closes at the next streak milestone — the same thresholds the
    /// moments use, so the circle means something rather than being a
    /// percentage of an arbitrary number.
    private var target: Int {
        [7, 30, 100, 365].first { $0 > current } ?? 365
    }

    private var fraction: Double {
        guard target > 0 else { return 0 }
        return min(1, Double(current) / Double(target))
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            ZStack {
                Circle()
                    .stroke(Theme.surfaceSubtle, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: drawn ? fraction : 0)
                    .stroke(Theme.chartPrimary, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Image(systemName: "flame")
                        .font(.subheadline)
                        .foregroundStyle(Theme.chartPrimary)
                    Text(UsageMetrics.integer(current))
                        .font(Theme.Typography.display)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textEmphasis)
                        .contentTransition(.numericText())
                }
            }
            .frame(width: 104, height: 104)
            .animation(reduceMotion ? nil : Theme.Motion.gentle, value: fraction)
            .onAppear { withAnimation(reduceMotion ? nil : Theme.Motion.gentle) { drawn = true } }

            Text(caption)
                .font(.subheadline)
                .foregroundStyle(Theme.textSubtle)
                .multilineTextAlignment(.center)
            if longest > current {
                Text("Bester: \(longest) Tage")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .calCard()
    }

    private var caption: String {
        switch current {
        case 0: String(localized: "Noch keine Serie")
        case 1: String(localized: "Neue Serie: 1 Tag")
        default: String(localized: "\(current) Tage in Folge")
        }
    }
}
