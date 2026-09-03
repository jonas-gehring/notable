import ApplicationServices
import AVFoundation
import EventKit
import Foundation
import IOKit.hid
import SwiftUI
import UserNotifications

/// Central authority for the five permissions Notable depends on.
/// Every feature checks here; no feature is allowed to fail silently
/// because a permission is missing.
@MainActor
final class PermissionsManager: ObservableObject {
    enum Status {
        case granted
        case denied
        case notDetermined
        /// macOS exposes no preflight for this right, so any lamp we drew would
        /// be a guess. Saying "not readable" is worse-looking and more honest
        /// than a green check that means nothing — see `Kind.systemAudio`.
        case unreadable

        var label: String {
            switch self {
            case .granted: "Erteilt"
            case .denied: "Verweigert"
            case .notDetermined: "Noch nicht angefragt"
            case .unreadable: "Nicht auslesbar — macOS fragt beim ersten Mitschnitt"
            }
        }

        var symbolName: String {
            switch self {
            case .granted: "checkmark.circle.fill"
            case .denied: "xmark.circle.fill"
            case .notDetermined: "questionmark.circle"
            case .unreadable: "questionmark.circle"
            }
        }

        var color: Color {
            switch self {
            case .granted: .green
            case .denied: .red
            case .notDetermined: .secondary
            case .unreadable: .secondary
            }
        }
    }

    enum Kind: String, CaseIterable, Identifiable {
        case microphone
        case systemAudio
        case inputMonitoring
        case accessibility
        case calendar
        case notifications

        var id: String { rawValue }

        var name: String {
            switch self {
            case .microphone: "Mikrofon"
            case .systemAudio: "Systemaudio-Aufnahme"
            case .inputMonitoring: "Eingabeüberwachung"
            case .accessibility: "Bedienungshilfen"
            case .calendar: "Kalender"
            case .notifications: "Mitteilungen"
            }
        }

        var purpose: String {
            switch self {
            case .microphone:
                "Diktat und Meeting-Aufnahme."
            case .systemAudio:
                "Der Ton der anderen Meeting-Teilnehmer. Ein eigenes Recht, *nicht* die Bildschirmaufnahme — Notable zeichnet kein Bild auf und fragt die Bildschirmaufnahme nie an."
            case .inputMonitoring:
                "Der globale Push-to-talk-Hotkey."
            case .accessibility:
                "Das Einfügen des Transkripts in das fokussierte Textfeld."
            case .calendar:
                "Aufnahmen dem passenden Termin zuordnen (nur Lesezugriff)."
            case .notifications:
                "Die Nachfrage »Diesen Call aufzeichnen?« und die Meldung, wenn die Notiz fertig ist. Ohne sie erscheint stattdessen ein kleines Fenster oben rechts."
            }
        }

        /// Anchor of the matching pane in System Settings → Privacy & Security.
        var settingsPane: String {
            switch self {
            case .microphone: "Privacy_Microphone"
            case .systemAudio: "Privacy_AudioCapture"
            case .inputMonitoring: "Privacy_ListenEvent"
            case .accessibility: "Privacy_Accessibility"
            case .calendar: "Privacy_Calendars"
            // Notifications live outside Privacy & Security; handled separately
            // in openSystemSettings(for:).
            case .notifications: ""
            }
        }
    }

    @Published private(set) var statuses: [Kind: Status] = [:]

    init() {
        refresh()
    }

    func refresh() {
        var result: [Kind: Status] = [:]
        for kind in Kind.allCases {
            result[kind] = Self.currentStatus(of: kind)
        }
        statuses = result
        // The notification status is only readable asynchronously; refresh the
        // cache and republish once it lands.
        Task {
            await NotificationCenterService.shared.refreshAuthorization()
            statuses[.notifications] = Self.currentStatus(of: .notifications)
        }
    }

    func status(of kind: Kind) -> Status {
        statuses[kind] ?? .notDetermined
    }

    func openSystemSettings(for kind: Kind) {
        let string = kind == .notifications
            ? "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            : "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsPane)"
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// True for the permissions macOS lets an app *prompt* for programmatically
    /// (mic, calendar, notifications). Screen-recording / input-monitoring /
    /// accessibility can only be toggled by the user in System Settings.
    func canPrompt(_ kind: Kind) -> Bool {
        (kind == .microphone || kind == .calendar || kind == .notifications)
            && status(of: kind) == .notDetermined
    }

    /// Shows the system prompt for a promptable permission. Without this the app
    /// never asks for the mic (AVAudioEngine.start does not reliably prompt on
    /// macOS), so it stays "notDetermined" and never even appears in System
    /// Settings — the exact reason dictation captured nothing.
    func request(_ kind: Kind) async {
        switch kind {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .calendar:
            _ = try? await EKEventStore().requestFullAccessToEvents()
        case .notifications:
            await NotificationCenterService.shared.requestAuthorizationIfNeeded()
        default:
            openSystemSettings(for: kind)
        }
        refresh()
    }

    /// Fire the mic prompt at launch so a fresh install (or a TCC reset) surfaces
    /// it immediately instead of failing silently on the first dictation.
    func requestMicrophoneIfNeeded() {
        guard status(of: .microphone) == .notDetermined else { return }
        Task { await request(.microphone) }
    }

    private static func currentStatus(of kind: Kind) -> Status {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .notDetermined: .notDetermined
            default: .denied
            }
        case .systemAudio:
            // There is no preflight for `kTCCServiceAudioCapture`. The obvious
            // substitutes are both wrong: `CGPreflightScreenCaptureAccess()`
            // answers about a different right the app never requests, and
            // creating a process tap to see whether it works answers nothing —
            // measured, an unsigned binary with no grant at all still gets a tap
            // and a valid stream format back. macOS raises the prompt on the
            // first real capture; until a recording has proven otherwise, the
            // honest answer here is that we do not know.
            .unreadable
        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: .granted
            case kIOHIDAccessTypeDenied: .denied
            default: .notDetermined
            }
        case .accessibility:
            // AX has no notDetermined state — untrusted is reported as denied.
            AXIsProcessTrusted() ? .granted : .denied
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: .granted
            case .notDetermined: .notDetermined
            default: .denied
            }
        case .notifications:
            // Cached by NotificationCenterService; UNUserNotificationCenter only
            // reports asynchronously.
            switch NotificationCenterService.shared.authorizationStatus {
            case .authorized, .provisional, .ephemeral: .granted
            case .notDetermined: .notDetermined
            default: .denied
            }
        }
    }
}
