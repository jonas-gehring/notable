import Foundation
import XCTest
@testable import Notable

/// Spec 38 §3.5 and §6.4.
///
/// The settings lost three pages, four submenus and a dozen controls, and the
/// one thing that must **not** have been lost is a value somebody set. Every
/// key stayed where it was; what changed is who writes it. So this file is
/// mostly about the seams that creates:
///
/// - a picker that stands for two keys, in both directions, including the
///   stored combinations that match no position at all;
/// - a page that absorbed another, and the old route that has to still arrive;
/// - a number that is now derived instead of asked for, and the stored value
///   that still overrides it;
/// - a provider that is now derived instead of picked — without ever becoming
///   the metered API.
final class SettingsBindingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "notable-spec38-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Ton während des Diktats (drei Toggles → ein Picker)

    func testAudioModeWritesExactlyOneKeyPerPosition() {
        XCTAssertEqual(DictationAudioMode.nothing.pausePlayback, false)
        XCTAssertEqual(DictationAudioMode.nothing.muteOutput, false)

        XCTAssertEqual(DictationAudioMode.pausePlayback.pausePlayback, true)
        XCTAssertEqual(DictationAudioMode.pausePlayback.muteOutput, false)

        XCTAssertEqual(DictationAudioMode.muteOutput.pausePlayback, false)
        XCTAssertEqual(DictationAudioMode.muteOutput.muteOutput, true)
    }

    /// Every position survives a round trip through its own key pair.
    func testAudioModeRoundTrips() {
        for mode in DictationAudioMode.allCases {
            XCTAssertEqual(
                DictationAudioMode(pausePlayback: mode.pausePlayback, muteOutput: mode.muteOutput),
                mode
            )
        }
    }

    /// Four stored combinations, three positions. `(true, true)` was reachable
    /// until Spec 38 — two separate checkboxes — and has to read as the
    /// *stronger* one: muting silences everything, pausing only stops one app,
    /// and telling someone their Mac still makes noise while it does not is the
    /// wrong direction to be wrong in.
    func testAudioModeReadsEveryStoredCombination() {
        XCTAssertEqual(DictationAudioMode(pausePlayback: false, muteOutput: false), .nothing)
        XCTAssertEqual(DictationAudioMode(pausePlayback: true, muteOutput: false), .pausePlayback)
        XCTAssertEqual(DictationAudioMode(pausePlayback: false, muteOutput: true), .muteOutput)
        XCTAssertEqual(DictationAudioMode(pausePlayback: true, muteOutput: true), .muteOutput,
                       "Die unmögliche Kombination zeigt die stärkere Stellung")
    }

    /// …and the next change writes a clean pair, so the impossible combination
    /// cannot survive being touched.
    func testAudioModeWritesCleanlyAfterAnImpossibleCombination() {
        let read = DictationAudioMode(pausePlayback: true, muteOutput: true)
        let next = DictationAudioMode.pausePlayback
        XCTAssertNotEqual(read, next)
        XCTAssertFalse(next.muteOutput, "Der Wechsel räumt den zweiten Key ab")
        XCTAssertTrue(next.pausePlayback)
    }

    /// The defaults are unchanged: both keys are `false` when unset, which is
    /// the `nothing` position, so nobody's dictation starts behaving differently
    /// because the interface was reshaped.
    func testUnsetAudioKeysMeanNothingHappens() {
        let mode = DictationAudioMode(
            pausePlayback: defaults.bool(forKey: MediaInterrupter.Key.pausePlayback),
            muteOutput: defaults.bool(forKey: MediaInterrupter.Key.muteOutput)
        )
        XCTAssertEqual(mode, .nothing)
    }

    // MARK: - Sprecher benennen (zwei Toggles → ein Picker)

    func testSpeakerNamingWritesTheExpectedKeyPair() {
        XCTAssertEqual(SpeakerNamingMode.off.namesFromConversation, false)
        XCTAssertEqual(SpeakerNamingMode.off.readsScreen, false)

        // The weaker source is on for the on-device position and stays on for
        // the strong one — the order *is* the privacy axis.
        XCTAssertEqual(SpeakerNamingMode.onDevice.namesFromConversation, false)
        XCTAssertEqual(SpeakerNamingMode.onDevice.readsScreen, true)

        XCTAssertEqual(SpeakerNamingMode.fromConversation.namesFromConversation, true)
        XCTAssertEqual(SpeakerNamingMode.fromConversation.readsScreen, true)
    }

    func testSpeakerNamingRoundTrips() {
        for mode in SpeakerNamingMode.allCases {
            XCTAssertEqual(
                SpeakerNamingMode(namesFromConversation: mode.namesFromConversation, readsScreen: mode.readsScreen),
                mode
            )
        }
    }

    /// `(naming: true, screen: false)` is the combination the two old toggles
    /// allowed and the picker has no step for. It reads as the strong position,
    /// because in that pair text *is* leaving the device and the control has to
    /// say so rather than understate it.
    func testSpeakerNamingReadsEveryStoredCombination() {
        XCTAssertEqual(SpeakerNamingMode(namesFromConversation: false, readsScreen: false), .off)
        XCTAssertEqual(SpeakerNamingMode(namesFromConversation: false, readsScreen: true), .onDevice)
        XCTAssertEqual(SpeakerNamingMode(namesFromConversation: true, readsScreen: true), .fromConversation)
        XCTAssertEqual(SpeakerNamingMode(namesFromConversation: true, readsScreen: false), .fromConversation,
                       "Text verlässt das Gerät — das ist die Stellung, die genannt werden muss")
    }

    /// Both keys default to `true`, so an untouched install reads as the strong
    /// position — exactly what it did before Spec 38, when both boxes were
    /// ticked.
    func testUnsetSpeakerKeysMeanTheSameAsBefore() {
        let mode = SpeakerNamingMode(
            namesFromConversation: DefaultsKey.speakerNamingEnabled.value(defaults),
            readsScreen: DefaultsKey.screenSpeakerRecognition.value(defaults)
        )
        XCTAssertEqual(mode, .fromConversation)
    }

    /// Only the two known keys are written. A mode that also silently flipped a
    /// third would be exactly the kind of hidden coupling this file exists to
    /// prevent, so the mapping is pinned as a table rather than trusted.
    func testEachSpeakerPositionIsDistinct() {
        let pairs = SpeakerNamingMode.allCases.map { [$0.namesFromConversation, $0.readsScreen] }
        XCTAssertEqual(Set(pairs.map(\.description)).count, SpeakerNamingMode.allCases.count)
    }

    // MARK: - Aufbewahrung (sechs Picker → einer)

    func testAudioRetentionOffersTheFiveStepsFromTheSpec() {
        XCTAssertEqual(AudioRetentionChoice.allCases.map(\.rawValue), [7, 30, 90, 365, 0])
    }

    /// A number that is none of the five — set by hand, or by a build with a
    /// different table — rounds **up**, never down: audio deleted earlier than
    /// the user asked for is gone, and the picker must not quietly shorten a
    /// deadline just by being looked at.
    func testAudioRetentionRoundsUpToTheNextOfferedStep() {
        XCTAssertEqual(AudioRetentionChoice.nearest(days: 7), .week)
        XCTAssertEqual(AudioRetentionChoice.nearest(days: 1), .week)
        XCTAssertEqual(AudioRetentionChoice.nearest(days: 8), .month)
        XCTAssertEqual(AudioRetentionChoice.nearest(days: 45), .quarter)
        XCTAssertEqual(AudioRetentionChoice.nearest(days: 365), .year)
        XCTAssertEqual(AudioRetentionChoice.nearest(days: 400), .forever)
        XCTAssertEqual(AudioRetentionChoice.nearest(days: 0), .forever)
    }

    /// Nothing stored still means exactly the policy it meant before.
    func testUnsetRetentionKeysStillMeanTheDefaultPolicy() {
        XCTAssertEqual(RetentionPolicy.fromDefaults(defaults), .default)
        XCTAssertFalse(RetentionPolicy.isEnabled(defaults), "Aufräumen bleibt opt-in")
    }

    /// The grace period for failed recordings lost its picker and is derived
    /// from the one age still on screen. Someone who halves the audio window
    /// means it for the failures too.
    func testFailedGracePeriodFollowsTheAudioAge() {
        defaults.set(7, forKey: RetentionPolicy.Key.audioAge)
        XCTAssertEqual(RetentionPolicy.fromDefaults(defaults).failedMaxAgeDays, 14)

        defaults.set(90, forKey: RetentionPolicy.Key.audioAge)
        XCTAssertEqual(RetentionPolicy.fromDefaults(defaults).failedMaxAgeDays, 180)
    }

    /// Off for audio means off for the failures — there is nothing to derive a
    /// deadline from, and inventing one would delete files the user just said
    /// to keep.
    func testAudioOffLeavesFailedRecordingsAlone() {
        defaults.set(0, forKey: RetentionPolicy.Key.audioAge)
        let policy = RetentionPolicy.fromDefaults(defaults)
        XCTAssertNil(policy.audioMaxAgeDays)
        XCTAssertNil(policy.failedMaxAgeDays)
    }

    /// §3.5, first class: the key has no picker over the fold any more, and it
    /// is still read. A stored value wins over the derivation.
    func testAStoredFailedAgeStillWins() {
        defaults.set(30, forKey: RetentionPolicy.Key.audioAge)
        defaults.set(5, forKey: RetentionPolicy.Key.failedAge)
        XCTAssertEqual(RetentionPolicy.fromDefaults(defaults).failedMaxAgeDays, 5)
    }

    /// The three text deadlines stopped being offered over the fold. They are
    /// still read, so whoever set one keeps it — this is the regression test
    /// §6.4 asks for, one per key.
    func testTheThreeTextDeadlinesAreStillRead() {
        defaults.set(90, forKey: RetentionPolicy.Key.dictationAge)
        defaults.set(30, forKey: RetentionPolicy.Key.meetingAge)
        defaults.set(7, forKey: RetentionPolicy.Key.chatAge)
        let policy = RetentionPolicy.fromDefaults(defaults)
        XCTAssertEqual(policy.dictationTextMaxAgeDays, 90)
        XCTAssertEqual(policy.meetingTextMaxAgeDays, 30)
        XCTAssertEqual(policy.chatMaxAgeDays, 7)
    }

    /// …and are still off when nothing was stored, which is what "Texte werden
    /// nicht mehr automatisch gelöscht" has to mean for everyone else.
    func testTextDeadlinesStayOffWhenNobodySetThem() {
        let policy = RetentionPolicy.fromDefaults(defaults)
        XCTAssertNil(policy.dictationTextMaxAgeDays)
        XCTAssertNil(policy.meetingTextMaxAgeDays)
        XCTAssertNil(policy.chatMaxAgeDays)
    }

    /// The budget key keeps its meaning too, including `0` for "no budget".
    func testTheAudioBudgetKeyIsStillRead() {
        defaults.set(5, forKey: RetentionPolicy.Key.audioBudget)
        XCTAssertEqual(RetentionPolicy.fromDefaults(defaults).audioBudgetBytes, 5 * 1024 * 1024 * 1024)
        defaults.set(0, forKey: RetentionPolicy.Key.audioBudget)
        XCTAssertNil(RetentionPolicy.fromDefaults(defaults).audioBudgetBytes)
    }

    // MARK: - Routen der aufgelösten Seiten

    /// Four pages were absorbed. Their raw values are written into notification
    /// payloads and set by menu items, so each one has to arrive at the page
    /// that took it over — resolving to `nil` would silently drop the user
    /// wherever the settings window happened to be left.
    func testEveryOldRouteReachesThePageThatAbsorbedIt() {
        XCTAssertEqual(SettingsPane(rawValue: "menubar"), .general)
        XCTAssertEqual(SettingsPane(rawValue: "summary"), .meetings)
        XCTAssertEqual(SettingsPane(rawValue: "storage"), .data)
        XCTAssertEqual(SettingsPane(rawValue: "permissions"), .data)
    }

    func testTheFourPagesRoundTripThroughTheirRawValue() {
        XCTAssertEqual(SettingsPane.allCases.count, 4)
        for pane in SettingsPane.allCases {
            XCTAssertEqual(SettingsPane(rawValue: pane.rawValue), pane)
        }
    }

    /// Widening the way in must not make it accept anything at all — a typo in
    /// a payload should still fail loudly rather than land on "Allgemein".
    func testAnUnknownRouteIsStillNil() {
        XCTAssertNil(SettingsPane(rawValue: "speicherplatz"))
        XCTAssertNil(SettingsPane(rawValue: ""))
    }

    // MARK: - Der abgeleitete Dienst der Verbesserung

    /// The "Dienst" picker is gone; the summarization provider answers for it
    /// when it is a CLI.
    func testTheEnhancementProviderFollowsTheSummarizationProvider() {
        XCTAssertEqual(
            DictationEnhancer.resolvedProviderID(enhance: nil, summarization: "gemini-cli"),
            .geminiCLI
        )
        XCTAssertEqual(
            DictationEnhancer.resolvedProviderID(enhance: nil, summarization: "codex-cli"),
            .codexCLI
        )
    }

    /// **The scope decision, as a table.** Whatever the summarization provider
    /// is, the dictation path lands on a subscription CLI — the metered API key
    /// is unreachable from here, and so is any unrecognised value.
    func testTheEnhancementProviderIsNeverTheMeteredAPI() {
        for summarization in ["anthropic-api", "something-else", ""] {
            let resolved = DictationEnhancer.resolvedProviderID(enhance: nil, summarization: summarization)
            XCTAssertEqual(resolved, .claudeCodeCLI, "\(summarization) muss auf der Claude-CLI landen")
            XCTAssertTrue(resolved.isCLI)
        }
        XCTAssertEqual(
            DictationEnhancer.resolvedProviderID(enhance: "anthropic-api", summarization: "anthropic-api"),
            .claudeCodeCLI,
            "Auch als ausdrücklich gesetzter Dienst ist die API nicht erreichbar"
        )
    }

    /// §3.5, third class: whoever set `dictationEnhanceProvider` keeps it, they
    /// just have no picker for it any more.
    func testAnExplicitlySetServiceStillWins() {
        XCTAssertEqual(
            DictationEnhancer.resolvedProviderID(enhance: "gemini-cli", summarization: "claude-code-cli"),
            .geminiCLI
        )
    }

    /// The time budget lost its slider and became one number. The key is still
    /// read and still clamped, so a value from before Spec 38 keeps working.
    func testTheDeadlineIsFixedButAStoredValueStillCounts() {
        XCTAssertEqual(EnhancementSettings.fixedDeadlineSeconds, 15)
        XCTAssertEqual(EnhancementSettings.deadline(defaults), .seconds(15))
        defaults.set(40.0, forKey: EnhancementSettings.deadlineKey)
        XCTAssertEqual(EnhancementSettings.deadline(defaults), .seconds(40))
    }

    // MARK: - Die Zahl, die nicht zurückwachsen darf (§6.2)

    /// Counts the controls in the settings source, the way `ThemeTests` counts
    /// fixed font sizes: the diet is only worth something if it stays done, and
    /// the way it comes undone is one more switch at a time, each of which
    /// looks reasonable on its own.
    ///
    /// **These ceilings are the measured totals, not the 16/10 from §6.2.** That
    /// pair counts the controls a *user* sees on the four pages; this counts
    /// occurrences in the source, which is a bigger number for three reasons
    /// that have nothing to do with the diet: the five switches inside the
    /// "Text aufbereiten" sheet, the per-row `Toggle`s in the dictionary and
    /// snippet tables (one in the source, N on screen), and two helpers that
    /// each emit one `Picker(` standing for five visible ones. §3.2's own
    /// tables already add up to ~18 switches, so 16 was never reachable while
    /// building every section it lists — see §9.
    /// **26 → 29 am 2026-09-16**, und die drei sind einzeln begründet — genau die
    /// Prüfung, die die Meldung unten verlangt:
    ///
    /// - „Wochenrückblick" (Spec 37 §3.4): eine Mitteilung, die ungefragt kommt.
    ///   Beide Stellungen sind für denselben Nutzer vertretbar.
    /// - „Stimmen wiedererkennen" (Spec 36 §3.3): legt biometrische Merkmale
    ///   *anderer* Leute an. Das darf nur ausdrücklich eingeschaltet werden.
    /// - „Wortzahl nach dem Diktat anzeigen" (Spec 37 §7): dort als Schalter
    ///   entschieden, für den, der nur den Ton will.
    ///
    /// Wer die Zahl das nächste Mal anhebt, schreibt hier wieder drei Zeilen —
    /// oder lässt es.
    func testTheControlCountDoesNotGrowBack() throws {
        let counts = try Self.controlCounts()
        XCTAssertLessThanOrEqual(counts.toggles, 29, "Ein Schalter mehr in den Einstellungen — war das eine Entscheidung, die der Code nicht treffen kann?")
        XCTAssertLessThanOrEqual(counts.pickers, 19, "Ein Picker mehr in den Einstellungen — siehe Spec 38 §3.1")
    }

    /// The four pages, and no fifth. Every page absorbed since Spec 38 has to
    /// stay absorbed; a new one is a decision, not an oversight.
    func testThereAreStillFourSettingsPages() throws {
        let root = Self.repoRoot.appendingPathComponent("Sources/Notable/Settings")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        for gone in ["MenuBarSettingsView.swift", "StorageSettingsView.swift", "PermissionsSettingsView.swift"] {
            XCTAssertFalse(files.contains(gone), "\(gone) ist in Spec 38 aufgegangen")
        }
        XCTAssertTrue(files.contains("DataSettingsView.swift"))
        XCTAssertTrue(files.contains("SettingsBindings.swift"))
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Comment lines are skipped — the doc comments in these files talk *about*
    /// `Toggle(` and `Picker(` a great deal, and counting the prose would make
    /// the guard fire on an explanation.
    private static func controlCounts() throws -> (toggles: Int, pickers: Int) {
        let root = repoRoot.appendingPathComponent("Sources/Notable/Settings")
        var toggles = 0
        var pickers = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                toggles += line.components(separatedBy: "Toggle(").count - 1
                pickers += line.components(separatedBy: "Picker(").count - 1
            }
        }
        return (toggles, pickers)
    }
}
