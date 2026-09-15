import Foundation

// Spec 34: when a recording ends by itself.
//
// Spec 09 made the call's end measurable (per-process CoreAudio flags), and in
// most archived meetings the recording stopped within seconds of the last word.
// Three shapes still ran on: a recording started by hand before the detector had
// confirmed the call, an app that keeps an output stream open after hanging up,
// and every recording with no call process at all. The first is fixed where the
// detector meets the controller (`MeetingController.adoptDetectedCall`); the
// other two are decided here, pure, so they are tested rather than trusted.

/// Whether the process a call lives in is still in that call.
enum CallEndRule {
    /// How long the far side may stay silent before an app that holds only its
    /// output stream no longer counts as "in the call". Long enough for a pause
    /// in a conversation, short enough that the recording does not outlive a
    /// hung-up Teams by more than about a minute (plus the detector's 20 s).
    static let remoteSilenceForEnd: TimeInterval = 60

    /// - Parameters:
    ///   - holdsInput: the call process has the microphone open.
    ///   - holdsOutput: it has any audio stream open (input or output).
    ///   - remoteSilentFor: how long the system track has carried no sound;
    ///     nil when that cannot be told (nothing recording, no system track).
    static func isStillActive(
        tier: MeetingApps.Tier,
        holdsInput: Bool,
        holdsOutput: Bool,
        remoteSilentFor: TimeInterval?
    ) -> Bool {
        if holdsInput { return true }
        switch tier {
        case .dedicated:
            // Muted but listening: the app plays the others, and that is a call.
            // An app that merely keeps its output open after hanging up plays
            // nothing — only the recording's own system track can tell the two
            // apart, so without one the old rule stands.
            guard holdsOutput else { return false }
            guard let remoteSilentFor else { return true }
            return remoteSilentFor < remoteSilenceForEnd
        case .browser, .ambient:
            // They play audio all day for unrelated reasons (Spec 09 §10).
            return false
        }
    }
}

/// Why a recording ended, written into `meta.json` (Spec 34 D). Before this an
/// archived meeting could not say whether it stopped with the call or by hand.
enum MeetingEndReason: String, Codable, Sendable {
    case manual
    case callEnded
    case silence
    case quit
}

/// The safety net for every recording, with or without a detected call: both
/// tracks without sound for three minutes → ask; two more minutes without an
/// answer and without a sound → stop.
///
/// Two thresholds, like `IdleDetector`: silence starts below `silenceLevel`, and
/// only a clear sound above `resetLevel` ends it — a level in between keeps the
/// state it found, so room noise hovering at the edge neither starts nor keeps
/// resetting the count. The levels are chunk RMS (`PCMDownsampler.currentLevel`)
/// and **starting values, not measurements**: a live microphone in a quiet room
/// sits well under 0.005, speech well over 0.015.
struct MeetingSilenceWatch: Sendable {
    enum Event: Equatable, Sendable {
        /// Silence has lasted long enough to ask.
        case ask
        /// A sound came back while the question was open.
        case withdraw
        /// The question went unanswered and it stayed silent.
        case stop
    }

    static let askAfter: TimeInterval = 180
    static let stopAfterAsking: TimeInterval = 120
    /// After "Weiter aufnehmen": the user said this silence is intended, so the
    /// next question waits much longer than the first.
    static let askAgainAfterKeeping: TimeInterval = 600

    var silenceLevel: Float = 0.005
    var resetLevel: Float = 0.015

    private(set) var silentSince: TimeInterval?
    private(set) var askedAt: TimeInterval?
    private var askAfter: TimeInterval = Self.askAfter

    /// Feeds one reading per track. `systemLevel` is nil without a system track;
    /// the microphone then decides alone.
    mutating func observe(micLevel: Float, systemLevel: Float?, at time: TimeInterval) -> Event? {
        let loudest = max(micLevel, systemLevel ?? 0)
        if loudest >= resetLevel {
            silentSince = nil
            guard askedAt != nil else { return nil }
            askedAt = nil
            return .withdraw
        }
        if loudest < silenceLevel, silentSince == nil {
            silentSince = time
        }
        guard let silentSince else { return nil }
        if let askedAt {
            return time - askedAt >= Self.stopAfterAsking ? .stop : nil
        }
        guard time - silentSince >= askAfter else { return nil }
        askedAt = time
        return .ask
    }

    /// "Weiter aufnehmen": the count starts afresh and the next question waits
    /// `askAgainAfterKeeping`.
    mutating func keepRecording(at time: TimeInterval) {
        askedAt = nil
        silentSince = time
        askAfter = Self.askAgainAfterKeeping
    }

    /// Whole minutes of silence the current question is about, for its text.
    var silentMinutes: Int {
        Int((askAfter / 60).rounded())
    }
}
