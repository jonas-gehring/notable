import Foundation

/// Phase 1 of name-based speaker recognition (see `specs/speaker-naming.md`):
/// attendee-anchored, *validated* LLM relabel of diarized `"Sprecher n"` labels
/// into real names.
///
/// The diarizer mints exactly two kinds of speaker label — `"Ich"` (the mic
/// track, always the recording user) and `"Sprecher 1"`, `"Sprecher 2"`, …
/// (the diarized system track). This resolver asks the summarization provider
/// for a strict-JSON mapping `{"Sprecher 1": "Anna Weber"|null, …}`, validates
/// it hard, and applies only the survivors. Everything biases toward leaving a
/// label anonymous: **a wrong name is worse than `Sprecher n`.**
///
/// Privacy: only transcript text (and attendee first names) leave the device —
/// the same boundary summarization already crosses. No audio, no embeddings.
///
/// The pure parts (`applyMapping`, `validated`, `parseMapping`) are unit-tested
/// without a live model; `resolve` wires them to the provider.
enum SpeakerNameResolver {

    /// The mic track's label. Never remapped — the recording user is `"Ich"`,
    /// and validation enforces it both as a key and as a target name.
    static let micSpeakerLabel = "Ich"

    /// The account holder's name, tokenized. A *remote* label must never be
    /// given it: the local user is `"Ich"` by construction, so the same name
    /// showing up as a remote speaker means the model bound the name it heard
    /// spoken — "Danke, Herr Hoffmann" — to the person saying it. Observed on
    /// one-sided recordings, and the resulting label is not a near miss but a
    /// straight inversion of who said what.
    static var ownerNameTokens: Set<String> { nameTokens(in: NSFullUserName()) }

    // MARK: - Pure: apply a mapping to segments

    /// Relabels `segment.speaker` where the validated mapping supplies a name.
    ///
    /// - Never touches `"Ich"` (the mic track).
    /// - Never gives a remote label the account holder's own name.
    /// - Never touches a label absent from the mapping.
    /// - Runs the same `validated(…)` gate `resolve` uses, so a mapping that
    ///   fails validation (collision, `"Ich"` remap, invented name in strict
    ///   mode) leaves *every* label as `"Sprecher n"`.
    ///
    /// - Parameter requireVerbatim: when true (default, "strict mode"), a name
    ///   is applied only if it — or one of its name tokens — appears verbatim in
    ///   the transcript text, defending against pure invention and
    ///   attendee-only guesses.
    static func applyMapping(
        _ segments: [MeetingTranscriptSegment],
        mapping: [String: String],
        requireVerbatim: Bool = true,
        ownerTokens: Set<String> = ownerNameTokens
    ) -> [MeetingTranscriptSegment] {
        let safe = validated(
            mapping, in: segments, requireVerbatim: requireVerbatim, ownerTokens: ownerTokens
        )
        guard !safe.isEmpty else { return segments }
        return segments.map { segment in
            guard let speaker = segment.speaker, let name = safe[speaker] else { return segment }
            var relabeled = segment
            relabeled.speaker = name
            return relabeled
        }
    }

    // MARK: - Pure: validation

