import Foundation
import OSLog

/// How long recorded material is kept. Loaded from `UserDefaults`, like
/// `TextPolisher.Options`.
///
/// Every field is optional and `nil` means **off**. That is the safe direction:
/// a policy nobody configured deletes nothing.
struct RetentionPolicy: Sendable, Equatable {
    /// Raw meeting audio in `spool-archive/`.
    var audioMaxAgeDays: Int?
    /// Second axis for audio, because one alone is not enough: 30 days do not
    /// protect against a single runaway session (there is a 6.4 GB one on disk,
    /// ≈ 14 hours — a recording that never ended), and a budget alone does not
    /// stop the quiet growth while there is still room.
    var audioBudgetBytes: Int64?
    /// `spool-failed/` — explicitly there to be salvaged by hand, so it gets a
    /// longer grace period of its own.
    var failedMaxAgeDays: Int?
    /// Text of old dictations. Off by default.
    var dictationTextMaxAgeDays: Int?
    /// Text of old meeting transcripts. Off by default.
    var meetingTextMaxAgeDays: Int?
    /// Chat histories. Off by default.
    var chatMaxAgeDays: Int?

    static let `default` = RetentionPolicy(
        audioMaxAgeDays: 30,
        audioBudgetBytes: 20 * 1024 * 1024 * 1024,
        failedMaxAgeDays: 90,
        dictationTextMaxAgeDays: nil,
        meetingTextMaxAgeDays: nil,
        chatMaxAgeDays: nil
    )

    /// Everything off — the plan is guaranteed empty.
    static let off = RetentionPolicy(
        audioMaxAgeDays: nil,
        audioBudgetBytes: nil,
        failedMaxAgeDays: nil,
        dictationTextMaxAgeDays: nil,
        meetingTextMaxAgeDays: nil,
        chatMaxAgeDays: nil
    )

    enum Key {
        static let audioAge = "retentionAudioDays"
        static let audioBudget = "retentionAudioBudgetGB"
        static let failedAge = "retentionFailedDays"
        static let dictationAge = "retentionDictationTextDays"
        static let meetingAge = "retentionMeetingTextDays"
        static let chatAge = "retentionChatDays"
        static let enabled = "retentionEnabled"
    }

    /// 0 in `UserDefaults` means "off" — `Picker` bindings cannot hold `nil`.
    private static func days(_ store: UserDefaults, _ key: String, fallback: Int?) -> Int? {
        guard store.object(forKey: key) != nil else { return fallback }
        let value = store.integer(forKey: key)
        return value > 0 ? value : nil
    }

    static func fromDefaults(_ store: UserDefaults = .standard) -> RetentionPolicy {
        var policy = RetentionPolicy(
            audioMaxAgeDays: days(store, Key.audioAge, fallback: RetentionPolicy.default.audioMaxAgeDays),
            audioBudgetBytes: RetentionPolicy.default.audioBudgetBytes,
            failedMaxAgeDays: days(store, Key.failedAge, fallback: RetentionPolicy.default.failedMaxAgeDays),
            dictationTextMaxAgeDays: days(store, Key.dictationAge, fallback: nil),
            meetingTextMaxAgeDays: days(store, Key.meetingAge, fallback: nil),
            chatMaxAgeDays: days(store, Key.chatAge, fallback: nil)
        )
        if store.object(forKey: Key.audioBudget) != nil {
            let gigabytes = store.integer(forKey: Key.audioBudget)
            policy.audioBudgetBytes = gigabytes > 0 ? Int64(gigabytes) * 1024 * 1024 * 1024 : nil
        }
        return policy
    }

    /// The master switch. Off by default is wrong here (the disk keeps filling),
    /// on by default without the user knowing is worse — so the onboarding sheet
    /// asks once and this key records the answer.
    static func isEnabled(_ store: UserDefaults = .standard) -> Bool {
        store.object(forKey: Key.enabled) == nil ? false : store.bool(forKey: Key.enabled)
    }
}

/// Decides **what** gets deleted. Pure: file listings in, URLs out — no
/// `FileManager`, no SQLite, so every rule is unit-testable.
enum RetentionPlanner {
    struct Session: Sendable, Equatable {
        let url: URL
        let startedAt: Date
        let byteSize: Int64
    }

    enum Class: String, Sendable {
        case archive = "spool-archive"
        case failed = "spool-failed"
    }

    enum Reason: Sendable, Equatable {
        case tooOld(days: Int)
        case overBudget

        /// Goes into the log line, so "where did my recording go" stays
        /// answerable a month later.
        var text: String {
            switch self {
            case .tooOld(let days): return "älter als \(days) Tage"
            case .overBudget: return String(localized: "über dem Speicherbudget")
            }
        }
    }

    struct Removal: Sendable, Equatable {
        let session: Session
        let reason: Reason
        let klass: Class

        var url: URL { session.url }
    }

    struct Plan: Sendable, Equatable {
        var removals: [Removal] = []
        /// Cut-off dates for the SQLite side; `nil` where the rule is off.
        var dictationTextBefore: Date?
        var meetingTextBefore: Date?
        var chatBefore: Date?

        var reclaimedBytes: Int64 { removals.reduce(0) { $0 + $1.session.byteSize } }
        var isEmpty: Bool {
            removals.isEmpty && dictationTextBefore == nil
                && meetingTextBefore == nil && chatBefore == nil
        }
    }

