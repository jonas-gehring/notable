import SwiftUI

/// Shared frame for the "Details" cards (issue #5).
///
/// Every one of them can be empty — the four measurements they rest on did not
/// exist before the update, so six weeks of rows carry `NULL`. An empty card must
/// therefore *say* that measuring has only just begun; a blank rectangle reads as
/// a bug.
struct DetailCard<Content: View>: View {
    let title: String
    var subtitle: String?
    /// Shown instead of the content when there is nothing to draw yet.
    var emptyMessage: String = "Wird ab jetzt gemessen."
    var isEmpty: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textEmphasis)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSubtle)
                }
            }
            if isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .calCard()
    }
}

/// One labelled row with a proportion bar — used by both the engine and the
/// target-app card, which are the same shape with different labels.
struct ShareRow: View {
    let label: String
    let value: String
    /// 0…1 relative to the largest row.
    let fraction: Double
    var icon: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDefault)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceSubtle)
                    Capsule()
                        .fill(Theme.chartPrimary)
                        .frame(width: max(2, proxy.size.width * fraction))
                }
            }
            .frame(height: 8)
            Text(value)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textSubtle)
                .frame(width: 90, alignment: .trailing)
        }
    }
}