    /// Returns the subset of `mapping` that is safe to apply, or `[:]` if the
    /// mapping as a whole must be rejected.
    ///
    /// Reject-the-whole-mapping conditions (a signal the model guessed):
    ///   - any key is `"Ich"`, or any value resolves to `"Ich"`;
    ///   - two labels map to the same non-empty name (a collision).
    ///
    /// Drop-this-entry conditions (the rest stay):
    ///   - the label does not appear in this transcript (unknown key);
    ///   - the name is empty (the model's `null`/uncertain answer);
    ///   - strict mode is on and the name is not attested in the transcript;
    ///   - the name is the account holder's own (see ``ownerNameTokens``).
    static func validated(
        _ mapping: [String: String],
        in segments: [MeetingTranscriptSegment],
        requireVerbatim: Bool = true,
        ownerTokens: Set<String> = ownerNameTokens
    ) -> [String: String] {
        let presentLabels = Set(segments.compactMap(\.speaker))
        let transcriptTokens = requireVerbatim ? nameTokens(in: transcriptText(segments)) : []

        var result: [String: String] = [:]
        var claimedNames = Set<String>()
        for (label, rawName) in mapping {
            // The mic track is never a rename target.
            if label == micSpeakerLabel { return [:] }
            // Unknown label for this transcript — ignore, don't reject.
            guard presentLabels.contains(label) else { continue }

            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }          // null / uncertain ⇒ stay anonymous
            if name == micSpeakerLabel { return [:] }       // must never resolve *to* "Ich"

            if requireVerbatim, !nameIsAttested(name, tokens: transcriptTokens) { continue }
            // The local user is "Ich"; their name on a remote label inverts the roles.
            if !ownerTokens.isEmpty, nameIsAttested(name, tokens: ownerTokens) { continue }

            // Two labels → one name means the model could not actually tell them
            // apart. Reject everything rather than pick a coin-flip.
            if !claimedNames.insert(name.lowercased()).inserted { return [:] }
            result[label] = name
        }
        return result
    }

    // MARK: - Pure: JSON parsing

    /// Parses the model's strict-JSON reply into non-null `label → name` pairs.
    /// Tolerant of surrounding prose or code fences (takes the outermost
    /// `{ … }`). `null` values, non-string values, and malformed input all
    /// yield no entry — never a crash. Structural safety is enforced later by
    /// `validated`.
    static func parseMapping(_ raw: String) -> [String: String] {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var mapping: [String: String] = [:]
        for (label, value) in object {
            if let name = value as? String { mapping[label] = name }
        }
        return mapping
    }

    // MARK: - Provider round-trip (best-effort)

    /// Builds the prompt, calls the chosen provider, parses and validates the
    /// reply. **Best-effort:** any failure — no remote speakers, provider error,
    /// unparseable reply, failed validation — returns `[:]`, so the pipeline
    /// proceeds with `"Sprecher n"`. Naming must never break a note.
    ///
    /// - Parameters:
    ///   - segments: the diarized transcript (post `MeetingPipeline.process`).
    ///   - attendees: candidate names from the calendar event (may be empty).
    ///   - providerID: the summarization provider chosen in Settings.
    ///   - recordingID: only to book the call's spend against the meeting; the
    ///     naming itself does not need it, and a nil id still records the row.
    static func resolve(
        segments: [MeetingTranscriptSegment],
        attendees: [String],
        providerID: String,
        recordingID: String? = nil
    ) async -> [String: String] {
        let labels = remoteLabels(in: segments)
        guard !labels.isEmpty else { return [:] }

        let transcript = transcriptText(segments)
        guard !transcript.isEmpty else { return [:] }

        let user = userPrompt(labels: labels, attendees: attendees, transcript: transcript)
        do {
            let raw = try await SummarizationService.complete(
                system: systemPrompt, user: user, providerID: providerID
            )
            await UsageRecorder.record(
                raw.usage, provider: providerID,
                purpose: .speakerNaming, recordingID: recordingID
            )
            return validated(parseMapping(raw.text), in: segments)
        } catch {
            return [:]
        }
    }

    // MARK: - Prompt

    /// The strict, conservative mapping instruction (spec §4.6). German, to
    /// match the German-only summaries and the German `"Sprecher n"` labels.
    static let systemPrompt = """
    Du ordnest anonyme Sprecher-Labels echten Namen zu. Du bekommst ein Meeting-Transkript,
    in dem Sprecher als "Sprecher 1", "Sprecher 2" … erscheinen (der Aufnehmende ist "Ich"),
    und optional eine Liste eingeladener Teilnehmer.
    Ordne einem Label NUR dann einen Namen zu, wenn das Transkript dafür klare Evidenz liefert:
    - Selbstvorstellung ("ich bin/heiße X", "hier spricht X"),
    - direkte Anrede ("Danke, X", "Was meinst du, X?"),
    - eindeutige Nennung, die genau einem Sprecher zugeordnet werden kann.
    Rate NICHT. Ordne einem Label NIE einen Namen nur deshalb zu, weil er in der Teilnehmerliste steht.
    "Ich" bleibt immer "Ich" und wird nie umbenannt.
    Nutze die Teilnehmerliste nur, um die Schreibweise eines im Transkript belegten Namens zu korrigieren.
    Antworte AUSSCHLIESSLICH mit JSON: { "Sprecher 1": "Anna", "Sprecher 2": null }.
    Jedes Label aus dem Transkript muss als Schlüssel vorkommen; ohne Evidenz ist der Wert null.
    """

    static func userPrompt(labels: [String], attendees: [String], transcript: String) -> String {
        let pool = attendees.isEmpty ? "keine" : attendees.joined(separator: ", ")
        let labelList = labels.joined(separator: ", ")
        return """
        Eingeladene Teilnehmer: \(pool)
        Zu benennende Labels: \(labelList)

        Transkript:

        \(transcript)
        """
    }

    // MARK: - Helpers

    /// Distinct non-`"Ich"` speaker labels, in first-appearance order.
    static func remoteLabels(in segments: [MeetingTranscriptSegment]) -> [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for segment in segments {
            guard let speaker = segment.speaker, speaker != micSpeakerLabel else { continue }
            if seen.insert(speaker).inserted { labels.append(speaker) }
        }
        return labels
    }

    /// The `"Label: text"` transcript, exactly as the summary prompt builds it.
    static func transcriptText(_ segments: [MeetingTranscriptSegment]) -> String {
        segments
            .map { "\($0.speaker ?? "Unbekannt"): \($0.text)" }
            .joined(separator: "\n")
    }

    /// Lowercased word tokens (≥ 2 letters) in a string. Umlaut-safe: splits on
    /// non-letters, so "Grüße" tokenizes cleanly.
    static func nameTokens(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.letters.inverted)
                .filter { $0.count >= 2 }
        )
    }

    /// True if the name — or any of its ≥ 2-letter tokens — appears among the
    /// transcript tokens. Lets "tom" in the transcript attest a "Tom Berger"
    /// candidate spelling while still rejecting a wholly invented name.
    static func nameIsAttested(_ name: String, tokens transcriptTokens: Set<String>) -> Bool {
        let parts = name.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 2 }
        guard !parts.isEmpty else { return false }
        return parts.contains { transcriptTokens.contains($0) }
    }
}