    static func plan(
        policy: RetentionPolicy,
        now: Date,
        archive: [Session],
        failed: [Session] = []
    ) -> Plan {
        var plan = Plan()
        plan.removals =
            removals(from: archive, klass: .archive, now: now,
                     maxAgeDays: policy.audioMaxAgeDays, budget: policy.audioBudgetBytes)
            + removals(from: failed, klass: .failed, now: now,
                       maxAgeDays: policy.failedMaxAgeDays, budget: nil)
        plan.dictationTextBefore = cutoff(policy.dictationTextMaxAgeDays, now: now)
        plan.meetingTextBefore = cutoff(policy.meetingTextMaxAgeDays, now: now)
        plan.chatBefore = cutoff(policy.chatMaxAgeDays, now: now)
        return plan
    }

    private static func cutoff(_ days: Int?, now: Date) -> Date? {
        days.map { now.addingTimeInterval(-Double($0) * 86_400) }
    }

    private static func removals(
        from sessions: [Session],
        klass: Class,
        now: Date,
        maxAgeDays: Int?,
        budget: Int64?
    ) -> [Removal] {
        // Oldest first, which is both the age order and the order the budget
        // rule wants to delete in.
        let ordered = sessions.sorted { $0.startedAt < $1.startedAt }
        var doomed: [Removal] = []
        var kept: [Session] = []

        for session in ordered {
            let age = now.timeIntervalSince(session.startedAt) / 86_400
            // Strictly greater: a session exactly at the limit survives the day.
            if let maxAgeDays, age > Double(maxAgeDays) {
                doomed.append(Removal(session: session, reason: .tooOld(days: Int(age)), klass: klass))
            } else {
                kept.append(session)
            }
        }

        guard let budget else { return doomed }
        var remaining = kept.reduce(Int64(0)) { $0 + $1.byteSize }
        var index = 0
        // Oldest first, and stop the moment we are under budget — never delete
        // one session more than the rule demands.
        while remaining > budget, index < kept.count {
            doomed.append(Removal(session: kept[index], reason: .overBudget, klass: klass))
            remaining -= kept[index].byteSize
            index += 1
        }
        return doomed
    }
}

/// Reads the spool directories into `RetentionPlanner.Session`s. The only part
/// that touches the disk on the planning side.
enum SpoolInventory {
    static func sessions(in directory: URL, fileManager: FileManager = .default) -> [RetentionPlanner.Session] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey]
        ) else { return [] }

        return entries.compactMap { url -> RetentionPlanner.Session? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
            guard values?.isDirectory == true else { return nil }
            // `meta.json` is the truth about when the meeting was; the folder's
            // creation date is only the fallback for a spool that lost it.
            let meta = try? JSONDecoder().decode(
                SpoolStore.Meta.self,
                from: Data(contentsOf: url.appendingPathComponent("meta.json"))
            )
            let startedAt = meta?.startedAt ?? values?.creationDate ?? Date.distantPast
            return RetentionPlanner.Session(url: url, startedAt: startedAt, byteSize: size(of: url, fileManager: fileManager))
        }
    }

    static func size(of directory: URL, fileManager: FileManager = .default) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}

/// Carries out a `RetentionPlan`. Everything that actually destroys something
/// lives here, and every destruction gets a log line with its reason — "where did
/// my recording go" has to stay answerable.
actor RetentionRunner {
    struct Result: Sendable, Equatable {
        var removedSessions = 0
        var reclaimedBytes: Int64 = 0
        var clearedDictationSegments = 0
        var clearedMeetingSegments = 0
        var deletedChatMessages = 0
    }

    private let store: RecordingStore
    private let fileManager: FileManager
    private let log = Logger(subsystem: "de.jonasgehring.notable", category: "retention")

    init(store: RecordingStore, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    /// Builds the plan from what is on disk right now.
    func plan(policy: RetentionPolicy, now: Date = Date()) -> RetentionPlanner.Plan {
        RetentionPlanner.plan(
            policy: policy,
            now: now,
            archive: SpoolInventory.sessions(in: SpoolStore.archiveURL, fileManager: fileManager),
            failed: SpoolInventory.sessions(in: SpoolStore.failedURL, fileManager: fileManager)
        )
    }

    @discardableResult
    func run(_ plan: RetentionPlanner.Plan) async -> Result {
        var result = Result()

        for removal in plan.removals {
            do {
                try fileManager.removeItem(at: removal.url)
                result.removedSessions += 1
                result.reclaimedBytes += removal.session.byteSize
                log.notice("""
                Aufräumen: \(removal.klass.rawValue, privacy: .public)/\
                \(removal.url.lastPathComponent, privacy: .public) gelöscht \
                (\(removal.reason.text, privacy: .public), \
                \(removal.session.byteSize, privacy: .public) Bytes)
                """)
            } catch {
                log.error("Aufräumen fehlgeschlagen für \(removal.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Text only — never the row. `UsageMetrics` reads `recordings`, so
        // deleting a row would retroactively rewrite the statistics.
        if let before = plan.dictationTextBefore {
            result.clearedDictationSegments = (try? await store.clearSegmentText(olderThan: before, kind: .dictation)) ?? 0
        }
        if let before = plan.meetingTextBefore {
            result.clearedMeetingSegments = (try? await store.clearSegmentText(olderThan: before, kind: .meeting)) ?? 0
        }
        if let before = plan.chatBefore {
            result.deletedChatMessages = (try? await store.deleteChatMessages(olderThan: before)) ?? 0
        }

        if result != Result() {
            log.notice("""
            Aufräumen fertig: \(result.removedSessions, privacy: .public) Sitzungen, \
            \(result.reclaimedBytes, privacy: .public) Bytes, \
            \(result.clearedDictationSegments + result.clearedMeetingSegments, privacy: .public) Segmente geleert, \
            \(result.deletedChatMessages, privacy: .public) Chat-Nachrichten gelöscht
            """)
        }
        return result
    }
}
