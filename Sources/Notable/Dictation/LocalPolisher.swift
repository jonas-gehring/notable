import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether the on-device model can be used, and if not, why (Spec 32 §3.2).
///
/// Said out loud in Settings: a switch that does nothing because Apple
/// Intelligence is off would be exactly the silent failure the rest of this
/// app refuses.
enum LocalModelAvailability: Equatable, Sendable {
    case available
    case requiresNewerSystem
    case deviceNotEligible
    case appleIntelligenceOff
    case modelNotReady
    case unavailable

    var isAvailable: Bool { self == .available }

    var reason: String? {
        switch self {
        case .available: nil
        case .requiresNewerSystem: String(localized: "Braucht macOS 26.")
        case .deviceNotEligible: String(localized: "Dieser Mac unterstützt Apple Intelligence nicht.")
        case .appleIntelligenceOff: String(localized: "Apple Intelligence ist aus — Systemeinstellungen → Apple Intelligence & Siri.")
        case .modelNotReady: String(localized: "Das Modell wird noch geladen.")
        case .unavailable: String(localized: "Das lokale Modell ist nicht verfügbar.")
        }
    }

    static var current: LocalModelAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .deviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled):
                return .appleIntelligenceOff
            case .unavailable(.modelNotReady):
                return .modelNotReady
            case .unavailable:
                return .unavailable
            @unknown default:
                return .unavailable
            }
        }
        #endif
        return .requiresNewerSystem
    }
}

/// What the on-device stage produced.
struct LocalPolishResult: Sendable, Equatable {
    /// The text to paste — the model's, or the rule-polished input.
    var text: String
    var didPolish: Bool
    /// Set when something sent the text back to the rules, for the notice.
    var failure: String?
    /// How long the model took, when it was asked at all.
    var milliseconds: Int?
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct PolishedDictation {
    @Guide(description: "Der aufbereitete Text, sonst nichts.")
    var text: String
}

/// The on-device text stage (Spec 32): Apple's system model, called with one
/// fixed instruction, answer checked by `LocalPolish.accept`.
///
/// **Never throws.** A refused answer, an error and a timeout all return the
/// rule-polished input — the same stance as `DictationEnhancer`, for the same
/// reason: losing a dictation to a model is the worst available trade.
///
/// A fresh session per dictation: a session keeps its transcript, and a
/// dictation must know nothing of the one before — nor fill a 4 096-token
/// context over an afternoon. The next session is created and prewarmed right
/// after each use, so the one waiting is warm.
@available(macOS 26, *)
actor LocalPolisher {
    static let shared = LocalPolisher()

    private var prepared: LanguageModelSession?
    private let deadline: Duration

    /// 4 s: the user is not waiting on purpose here, unlike the CLI enhancement.
    init(deadline: Duration = .seconds(4)) {
        self.deadline = deadline
    }

    func prewarm() {
        guard prepared == nil, LocalModelAvailability.current.isAvailable else { return }
        let session = LanguageModelSession(instructions: LocalPolish.instructions)
        session.prewarm()
        prepared = session
    }

    func polish(_ text: String, category: AppCategory) async -> LocalPolishResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, LocalModelAvailability.current.isAvailable else {
            return LocalPolishResult(text: text, didPolish: false)
        }
        let session = prepared ?? LanguageModelSession(instructions: LocalPolish.instructions)
        prepared = nil
        defer { prewarm() }

        let prompt = LocalPolish.prompt(for: trimmed, category: category)
        let started = ContinuousClock.now
        func elapsed() -> Int {
            let duration = started.duration(to: .now)
            return Int(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
        }

        do {
            let output = try await withDeadline(deadline) {
                try await session.respond(to: prompt, generating: PolishedDictation.self).content.text
            }
            guard let accepted = LocalPolish.accept(output, forInput: trimmed) else {
                return LocalPolishResult(
                    text: text, didPolish: false,
                    failure: String(localized: "Formatierung verworfen — Regeltext eingefügt."),
                    milliseconds: elapsed()
                )
            }
            return LocalPolishResult(text: accepted, didPolish: true, milliseconds: elapsed())
        } catch is DeadlineExceeded {
            return LocalPolishResult(
                text: text, didPolish: false,
                failure: String(localized: "Formatierung dauerte zu lange — Regeltext eingefügt."),
                milliseconds: elapsed()
            )
        } catch {
            return LocalPolishResult(
                text: text, didPolish: false,
                failure: String(localized: "Formatierung fehlgeschlagen — Regeltext eingefügt."),
                milliseconds: elapsed()
            )
        }
    }
}
#endif
