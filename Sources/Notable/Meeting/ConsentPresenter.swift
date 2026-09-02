import Foundation

/// The answer to "diesen Call transkribieren?".
struct ConsentChoice: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case yes, no }
    var kind: Kind
    /// The user chose the "immer für diese App" variant — persist the decision.
    var remember: Bool
}

/// How the consent question reaches the user. Two implementations:
/// `NotificationConsentPresenter` (default) and the `ConsentPromptController`
/// panel (fallback when notifications are not authorized — without it an
/// `LSUIElement` with denied notifications would silently never ask).
@MainActor
protocol ConsentPresenting: AnyObject {
    /// `onChoice` is invoked **at most once**. `timeout` of `nil` means "wait
    /// indefinitely" — correct for a notification, which stays in Notification
    /// Center and may legitimately be answered minutes into the call.
    func present(sourceName: String,
                 identityKey: String,
                 timeout: TimeInterval?,
                 onChoice: @escaping (ConsentChoice) -> Void)

    /// Tears the prompt down *without* invoking `onChoice` — the call ended
    /// before the user answered.
    func dismiss()
}

/// Posts the consent question to Notification Center.
@MainActor
final class NotificationConsentPresenter: ConsentPresenting {
    private let service: NotificationCenterService
    private var currentID: String?
    private var onChoice: ((ConsentChoice) -> Void)?

    init(service: NotificationCenterService = .shared) {
        self.service = service
    }

    func present(sourceName: String,
                 identityKey: String,
                 timeout: TimeInterval?,
                 onChoice: @escaping (ConsentChoice) -> Void) {
        dismiss()

        let id = "meeting-consent-\(UUID().uuidString)"
        currentID = id
        self.onChoice = onChoice
        service.onConsentAction = { [weak self] action in
            self?.resolve(action)
        }
        service.postConsentPrompt(
            id: id,
            sourceName: sourceName,
            canRemember: MeetingIdentity.isRememberable(identityKey)
        )
    }

    func dismiss() {
        if let currentID { service.withdraw(id: currentID) }
        currentID = nil
        onChoice = nil
    }

    private func resolve(_ action: NotificationCenterService.Action) {
        guard let callback = onChoice else { return }
        onChoice = nil
        currentID = nil
        switch action {
        case .record: callback(ConsentChoice(kind: .yes, remember: false))
        case .remember: callback(ConsentChoice(kind: .yes, remember: true))
        case .later: callback(ConsentChoice(kind: .no, remember: false))
        }
    }
}
