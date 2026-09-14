import Foundation

/// The decisions of a dictation, taken out of `DictationController` so they can
/// be tested (Spec 29).
///
/// `finishRecording` used to transcribe, polish, enhance, paste and save in one
/// task on the main actor, and nothing in it could be checked. That is where the
/// defects sat: a hotkey during transcription silently dropped, an empty
/// transcript that looked like success, an Esc branch no event could reach, a
/// paste into whichever app happened to be in front. Each of those was a
/// *decision* hiding inside an effect. They live here now — pure functions of
/// what the controller measured — and the controller only carries them out.
///
/// Same pattern as `PTTStateMachine`, `HotkeyRouting` and `BootstrapPolicy`.
enum DictationPipeline {
    // MARK: - Starting

    enum MicrophonePermission: Equatable, Sendable {
        case granted
        case notDetermined
        case denied
    }

    enum StartDecision: Equatable, Sendable {
        case start
        /// Ask TCC; this press does not record.
        case requestPermission
        case refuse(DictationFailure)
    }

    /// Whether a key-down may open the microphone.
    ///
    /// Permission first: without it nothing else matters, and a denied device
    /// still opens and records zeros — so this is the only moment the real cause
    /// can be named. Secure input next, because the paste would be swallowed
    /// even if the recording worked. The closed lid last, since it is a property
    /// of the device the policy chose.
    static func start(
        permission: MicrophonePermission,
        secureInput: Bool,
        knownSilent: Bool
    ) -> StartDecision {
        switch permission {
        case .denied: return .refuse(.microphoneDenied)
        case .notDetermined: return .requestPermission
        case .granted: break
        }
        if secureInput { return .refuse(.secureInput) }
        if knownSilent { return .refuse(.lidClosed) }
        return .start
    }

    /// The role a recording carries is decided when it **starts** and not
    /// changed by the press that ends it.
    ///
    /// A hands-free recording ends on any key-down, and the old code set the
    /// role on every key-down — so ending a plain dictation with the enhance key
    /// sent it off the device, and ending an enhanced one with the plain key
    /// dropped the enhancement. Whether text leaves the machine must not depend
    /// on which key stopped the recording.
    static func enhanceRequested(
        after action: PTTStateMachine.Action,
        pressed role: HotkeyRole,
        current: Bool
    ) -> Bool {
        action == .start ? role == .enhanced : current
    }

    // MARK: - Stopping

    enum StopDecision: Equatable, Sendable {
        case transcribe
        case refuse(DictationFailure)
    }

    /// What to do with a recording that just stopped.
    ///
    /// The peak check needs no minimum length, unlike `TrackSilence.isSilent`:
    /// that one guards against flagging a legitimately quiet two-second meeting
    /// track, while every real microphone has a noise floor orders of magnitude
    /// above `peakThreshold` from the first buffer on. Digital zero over a third
    /// of a second is a dead device, not a quiet room.
    static func afterStop(
        duration: TimeInterval,
        minimumDuration: TimeInterval,
        peak: Float,
        device: String?,
        silenceThreshold: Float = TrackSilence.peakThreshold
    ) -> StopDecision {
        guard duration >= minimumDuration else { return .refuse(.tooShort) }
        guard peak > silenceThreshold else { return .refuse(.nothingHeard(device: device)) }
        return .transcribe
    }

    /// An empty result after real signal is its own case, with its own sound.
    static func afterTranscript(_ polished: String) -> DictationFailure? {
        polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .nothingRecognized : nil
    }

    // MARK: - Pasting

    enum PasteDecision: Equatable, Sendable {
        case paste
        /// Put the text on the pasteboard and say why it is not in the field.
        case clipboard(DictationFailure)
    }

    /// Whether the text may go into the frontmost app now.
    ///
    /// The target was frozen on release. If another app is in front by the time
    /// the text is ready, ⌘V would land in that one — with a slow transcription
    /// or an enhancement that is seconds, plenty for a ⌘Tab. Only a *known*
    /// mismatch refuses: with either side unknown there is nothing to compare,
    /// and refusing would turn every paste from an app without a bundle id into
    /// a failure. Two tabs of one browser share an id; that stays undetectable.
    static func paste(
        target: String?,
        frontmost: String?,
        frontmostName: String?,
        secureInput: Bool
    ) -> PasteDecision {
        if secureInput { return .clipboard(.secureInput) }
        if let target, let frontmost, target.lowercased() != frontmost.lowercased() {
            return .clipboard(.targetChanged(app: frontmostName))
        }
        return .paste
    }

    // MARK: - Esc

    enum EscapeTarget: Equatable, Sendable {
        case recording
        case job(Int)
        case none
    }

    /// What Esc aborts. The newest thing the user is waiting for: a running
    /// recording before anything else, otherwise the most recent job — the one
    /// whose text has not appeared yet and that they most likely regret.
    static func escapeTarget(isCapturing: Bool, jobs: JobQueue) -> EscapeTarget {
        if isCapturing { return .recording }
        if let newest = jobs.newest { return .job(newest) }
        return .none
    }

    // MARK: - Hands-free limits

    /// The 10-minute cap, by wall clock. It used to count 0.1 s timer ticks, and a
    /// main thread that stalled stretched the cap by exactly as long as it stalled.
    static func reachedMaximum(startedAt: Date, now: Date, maximum: TimeInterval) -> Bool {
        now.timeIntervalSince(startedAt) >= maximum
    }
}

/// The dictations still being turned into text, oldest first.
///
/// Capture and processing are separate states since Spec 29 — the same split
/// that let `MeetingController` record back-to-back calls. A new recording may
/// start while an older one is still transcribing, so there can be more than
/// one job, and their texts must land in the order they were spoken.
struct JobQueue: Equatable, Sendable {
    private(set) var jobs: [Int] = []

    var isEmpty: Bool { jobs.isEmpty }
    var count: Int { jobs.count }
    var newest: Int? { jobs.last }
    var oldest: Int? { jobs.first }

    mutating func enqueue(_ generation: Int) {
        guard !jobs.contains(generation) else { return }
        jobs.append(generation)
    }

    /// Finished, cancelled or failed — all the same to the queue.
    mutating func finish(_ generation: Int) {
        jobs.removeAll { $0 == generation }
    }

    func contains(_ generation: Int) -> Bool { jobs.contains(generation) }
}

/// Ends a hands-free recording after a run of silence, with hysteresis.
///
/// The old rule was one threshold: every 0.1 s tick below 0.04 RMS counted, any
/// tick above reset. A soft speaker hovering around the threshold timed out
/// mid-sentence, and a noisy room never timed out at all. Two thresholds fix
/// the first: silence starts below `silenceLevel`, and only a clear sound above
/// `resetLevel` ends it — the band between keeps whatever state it found.
struct IdleDetector: Sendable {
    var timeout: TimeInterval
    var silenceLevel: Float = 0.04
    var resetLevel: Float = 0.08

    private(set) var silentSince: TimeInterval?

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    /// Feeds one level reading. Returns true once the silence has lasted
    /// `timeout`. A timeout of zero or less never fires.
    mutating func observe(level: Float, at time: TimeInterval) -> Bool {
        guard timeout > 0 else { return false }
        if level >= resetLevel {
            silentSince = nil
        } else if level < silenceLevel, silentSince == nil {
            silentSince = time
        }
        guard let silentSince else { return false }
        return time - silentSince >= timeout
    }
}
