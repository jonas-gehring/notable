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
/// answer and without a sound → stop. **Not while the detector still sees the
/// call**: then the call's end ends the recording (`adoptDetectedCall`), and
/// the question says that the recording runs on. On 2026-09-21 this watch
/// stopped a Safari call after ten of its 27 minutes (`endReason=silence`).
/// Five quiet minutes in a running call are a call on hold, a muted room or a
/// measurement gone wrong; none of them is its end.
///
/// Two thresholds with two jobs. Silence is only what stays below
/// `silenceLevel`, and **any** reading at or above it ends the count: until
/// 2026-10 a level between the two thresholds kept counting, so a single quiet
/// reading followed by five minutes of soft speech was enough to stop a
/// recording. `resetLevel` only decides whether an open question is withdrawn,
/// so room noise at the edge does not make the notification come and go; the
/// stop still waits for two unbroken minutes of silence. A room whose noise
/// reaches `silenceLevel` is therefore never asked about, and its recording ends
/// by hand or with its call. That is the intended side to err on: a missed stop
/// costs disk space, a wrong one costs the meeting.
///
/// The levels are the loudest chunk RMS of each second
/// (`PCMDownsampler.takePeakLevel`; until 2026-10 a single chunk, read once a
/// second) and **starting values, not measurements**: a live microphone in a
/// quiet room sits well under 0.005, speech well over 0.015. The recording that
/// prompted the change (2026-09-21) could not be measured, so these are kept
/// rather than tuned.
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

    /// Feeds one reading per track, the loudest chunk of the past second
    /// (`PCMDownsampler.takePeakLevel`). `systemLevel` is nil without a system
    /// track; the microphone then decides alone. `callActive`: the detector
    /// still sees a call. The question is asked all the same, but its two
    /// minutes only run once the call is gone.
    mutating func observe(
        micLevel: Float,
        systemLevel: Float?,
        at time: TimeInterval,
        callActive: Bool = false
    ) -> Event? {
        let loudest = max(micLevel, systemLevel ?? 0)
        if loudest >= resetLevel {
            silentSince = nil
            guard askedAt != nil else { return nil }
            askedAt = nil
            return .withdraw
        }
        if loudest >= silenceLevel {
            // Some sound, not a clear one: the silence is over, an open
            // question stays.
            silentSince = nil
            return nil
        }
        let silentSince = self.silentSince ?? time
        self.silentSince = silentSince
        if let askedAt {
            if callActive {
                self.askedAt = time
                return nil
            }
            return time - max(askedAt, silentSince) >= Self.stopAfterAsking ? .stop : nil
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
