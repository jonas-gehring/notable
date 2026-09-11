import AppKit
import Foundation
import UserNotifications

/// Notification Center for the two moments the user is not looking at the menu
/// bar: a call was detected (record it?) and a meeting note is finished.
///
/// Every action is registered **without** `.foreground`. Notable is an
/// `LSUIElement` whose whole dictation mechanic depends on not stealing focus, so
/// answering "Aufnehmen" mid-call must not pull the app forward; the work happens
/// in-process and the note is opened via `NSWorkspace` instead.
@MainActor
final class NotificationCenterService: NSObject {
    static let shared = NotificationCenterService()

    enum Category: String {
        case meetingConsent = "meeting.consent"
        case meetingReady = "meeting.ready"
        case dictationEnhanced = "dictation.enhanced"
        case updateNudge = "update.nudge"
    }

    /// The one action that installs from a notification, and only on the
    /// 72-hour nudge (Spec 25 §3.8): by then the user has seen "Update
    /// verfügbar" and three days of it not happening.
    enum UpdateAction: String {
        case installNow = "update.installNow"
    }

    enum Action: String {
        case record = "meeting.record"
        case remember = "meeting.remember"
        case later = "meeting.later"
    }

    /// Kept out of `Action`: that enum is the consent vocabulary, and every
    /// `switch` over it is a consent decision. "Einfügen" is neither.
    enum DictationAction: String {
        case paste = "dictation.paste"
    }

    /// Called at most once per consent notification, on the main actor.
    var onConsentAction: ((Action) -> Void)?
    /// "Einfügen" on an improved dictation. The text is already on the clipboard;
    /// this only offers to put it in the focused field as well.
    var onPasteEnhanced: (() -> Void)?
    /// A click on a notification that leads to a settings pane (by raw value).
    var onOpenSettings: ((String) -> Void)?
    /// "Jetzt installieren" on the update nudge.
    var onInstallUpdateNow: (() -> Void)?

    private(set) var isAuthorized = false
    /// Cached so the (synchronous) permissions UI can show it without awaiting.
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    /// Guards against a second delivery (action tap *and* dismissal) resolving
    /// the same prompt twice.
    private var resolvedConsentIDs = Set<String>()
    private var pendingConsentID: String?

    /// Must run before any notification is posted — the delegate is what turns a
    /// button tap back into an in-process action.
    func registerCategoriesAndDelegate() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let consent = UNNotificationCategory(
            identifier: Category.meetingConsent.rawValue,
            actions: [
                UNNotificationAction(identifier: Action.record.rawValue, title: "Aufnehmen", options: []),
                UNNotificationAction(identifier: Action.remember.rawValue, title: String(localized: "Immer für diese App"), options: []),
                UNNotificationAction(identifier: Action.later.rawValue, title: String(localized: "Später"), options: []),
            ],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        // Same category without the "always" button, for sources too coarse to
        // remember a standing decision for (an unidentified browser call).
        let consentNoRemember = UNNotificationCategory(
            identifier: Category.meetingConsent.rawValue + ".once",
            actions: [
                UNNotificationAction(identifier: Action.record.rawValue, title: "Aufnehmen", options: []),
                UNNotificationAction(identifier: Action.later.rawValue, title: String(localized: "Später"), options: []),
            ],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let ready = UNNotificationCategory(
            identifier: Category.meetingReady.rawValue,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        // No `.foreground`, like everything else here: pulling Notable forward
        // would move focus away from the field the text is meant for.
        let enhanced = UNNotificationCategory(
            identifier: Category.dictationEnhanced.rawValue,
            actions: [UNNotificationAction(identifier: DictationAction.paste.rawValue, title: String(localized: "Einfügen"), options: [])],
            intentIdentifiers: [],
            options: []
        )
        let nudge = UNNotificationCategory(
            identifier: Category.updateNudge.rawValue,
            actions: [UNNotificationAction(identifier: UpdateAction.installNow.rawValue, title: String(localized: "Jetzt installieren"), options: [])],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([consent, consentNoRemember, ready, enhanced, nudge])
    }

    /// Asks once; afterwards just refreshes the cached status. The cached flag is
    /// what the consent layer consults synchronously to decide between
    /// notification and panel fallback.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            // Sound stays off on purpose: the consent prompt fires *during* a
            // call, and a ding on the call audio is worse than no ding.
            _ = try? await center.requestAuthorization(options: [.alert, .badge])
        }
        await refreshAuthorization()
        return isAuthorized
    }

    func refreshAuthorization() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        authorizationStatus = status
        switch status {
        case .authorized, .provisional, .ephemeral: isAuthorized = true
        default: isAuthorized = false
        }
    }

    // MARK: - Posting

    func postConsentPrompt(id: String, sourceName: String, canRemember: Bool) {
        resolvedConsentIDs.remove(id)
        pendingConsentID = id

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Meeting erkannt")
        content.body = String(localized: "\(sourceName) — aufzeichnen?")
        content.categoryIdentifier = canRemember
            ? Category.meetingConsent.rawValue
            : Category.meetingConsent.rawValue + ".once"
        content.interruptionLevel = .timeSensitive // it is only useful during the call

        post(id: id, content: content)
    }

