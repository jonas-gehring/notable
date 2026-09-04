import XCTest

/// Pure-path coverage for `SpeakerNameResolver` — no network, no model.
/// The one behaviour that matters most: a clip with no cues invents no names.
final class SpeakerNameResolverTests: XCTestCase {

    private func seg(_ speaker: String?, _ text: String) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(speaker: speaker, start: 0, end: 1, text: text)
    }

    // MARK: - applyMapping

    func testRelabelsMatchedSpeakers() {
        let segments = [
            seg("Ich", "Hallo zusammen."),
            seg("Sprecher 1", "Hier spricht Anna."),
            seg("Sprecher 2", "Und ich bin Tom."),
        ]
        let named = SpeakerNameResolver.applyMapping(
            segments,
            mapping: ["Sprecher 1": "Anna", "Sprecher 2": "Tom"]
        )
        XCTAssertEqual(named.map(\.speaker), ["Ich", "Anna", "Tom"])
    }

    func testNeverRelabelsIch() {
        let segments = [seg("Ich", "Ich rede."), seg("Sprecher 1", "Danke Anna.")]
        // Even if the model returns a bogus "Ich" key, the whole mapping is
        // rejected — "Ich" is load-bearing.
        let named = SpeakerNameResolver.applyMapping(
            segments,
            mapping: ["Ich": "Alex", "Sprecher 1": "Anna"]
        )
        XCTAssertEqual(named.map(\.speaker), ["Ich", "Sprecher 1"])
    }

    /// The field failure this guards: with only the remote side recorded, the
    /// counterpart addresses the local user by name and the model binds that name
    /// to the person *saying* it. The local user is "Ich" by construction, so that
    /// name on a remote label is always an inversion — drop it, keep the rest.
    func testNeverGivesARemoteLabelTheOwnersOwnName() {
        let segments = [
            seg("Sprecher 1", "Danke, Herr Hoffmann, das passt so."),
            seg("Sprecher 2", "Hier spricht Anna."),
        ]
        let named = SpeakerNameResolver.applyMapping(
            segments,
            mapping: ["Sprecher 1": "Herr Hoffmann", "Sprecher 2": "Anna"],
            ownerTokens: SpeakerNameResolver.nameTokens(in: "Alex Hoffmann")
        )
        XCTAssertEqual(named.map(\.speaker), ["Sprecher 1", "Anna"])
    }

    /// A colleague who merely shares the account holder's first name must still
    /// be nameable — the old token-overlap rule banned them for good.
    func testColleagueSharingAFirstNameIsStillNamed() {
        let segments = [seg("Sprecher 1", "Hier spricht Jonas Weber.")]
        let named = SpeakerNameResolver.applyMapping(
            segments,
            mapping: ["Sprecher 1": "Jonas Weber"],
            ownerTokens: SpeakerNameResolver.nameTokens(in: "Jonas Gehring")
        )
        XCTAssertEqual(named.map(\.speaker), ["Jonas Weber"])
    }

    /// An adverb that happens to look like a first name is not evidence that a
    /// person was in the call.
    func testNameIsNotAttestedByACoincidentalWord() {
        let tokens: Set<String> = ["das", "war", "frank", "gesagt"]
        XCTAssertFalse(SpeakerNameResolver.nameIsAttested("Weber Frank", tokens: tokens),
                       "Nachname allein darf nicht belegen")
        XCTAssertTrue(SpeakerNameResolver.nameIsAttested("Frank Weber", tokens: tokens),
                      "Vorname im Transkript belegt weiterhin")
    }

    /// Without a known account name the gate does nothing — it must not become a
    /// silent blanket filter on machines where the account has no full name.
    func testOwnerGateIsInertWithoutAnOwnerName() {
        let segments = [seg("Sprecher 1", "Hier spricht Anna.")]
        let named = SpeakerNameResolver.applyMapping(
            segments, mapping: ["Sprecher 1": "Anna"], ownerTokens: []
        )
        XCTAssertEqual(named.first?.speaker, "Anna")
    }

    func testRejectsMappingThatResolvesToIch() {
        let segments = [seg("Sprecher 1", "Ich Ich Ich")]
        let named = SpeakerNameResolver.applyMapping(segments, mapping: ["Sprecher 1": "Ich"])
        XCTAssertEqual(named.first?.speaker, "Sprecher 1")
    }

    func testRejectsNameCollision() {
        // Two labels mapped to the same name means the model couldn't tell them
        // apart — reject the entire mapping, leave both anonymous.
        let segments = [
            seg("Sprecher 1", "Anna hier."),
            seg("Sprecher 2", "Auch Anna."),
        ]
        let named = SpeakerNameResolver.applyMapping(
            segments,
            mapping: ["Sprecher 1": "Anna", "Sprecher 2": "Anna"]
        )
        XCTAssertEqual(named.map(\.speaker), ["Sprecher 1", "Sprecher 2"])
    }

    func testUnknownSpeakerLeftUntouched() {
        // A key that doesn't appear in this transcript is ignored, and the
        // valid entry still applies.
        let segments = [seg("Sprecher 1", "Ich bin Anna.")]
        let named = SpeakerNameResolver.applyMapping(
            segments,
            mapping: ["Sprecher 1": "Anna", "Sprecher 9": "Geist"]
        )
        XCTAssertEqual(named.map(\.speaker), ["Anna"])
    }

    func testEmptyMappingLeavesSegmentsUntouched() {
        let segments = [seg("Ich", "a"), seg("Sprecher 1", "b")]
        let named = SpeakerNameResolver.applyMapping(segments, mapping: [:])
        XCTAssertEqual(named.map(\.speaker), ["Ich", "Sprecher 1"])
    }

    // MARK: - strict verbatim mode

    func testStrictModeDropsUnattestedName() {
        // Name never spoken in the transcript ⇒ dropped (attendee-only guess).
        let segments = [seg("Sprecher 1", "Also die Zahlen sehen gut aus.")]
        let named = SpeakerNameResolver.applyMapping(segments, mapping: ["Sprecher 1": "Anna Weber"])
        XCTAssertEqual(named.first?.speaker, "Sprecher 1")
    }

    func testStrictModeAcceptsAttestedFirstNameToken() {
        // "tom" is spoken; candidate spelling "Tom Berger" is anchored by it.
        let segments = [seg("Sprecher 1", "Genau, das sehe ich auch so, sagt tom.")]
        let named = SpeakerNameResolver.applyMapping(segments, mapping: ["Sprecher 1": "Tom Berger"])
        XCTAssertEqual(named.first?.speaker, "Tom Berger")
    }

    func testVerbatimDisabledAppliesUnattestedName() {
        let segments = [seg("Sprecher 1", "Keine Namen hier.")]
        let named = SpeakerNameResolver.applyMapping(
            segments,
            mapping: ["Sprecher 1": "Anna"],
            requireVerbatim: false
        )
        XCTAssertEqual(named.first?.speaker, "Anna")
    }

    // MARK: - JSON parsing

    func testParsesStrictJSONAndDropsNulls() {
        let raw = #"{"Sprecher 1": "Anna", "Sprecher 2": null}"#
        let mapping = SpeakerNameResolver.parseMapping(raw)
        XCTAssertEqual(mapping, ["Sprecher 1": "Anna"])
    }

    func testParsesJSONWrappedInProse() {
        let raw = "Hier das Ergebnis:\n{\"Sprecher 1\": \"Anna\"}\nFertig."
        XCTAssertEqual(SpeakerNameResolver.parseMapping(raw), ["Sprecher 1": "Anna"])
    }

    func testMalformedJSONYieldsEmptyMapping() {
        XCTAssertTrue(SpeakerNameResolver.parseMapping("nicht mal JSON").isEmpty)
        XCTAssertTrue(SpeakerNameResolver.parseMapping("{ kaputt ").isEmpty)
    }

    func testParseThenApplyEndToEndNoCues() {
        // The most important guard: a real reply of all-null on a cue-less clip
        // renames nobody.
        let segments = [
            seg("Ich", "Fangen wir an."),
            seg("Sprecher 1", "Die Latenz ist zu hoch im Batch-Pfad."),
            seg("Sprecher 2", "Wir sollten das Caching überdenken."),
        ]
        let mapping = SpeakerNameResolver.parseMapping(#"{"Sprecher 1": null, "Sprecher 2": null}"#)
        let named = SpeakerNameResolver.applyMapping(segments, mapping: mapping)
        XCTAssertEqual(named.map(\.speaker), ["Ich", "Sprecher 1", "Sprecher 2"])
    }

    // MARK: - helpers

    func testRemoteLabelsExcludesIchAndDeduplicates() {
        let segments = [
            seg("Ich", "a"),
            seg("Sprecher 2", "b"),
            seg("Sprecher 1", "c"),
            seg("Sprecher 2", "d"),
        ]
        XCTAssertEqual(SpeakerNameResolver.remoteLabels(in: segments), ["Sprecher 2", "Sprecher 1"])
    }
}
