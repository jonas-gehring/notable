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

        var label: String {
            switch self {
            case .idle: "Bereit"
            case .recording: "Aufnahme läuft…"
            case .transcribing: "Transkribiere…"
            }
        }
    }

    @Published var captureState: CaptureState = .idle
}
