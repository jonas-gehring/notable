import SwiftUI

/// The assumption behind every "gespart" number: how fast the same text would
/// have been typed.
///
/// It stood twice — once in the menu-bar settings pane, once at the bottom of
/// the statistics window — as two `Stepper`s over the same `@AppStorage` key,
/// and only one of the two remembered to refresh the menu line afterwards. The
/// saved-time figure is computed, never stored, so changing the assumption has
/// to recompute everything that shows it; a copy that forgets that leaves the
/// menu quoting a number from the old assumption until the next dictation.
struct TypingSpeedStepper: View {
    /// The two surroundings this appears in. The stepper, its range, its key
    /// and its side effect are the same; only the label around it differs,
    /// because one sits in a `Form` row and the other in a styled card.
    enum Style { case formRow, card }

    var style: Style = .formRow

    @AppStorage(DefaultsKey.typingWPM.key) private var typingWPM = DefaultsKey.typingWPM.fallback

    var body: some View {
        Stepper(value: $typingWPM, in: 20 ... 120, step: 5) {
            switch style {
            case .formRow:
                LabeledContent("Tippgeschwindigkeit", value: "\(Int(typingWPM)) WPM")
            case .card:
                Text("\(Int(typingWPM)) WPM")
                    .monospacedDigit()
                    .foregroundStyle(Theme.textEmphasis)
            }
        }
        // The saved-time figure is computed, never stored, so changing the
        // assumption has to recompute everything that shows it. The copy in the
        // statistics window remembered this; the one in the settings did not.
        .onChange(of: typingWPM) { _, _ in AppContainer.shared.usage.refreshSoon() }
    }
}
