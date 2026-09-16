import XCTest

/// Spec 35: every silent exit of the speaker naming and the title has its own
/// code, so the next meeting says which one it took.
final class NoteDiagnosisNamingTests: XCTestCase {
    private func naming(
        hasTranscript: Bool = true, micSilent: Bool = false, remoteLabels: Int = 2,
        screenNamed: Int = 0, calendarNamed: Int = 0, voiceNamed: Int = 0,
        openLabels: Int = 2, enabled: Bool = true,
        outcome: SpeakerNameResolver.Outcome? = nil
    ) -> String {
        NoteDiagnosis.naming(hasTranscript: hasTranscript, micSilent: micSilent, remoteLabels: remoteLabels,
                             screenNamed: screenNamed, calendarNamed: calendarNamed, voiceNamed: voiceNamed,
                             openLabels: openLabels, enabled: enabled, outcome: outcome)
    }

    /// Spec 36: the voice is the source that costs nothing to try and is the
    /// easiest to be wrong about, so it is counted where it fired.
    func testTheVoiceIsCountedSeparately() {
        XCTAssertEqual(naming(remoteLabels: 1, voiceNamed: 1, openLabels: 0),
                       "benannt: 1 von 1 (ohne Modell, stimme: 1)")
        XCTAssertEqual(naming(remoteLabels: 2, voiceNamed: 1, openLabels: 1,
                              outcome: .init(result: .answered, proposed: 1, accepted: 1)),
                       "benannt: 2 von 2 (stimme: 1)")
        XCTAssertEqual(naming(remoteLabels: 1, calendarNamed: 1, openLabels: 0),
                       "benannt: 1 von 1 (ohne Modell)", "ohne Stimme steht auch nichts davon da")
    }

    /// Spec 36 §3.2: the notification offers the dialog exactly when nothing was
    /// named and there is more than one voice to tell apart.
    func testTheDialogIsOfferedOnlyWhereItHelps() {
        XCTAssertTrue(NoteDiagnosis.offersSpeakerNaming(naming: "nichtVersucht", remoteLabels: 2))
        XCTAssertTrue(NoteDiagnosis.offersSpeakerNaming(naming: "modellOhneNamen (2 offen)", remoteLabels: 3))
        XCTAssertFalse(NoteDiagnosis.offersSpeakerNaming(naming: "benannt: 1 von 2", remoteLabels: 2))
        XCTAssertFalse(NoteDiagnosis.offersSpeakerNaming(naming: "nichtVersucht", remoteLabels: 1),
                       "eine einzige Gegenseite braucht keinen Dialog")
        XCTAssertFalse(NoteDiagnosis.offersSpeakerNaming(naming: "mikrofonStumm", remoteLabels: 0))
    }

    /// Spec 36 §3.1: an adapter that finds nothing is news; no adapter is not.
    func testTheScreenSaysWhichOfTheTwoSilencesItIs() {
        XCTAssertEqual(NoteDiagnosis.screen(adapterRan: false, observations: 0, meetingsWithoutData: 7), "keinAdapter")
        XCTAssertEqual(NoteDiagnosis.screen(adapterRan: true, observations: 0, meetingsWithoutData: 3),
                       "bildschirmOhneDaten: 3 Meetings")
        XCTAssertEqual(NoteDiagnosis.screen(adapterRan: true, observations: 42, meetingsWithoutData: 0),
                       "gelesen: 42 Beobachtungen")
    }

    /// The one-to-one rule names without the model (Spec 35).
    func testTheCalendarCountsAsNamedWithoutTheModel() {
        XCTAssertEqual(naming(remoteLabels: 1, calendarNamed: 1, openLabels: 0), "benannt: 1 von 1 (ohne Modell)")
        XCTAssertEqual(naming(remoteLabels: 2, calendarNamed: 1, openLabels: 1,
                              outcome: .init(result: .answered, proposed: 1, accepted: 1)), "benannt: 2 von 2")
    }

    func testTheOrderOfTheExitsIsTheOrderOfTheCode() {
        XCTAssertEqual(naming(hasTranscript: false), "keinTranskript")
        XCTAssertEqual(naming(remoteLabels: 0), "keineGegenseite")
        XCTAssertEqual(naming(micSilent: true), "mikrofonStumm")
        XCTAssertEqual(naming(enabled: false), "ausgeschaltet")
        XCTAssertEqual(naming(), "nichtVersucht")
    }

