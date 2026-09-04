import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum CaptureState {
        case idle
        case recording
        case transcribing

        var symbolName: String {
            switch self {
            case .idle: "waveform"
            case .recording: "waveform.circle.fill"
            case .transcribing: "hourglass.circle"
            }
        }

        /// Every branch through `String(localized:)`: this is a plain `String`,
        /// and `Text(state.label)` renders it verbatim — two of the three used
        /// to show German inside an English window, right next to a third that
        /// did not.
        var label: String {
            switch self {
            case .idle: String(localized: "Bereit")
            case .recording: String(localized: "Aufnahme läuft…")
            case .transcribing: String(localized: "Transkribiere…")
            }
        }
    }

    @Published var captureState: CaptureState = .idle
}
