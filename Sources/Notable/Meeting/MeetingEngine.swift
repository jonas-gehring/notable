import Foundation

/// Which model transcribes a meeting (plan of 2026-10-21, Phase 2).
///
/// Parakeet v3 stays the default until the archive replay
/// (`MeetingPipelineReplayTests`) shows another engine doing better on real
/// meetings (Spec 39 §3.4). Whisper large-v3-turbo can be chosen before that,
/// so the replay's numbers can be checked against daily use.
///
/// One picker where there used to be a switch ("Meetings mit dem gewählten
/// Diktat-Modell transkribieren"). That key is still read and still written,
/// so a build from before this keeps the user's choice.
enum MeetingEngineChoice: String, CaseIterable, Identifiable, Sendable {
    case parakeet
    case dictation
    case whisperTurbo = "whisper-turbo"

    var id: String { rawValue }

    static var current: MeetingEngineChoice {
        MeetingEngineChoice(
            stored: DefaultsKey.meetingEngine.value(),
            useDictationEngine: DefaultsKey.meetingUseDictationEngine.value()
        )
    }

    /// A stored choice wins; without one, the old switch decides.
    init(stored: String, useDictationEngine: Bool) {
        if let choice = MeetingEngineChoice(rawValue: stored) {
            self = choice
        } else {
            self = useDictationEngine ? .dictation : .parakeet
        }
    }

    /// Downloads and compiles the Whisper model in the background when it is
    /// chosen, so the first meeting after the choice does not wait a gigabyte
    /// for it. Loaded once and dropped; the files stay.
    static func prefetchWhisper() {
        Task.detached(priority: .utility) {
            try? await WhisperTranscriber(modelName: WhisperTranscriber.meetingModel).prepare()
        }
    }

    /// What this choice writes into the old key, so an older build reads it
    /// as the nearest thing it knows: Parakeet, unless it was "like dictation".
    var usesDictationEngine: Bool { self == .dictation }

    var label: String {
        let key: String.LocalizationValue = switch self {
        case .parakeet: "Parakeet v3 (Standard)"
        case .dictation: "Wie beim Diktat"
        case .whisperTurbo: "Whisper large-v3-turbo"
        }
        return String(localized: key)
    }

    var explanation: String {
        let key: String.LocalizationValue = switch self {
        case .parakeet: "Schnell und auf dem Gerät. Der Standard."
        case .dictation: "Nimmt das Modell aus den Diktat-Einstellungen."
        case .whisperTurbo: "Langsamer als Parakeet. Bekommt Namen aus Kalender und Wörterbuch als Hinweis und legt die Sprache nach der ersten Minute Sprache fest. Lädt beim Auswählen einmal gut ein Gigabyte herunter."
        }
        return String(localized: key)
    }
}

/// One language for a whole meeting, decided from its first minute of speech.
///
/// Whisper detects the language per clip, and a meeting's clips are often a
/// few words long — exactly where detection guesses. Parakeet had the same
/// problem (`MeetingLanguageGuard` cleans up after it); with Whisper it can be
/// avoided instead: detect while the first minute comes in, then pin the
/// language that minute mostly was. A profile with one language is pinned from
/// the start. Ties go to the profile's first language.
struct MeetingLanguagePin: Sendable, Equatable {
    static let decideAfter: TimeInterval = 60

    let allowed: [String]
    private(set) var pinned: String?
    private var heard: [String: TimeInterval] = [:]

    init(allowed: [String]) {
        self.allowed = allowed
        pinned = allowed.count == 1 ? allowed[0] : nil
    }

    /// A clip Whisper detected as `language`. Languages outside the profile
    /// are not counted: they are the misdetections this exists to stop.
    mutating func record(_ language: String?, seconds: TimeInterval) {
        guard pinned == nil, let language, allowed.contains(language) else { return }
        heard[language, default: 0] += seconds
        guard heard.values.reduce(0, +) >= Self.decideAfter else { return }
        pinned = allowed.max { (heard[$0] ?? 0) < (heard[$1] ?? 0) }
    }

    /// Whether a clip detected as `language` has to be transcribed again,
    /// pinned to the profile's first language: Whisper heard a language
    /// nobody in this meeting speaks.
    func needsRetry(detected language: String?) -> Bool {
        guard !allowed.isEmpty, let language else { return false }
        return !allowed.contains(language)
    }
}

/// Whisper for a meeting: the meeting's names and terms as prompt (see
/// `WhisperTranscriber.vocabulary`) and one language once the first minute
/// has decided it (`MeetingLanguagePin`).
final class MeetingWhisperTranscriber: TranscriptionEngine, @unchecked Sendable {
    let displayName = "Whisper large-v3-turbo (Meeting)"

    private let whisper: WhisperTranscriber
    private let lock = NSLock()
    private var pin: MeetingLanguagePin

    init(whisper: WhisperTranscriber, languages: [String]) {
        self.whisper = whisper
        pin = MeetingLanguagePin(allowed: languages)
    }

    func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        let current = lock.withLock { pin }
        if let pinned = current.pinned {
            return try await whisper.transcribe(samples: samples, language: pinned).text
        }
        let detected = try await whisper.transcribe(samples: samples, language: nil)
        if current.needsRetry(detected: detected.language), let first = current.allowed.first {
            return try await whisper.transcribe(samples: samples, language: first).text
        }
        let seconds = Double(samples.count) / Double(sampleRate)
        lock.withLock { pin.record(detected.language, seconds: seconds) }
        return detected.text
    }
}
