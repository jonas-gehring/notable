import AppKit
import CoreAudio
import Foundation

/// Debounced fusion of the "call started" and "call still running" signals.
/// Pure logic, unit-tested; one tick per poll interval.
struct DetectionStateMachine: Equatable, Sendable {
    enum Event: Equatable {
        case started
        case ended
    }

    /// Consecutive positive ticks before a meeting counts as started/ended.
    var startThreshold: Int
    var endThreshold: Int

    /// End needs four ticks (≈ 20 s) rather than three: the end signal is now a
    /// live audio-stream flag, and a short gap (device switch, a mute that
    /// briefly re-opens the stream) must not cut a running meeting short.
    init(startThreshold: Int = 2, endThreshold: Int = 4) {
        self.startThreshold = startThreshold
        self.endThreshold = endThreshold
    }

    private(set) var isActive = false
    private var startTicks = 0
    private var endTicks = 0

    /// - Parameters:
    ///   - startSignal: a call was detected *and* it holds the microphone.
    ///   - callStillActive: the latched call process still has audio running.
    ///     Deliberately separate from `startSignal`: a muted participant may
    ///     stop being a start signal while the call is very much still running.
    mutating func tick(startSignal: Bool, callStillActive: Bool) -> Event? {
        if isActive {
            endTicks = callStillActive ? 0 : endTicks + 1
            if endTicks >= endThreshold {
                isActive = false
                endTicks = 0
                return .ended
            }
        } else {
            startTicks = startSignal ? startTicks + 1 : 0
            if startTicks >= startThreshold {
                isActive = true
                startTicks = 0
                return .started
            }
        }
        return nil
    }

    /// Legacy shape, kept for the fallback path (and its tests) where the only
    /// signals available are "a known app is running" plus a global microphone
    /// bit: the app running *is* the end signal there.
    mutating func tick(candidatePresent: Bool, micActive: Bool) -> Event? {
        tick(startSignal: candidatePresent && micActive, callStillActive: candidatePresent)
    }
}

/// Detects active calls per *process*: a known meeting app (or a browser) that
/// currently holds the microphone.
///
/// The earlier version asked `NSWorkspace` whether Zoom/Teams was *running* and
/// fused that with a global "someone uses the mic" bit. That defined the end of a
/// call as "the app quit", which never happens for Teams or Slack — so an
/// auto-started recording ran on forever. CoreAudio's per-process run flags
/// (macOS 14+) answer the real question, and they keep working while we record,
/// because our own capture is a different process.
///
/// The old heuristic survives as a fallback for the case where the process list
/// is unavailable, so a CoreAudio failure degrades to today's behaviour instead
/// of "no meetings are ever detected".
@MainActor
final class MeetingDetector: ObservableObject {
    /// Dedicated apps run (almost) only while calling; browsers and ambient apps
    /// (Slack) make noise all day. The tier decides both priority and how
    /// permissive the *end* signal may be.
    enum Tier: Sendable, Equatable { case dedicated, browser, ambient }

    struct Candidate: Equatable, Sendable {
        /// Human-facing display string, e.g. "Zoom" or "Google Meet (Google Chrome)".
        var sourceName: String
        /// Stable key for remembering per-source consent: a native app's bundle id
        /// (`us.zoom.xos`) or a web service tag (`web:zoom`). Defaults to `"unknown"`
        /// for the placeholder candidate the poll loop synthesises when a call is
        /// confirmed but the candidate momentarily reads nil.
        var identityKey: String = "unknown"
        /// Bundle ids of the processes that actually hold the audio streams — the
        /// browser for a web call, the app itself otherwise. This is what the end
        /// signal watches, so it must be the *process*, not the service.
        var processBundleIDs: [String] = []
        var tier: Tier = .dedicated
    }

    @Published private(set) var currentCandidate: Candidate?

    var onMeetingStart: ((Candidate) -> Void)?
    var onMeetingEnd: (() -> Void)?
    /// Only used by the legacy fallback path, where the microphone signal is
    /// global and our own capture would otherwise look like a meeting.
    var isOwnCaptureActive: () -> Bool = { false }