    func testTheProviderErrorIsKeptAndShortened() {
        let long = String(repeating: "x", count: 500)
        let code = naming(outcome: .init(result: .providerFailed(long)))
        XCTAssertTrue(code.hasPrefix("anbieterFehler: "))
        XCTAssertLessThanOrEqual(code.count, "anbieterFehler: ".count + 120)
    }

    func testNoNamesAndRejectedNamesAreDifferentFindings() {
        XCTAssertEqual(naming(outcome: .init(result: .answered, proposed: 0, accepted: 0)), "modellOhneNamen (2 offen)")
        XCTAssertEqual(naming(outcome: .init(result: .answered, proposed: 2, accepted: 0)), "verworfen: 2 vorgeschlagen, 0 übernommen")
        XCTAssertEqual(naming(screenNamed: 1, openLabels: 1, outcome: .init(result: .answered, proposed: 1, accepted: 1)),
                       "benannt: 2 von 2")
    }

    func testTheScreenNamingEverythingNeedsNoModel() {
        XCTAssertEqual(naming(screenNamed: 2, openLabels: 0), "benannt: 2 von 2 (ohne Modell)")
    }
}

final class NoteDiagnosisTitleTests: XCTestCase {
    private func title(
        eventAtStart: Bool = false, eventAtStop: Bool = false, windowTitled: Bool = false, modelTitled: Bool = false,
        callSource: Bool = false, calendarAccess: Bool = true, hasTranscript: Bool = true, summaryFailed: Bool = false
    ) -> String {
        NoteDiagnosis.title(eventAtStart: eventAtStart, eventAtStop: eventAtStop, windowTitled: windowTitled,
                            modelTitled: modelTitled,
                            callSource: callSource, calendarAccess: calendarAccess,
                            hasTranscript: hasTranscript, summaryFailed: summaryFailed)
    }

    func testWhereTheTitleCameFrom() {
        XCTAssertEqual(title(eventAtStart: true), "kalender")
        XCTAssertEqual(title(eventAtStop: true), "kalenderBeimStopp")
        XCTAssertEqual(title(modelTitled: true), "modell")
    }

    /// Spec 36 §3.1: the window's title is the one the organiser set, so it is
    /// ranked before the model — and behind the calendar.
    func testTheWindowTitleSitsBetweenTheCalendarAndTheModel() {
        XCTAssertEqual(title(windowTitled: true), "fenster")
        XCTAssertEqual(title(windowTitled: true, modelTitled: true), "fenster")
        XCTAssertEqual(title(eventAtStart: true, windowTitled: true), "kalender")
    }

    /// "Meeting" on its own was the symptom; these are its causes.
    func testTheFallbackNamesBothMissingSources() {
        XCTAssertEqual(title(calendarAccess: false, hasTranscript: false), "fallback: keinKalenderzugriff, keinTranskript")
        XCTAssertEqual(title(callSource: true, summaryFailed: true), "callQuelle: keinPassenderTermin, zusammenfassungFehlgeschlagen")
        XCTAssertEqual(title(), "fallback: keinPassenderTermin, modellOhneTitel")
    }
}

/// Spec 35: the account's first name is not enough to recognise the owner.
final class OwnerNameTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DefaultsKey.ownerName.key)
        super.tearDown()
    }

    func testTheSurnameFromSettingsMakesHerrGehringTheOwner() {
        UserDefaults.standard.set("Jonas Gehring", forKey: DefaultsKey.ownerName.key)
        let tokens = SpeakerNameResolver.ownerNameTokens
        XCTAssertTrue(SpeakerNameResolver.isOwnerName("Herr Gehring", ownerTokens: tokens))
        XCTAssertFalse(SpeakerNameResolver.isOwnerName("Maria Wendler", ownerTokens: tokens))
    }

    func testMetaCarriesTheDiagnosis() throws {
        let meta = SpoolStore.Meta(startedAt: Date(timeIntervalSinceReferenceDate: 0),
                                   naming: "mikrofonStumm", titleSource: "kalender")
        let decoded = try JSONDecoder().decode(SpoolStore.Meta.self, from: JSONEncoder().encode(meta))
        XCTAssertEqual(decoded.naming, "mikrofonStumm")
        XCTAssertEqual(decoded.titleSource, "kalender")
    }
}
