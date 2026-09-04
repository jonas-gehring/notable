import FluidAudio
import XCTest

/// The whole chain that runs after a meeting stops — everything
/// `MeetingController.produceNote` does, minus the audio capture it cannot do
/// headless: VAD + diarization + per-segment ASR (`MeetingPipeline`) → Markdown
/// projection → SQLite persistence → summarization via the provider chosen in
/// Settings → the file written into the chosen notes folder.
///
/// The narrow `MeetingPipelineE2ETests` stops at `process()`; this proves the
/// part the field failure actually hit — that a real two-speaker meeting ends
/// as a note containing BOTH an attributed transcript AND a summary, sitting in
/// the folder the user picked. Mirrors produceNote step for step (that method is
/// private and drags in AudioRecorder/EventKit, so it cannot be called directly
/// from the source-recompiled test target).
final class MeetingEndToEndTests: XCTestCase {
    private func synthesize(_ text: String, rate: Int = 175) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-e2e-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-r", String(rate), "-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw XCTSkip("`say` nicht verfügbar") }
        return try AudioConverter().resampleAudioFile(path: url.path)
    }

    func testMeetingBecomesSummarizedNoteInChosenFolder() async throws {
        // Summarization uses the user's configured provider; the subscription CLI is
        // the real one. Skip cleanly when it is not logged in/installed
        // so a machine without it still passes — but when present this exercises
        // the real CLI round trip, the exact thing that "was not summarized".
        let provider = ClaudeCodeCLIProvider()
        let cliAvailable = await provider.availability() == .available
        try XCTSkipIf(
            !cliAvailable,
            "Claude Code CLI nicht verfügbar — End-to-End-Summary übersprungen."
        )

        let sampleRate = 16_000
        let gap = [Float](repeating: 0, count: sampleRate) // 1 s of silence between turns
        func silence(_ n: Int) -> [Float] { [Float](repeating: 0, count: n) }

        // A short but real two-speaker meeting: I open, remote replies, I close.
        let mine1 = try synthesize("Welcome everyone. Today we decide the launch date for the new dashboard.")
        let remote1 = try synthesize("Thanks. I think the second week of March is realistic for the backend.")
        let mine2 = try synthesize("Good. Then I will finalize the design review by next Friday.")

        // Both tracks share one timeline; each is silent while the other speaks —
        // exactly how the two captured tracks look coming out of the recorder.
        let micTrack = mine1 + gap + silence(remote1.count) + gap + mine2
        let systemTrack = silence(mine1.count) + gap + remote1 + gap + silence(mine2.count)

        // ---- produceNote chain, step for step ----

        // 1. Transcribe + diarize.
        let transcriber = ParakeetTranscriber()
        try await transcriber.prepare()
        let segments = try await MeetingPipeline.process(
            micSamples: micTrack, systemSamples: systemTrack, transcriber: transcriber
        )
        XCTAssertFalse(segments.isEmpty, "Pipeline lieferte kein einziges Segment — genau der Feldfehler")
        XCTAssertTrue(segments.contains { $0.speaker == "Ich" }, "Mikrofonspur ('Ich') fehlt")
        XCTAssertTrue(
            segments.contains { $0.speaker?.hasPrefix("Sprecher") == true },
            "Diarisierter System-Sprecher fehlt"
        )

        let startedAt = Date(timeIntervalSince1970: 1_784_000_000)
        let title = "End-to-End Testmeeting"
        var note = MarkdownProjector.Note(
            title: title, date: startedAt, calendarEventTitle: title,
            segments: segments.map { ($0.speaker, $0.text) }, summary: nil
        )

        // 2. Write into the chosen notes folder (a throwaway temp dir stands in
        //    for whatever the folder picker persisted). Transcript first, so a
        //    summary failure can never lose it.
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-e2e-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let fileURL = folderURL.appendingPathComponent(
            MarkdownProjector.fileName(title: title, date: startedAt)
        )
        try MarkdownProjector.render(note).write(to: fileURL, atomically: true, encoding: .utf8)

        // 3. Persist to a throwaway SQLite store — never the real one.
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-e2e-db-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = RecordingStore(directory: storeDir)
        let duration = Double(max(micTrack.count, systemTrack.count)) / Double(sampleRate)
        let recording = RecordingStore.Recording(
            id: UUID().uuidString, kind: .meeting, startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration), title: title,
            calendarEventID: nil, markdownPath: fileURL.path
        )
        try await store.insertMeeting(recording, segments: segments.map {
            RecordingStore.Segment(speaker: $0.speaker, start: $0.start, end: $0.end, text: $0.text)
        })

        // 4. Summarize with the chosen provider and fold the summary back in.
        let transcriptText = segments
            .map { "\($0.speaker ?? "Unbekannt"): \($0.text)" }
            .joined(separator: "\n")
        let context = MeetingContext(title: title, date: startedAt, durationSeconds: duration)
        let summary = try await SummarizationService.summarize(
            transcript: transcriptText, context: context, providerID: provider.id
        )
        XCTAssertFalse(summary.markdown.isEmpty, "Provider lieferte eine leere Zusammenfassung")
        note.summary = summary.markdown
        try MarkdownProjector.render(note).write(to: fileURL, atomically: true, encoding: .utf8)

        // ---- What the user actually opens on disk ----
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        print("E2E_NOTE_PROBE segments=\(segments.count) summary_chars=\(summary.markdown.count) file=\(fileURL.lastPathComponent)")

        XCTAssertTrue(fileURL.path.hasPrefix(folderURL.path), "Notiz liegt nicht im gewählten Ordner")
        XCTAssertTrue(onDisk.contains("## Transkript"), "Transkript-Abschnitt fehlt in der Datei")
        XCTAssertTrue(onDisk.contains("**Ich:**"), "Attribution 'Ich' fehlt in der Datei")
        // Either heading: the summary is written in the language of the
        // *meeting*, so an English fixture legitimately produces "## Summary".
        let summaryHeading = ["## Zusammenfassung", "## Summary"].first { onDisk.contains($0) }
        XCTAssertNotNil(summaryHeading, "Zusammenfassung-Abschnitt fehlt in der Datei")
        // Duplicate-heading regression is covered deterministically in
        // MarkdownProjectorTests (the LLM's exact heading wording varies, so it
        // is the wrong thing to count here).
        let afterSummary = onDisk.components(separatedBy: summaryHeading ?? "## Zusammenfassung").last ?? ""
        XCTAssertGreaterThan(
            afterSummary.trimmingCharacters(in: .whitespacesAndNewlines).count, 20,
            "Zusammenfassung-Abschnitt steht in der Datei, ist aber leer"
        )
    }
}
