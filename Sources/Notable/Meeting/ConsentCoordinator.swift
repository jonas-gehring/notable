import Foundation

/// Sits between `MeetingDetector` and `MeetingController`, inserting a consent
/// gate before any auto-recording starts.
///
/// The detector's `DetectionStateMachine` already latches one `.started` per call
/// and one `.ended`, so this coordinator does no second debounce: it tracks a light
/// per-call status purely to guard against re-entrancy. On a detected call it either
/// honours a remembered `.always`/`.never`, or shows the non-activating consent
/// panel and acts on the answer. Recording starts **only** on an explicit (or
/// remembered) Ja — the exact `meeting.startAutomatically(source:)` call the old
/// silent-auto path made, so the existing auto-stop path is unchanged.
@MainActor
final class ConsentCoordinator {
    /// Mirrors the current auto-record default key so behaviour with the toggle off
    /// matches the pre-consent guard in `AppDelegate`.
    static let autoRecordDefaultsKey = "autoRecordMeetings"

    private enum CallStatus {
        case idle
        case awaitingConsent
        case recording
        case declined
    }

    private let meeting: MeetingController
    private let notificationPresenter: ConsentPresenting
    private let panelPresenter: ConsentPresenting
    /// Panel-only: a notification stays in Notification Center and may be
    /// answered minutes into the call, so it is resolved by the call's end, not
    /// by a clock.
    private let panelTimeout: TimeInterval
    private let defaults: UserDefaults

    private var status: CallStatus = .idle
    /// The presenter that actually showed the current prompt — the one that must
    /// be dismissed when the call ends.
    private var activePresenter: ConsentPresenting?

    init(meeting: MeetingController,
         notificationPresenter: ConsentPresenting = NotificationConsentPresenter(),
         panelPresenter: ConsentPresenting = ConsentPromptController(),
         panelTimeout: TimeInterval = 25,
         defaults: UserDefaults = .standard) {
        self.meeting = meeting
        self.notificationPresenter = notificationPresenter
        self.panelPresenter = panelPresenter
        self.panelTimeout = panelTimeout
        self.defaults = defaults
    }

    /// Wire to `MeetingDetector.onMeetingStart`. Fires once per detected call.
    func callDetected(_ candidate: MeetingDetector.Candidate) {
        // Master switch off → parity with the old guard: neither prompt nor record.
        guard autoRecordEnabled else { return }
        // The detector fires `.started` once per call; ignore any re-entrancy.
        guard status == .idle else { return }

        switch MeetingConsentStore.decision(for: candidate.identityKey, defaults: defaults) {
        case .always:
            startRecording(source: candidate.sourceName)
        case .never:
            status = .declined
        case nil:
            status = .awaitingConsent
            // Notification Center is the chosen surface; the panel steps in only
            // when notifications are unavailable, so the question never silently
            // disappears.
            let useNotification = NotificationCenterService.shared.isAuthorized
            let presenter = useNotification ? notificationPresenter : panelPresenter
            activePresenter = presenter
            presenter.present(sourceName: candidate.sourceName,
                              identityKey: candidate.identityKey,
                              timeout: useNotification ? nil : panelTimeout) { [weak self] choice in
                self?.resolve(choice, candidate: candidate)
            }
        }
    }

    /// Wire to `MeetingDetector.onMeetingEnd`. Withdraws any pending prompt and
    /// stops the recording — which then runs the pipeline and the summary.
    func callEnded() {
        activePresenter?.dismiss()
        activePresenter = nil
        status = .idle
        meeting.stopAutomatically()
    }

    // MARK: - Private

    private func resolve(_ choice: ConsentChoice, candidate: MeetingDetector.Candidate) {
        // A late answer after the call already ended is a no-op.
        guard status == .awaitingConsent else { return }
        activePresenter = nil

        // Never persist a standing decision for an identity too coarse to hold
        // one (an unidentified browser call would otherwise turn every future
        // microphone use of that browser into a recording).
        let mayRemember = choice.remember && MeetingIdentity.isRememberable(candidate.identityKey)

        switch choice.kind {
        case .yes:
            if mayRemember {
                MeetingConsentStore.remember(.always, for: candidate.identityKey, defaults: defaults)
            }
            startRecording(source: candidate.sourceName)
        case .no:
            if mayRemember {
                MeetingConsentStore.remember(.never, for: candidate.identityKey, defaults: defaults)
            }
            status = .declined
        }
    }

    private func startRecording(source: String) {
        status = .recording
        meeting.startAutomatically(source: source)
    }

    private var autoRecordEnabled: Bool {
        defaults.object(forKey: Self.autoRecordDefaultsKey) as? Bool ?? true
    }
}