    /// True between `.started` and `.ended` — "a call is going on right now".
    /// `MeetingController` uses it to decide whether a manually started recording
    /// belongs to the call and should end with it.
    var isCallActive: Bool { stateMachine.isActive }

    private static let meetingApps: [(bundleID: String, name: String, tier: Tier)] = [
        ("us.zoom.xos", "Zoom", .dedicated),
        ("com.microsoft.teams2", "Microsoft Teams", .dedicated),
        ("com.microsoft.teams", "Microsoft Teams", .dedicated),
        ("com.apple.FaceTime", "FaceTime", .dedicated),
        ("Cisco-Systems.Spark", "Webex", .dedicated),
        ("com.webex.meetingmanager", "Webex", .dedicated),
        ("com.tinyspeck.slackmacgap", "Slack", .ambient),
    ]

    /// Browsers, with the `kCGWindowOwnerName` used to read their window titles
    /// and the process bundle ids that actually carry their audio.
    ///
    /// Chromium browsers do audio in a helper whose bundle id is the app's plus a
    /// suffix (`com.google.Chrome.helper`) — the snapshot's prefix matching covers
    /// that. Safari is different: measured on this machine, its audio lives in
    /// `com.apple.WebKit.GPU`, which shares no prefix with `com.apple.Safari`, so
    /// it has to be listed explicitly or Safari calls would never be detected.
    private static let browsers: [(processBundleIDs: [String], owner: String)] = [
        (["com.google.Chrome"], "Google Chrome"),
        (["com.apple.Safari", "com.apple.WebKit"], "Safari"),
        (["company.thebrowser.Browser"], "Arc"),
        (["com.microsoft.edgemac"], "Microsoft Edge"),
        (["org.mozilla.firefox"], "Firefox"),
        (["com.brave.Browser"], "Brave Browser"),
    ]

    private var stateMachine = DetectionStateMachine()
    private var timer: Timer?
    /// The candidate the current call was latched onto — the end signal follows
    /// *this* process, not whatever happens to be detectable now.
    private var activeCandidate: Candidate?

    func start(pollInterval: TimeInterval = 5) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let snapshot = AudioProcessMonitor.snapshot()
        let candidate: Candidate?
        let startSignal: Bool
        let stillActive: Bool

        if snapshot.isAvailable {
            candidate = Self.detectInCallCandidate(snapshot: snapshot)
            startSignal = candidate != nil
            if let active = activeCandidate {
                stillActive = Self.isStillActive(active, snapshot: snapshot)
            } else {
                stillActive = candidate != nil
            }
        } else {
            // Fallback: the pre-process-monitor heuristic, unchanged.
            let legacy = Self.detectRunningAppCandidate()
            let micActive = !isOwnCaptureActive() && Self.isDefaultInputRunningSomewhere()
            candidate = legacy
            startSignal = legacy != nil && micActive
            stillActive = legacy != nil
        }

        if !stateMachine.isActive {
            currentCandidate = candidate
        }

