import EventKit
import Foundation

/// Read-only EventKit access against the local calendar store: which event
/// does a recording belong to?
@MainActor
final class CalendarMonitor: ObservableObject {
    struct EventMatch: Sendable {
        var title: String
        var eventIdentifier: String
        /// Display names of the invited attendees (self, room/resource entries,
        /// and bare email addresses filtered out). A candidate pool for
        /// `SpeakerNameResolver` — never a positional speaker map. Defaults to
        /// empty so crash-recovery reconstruction (which has no attendees) and
        /// older call sites keep compiling.
        var attendeeNames: [String] = []
    }

    private let store = EKEventStore()

    /// Prompts on first call; returns whether full read access is granted.
    func requestAccessIfNeeded() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            return (try? await store.requestFullAccessToEvents()) ?? false
        default:
            return false
        }
    }

    /// The event a recording started at `date` most plausibly belongs to:
    /// currently running (or starting within 5 minutes), not all-day, not
    /// declined.
    ///
    /// **A running event beats an upcoming one.** Sorting purely by start date
    /// descending put the 10:30 slot ahead of the 10:00 call that was still in
    /// progress at 10:27, so an overrunning meeting was filed under the meeting
    /// that had not begun — wrong title, wrong `calendarEventID`, and the wrong
    /// attendee pool handed to the speaker naming. Among equals, the one that
    /// started most recently still wins, and an event with attendees beats one
    /// without: attendees are what the naming actually uses.
    func currentEvent(at date: Date = Date()) -> EventMatch? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }

        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-4 * 3600),
            end: date.addingTimeInterval(5 * 60),
            calendars: nil
        )
        let candidate = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .filter { $0.endDate > date && $0.startDate < date.addingTimeInterval(5 * 60) }
            // An event the user said no to is not the meeting they are in.
            .filter { !Self.isDeclined($0) && $0.status != .canceled }
            .sorted { Self.ranks($0, over: $1, at: date) }
            .first

        guard let candidate, let identifier = candidate.eventIdentifier else { return nil }
        return EventMatch(
            title: candidate.title ?? "Meeting",
            eventIdentifier: identifier,
            attendeeNames: Self.attendeeNames(of: candidate)
        )
    }

    /// Did the user decline this invitation? EventKit has no direct accessor —
    /// the answer is the current user's own row in the attendee list.
    static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    /// Ordering for `currentEvent`: running first, then the later start, then
    /// the one that actually has attendees.
    static func ranks(_ lhs: EKEvent, over rhs: EKEvent, at date: Date) -> Bool {
        let lhsRunning = lhs.startDate <= date
        let rhsRunning = rhs.startDate <= date
        if lhsRunning != rhsRunning { return lhsRunning }
        if lhs.startDate != rhs.startDate { return lhs.startDate > rhs.startDate }
        return (lhs.attendees?.count ?? 0) > (rhs.attendees?.count ?? 0)
    }

    struct UpcomingEvent: Sendable {
        var title: String
        var startDate: Date
    }

    /// The next non-all-day event starting after `date` within `hours` — for the
    /// "next meeting in the menu bar" line. nil when calendar access is missing
    /// or nothing is coming up.
    func nextEvent(after date: Date = Date(), within hours: Double = 12) -> UpcomingEvent? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let predicate = store.predicateForEvents(
            withStart: date, end: date.addingTimeInterval(hours * 3600), calendars: nil)
        let next = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate > date }
            .sorted { $0.startDate < $1.startDate }
            .first
        guard let next else { return nil }
        return UpcomingEvent(title: next.title ?? "Termin", startDate: next.startDate)
    }

    /// Real invitee display names from EventKit, defensively filtered. Attendees
    /// are frequently `nil` or noisy (rooms, absentees, mailing lists, bare
    /// email addresses) — degrade gracefully to an empty pool rather than feed
    /// the resolver junk. Deduplicated, order preserved.
    private static func attendeeNames(of event: EKEvent) -> [String] {
        guard let attendees = event.attendees else { return [] }
        var seen = Set<String>()
        var names: [String] = []
        for participant in attendees {
            if participant.isCurrentUser { continue }
            switch participant.participantType {
            case .room, .resource, .unknown: continue
            default: break
            }
            guard let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  !looksLikeEmailAddress(name)
            else { continue }
            if seen.insert(name.lowercased()).inserted { names.append(name) }
        }
        return names
    }

    /// A bare "user@host" with no whitespace — EventKit's fallback when a
    /// participant has no display name. Not a usable person name.
    private static func looksLikeEmailAddress(_ value: String) -> Bool {
        value.contains("@") && !value.contains(" ")
    }
}