    func postMeetingReady(id: String, title: String, body: String, noteURL: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Category.meetingReady.rawValue
        if let noteURL { content.userInfo = ["notePath": noteURL.path] }
        post(id: id, content: content)
    }

    /// Pulls a delivered notification back — used when the call ends before the
    /// user answered, so no stale "aufzeichnen?" survives the meeting.
    /// The improved text is on the clipboard; this says so and offers a paste.
    func postDictationEnhanced(id: String, preview: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Diktat verbessert")
        content.body = preview
        content.categoryIdentifier = Category.dictationEnhanced.rawValue
        post(id: id, content: content)
    }

    /// A found update is otherwise only visible to whoever happens to open the
    /// menu. No category and no action: tapping it opens Notable, and the install
    /// button is one click away there — an "install now" action in a notification
    /// would replace the running app from a place the user cannot see what is
    /// being replaced.
    @discardableResult
    func postUpdateAvailable(version: String) -> Bool {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Update verfügbar")
        content.body = String(localized: "Notable \(version) steht bereit — im Menü oder in den Einstellungen installieren.")
        return post(id: "update.available.\(version)", content: content)
    }

    /// After the swap, once (Spec 25 §3.7). Clicking it opens Settings →
    /// Allgemein, where the release notes of the installed version stand.
    @discardableResult
    func postUpdateInstalled(version: String) -> Bool {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Notable wurde aktualisiert")
        content.body = String(localized: "Jetzt Version \(version). Was neu ist, steht in den Einstellungen.")
        content.userInfo = ["settingsPane": "general"]
        return post(id: "update.installed.\(version)", content: content)
    }

    /// The swap did not take and the old version was started again. Silence
    /// here would look exactly like the updater not existing.
    @discardableResult
    func postUpdateFailed(target: String, running: String) -> Bool {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Update nicht installiert")
        content.body = String(localized: "Notable \(target) ließ sich nicht installieren — es läuft weiter \(running).")
        content.userInfo = ["settingsPane": "general"]
        return post(id: "update.failed.\(target)", content: content)
    }

    /// Three days held back by open windows alone (Spec 25 §3.8).
    @discardableResult
    func postUpdateNudge(version: String) -> Bool {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Update wartet")
        content.body = String(localized: "Notable \(version) wartet seit drei Tagen auf einen Moment ohne offenes Notable-Fenster.")
        content.categoryIdentifier = Category.updateNudge.rawValue
        content.userInfo = ["settingsPane": "general"]
        return post(id: "update.nudge.\(version)", content: content)
    }

    func withdraw(id: String) {
        if pendingConsentID == id { pendingConsentID = nil }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// Returns whether anything was actually posted.
    ///
    /// The caller needs to know: the update checker marked a version as
    /// "announced" *before* calling this, so on a fresh install — where the
    /// authorization dialog is still open when the launch check finishes — that
    /// version was recorded as announced and never announced again, for good.
    @discardableResult
    private func post(id: String, content: UNMutableNotificationContent) -> Bool {
        guard isAuthorized else { return false }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        return true
    }

    // MARK: - Handling

    fileprivate func handle(actionID: String, requestID: String, notePath: String?, settingsPane: String?) {
        if let notePath, actionID == UNNotificationDefaultActionIdentifier {
            NSWorkspace.shared.open(URL(fileURLWithPath: notePath))
            return
        }
        if actionID == DictationAction.paste.rawValue {
            onPasteEnhanced?()
            return
        }
        if actionID == UpdateAction.installNow.rawValue {
            onInstallUpdateNow?()
            return
        }
        if let settingsPane, actionID == UNNotificationDefaultActionIdentifier {
            onOpenSettings?(settingsPane)
            return
        }
        guard requestID == pendingConsentID, !resolvedConsentIDs.contains(requestID) else { return }

        let action: Action?
        switch actionID {
        case Action.record.rawValue, UNNotificationDefaultActionIdentifier:
            // Clicking a "… aufzeichnen?" notification means yes.
            action = .record
        case Action.remember.rawValue:
            action = .remember
        case Action.later.rawValue, UNNotificationDismissActionIdentifier:
            action = .later
        default:
            action = nil
        }
        guard let action else { return }

        resolvedConsentIDs.insert(requestID)
        pendingConsentID = nil
        onConsentAction?(action)
    }
}

// The delegate callbacks arrive off the main actor; only Sendable values (the
// identifiers and the note path) are carried across the hop.
extension NotificationCenterService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list] // show even while Notable is frontmost
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionID = response.actionIdentifier
        let requestID = response.notification.request.identifier
        let userInfo = response.notification.request.content.userInfo
        let notePath = userInfo["notePath"] as? String
        let settingsPane = userInfo["settingsPane"] as? String
        await MainActor.run {
            NotificationCenterService.shared.handle(
                actionID: actionID, requestID: requestID, notePath: notePath, settingsPane: settingsPane
            )
        }
    }
}
