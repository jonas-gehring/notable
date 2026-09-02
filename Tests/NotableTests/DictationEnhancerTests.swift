import XCTest
@testable import Notable

/// Issue #1 Stufe 2. Dictation text leaving the device is the one thing this
/// project spent two scope decisions on, so most of these tests are about the
/// cases where it must **not** happen — and about what may be pasted when it did.
final class DictationEnhancerTests: XCTestCase {
    // MARK: - The scope decision, as a test

    /// The dictation path is hard-wired to the Claude Code CLI. The
    /// metered API key must be unreachable from here — including when it is the
    /// selected *meeting* provider, which is exactly the mix-up that would
    /// otherwise go unnoticed.
    func testDictationPathIsWiredToTheCLIProviderOnly() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "summarizationProvider")
        defer { defaults.set(previous, forKey: "summarizationProvider") }

        defaults.set("anthropic-api", forKey: "summarizationProvider")
        XCTAssertEqual(DictationEnhancer.dictationProvider.id, ClaudeCodeCLIProvider().id)
        XCTAssertEqual(DictationEnhancer.forDictation().provider.id, "claude-code-cli")
        XCTAssertNotEqual(DictationEnhancer.forDictation().provider.id, AnthropicAPIProvider().id)
    }

    /// Off means off at the key level: no hotkey is installed at all, so the
    /// feature cannot fire by accident.
    func testNoHotkeyWhileTheFeatureIsOff() {
        let store = UserDefaults(suiteName: "Enhance.\(UUID().uuidString)")!
        store.set("rightCommand", forKey: EnhancementSettings.hotkeyKey)
        XCTAssertFalse(EnhancementSettings.isEnabled(store))
        XCTAssertNil(EnhancementSettings.hotkey(store))

        store.set(true, forKey: EnhancementSettings.enabledKey)
        XCTAssertEqual(EnhancementSettings.hotkey(store), .rightCommand)
    }

    func testEnabledWithoutAKeyStillHasNoHotkey() {
        let store = UserDefaults(suiteName: "Enhance.\(UUID().uuidString)")!
        store.set(true, forKey: EnhancementSettings.enabledKey)
        XCTAssertNil(EnhancementSettings.hotkey(store), "Menüweg allein braucht keine Taste")
    }

    // MARK: - Guardrails

    private let input = "Das ist ein diktierter Satz, der überarbeitet werden soll."

    func testPlainRewriteIsAccepted() {
        let output = "Das ist ein diktierter Satz, der überarbeitet werden sollte."
        XCTAssertEqual(EnhancementGuard.accept(output, forInput: input), output)
    }

    func testEmptyAnswerIsRejected() {
        XCTAssertNil(EnhancementGuard.accept("", forInput: input))
        XCTAssertNil(EnhancementGuard.accept("   \n ", forInput: input))
    }

    /// The classic: the model answers *about* the text instead of returning it.
    func testMetaAnswerIsRejected() {
        XCTAssertNil(EnhancementGuard.accept("Hier ist die überarbeitete Version: Das ist ein Satz.", forInput: input))
        XCTAssertNil(EnhancementGuard.accept("Sure, here's the improved text: A sentence.", forInput: input))
    }

    func testAnswerThatDroppedMostOfTheTextIsRejected() {
        XCTAssertNil(EnhancementGuard.accept("Ein Satz.", forInput: input))
    }

    func testAnswerThatInventedTextIsRejected() {
        let inflated = String(repeating: "Und weiter geht es mit noch mehr Text. ", count: 10)
        XCTAssertNil(EnhancementGuard.accept(inflated, forInput: input))
    }

    /// A fence *wrapping* the answer is a formatting habit — unwrap and judge the
    /// content. A fence inside it means the model reformatted rather than rewrote.
    func testWrappingCodeFenceIsUnwrappedButAnInnerOneIsRejected() {
        let wrapped = "```\nDas ist ein diktierter Satz, der überarbeitet wurde.\n```"
        XCTAssertEqual(
            EnhancementGuard.accept(wrapped, forInput: input),
            "Das ist ein diktierter Satz, der überarbeitet wurde."
        )
        XCTAssertNil(EnhancementGuard.accept("Text mit ```code``` mittendrin und noch etwas mehr.", forInput: input))
    }

    /// Ratios say nothing on very short input — "ja" → "Ja." is 150 % and right.
    func testShortInputSkipsTheRatioRules() {
        XCTAssertEqual(EnhancementGuard.accept("Ja.", forInput: "ja"), "Ja.")
    }

    // MARK: - The round-trip

    /// A provider that answers, throws, or hangs — the three things that must all
    /// end with text in the user's field.
    private struct StubProvider: SummarizationProvider {
        var id = "stub"
        var displayName = "Stub"
        var answer: String?
        var error: Error?
        var delay: Duration?

        func availability() async -> ProviderAvailability { .available }
        func summarize(transcript: String, context: MeetingContext) async throws -> Summary {
            Summary(markdown: "", providerID: id)
        }
        func complete(system: String, user: String) async throws -> Completion {
            if let delay { try await Task.sleep(for: delay) }
            if let error { throw error }
            return Completion(text: answer ?? "", usage: SummarizationUsage(inputTokens: 10, outputTokens: 5, billed: false))
        }
    }

    private struct StubError: Error, LocalizedError {
        var errorDescription: String? { "CLI kaputt" }
    }

    func testSuccessfulEnhancementReturnsTheModelsText() async {
        let enhancer = DictationEnhancer(provider: StubProvider(answer: "Ein überarbeiteter, deutlich klarerer Satz."))
        let result = await enhancer.enhance(input, profile: .tighten)
        XCTAssertTrue(result.didEnhance)
        XCTAssertEqual(result.text, "Ein überarbeiteter, deutlich klarerer Satz.")
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.usage?.billed, false, "Abo-CLI: nie als Ausgabe verbucht")
    }

    /// Losing a dictation because a network call failed would be the worst
    /// possible trade — every failure path pastes the polished original.
    func testProviderErrorFallsBackToTheOriginal() async {
        let enhancer = DictationEnhancer(provider: StubProvider(error: StubError()))
        let result = await enhancer.enhance(input, profile: .tighten)
        XCTAssertFalse(result.didEnhance)
        XCTAssertEqual(result.text, input)
        XCTAssertNotNil(result.failure)
    }

    func testRejectedAnswerFallsBackToTheOriginal() async {
        let enhancer = DictationEnhancer(provider: StubProvider(answer: "Hier ist die überarbeitete Version: irgendwas."))
        let result = await enhancer.enhance(input, profile: .tighten)
        XCTAssertFalse(result.didEnhance)
        XCTAssertEqual(result.text, input)
        XCTAssertNotNil(result.failure)
        XCTAssertNotNil(result.usage, "verworfen heißt nicht ungebucht — der Text war trotzdem draußen")
    }

    func testTimeoutFallsBackToTheOriginal() async {
        let enhancer = DictationEnhancer(
            provider: StubProvider(answer: "Zu spät.", delay: .seconds(5)),
            deadline: .milliseconds(80)
        )
        let result = await enhancer.enhance(input, profile: .tighten)
        XCTAssertFalse(result.didEnhance)
        XCTAssertEqual(result.text, input)
        XCTAssertEqual(result.failure, "Verbesserung dauerte zu lange — Originaltext eingefügt.")
    }

    func testEmptyInputMakesNoCall() async {
        let enhancer = DictationEnhancer(provider: StubProvider(answer: "sollte nie gefragt werden"))
        let result = await enhancer.enhance("   ", profile: .tighten)
        XCTAssertFalse(result.didEnhance)
        XCTAssertNil(result.usage)
    }

    // MARK: - Profiles

    func testBuiltInProfilesCarryTheCommonRules() {
        for profile in EnhancementProfile.builtIn {
            XCTAssertTrue(profile.systemPrompt.contains("Erfinde nichts"), profile.id)
            XCTAssertTrue(profile.systemPrompt.contains("Behalte die Sprache"), profile.id)
        }
    }

    func testProfileIsSuggestedFromTheTargetApp() {
        let store = UserDefaults(suiteName: "Enhance.\(UUID().uuidString)")!
        XCTAssertEqual(EnhancementSettings.profile(for: .mail, store: store).id, "mail")
        XCTAssertEqual(EnhancementSettings.profile(for: .chat, store: store).id, "chat")

        store.set("notes", forKey: EnhancementSettings.profileKey)
        XCTAssertEqual(EnhancementSettings.profile(for: .mail, store: store).id, "notes", "feste Wahl schlägt die App")
    }

    func testCustomProfilesRoundTripAndRejectEmptyOnes() {
        let store = UserDefaults(suiteName: "Enhance.\(UUID().uuidString)")!
        EnhancementProfile.saveCustom([
            EnhancementProfile(id: "a", title: "Protokoll", systemPrompt: "Mach ein Protokoll."),
            EnhancementProfile(id: "b", title: "", systemPrompt: "kein Titel"),
        ], store: store)
        let loaded = EnhancementProfile.custom(store: store)
        XCTAssertEqual(loaded.map(\.id), ["a"])
        XCTAssertTrue(loaded[0].isCustom)
        XCTAssertEqual(EnhancementProfile.all(store: store).count, EnhancementProfile.builtIn.count + 1)
    }

    func testDeadlineIsClamped() {
        let store = UserDefaults(suiteName: "Enhance.\(UUID().uuidString)")!
        XCTAssertEqual(EnhancementSettings.deadline(store), .seconds(15))
        store.set(1.0, forKey: EnhancementSettings.deadlineKey)
        XCTAssertEqual(EnhancementSettings.deadline(store), .seconds(3))
        store.set(9999.0, forKey: EnhancementSettings.deadlineKey)
        XCTAssertEqual(EnhancementSettings.deadline(store), .seconds(60))
    }
}