        switch stateMachine.tick(startSignal: startSignal, callStillActive: stillActive) {
        case .started:
            let started = candidate ?? Candidate(sourceName: "Unbekannt")
            currentCandidate = started
            activeCandidate = started
            onMeetingStart?(started)
        case .ended:
            currentCandidate = nil
            activeCandidate = nil
            onMeetingEnd?()
        case nil:
            break
        }
    }

    // MARK: - Signals (process-based)

    /// A call is a *known app holding the microphone*, in tier order.
    private static func detectInCallCandidate(snapshot: AudioProcessSnapshot) -> Candidate? {
        func firstApp(_ tier: Tier) -> Candidate? {
            for app in meetingApps where app.tier == tier {
                if snapshot.inputEntry(bundleID: app.bundleID) != nil {
                    return Candidate(sourceName: app.name, identityKey: app.bundleID,
                                     processBundleIDs: [app.bundleID], tier: tier)
                }
            }
            return nil
        }

        if let dedicated = firstApp(.dedicated) { return dedicated }
        if let browser = detectBrowserCall(snapshot: snapshot) { return browser }
        return firstApp(.ambient)
    }

    /// A browser with the microphone open is a call candidate. The window title
    /// only *names* it (Meet/Zoom/Teams) — without the Screen Recording
    /// permission the call is still detected, just generically.
    private static func detectBrowserCall(snapshot: AudioProcessSnapshot) -> Candidate? {
        for browser in browsers {
            guard snapshot.inputEntry(anyOf: browser.processBundleIDs) != nil else { continue }
            if let service = webServiceInWindowTitles(ownedBy: browser.owner) {
                return Candidate(sourceName: "\(service.display) (\(browser.owner))",
                                 identityKey: service.key,
                                 processBundleIDs: browser.processBundleIDs, tier: .browser)
            }
            // Unidentified: still a candidate, but with a key that must never be
            // remembered as "always" (see ConsentCoordinator) — otherwise every
            // voice search would auto-record.
            return Candidate(sourceName: "Browser-Call (\(browser.owner))",
                             identityKey: MeetingIdentity.unknownWebKey,
                             processBundleIDs: browser.processBundleIDs, tier: .browser)
        }
        return nil
    }

    /// The call is over when the process it lived in stops making audio.
    ///
    /// Dedicated apps may keep only the output stream (muted participant still
    /// hearing the others) and that counts as running. Browsers and Slack play
    /// audio all day long for unrelated reasons, so for them only the microphone
    /// counts.
    private static func isStillActive(_ candidate: Candidate, snapshot: AudioProcessSnapshot) -> Bool {
        guard !candidate.processBundleIDs.isEmpty else {
            // Placeholder candidate (no process known) — fall back to "is any
            // known meeting app still holding the mic".
            return detectInCallCandidate(snapshot: snapshot) != nil
        }
        switch candidate.tier {
        case .dedicated:
            return snapshot.isActive(anyOf: candidate.processBundleIDs)
        case .browser, .ambient:
            return snapshot.inputEntry(anyOf: candidate.processBundleIDs) != nil
        }
    }

    // MARK: - Signals (legacy fallback)

    private static func detectRunningAppCandidate() -> Candidate? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        func firstRunning(_ tier: Tier) -> Candidate? {
            meetingApps
                .first { $0.tier == tier && running.contains($0.bundleID) }
                .map { Candidate(sourceName: $0.name, identityKey: $0.bundleID,
                                 processBundleIDs: [$0.bundleID], tier: tier) }
        }
        if let dedicated = firstRunning(.dedicated) { return dedicated }
        if let browser = legacyBrowserCandidate() { return browser }
        return firstRunning(.ambient)
    }

    private static func legacyBrowserCandidate() -> Candidate? {
        for browser in browsers {
            if let service = webServiceInWindowTitles(ownedBy: browser.owner) {
                return Candidate(sourceName: "\(service.display) (\(browser.owner))",
                                 identityKey: service.key,
                                 processBundleIDs: browser.processBundleIDs, tier: .browser)
            }
        }
        return nil
    }

    /// Scans on-screen window titles of one browser for call evidence. Titles are
    /// only readable with the Screen Recording permission; without it this
    /// silently contributes nothing.
    private static func webServiceInWindowTitles(ownedBy owner: String) -> (key: String, display: String)? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return nil }

        for window in windows {
            guard let windowOwner = window[kCGWindowOwnerName as String] as? String,
                  windowOwner == owner,
                  let title = window[kCGWindowName as String] as? String
            else { continue }
            // MeetingIdentity is the single source of truth for the title match,
            // the display name, and the stable "web:*" consent key.
            if let service = MeetingIdentity.webService(forWindowTitle: title) {
                return service
            }
        }
        return nil
    }

    /// True when any process has the default input device running.
    private static func isDefaultInputRunningSomewhere() -> Bool {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return false }

        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }
}
