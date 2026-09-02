import AppKit
import SwiftUI

/// A restrained layer on top of *native* AppKit system colours,
/// so everything still reads as SwiftUI: neutral greys, generous whitespace, hair
/// borders, colour used sparingly. Using the semantic `NSColor`s (label / control
/// / separator) keeps it adaptive in light and dark for free.
enum Theme {
    // MARK: Surfaces (native greys)
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let surfaceSubtle = Color.primary.opacity(0.05)
    static let hover = Color.primary.opacity(0.07)

    // MARK: Border
    static let border = Color(nsColor: .separatorColor)

    // MARK: Text (native label ramp)
    static let textEmphasis = Color(nsColor: .labelColor)
    static let textDefault = Color(nsColor: .labelColor)
    static let textSubtle = Color(nsColor: .secondaryLabelColor)
    static let textMuted = Color(nsColor: .tertiaryLabelColor)

    // MARK: Accents — used sparingly
    static let accent = Color(nsColor: .controlAccentColor)
    static let success = Color(nsColor: .systemGreen)
    static let danger = Color(nsColor: .systemRed)

    // MARK: Chart hues
    /// Two data hues, one per single-series chart. Each mode has its **own** steps
    /// (a dark palette is chosen, never an automatic flip of the light one) and both
    /// pairs were run through the palette validator against their surface: lightness
    /// band, chroma floor, CVD separation (worst pair ΔE 18 deutan) and 3:1 contrast
    /// all pass. Don't hand-tweak these without re-validating.
    static let chartPrimary = dynamic(light: rgb(0x4F, 0x46, 0xE5), dark: rgb(0x6E, 0x6B, 0xF2))
    static let chartSecondary = dynamic(light: rgb(0x0D, 0x94, 0x88), dark: rgb(0x1A, 0xA3, 0x96))

    // MARK: Geometry
    static let radiusCard: CGFloat = 10
    static let radiusControl: CGFloat = 7
    static let radiusSmall: CGFloat = 6

    // MARK: Private

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// Resolves per appearance, so a fixed brand hue still adapts light/dark the way
    /// the semantic `NSColor`s above do.
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Reusable surfaces

/// A quiet, native-feeling card: control-background fill, hairline separator
/// border, soft rounding. Content supplies its own padding via `padding:`.
struct CalCard: ViewModifier {
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .fill(Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1))
    }
}

extension View {
    func calCard(padding: CGFloat = 14) -> some View { modifier(CalCard(padding: padding)) }
}

/// A restrained segmented control: a recessed track with a raised surface pill
/// under the selection.
struct CalSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == option.value ? Theme.textEmphasis : Theme.textSubtle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                                .fill(selection == option.value ? Theme.surface : .clear)
                                .shadow(color: .black.opacity(selection == option.value ? 0.08 : 0),
                                        radius: 1, y: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .fill(Theme.surfaceSubtle))
    }
}