/// The store side of issue #1 Stufe 2: `raw_text` is what makes an enhancement
/// reversible-in-hindsight — without it nobody can tell what the model changed.
final class EnhancedDictationStoreTests: XCTestCase {
    func testRawTextIsStoredOnlyWhenSomethingWasEnhanced() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-enhance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecordingStore(directory: dir)

        try await store.saveDictation(
            text: "Ein ganz normales Diktat.",
            startedAt: Date(timeIntervalSince1970: 1000),
            duration: 2
        )
        try await store.saveDictation(
            text: "Ein überarbeitetes Diktat.",
            startedAt: Date(timeIntervalSince1970: 2000),
            duration: 2,
            enhanced: true,
            rawText: "ein ueberarbeitetes diktat"
        )

        let rows = try await store.recentDictations(limit: 10)
        XCTAssertEqual(rows[0].rawText, "ein ueberarbeitetes diktat")
        XCTAssertNil(rows[1].rawText, "ein normales Diktat hat kein Original")
    }

    /// The enhanced flag must not leak into the statistics as an engine or an
    /// app — it is neither.
    func testEnhancedDictationStillCountsNormallyInTheStatistics() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-enhance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecordingStore(directory: dir)

        try await store.saveDictation(
            text: "Vier Wörter stehen hier",
            startedAt: Date(timeIntervalSince1970: 1000),
            duration: 2,
            engine: "parakeet-v3",
            enhanced: true,
            rawText: "vier woerter stehen hier"
        )
        let rows = try await store.usageRows(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].wordCount, 4)
        XCTAssertTrue(rows[0].enhanced)
        XCTAssertEqual(rows[0].engine, "parakeet-v3")
    }
}
