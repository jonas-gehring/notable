import SwiftUI

/// "Nothing here yet", said the same way everywhere (Spec 33 §3.6).
///
/// There were three visual languages for it: `ContentUnavailableView`, a bespoke
/// card in the statistics window, and seven hand-written grey `Text` lines that
/// differed in punctuation and wording. Whole windows keep
/// `ContentUnavailableView`; every list inside a form uses this.
struct EmptyState: View {
    let title: LocalizedStringKey
    var systemImage: String?

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: LocalizedStringKey, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .foregroundStyle(.secondary)
        // Fades in rather than appearing mid-layout: a list that has just
        // finished loading and a list that is empty look the same for one
        // frame, and the jump is what made the difference invisible.
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(reduceMotion ? nil : Theme.Motion.appear) { shown = true } }
    }
}

/// A download, shown the same way wherever one runs (Spec 33 §3.6).
///
/// Four places reported progress in four wordings ("ASR-Modell lädt: 40 %",
/// "lädt: 40 %", "Das große Modell lädt noch: 40 %", "Wird geladen — 40 %"),
/// and only the update had a bar. The wording now comes from `percent`, and
/// every place with room for a bar gets one.
struct DownloadProgressRow: View {
    let fraction: Double?
    var caption: LocalizedStringKey?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The one wording, also for the menu, which cannot draw a bar.
    static func percent(_ fraction: Double) -> String {
        String(localized: "Lädt: \(Int((fraction * 100).rounded())) %")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let fraction {
                // A download reports in jumps (one per chunk); the bar moves
                // between them instead of teleporting.
                ProgressView(value: fraction)
                    .animation(reduceMotion ? nil : Theme.Motion.gentle, value: fraction)
                Text(Self.percent(fraction))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: Theme.Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Lädt…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
