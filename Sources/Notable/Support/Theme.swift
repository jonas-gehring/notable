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
    /// The label colour. There used to be a `textDefault` with the identical
    /// value next to it — a token that carried no information (Spec 33 §3.3).
    static let textEmphasis = Color(nsColor: .labelColor)
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
    /// Chart marks such as heatmap cells — a mark, not a surface.
    static let radiusMark: CGFloat = 2

    // MARK: Spacing, typography, motion (Spec 33 §3.3)

    /// The only spacing steps. A value between two of them is a decision nobody
    /// made on purpose; `StatsView` alone used to have twelve different ones.
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// The two sizes no text style covers: the big numbers in the statistics
    /// window and the onboarding icons. Everything else uses a semantic font
    /// (`.callout`, `.headline`, …), so it follows the system text size.
    enum Typography {
        static let display = Font.system(size: 30)
        static let hero = Font.system(size: 40, weight: .semibold)
    }

    /// Durations for appearing, disappearing and changing state — the HUD's
    /// numbers from Spec 30, named once.
    enum Motion {
        static let appear: Double = 0.12
        static let disappear: Double = 0.16
        static let state: Double = 0.20
    }

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
