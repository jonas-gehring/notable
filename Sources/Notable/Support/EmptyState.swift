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

    /// The one wording, also for the menu, which cannot draw a bar.
    static func percent(_ fraction: Double) -> String {
        String(localized: "Lädt: \(Int((fraction * 100).rounded())) %")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let fraction {
                ProgressView(value: fraction)
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
